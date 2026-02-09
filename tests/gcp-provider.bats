#!/usr/bin/env bats

setup() {
  load "${BATS_PLUGIN_PATH}/load.bash"

  export BUILDKITE_PIPELINE_SLUG=testpipe
  export BUILDKITE_PLUGIN_SECRETS_PROVIDER=gcp
  export BUILDKITE_PLUGIN_SECRETS_RETRY_BASE_DELAY=0
  export BUILDKITE_PLUGIN_SECRETS_SKIP_REDACTION=true
  export BUILDKITE_PLUGIN_SECRETS_GCP_PROJECT=test-project

  # Create mock binaries for dependency checks
  TEST_TEMP_DIR=$(mktemp -d)

  cat <<'EOF' >"$TEST_TEMP_DIR/buildkite-agent"
#!/bin/bash
exit 0
EOF
  chmod +x "$TEST_TEMP_DIR/buildkite-agent"

  cat <<'EOF' >"$TEST_TEMP_DIR/gcloud"
#!/bin/bash
exit 0
EOF
  chmod +x "$TEST_TEMP_DIR/gcloud"

  # Append to end of PATH so bats-mock stubs take precedence over manual mocks
  export PATH="$PATH:$TEST_TEMP_DIR"
}

teardown() {
  rm -rf "$TEST_TEMP_DIR"
}

@test "GCP: Fails when gcloud is missing" {
  local tmp
  tmp=$(mktemp -d)

  cat <<'EOF' >"$tmp/dirname"
#!/bin/bash
/usr/bin/dirname "$@"
EOF
  cat <<'EOF' >"$tmp/buildkite-agent"
#!/bin/bash
exit 0
EOF
  chmod +x "$tmp/dirname" "$tmp/buildkite-agent"

  run env PATH="$tmp" BUILDKITE_PLUGIN_SECRETS_PROVIDER=gcp /bin/bash -c "$PWD/hooks/environment"

  assert_failure
  assert_output --partial "gcloud CLI is required"
  assert_output --partial "Missing required dependencies"

  rm -rf "$tmp"
}

@test "GCP: Fails when GCP project not configured" {
  unset BUILDKITE_PLUGIN_SECRETS_GCP_PROJECT
  unset CLOUDSDK_CORE_PROJECT

  stub gcloud "config get-value project : echo ''"

  run bash -c "$PWD/hooks/environment"

  assert_failure
  assert_output --partial "GCP project not configured"
  unstub gcloud
}

@test "GCP: Download single variable" {
  export BUILDKITE_PLUGIN_SECRETS_VARIABLES_API_KEY="my-api-secret"

  stub gcloud \
    "secrets versions access latest --secret=my-api-secret --project=test-project : echo secret-value-123"

  run bash -c "source $PWD/hooks/environment && echo API_KEY=\$API_KEY"

  assert_success
  assert_output --partial "API_KEY=secret-value-123"
  unstub gcloud
}

@test "GCP: Download multiple variables" {
  export BUILDKITE_PLUGIN_SECRETS_VARIABLES_API_KEY="api-secret"
  export BUILDKITE_PLUGIN_SECRETS_VARIABLES_DB_PASS="db-secret"

  stub gcloud \
    "secrets versions access latest --secret=api-secret --project=test-project : echo api-value" \
    "secrets versions access latest --secret=db-secret --project=test-project : echo db-value"

  run bash -c "source $PWD/hooks/environment && echo API_KEY=\$API_KEY && echo DB_PASS=\$DB_PASS"

  assert_success
  assert_output --partial "API_KEY=api-value"
  assert_output --partial "DB_PASS=db-value"
  unstub gcloud
}

@test "GCP: Download batch env secrets (base64)" {
  export TESTDATA=$(echo -e "FOO=bar\nBAR=Baz\nSECRET=llamas" | base64)
  export BUILDKITE_PLUGIN_SECRETS_ENV="env-secrets"

  stub gcloud \
    "secrets versions access latest --secret=env-secrets --project=test-project : echo \${TESTDATA}"

  run bash -c "source $PWD/hooks/environment && echo FOO=\$FOO && echo BAR=\$BAR && echo SECRET=\$SECRET"

  assert_success
  assert_output --partial "FOO=bar"
  assert_output --partial "BAR=Baz"
  assert_output --partial "SECRET=llamas"
  unstub gcloud
}

@test "GCP: No retry on NOT_FOUND errors" {
  export BUILDKITE_PLUGIN_SECRETS_VARIABLES_API_KEY="missing-secret"
  export BUILDKITE_PLUGIN_SECRETS_RETRY_MAX_ATTEMPTS=3

  stub gcloud \
    "secrets versions access latest --secret=missing-secret --project=test-project : echo 'ERROR: NOT_FOUND: Secret not found' >&2 && exit 1"

  run bash -c "$PWD/hooks/environment"

  assert_failure
  refute_output --partial "Retrying"
  unstub gcloud
}

@test "GCP: No retry on PERMISSION_DENIED errors" {
  export BUILDKITE_PLUGIN_SECRETS_VARIABLES_API_KEY="forbidden-secret"
  export BUILDKITE_PLUGIN_SECRETS_RETRY_MAX_ATTEMPTS=3

  stub gcloud \
    "secrets versions access latest --secret=forbidden-secret --project=test-project : echo 'ERROR: PERMISSION_DENIED: Access denied' >&2 && exit 1"

  run bash -c "$PWD/hooks/environment"

  assert_failure
  refute_output --partial "Retrying"
  unstub gcloud
}

@test "GCP: Retry on UNAVAILABLE errors" {
  export BUILDKITE_PLUGIN_SECRETS_VARIABLES_API_KEY="flaky-secret"
  export BUILDKITE_PLUGIN_SECRETS_RETRY_MAX_ATTEMPTS=3

  stub gcloud \
    "secrets versions access latest --secret=flaky-secret --project=test-project : echo 'ERROR: UNAVAILABLE: Service unavailable' >&2 && exit 1" \
    "secrets versions access latest --secret=flaky-secret --project=test-project : echo secret-value"

  run bash -c "source $PWD/hooks/environment && echo API_KEY=\$API_KEY"

  assert_success
  assert_output --partial "Retrying"
  assert_output --partial "API_KEY=secret-value"
  unstub gcloud
}

@test "GCP: Fails after max retry attempts" {
  export BUILDKITE_PLUGIN_SECRETS_VARIABLES_API_KEY="always-failing"
  export BUILDKITE_PLUGIN_SECRETS_RETRY_MAX_ATTEMPTS=3

  stub gcloud \
    "secrets versions access latest --secret=always-failing --project=test-project : echo 'ERROR: UNAVAILABLE' >&2 && exit 1" \
    "secrets versions access latest --secret=always-failing --project=test-project : echo 'ERROR: UNAVAILABLE' >&2 && exit 1" \
    "secrets versions access latest --secret=always-failing --project=test-project : echo 'ERROR: UNAVAILABLE' >&2 && exit 1"

  run bash -c "$PWD/hooks/environment"

  assert_failure
  assert_output --partial "after 3 attempts"
  unstub gcloud
}

@test "GCP: Uses CLOUDSDK_CORE_PROJECT as fallback" {
  unset BUILDKITE_PLUGIN_SECRETS_GCP_PROJECT
  export CLOUDSDK_CORE_PROJECT="fallback-project"
  export BUILDKITE_PLUGIN_SECRETS_VARIABLES_API_KEY="my-secret"

  stub gcloud \
    "secrets versions access latest --secret=my-secret --project=fallback-project : echo secret-from-fallback"

  run bash -c "source $PWD/hooks/environment && echo API_KEY=\$API_KEY"

  assert_success
  assert_output --partial "API_KEY=secret-from-fallback"
  unstub gcloud
}

@test "GCP: Skips invalid variable names in decoded secrets" {
  export TESTDATA=$(echo -e "VALID=goodvalue\n0INVALID=badvalue\nALSO_VALID=anothervalue" | base64)
  export BUILDKITE_PLUGIN_SECRETS_ENV="env-secrets"

  stub gcloud \
    "secrets versions access latest --secret=env-secrets --project=test-project : echo \${TESTDATA}"

  run bash -c "source $PWD/hooks/environment && echo VALID=\$VALID && echo ALSO_VALID=\$ALSO_VALID"

  assert_success
  assert_output --partial "VALID=goodvalue"
  assert_output --partial "ALSO_VALID=anothervalue"
  assert_output --partial "Skipping invalid variable name"
  assert_output --partial "0INVALID"
  unstub gcloud
}

@test "GCP: Redacts secrets when redaction is not skipped" {
  export BUILDKITE_PLUGIN_SECRETS_VARIABLES_API_KEY="api-secret"
  unset BUILDKITE_PLUGIN_SECRETS_SKIP_REDACTION

  # Replace buildkite-agent mock with one that supports redaction
  rm -f "$TEST_TEMP_DIR/buildkite-agent"
  cat <<'AGENT_EOF' >"$TEST_TEMP_DIR/buildkite-agent"
#!/bin/bash
if [[ "$1" == "redactor" && "$2" == "add" ]]; then
  if [[ "$3" == "--help" ]]; then
    echo "usage info"
    exit 0
  fi
  cat >/dev/null
  exit 0
fi
exit 0
AGENT_EOF
  chmod +x "$TEST_TEMP_DIR/buildkite-agent"

  stub gcloud \
    "secrets versions access latest --secret=api-secret --project=test-project : echo super-secret-value"

  run bash -c "$PWD/hooks/environment"

  assert_success
  assert_output --partial "Redacting"
  assert_output --partial "secret(s)"
  unstub gcloud
}

@test "GCP: Rejects invalid secret IDs" {
  export BUILDKITE_PLUGIN_SECRETS_VARIABLES_API_KEY="invalid secret/name!"

  run bash -c "$PWD/hooks/environment"

  assert_failure
  assert_output --partial "Invalid GCP secret ID"
}
