#!/usr/bin/env bats

setup() {
  load "${BATS_PLUGIN_PATH}/load.bash"

  export BUILDKITE_PIPELINE_SLUG=testpipe
  export BUILDKITE_PLUGIN_SECRETS_PROVIDER="gcp"
  export BUILDKITE_PLUGIN_SECRETS_GCP_PROJECT="test-project"
  export BUILDKITE_PLUGIN_SECRETS_RETRY_BASE_DELAY=0
  export BUILDKITE_PLUGIN_SECRETS_SKIP_REDACTION=true

  # Create a mock buildkite-agent in a temp directory
  TEST_TEMP_DIR="$(mktemp -d)"
  cat <<'EOF' >"$TEST_TEMP_DIR/buildkite-agent"
#!/bin/bash
exit 0
EOF
  chmod +x "$TEST_TEMP_DIR/buildkite-agent"
  export PATH="$TEST_TEMP_DIR:$PATH"
}

teardown() {
  if [[ -n "$TEST_TEMP_DIR" ]] && [[ -d "$TEST_TEMP_DIR" ]]; then
    rm -rf "$TEST_TEMP_DIR"
  fi
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

  run env PATH="$tmp" /bin/bash -c "$PWD/hooks/environment"

  assert_failure
  assert_output --partial "gcloud CLI is required for GCP Secret Manager"
}

@test "GCP: Fails when GCP project not configured" {
  unset BUILDKITE_PLUGIN_SECRETS_GCP_PROJECT
  unset CLOUDSDK_CORE_PROJECT

  stub gcloud "config get-value project : echo '' && exit 1"

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
  export BUILDKITE_PLUGIN_SECRETS_VARIABLES_DB_PASSWORD="db-secret"

  stub gcloud \
    "secrets versions access latest --secret=api-secret --project=test-project : echo api-key-value" \
    "secrets versions access latest --secret=db-secret --project=test-project : echo db-pass-value"

  run bash -c "source $PWD/hooks/environment && echo API_KEY=\$API_KEY && echo DB_PASSWORD=\$DB_PASSWORD"

  assert_success
  assert_output --partial "API_KEY=api-key-value"
  assert_output --partial "DB_PASSWORD=db-pass-value"
  unstub gcloud
}

@test "GCP: Download batch env secrets (base64 encoded)" {
  export TESTDATA="Rk9PPWJhcgpCQVI9QmF6ClNFQ1JFVD1sbGFtYXMK"
  export BUILDKITE_PLUGIN_SECRETS_ENV="batch-secrets"

  stub gcloud \
    "secrets versions access latest --secret=batch-secrets --project=test-project : echo ${TESTDATA}"

  run bash -c "source $PWD/hooks/environment && echo FOO=\$FOO && echo BAR=\$BAR && echo SECRET=\$SECRET"

  assert_success
  assert_output --partial "FOO=bar"
  assert_output --partial "BAR=Baz"
  assert_output --partial "SECRET=llamas"
  unstub gcloud
}

@test "GCP: Fails when secret not found" {
  export BUILDKITE_PLUGIN_SECRETS_VARIABLES_API_KEY="missing-secret"

  stub gcloud \
    "secrets versions access latest --secret=missing-secret --project=test-project : echo 'NOT_FOUND: Secret not found' >&2 && exit 1"

  run bash -c "$PWD/hooks/environment"

  assert_failure
  assert_output --partial "Unable to find GCP secret"
  unstub gcloud
}

@test "GCP: No retry on 404 (NOT_FOUND)" {
  export BUILDKITE_PLUGIN_SECRETS_VARIABLES_API_KEY="missing-secret"
  export BUILDKITE_PLUGIN_SECRETS_RETRY_MAX_ATTEMPTS=3

  stub gcloud \
    "secrets versions access latest --secret=missing-secret --project=test-project : echo 'NOT_FOUND: Secret not found' >&2 && exit 1"

  run bash -c "$PWD/hooks/environment"

  assert_failure
  refute_output --partial "Retrying"
  unstub gcloud
}

@test "GCP: No retry on 403 (PERMISSION_DENIED)" {
  export BUILDKITE_PLUGIN_SECRETS_VARIABLES_API_KEY="forbidden-secret"
  export BUILDKITE_PLUGIN_SECRETS_RETRY_MAX_ATTEMPTS=3

  stub gcloud \
    "secrets versions access latest --secret=forbidden-secret --project=test-project : echo 'PERMISSION_DENIED: Access denied' >&2 && exit 1"

  run bash -c "$PWD/hooks/environment"

  assert_failure
  refute_output --partial "Retrying"
  unstub gcloud
}

@test "GCP: Retry on transient failure (UNAVAILABLE)" {
  export BUILDKITE_PLUGIN_SECRETS_VARIABLES_API_KEY="flaky-secret"
  export BUILDKITE_PLUGIN_SECRETS_RETRY_MAX_ATTEMPTS=3

  stub gcloud \
    "secrets versions access latest --secret=flaky-secret --project=test-project : echo 'UNAVAILABLE: Service unavailable' >&2 && exit 1" \
    "secrets versions access latest --secret=flaky-secret --project=test-project : echo 'UNAVAILABLE: Service unavailable' >&2 && exit 1" \
    "secrets versions access latest --secret=flaky-secret --project=test-project : echo secret-value"

  run bash -c "source $PWD/hooks/environment && echo API_KEY=\$API_KEY"

  assert_success
  assert_output --partial "attempt 1/3"
  assert_output --partial "attempt 2/3"
  assert_output --partial "API_KEY=secret-value"
  unstub gcloud
}

@test "GCP: Fails after max retry attempts" {
  export BUILDKITE_PLUGIN_SECRETS_VARIABLES_API_KEY="always-failing"
  export BUILDKITE_PLUGIN_SECRETS_RETRY_MAX_ATTEMPTS=3

  stub gcloud \
    "secrets versions access latest --secret=always-failing --project=test-project : echo 'UNAVAILABLE' >&2 && exit 1" \
    "secrets versions access latest --secret=always-failing --project=test-project : echo 'UNAVAILABLE' >&2 && exit 1" \
    "secrets versions access latest --secret=always-failing --project=test-project : echo 'UNAVAILABLE' >&2 && exit 1"

  run bash -c "$PWD/hooks/environment"

  assert_failure
  assert_output --partial "Failed to fetch GCP secret always-failing after 3 attempts"
  unstub gcloud
}

@test "GCP: Uses CLOUDSDK_CORE_PROJECT when gcp-project not set" {
  unset BUILDKITE_PLUGIN_SECRETS_GCP_PROJECT
  export CLOUDSDK_CORE_PROJECT="env-project"
  export BUILDKITE_PLUGIN_SECRETS_VARIABLES_API_KEY="my-secret"

  stub gcloud \
    "secrets versions access latest --secret=my-secret --project=env-project : echo secret-value"

  run bash -c "source $PWD/hooks/environment && echo API_KEY=\$API_KEY"

  assert_success
  assert_output --partial "API_KEY=secret-value"
  unstub gcloud
}

@test "GCP: Skip invalid variable names in decoded secrets" {
  export TESTDATA=$(echo -e "VALID=goodvalue\n0INVALID=badvalue\nALSO_VALID=anothervalue" | base64)
  export BUILDKITE_PLUGIN_SECRETS_ENV="env"

  stub gcloud \
    "secrets versions access latest --secret=env --project=test-project : echo \${TESTDATA}"

  run bash -c "source $PWD/hooks/environment && echo VALID=\$VALID && echo ALSO_VALID=\$ALSO_VALID"

  assert_success
  assert_output --partial "VALID=goodvalue"
  assert_output --partial "ALSO_VALID=anothervalue"
  assert_output --partial "Skipping invalid variable name"
  assert_output --partial "0INVALID"
  unstub gcloud
}

@test "GCP: Redact secrets when redaction is enabled" {
  export BUILDKITE_PLUGIN_SECRETS_VARIABLES_API_KEY="my-secret"
  unset BUILDKITE_PLUGIN_SECRETS_SKIP_REDACTION

  # Remove mock buildkite-agent from PATH so stub takes full control
  rm -f "$TEST_TEMP_DIR/buildkite-agent"

  stub gcloud \
    "secrets versions access latest --secret=my-secret --project=test-project : echo secret-value"
  stub buildkite-agent \
    "redactor add --help : echo 'usage info' && exit 0" \
    "redactor add : cat"

  run bash -c "$PWD/hooks/environment"

  assert_success
  assert_output --partial "Redacting"
  unstub gcloud
  unstub buildkite-agent
}
