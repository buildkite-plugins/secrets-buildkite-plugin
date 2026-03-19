#!/usr/bin/env bats

setup() {
  load "${BATS_PLUGIN_PATH}/load.bash"

  export BUILDKITE_PIPELINE_SLUG=testpipe
  export BUILDKITE_PLUGIN_SECRETS_PROVIDER="op"
  export BUILDKITE_PLUGIN_SECRETS_RETRY_BASE_DELAY=0
  export BUILDKITE_PLUGIN_SECRETS_RETRY_MAX_ATTEMPTS=3
  export BUILDKITE_PLUGIN_SECRETS_SKIP_REDACTION=true
  export OP_SERVICE_ACCOUNT_TOKEN="test-token"

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

@test "1Password: Fails when op CLI is missing" {
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
    BUILDKITE_PLUGIN_SECRETS_PROVIDER="op" \
    OP_SERVICE_ACCOUNT_TOKEN="test-token" \
    BUILDKITE_PLUGIN_SECRETS_VARIABLES_API_KEY="op://vault/item/field" \
    /bin/bash -c "$PWD/hooks/environment"

  assert_failure
  assert_output --partial "1Password CLI (op) is required"
  assert_output --partial "Missing required dependencies: op"
}

@test "1Password: Fails when no auth credentials and no active session" {
  unset OP_SERVICE_ACCOUNT_TOKEN

  stub op \
    "account list --format=json : exit 1" \
    "* : exit 1"

  run bash -c "unset OP_SERVICE_ACCOUNT_TOKEN; unset OP_CONNECT_HOST; unset OP_CONNECT_TOKEN; $PWD/hooks/environment"

  assert_failure
  assert_output --partial "No 1Password authentication found"

  unstub op || true
}

@test "1Password: Succeeds auth check with Connect Server credentials" {
  unset OP_SERVICE_ACCOUNT_TOKEN
  export OP_CONNECT_HOST="https://connect.example.com"
  export OP_CONNECT_TOKEN="test-connect-token"
  export BUILDKITE_PLUGIN_SECRETS_VARIABLES_API_KEY="op://my-vault/my-item/api-key"

  stub op "read op://my-vault/my-item/api-key : echo connect-secret-value"

  run bash -c "source $PWD/hooks/environment && echo API_KEY=\$API_KEY"

  assert_success
  assert_output --partial "API_KEY=connect-secret-value"
  unstub op
}

@test "1Password: Download single variable" {
  export BUILDKITE_PLUGIN_SECRETS_VARIABLES_API_KEY="op://my-vault/my-item/api-key"

  stub op "read op://my-vault/my-item/api-key : echo secret-value-123"

  run bash -c "source $PWD/hooks/environment && echo API_KEY=\$API_KEY"

  assert_success
  assert_output --partial "API_KEY=secret-value-123"
  unstub op
}

@test "1Password: Download multiple variables" {
  export BUILDKITE_PLUGIN_SECRETS_VARIABLES_API_KEY="op://vault/item/api-key"
  export BUILDKITE_PLUGIN_SECRETS_VARIABLES_DB_PASS="op://vault/item/db-pass"
  export BUILDKITE_PLUGIN_SECRETS_VARIABLES_TOKEN="op://vault/item/token"

  stub op \
    "read op://vault/item/api-key : echo secret-key-123" \
    "read op://vault/item/db-pass : echo db-pass-456" \
    "read op://vault/item/token : echo token-789"

  run bash -c "source $PWD/hooks/environment && echo API_KEY=\$API_KEY && echo DB_PASS=\$DB_PASS && echo TOKEN=\$TOKEN"

  assert_success
  assert_output --partial "API_KEY=secret-key-123"
  assert_output --partial "DB_PASS=db-pass-456"
  assert_output --partial "TOKEN=token-789"
  unstub op
}

@test "1Password: Download batch env secrets (base64)" {
  export TESTDATA="Rk9PPWJhcgpTRUNSRVRfS0VZPWxsYW1hcwpDT0ZGRUU9bW9yZQo="
  export BUILDKITE_PLUGIN_SECRETS_ENV="op://my-vault/batch/env"

  stub op "read op://my-vault/batch/env : echo \${TESTDATA}"

  run bash -c "source $PWD/hooks/environment && echo FOO=\$FOO && echo SECRET_KEY=\$SECRET_KEY && echo COFFEE=\$COFFEE"

  assert_success
  assert_output --partial "FOO=bar"
  assert_output --partial "SECRET_KEY=llamas"
  assert_output --partial "COFFEE=more"
  unstub op
}

@test "1Password: No retry on item not found" {
  export BUILDKITE_PLUGIN_SECRETS_VARIABLES_API_KEY="op://vault/missing/field"

  stub op "read op://vault/missing/field : echo \"[ERROR] 2024/01/01 00:00:00 isn't an item in the vault\" >&2 && exit 1"

  run bash -c "$PWD/hooks/environment"

  assert_failure
  refute_output --partial "Retrying"
  unstub op
}

@test "1Password: No retry on unauthorized" {
  export BUILDKITE_PLUGIN_SECRETS_VARIABLES_API_KEY="op://vault/item/field"

  stub op "read op://vault/item/field : echo '[ERROR] unauthorized' >&2 && exit 1"

  run bash -c "$PWD/hooks/environment"

  assert_failure
  refute_output --partial "Retrying"
  unstub op
}

@test "1Password: Retry on transient error then succeed" {
  export BUILDKITE_PLUGIN_SECRETS_VARIABLES_API_KEY="op://vault/item/field"

  stub op \
    "read op://vault/item/field : echo 'connection error' >&2 && exit 1" \
    "read op://vault/item/field : echo 'connection error' >&2 && exit 1" \
    "read op://vault/item/field : echo recovered-value"

  run bash -c "source $PWD/hooks/environment && echo API_KEY=\$API_KEY"

  assert_success
  assert_output --partial "Failed to fetch secret op://vault/item/field (attempt 1/3)"
  assert_output --partial "Failed to fetch secret op://vault/item/field (attempt 2/3)"
  assert_output --partial "API_KEY=recovered-value"
  unstub op
}

@test "1Password: Fails after max retry attempts" {
  export BUILDKITE_PLUGIN_SECRETS_VARIABLES_API_KEY="op://vault/item/field"

  stub op \
    "read op://vault/item/field : echo 'Server Error' >&2 && exit 1" \
    "read op://vault/item/field : echo 'Server Error' >&2 && exit 1" \
    "read op://vault/item/field : echo 'Server Error' >&2 && exit 1"

  run bash -c "$PWD/hooks/environment"

  assert_failure
  assert_output --partial "Failed to fetch secret op://vault/item/field after 3 attempts"
  unstub op
}

@test "1Password: Rejects invalid secret references" {
  export BUILDKITE_PLUGIN_SECRETS_VARIABLES_API_KEY="not-an-op-reference"

  cat <<'MOCK' > "$TEST_TEMP_DIR/op"
#!/bin/bash
echo "ERROR: should not be called" >&2
exit 1
MOCK
  chmod +x "$TEST_TEMP_DIR/op"

  run bash -c "$PWD/hooks/environment"

  assert_failure
  assert_output --partial "Invalid 1Password secret reference"
}

@test "1Password: Skips invalid variable names in decoded secrets" {
  export TESTDATA
  TESTDATA=$(echo -e "VALID=goodvalue\n0INVALID=badvalue\nALSO_VALID=anothervalue" | base64)
  export BUILDKITE_PLUGIN_SECRETS_ENV="op://vault/batch/env"

  stub op "read op://vault/batch/env : echo \${TESTDATA}"

  run bash -c "source $PWD/hooks/environment && echo VALID=\$VALID && echo ALSO_VALID=\$ALSO_VALID"

  assert_success
  assert_output --partial "VALID=goodvalue"
  assert_output --partial "ALSO_VALID=anothervalue"
  assert_output --partial "Skipping invalid variable name"
  assert_output --partial "0INVALID"
  unstub op
}

@test "1Password: Redacts secrets when enabled" {
  export BUILDKITE_PLUGIN_SECRETS_VARIABLES_API_KEY="op://vault/item/api-key"
  unset BUILDKITE_PLUGIN_SECRETS_SKIP_REDACTION

  stub op "read op://vault/item/api-key : echo secret-value-123"

  stub buildkite-agent \
    "redactor add --help : echo 'usage info' && exit 0" \
    "redactor add : cat"

  run bash -c "$PWD/hooks/environment"

  assert_success
  assert_output --partial "Redacting"
  assert_output --partial "secret(s)"
  unstub op
  unstub buildkite-agent
}

@test "1Password: Combined env and variables usage" {
  export TESTDATA
  TESTDATA=$(echo -e "FOO=bar\nBAR=baz" | base64)
  export BUILDKITE_PLUGIN_SECRETS_ENV="op://vault/batch/env"
  export BUILDKITE_PLUGIN_SECRETS_VARIABLES_API_KEY="op://vault/item/api-key"

  stub op \
    "read op://vault/batch/env : echo \${TESTDATA}" \
    "read op://vault/item/api-key : echo individual-secret-value"

  run bash -c "source $PWD/hooks/environment && echo FOO=\$FOO && echo BAR=\$BAR && echo API_KEY=\$API_KEY"

  assert_success
  assert_output --partial "FOO=bar"
  assert_output --partial "BAR=baz"
  assert_output --partial "API_KEY=individual-secret-value"
  unstub op
}

@test "1Password: Fails on invalid base64 in env secret" {
  export BUILDKITE_PLUGIN_SECRETS_ENV="op://vault/batch/env"

  stub op "read op://vault/batch/env : echo '!@#\$%^&*'"

  run bash -c "$PWD/hooks/environment"

  assert_failure
  assert_output --partial "Failed to decode base64 secret"
  unstub op
}

@test "1Password: Fails on whitespace-only decoded env secret" {
  export WHITESPACE_B64
  WHITESPACE_B64=$(printf '   \n' | base64)
  export BUILDKITE_PLUGIN_SECRETS_ENV="op://vault/batch/env"

  stub op "read op://vault/batch/env : echo \${WHITESPACE_B64}"

  run bash -c "$PWD/hooks/environment"

  assert_failure
  assert_output --partial "empty or contains only whitespace"
  unstub op
}
