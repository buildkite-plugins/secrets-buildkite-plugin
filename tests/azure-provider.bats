#!/usr/bin/env bats

setup() {
  load "${BATS_PLUGIN_PATH}/load.bash"

  export BUILDKITE_PIPELINE_SLUG=testpipe
  export BUILDKITE_PLUGIN_SECRETS_PROVIDER="azure"
  export BUILDKITE_PLUGIN_SECRETS_AZURE_VAULT_NAME="my-vault"
  export BUILDKITE_PLUGIN_SECRETS_RETRY_BASE_DELAY=0
  export BUILDKITE_PLUGIN_SECRETS_RETRY_MAX_ATTEMPTS=3
  export BUILDKITE_PLUGIN_SECRETS_SKIP_REDACTION=true

  # Create a temp directory for manual mocks
  TEST_TEMP_DIR=$(mktemp -d)

  # Create a manual buildkite-agent mock that always succeeds
  cat <<'MOCK' > "$TEST_TEMP_DIR/buildkite-agent"
#!/bin/bash
exit 0
MOCK
  chmod +x "$TEST_TEMP_DIR/buildkite-agent"

  # Append temp dir to END of PATH so bats-mock stubs take precedence
  export PATH="$PATH:$TEST_TEMP_DIR"
}

teardown() {
  rm -rf "$TEST_TEMP_DIR"
}

@test "Azure: Fails when az CLI is missing" {
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

  run env PATH="$tmp" \
    BUILDKITE_PLUGIN_SECRETS_PROVIDER="azure" \
    BUILDKITE_PLUGIN_SECRETS_AZURE_VAULT_NAME="my-vault" \
    BUILDKITE_PLUGIN_SECRETS_VARIABLES_FOO="bar" \
    /bin/bash -c "$PWD/hooks/environment"

  assert_failure
  assert_output --partial "Azure CLI (az) is required"
  assert_output --partial "Missing required dependencies: az"
}

@test "Azure: Fails when azure-vault-name is not set" {
  stub az ""

  unset BUILDKITE_PLUGIN_SECRETS_AZURE_VAULT_NAME

  run bash -c "BUILDKITE_PLUGIN_SECRETS_AZURE_VAULT_NAME='' $PWD/hooks/environment"

  assert_failure
  assert_output --partial "azure-vault-name is required"

  unstub az || true
}

@test "Azure: Download single variable" {
  export BUILDKITE_PLUGIN_SECRETS_VARIABLES_API_KEY="my-api-key"

  stub az "keyvault secret show --vault-name my-vault --name my-api-key --query value -o tsv : echo secret-value-123"

  run bash -c "source $PWD/hooks/environment && echo API_KEY=\$API_KEY"

  assert_success
  assert_output --partial "API_KEY=secret-value-123"
  unstub az
}

@test "Azure: Download multiple variables" {
  export BUILDKITE_PLUGIN_SECRETS_VARIABLES_API_KEY="my-api-key"
  export BUILDKITE_PLUGIN_SECRETS_VARIABLES_DB_PASS="db-password"
  export BUILDKITE_PLUGIN_SECRETS_VARIABLES_TOKEN="auth-token"

  stub az \
    "keyvault secret show --vault-name my-vault --name my-api-key --query value -o tsv : echo secret-key-123" \
    "keyvault secret show --vault-name my-vault --name db-password --query value -o tsv : echo db-pass-456" \
    "keyvault secret show --vault-name my-vault --name auth-token --query value -o tsv : echo token-789"

  run bash -c "source $PWD/hooks/environment && echo API_KEY=\$API_KEY && echo DB_PASS=\$DB_PASS && echo TOKEN=\$TOKEN"

  assert_success
  assert_output --partial "API_KEY=secret-key-123"
  assert_output --partial "DB_PASS=db-pass-456"
  assert_output --partial "TOKEN=token-789"
  unstub az
}

@test "Azure: Download batch env secrets (base64)" {
  export TESTDATA="Rk9PPWJhcgpTRUNSRVRfS0VZPWxsYW1hcwpDT0ZGRUU9bW9yZQo="
  export BUILDKITE_PLUGIN_SECRETS_ENV="batch-secrets"

  stub az "keyvault secret show --vault-name my-vault --name batch-secrets --query value -o tsv : echo \${TESTDATA}"

  run bash -c "source $PWD/hooks/environment && echo FOO=\$FOO && echo SECRET_KEY=\$SECRET_KEY && echo COFFEE=\$COFFEE"

  assert_success
  assert_output --partial "FOO=bar"
  assert_output --partial "SECRET_KEY=llamas"
  assert_output --partial "COFFEE=more"
  unstub az
}

@test "Azure: No retry on SecretNotFound" {
  export BUILDKITE_PLUGIN_SECRETS_VARIABLES_API_KEY="missing-secret"

  stub az "keyvault secret show --vault-name my-vault --name missing-secret --query value -o tsv : echo 'ERROR: SecretNotFound' >&2 && exit 1"

  run bash -c "$PWD/hooks/environment"

  assert_failure
  refute_output --partial "Retrying"
  unstub az
}

@test "Azure: No retry on Forbidden" {
  export BUILDKITE_PLUGIN_SECRETS_VARIABLES_API_KEY="forbidden-secret"

  stub az "keyvault secret show --vault-name my-vault --name forbidden-secret --query value -o tsv : echo 'ERROR: Forbidden (403)' >&2 && exit 1"

  run bash -c "$PWD/hooks/environment"

  assert_failure
  refute_output --partial "Retrying"
  unstub az
}

@test "Azure: Retry on service unavailable then succeed" {
  export BUILDKITE_PLUGIN_SECRETS_VARIABLES_API_KEY="my-secret"

  stub az \
    "keyvault secret show --vault-name my-vault --name my-secret --query value -o tsv : echo 'Service Unavailable' >&2 && exit 1" \
    "keyvault secret show --vault-name my-vault --name my-secret --query value -o tsv : echo 'Service Unavailable' >&2 && exit 1" \
    "keyvault secret show --vault-name my-vault --name my-secret --query value -o tsv : echo recovered-value"

  run bash -c "source $PWD/hooks/environment && echo API_KEY=\$API_KEY"

  assert_success
  assert_output --partial "Failed to fetch secret my-secret (attempt 1/3)"
  assert_output --partial "Failed to fetch secret my-secret (attempt 2/3)"
  assert_output --partial "API_KEY=recovered-value"
  unstub az
}

@test "Azure: Fails after max retry attempts" {
  export BUILDKITE_PLUGIN_SECRETS_VARIABLES_API_KEY="flaky-secret"

  stub az \
    "keyvault secret show --vault-name my-vault --name flaky-secret --query value -o tsv : echo 'Server Error' >&2 && exit 1" \
    "keyvault secret show --vault-name my-vault --name flaky-secret --query value -o tsv : echo 'Server Error' >&2 && exit 1" \
    "keyvault secret show --vault-name my-vault --name flaky-secret --query value -o tsv : echo 'Server Error' >&2 && exit 1"

  run bash -c "$PWD/hooks/environment"

  assert_failure
  assert_output --partial "Failed to fetch secret flaky-secret after 3 attempts"
  unstub az
}

@test "Azure: Skips invalid variable names in decoded secrets" {
  export TESTDATA=$(echo -e "VALID=goodvalue\n0INVALID=badvalue\nALSO_VALID=anothervalue" | base64)
  export BUILDKITE_PLUGIN_SECRETS_ENV="batch-secrets"

  stub az "keyvault secret show --vault-name my-vault --name batch-secrets --query value -o tsv : echo \${TESTDATA}"

  run bash -c "source $PWD/hooks/environment && echo VALID=\$VALID && echo ALSO_VALID=\$ALSO_VALID"

  assert_success
  assert_output --partial "VALID=goodvalue"
  assert_output --partial "ALSO_VALID=anothervalue"
  assert_output --partial "Skipping invalid variable name"
  assert_output --partial "0INVALID"
  unstub az
}

@test "Azure: Redacts secrets when enabled" {
  export BUILDKITE_PLUGIN_SECRETS_VARIABLES_API_KEY="my-api-key"
  unset BUILDKITE_PLUGIN_SECRETS_SKIP_REDACTION

  # Override the manual buildkite-agent mock with a stub that handles redactor
  stub az "keyvault secret show --vault-name my-vault --name my-api-key --query value -o tsv : echo secret-value-123"

  stub buildkite-agent \
    "redactor add --help : echo 'usage info' && exit 0" \
    "redactor add : cat"

  run bash -c "$PWD/hooks/environment"

  assert_success
  assert_output --partial "Redacting"
  assert_output --partial "secret(s)"
  unstub az
  unstub buildkite-agent
}

@test "Azure: Rejects invalid secret names" {
  export BUILDKITE_PLUGIN_SECRETS_VARIABLES_API_KEY="../traversal-attempt"

  # Create a minimal az mock since az CLI must exist for dependency check to pass
  # but the validation should fail before az is actually called
  cat <<'MOCK' > "$TEST_TEMP_DIR/az"
#!/bin/bash
echo "ERROR: should not be called" >&2
exit 1
MOCK
  chmod +x "$TEST_TEMP_DIR/az"

  run bash -c "$PWD/hooks/environment"

  assert_failure
  assert_output --partial "Invalid Azure secret name"
}

@test "Azure: Uses azure-secret-version when specified" {
  export BUILDKITE_PLUGIN_SECRETS_VARIABLES_API_KEY="my-api-key"
  export BUILDKITE_PLUGIN_SECRETS_AZURE_SECRET_VERSION="abc123def456"

  stub az "keyvault secret show --vault-name my-vault --name my-api-key --query value -o tsv --version abc123def456 : echo versioned-secret-value"

  run bash -c "source $PWD/hooks/environment && echo API_KEY=\$API_KEY"

  assert_success
  assert_output --partial "API_KEY=versioned-secret-value"
  unstub az
}
