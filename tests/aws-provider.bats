#!/usr/bin/env bats

setup() {
  load "${BATS_PLUGIN_PATH}/load.bash"

  export BUILDKITE_PIPELINE_SLUG=testpipe
  export BUILDKITE_PLUGIN_SECRETS_PROVIDER=aws
  export BUILDKITE_PLUGIN_SECRETS_RETRY_BASE_DELAY=0
  export BUILDKITE_PLUGIN_SECRETS_SKIP_REDACTION=true

  # Create mock binaries for dependency checks
  TEST_TEMP_DIR=$(mktemp -d)

  cat <<'EOF' >"$TEST_TEMP_DIR/buildkite-agent"
#!/bin/bash
exit 0
EOF
  chmod +x "$TEST_TEMP_DIR/buildkite-agent"

  cat <<'EOF' >"$TEST_TEMP_DIR/aws"
#!/bin/bash
exit 0
EOF
  chmod +x "$TEST_TEMP_DIR/aws"

  # Append to end of PATH so bats-mock stubs take precedence over manual mocks
  export PATH="$PATH:$TEST_TEMP_DIR"
}

teardown() {
  rm -rf "$TEST_TEMP_DIR"
}

@test "AWS: Fails when aws CLI is missing" {
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

  run env PATH="$tmp" BUILDKITE_PLUGIN_SECRETS_PROVIDER=aws /bin/bash -c "$PWD/hooks/environment"

  assert_failure
  assert_output --partial "AWS CLI (aws) is required"
  assert_output --partial "Missing required dependencies"

  rm -rf "$tmp"
}

@test "AWS: Download single variable" {
  export BUILDKITE_PLUGIN_SECRETS_VARIABLES_API_KEY="my-api-secret"

  stub aws \
    "secretsmanager get-secret-value --secret-id my-api-secret --query SecretString --output text : echo secret-value-123"

  run bash -c "source $PWD/hooks/environment && echo API_KEY=\$API_KEY"

  assert_success
  assert_output --partial "API_KEY=secret-value-123"
  unstub aws
}

@test "AWS: Download multiple variables" {
  export BUILDKITE_PLUGIN_SECRETS_VARIABLES_API_KEY="api-secret"
  export BUILDKITE_PLUGIN_SECRETS_VARIABLES_DB_PASS="db-secret"

  stub aws \
    "secretsmanager get-secret-value --secret-id api-secret --query SecretString --output text : echo api-value" \
    "secretsmanager get-secret-value --secret-id db-secret --query SecretString --output text : echo db-value"

  run bash -c "source $PWD/hooks/environment && echo API_KEY=\$API_KEY && echo DB_PASS=\$DB_PASS"

  assert_success
  assert_output --partial "API_KEY=api-value"
  assert_output --partial "DB_PASS=db-value"
  unstub aws
}

@test "AWS: Uses aws-region when specified" {
  export BUILDKITE_PLUGIN_SECRETS_VARIABLES_API_KEY="my-api-secret"
  export BUILDKITE_PLUGIN_SECRETS_AWS_REGION="us-west-2"

  stub aws \
    "secretsmanager get-secret-value --secret-id my-api-secret --query SecretString --output text --region us-west-2 : echo region-scoped-value"

  run bash -c "source $PWD/hooks/environment && echo API_KEY=\$API_KEY"

  assert_success
  assert_output --partial "API_KEY=region-scoped-value"
  unstub aws
}

@test "AWS: Uses aws-secret-version-id when specified" {
  export BUILDKITE_PLUGIN_SECRETS_VARIABLES_API_KEY="my-api-secret"
  export BUILDKITE_PLUGIN_SECRETS_AWS_SECRET_VERSION_ID="abc123"

  stub aws \
    "secretsmanager get-secret-value --secret-id my-api-secret --query SecretString --output text --version-id abc123 : echo versioned-secret-value"

  run bash -c "source $PWD/hooks/environment && echo API_KEY=\$API_KEY"

  assert_success
  assert_output --partial "API_KEY=versioned-secret-value"
  unstub aws
}

@test "AWS: Uses aws-secret-version-stage when specified" {
  export BUILDKITE_PLUGIN_SECRETS_VARIABLES_API_KEY="my-api-secret"
  export BUILDKITE_PLUGIN_SECRETS_AWS_SECRET_VERSION_STAGE="AWSPREVIOUS"

  stub aws \
    "secretsmanager get-secret-value --secret-id my-api-secret --query SecretString --output text --version-stage AWSPREVIOUS : echo previous-secret-value"

  run bash -c "source $PWD/hooks/environment && echo API_KEY=\$API_KEY"

  assert_success
  assert_output --partial "API_KEY=previous-secret-value"
  unstub aws
}

@test "AWS: Download batch env secrets (base64)" {
  export TESTDATA=$(echo -e "FOO=bar\nBAR=Baz\nSECRET=llamas" | base64)
  export BUILDKITE_PLUGIN_SECRETS_ENV="env-secrets"

  stub aws \
    "secretsmanager get-secret-value --secret-id env-secrets --query SecretString --output text : echo \${TESTDATA}"

  run bash -c "source $PWD/hooks/environment && echo FOO=\$FOO && echo BAR=\$BAR && echo SECRET=\$SECRET"

  assert_success
  assert_output --partial "FOO=bar"
  assert_output --partial "BAR=Baz"
  assert_output --partial "SECRET=llamas"
  unstub aws
}

@test "AWS: No retry on ResourceNotFoundException" {
  export BUILDKITE_PLUGIN_SECRETS_VARIABLES_API_KEY="missing-secret"
  export BUILDKITE_PLUGIN_SECRETS_RETRY_MAX_ATTEMPTS=3

  stub aws \
    "secretsmanager get-secret-value --secret-id missing-secret --query SecretString --output text : echo 'An error occurred (ResourceNotFoundException)' >&2 && exit 1"

  run bash -c "$PWD/hooks/environment"

  assert_failure
  refute_output --partial "Retrying"
  unstub aws
}

@test "AWS: No retry on AccessDeniedException" {
  export BUILDKITE_PLUGIN_SECRETS_VARIABLES_API_KEY="forbidden-secret"
  export BUILDKITE_PLUGIN_SECRETS_RETRY_MAX_ATTEMPTS=3

  stub aws \
    "secretsmanager get-secret-value --secret-id forbidden-secret --query SecretString --output text : echo 'An error occurred (AccessDeniedException)' >&2 && exit 1"

  run bash -c "$PWD/hooks/environment"

  assert_failure
  refute_output --partial "Retrying"
  unstub aws
}

@test "AWS: Retry on throttling then succeed" {
  export BUILDKITE_PLUGIN_SECRETS_VARIABLES_API_KEY="flaky-secret"
  export BUILDKITE_PLUGIN_SECRETS_RETRY_MAX_ATTEMPTS=3

  stub aws \
    "secretsmanager get-secret-value --secret-id flaky-secret --query SecretString --output text : echo 'An error occurred (ThrottlingException)' >&2 && exit 1" \
    "secretsmanager get-secret-value --secret-id flaky-secret --query SecretString --output text : echo secret-value"

  run bash -c "source $PWD/hooks/environment && echo API_KEY=\$API_KEY"

  assert_success
  assert_output --partial "Retrying"
  assert_output --partial "API_KEY=secret-value"
  unstub aws
}

@test "AWS: Fails after max retry attempts" {
  export BUILDKITE_PLUGIN_SECRETS_VARIABLES_API_KEY="always-failing"
  export BUILDKITE_PLUGIN_SECRETS_RETRY_MAX_ATTEMPTS=3

  stub aws \
    "secretsmanager get-secret-value --secret-id always-failing --query SecretString --output text : echo 'An error occurred (InternalServiceError)' >&2 && exit 1" \
    "secretsmanager get-secret-value --secret-id always-failing --query SecretString --output text : echo 'An error occurred (InternalServiceError)' >&2 && exit 1" \
    "secretsmanager get-secret-value --secret-id always-failing --query SecretString --output text : echo 'An error occurred (InternalServiceError)' >&2 && exit 1"

  run bash -c "$PWD/hooks/environment"

  assert_failure
  assert_output --partial "after 3 attempts"
  unstub aws
}

@test "AWS: Skips invalid variable names in decoded secrets" {
  export TESTDATA=$(echo -e "VALID=goodvalue\n0INVALID=badvalue\nALSO_VALID=anothervalue" | base64)
  export BUILDKITE_PLUGIN_SECRETS_ENV="env-secrets"

  stub aws \
    "secretsmanager get-secret-value --secret-id env-secrets --query SecretString --output text : echo \${TESTDATA}"

  run bash -c "source $PWD/hooks/environment && echo VALID=\$VALID && echo ALSO_VALID=\$ALSO_VALID"

  assert_success
  assert_output --partial "VALID=goodvalue"
  assert_output --partial "ALSO_VALID=anothervalue"
  assert_output --partial "Skipping invalid variable name"
  assert_output --partial "0INVALID"
  unstub aws
}

@test "AWS: Rejects invalid secret IDs" {
  export BUILDKITE_PLUGIN_SECRETS_VARIABLES_API_KEY="invalid secret!"

  run bash -c "$PWD/hooks/environment"

  assert_failure
  assert_output --partial "Invalid AWS secret ID"
}

@test "AWS: Combined env and variables usage" {
  export TESTDATA=$(echo -e "FOO=bar\nBAR=baz" | base64)
  export BUILDKITE_PLUGIN_SECRETS_ENV="env-secrets"
  export BUILDKITE_PLUGIN_SECRETS_VARIABLES_API_KEY="my-api-secret"

  stub aws \
    "secretsmanager get-secret-value --secret-id env-secrets --query SecretString --output text : echo \${TESTDATA}" \
    "secretsmanager get-secret-value --secret-id my-api-secret --query SecretString --output text : echo individual-secret-value"

  run bash -c "source $PWD/hooks/environment && echo FOO=\$FOO && echo BAR=\$BAR && echo API_KEY=\$API_KEY"

  assert_success
  assert_output --partial "FOO=bar"
  assert_output --partial "BAR=baz"
  assert_output --partial "API_KEY=individual-secret-value"
  unstub aws
}

@test "AWS: Fails on invalid base64 in env secret" {
  export BUILDKITE_PLUGIN_SECRETS_ENV="env-secrets"

  stub aws \
    "secretsmanager get-secret-value --secret-id env-secrets --query SecretString --output text : echo '!@#\$%^&*'"

  run bash -c "$PWD/hooks/environment"

  assert_failure
  assert_output --partial "Failed to decode base64 secret"
  unstub aws
}

@test "AWS: Fails on whitespace-only decoded env secret" {
  export WHITESPACE_B64
  WHITESPACE_B64=$(printf '   \n' | base64)
  export BUILDKITE_PLUGIN_SECRETS_ENV="env-secrets"

  stub aws \
    "secretsmanager get-secret-value --secret-id env-secrets --query SecretString --output text : echo \${WHITESPACE_B64}"

  run bash -c "$PWD/hooks/environment"

  assert_failure
  assert_output --partial "empty or contains only whitespace"
  unstub aws
}

@test "AWS: Redacts secrets when enabled" {
  export BUILDKITE_PLUGIN_SECRETS_VARIABLES_API_KEY="my-api-key"
  unset BUILDKITE_PLUGIN_SECRETS_SKIP_REDACTION

  stub aws "secretsmanager get-secret-value --secret-id my-api-key --query SecretString --output text : echo secret-value-123"

  stub buildkite-agent \
    "redactor add --help : echo 'usage info' && exit 0" \
    "redactor add : cat"

  run bash -c "$PWD/hooks/environment"

  assert_success
  assert_output --partial "Redacting"
  assert_output --partial "secret(s)"
  unstub aws
  unstub buildkite-agent
}

@test "AWS: json-variables fails when jq is missing" {
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
  cat <<'EOF' >"$tmp/aws"
#!/bin/bash
exit 0
EOF
  chmod +x "$tmp/dirname" "$tmp/buildkite-agent" "$tmp/aws"

  run env PATH="$tmp" \
    BUILDKITE_PLUGIN_SECRETS_PROVIDER=aws \
    BUILDKITE_PLUGIN_SECRETS_JSON_VARIABLES_0_SECRET_ID="my-json-secret" \
    /bin/bash -c "$PWD/hooks/environment"

  assert_failure
  assert_output --partial "jq is required"

  rm -rf "$tmp"
}

@test "AWS: json-variables expands top-level JSON keys into env vars (default json-key)" {
  export BUILDKITE_PLUGIN_SECRETS_JSON_VARIABLES_0_SECRET_ID="my-json-secret"

  stub aws \
    "secretsmanager get-secret-value --secret-id my-json-secret --query SecretString --output text : echo '{\"DB_HOST\":\"db.example.com\",\"DB_PASSWORD\":\"supersecret\",\"DB_PORT\":5432}'"

  run bash -c "source $PWD/hooks/environment && echo DB_HOST=\$DB_HOST && echo DB_PASSWORD=\$DB_PASSWORD && echo DB_PORT=\$DB_PORT"

  assert_success
  assert_output --partial "DB_HOST=db.example.com"
  assert_output --partial "DB_PASSWORD=supersecret"
  assert_output --partial "DB_PORT=5432"
  unstub aws
}

@test "AWS: json-variables expands a nested object via json-key" {
  export BUILDKITE_PLUGIN_SECRETS_JSON_VARIABLES_0_SECRET_ID="my-json-secret"
  export BUILDKITE_PLUGIN_SECRETS_JSON_VARIABLES_0_JSON_KEY=".Variables"

  stub aws \
    "secretsmanager get-secret-value --secret-id my-json-secret --query SecretString --output text : echo '{\"Variables\":{\"MY_SECRET\":\"value\",\"MY_OTHER_SECRET\":\"other value\"}}'"

  run bash -c "source $PWD/hooks/environment && echo MY_SECRET=\$MY_SECRET && echo MY_OTHER_SECRET=\$MY_OTHER_SECRET"

  assert_success
  assert_output --partial "MY_SECRET=value"
  assert_output --partial "MY_OTHER_SECRET=other value"
  unstub aws
}

@test "AWS: json-variables sanitizes special characters in keys" {
  export BUILDKITE_PLUGIN_SECRETS_JSON_VARIABLES_0_SECRET_ID="my-json-secret"

  stub aws \
    "secretsmanager get-secret-value --secret-id my-json-secret --query SecretString --output text : echo '{\"My-great key!\":\"value\",\"0LEADING\":\"digit\"}'"

  run bash -c "source $PWD/hooks/environment && echo My_great_key_=\$My_great_key_ && echo _0LEADING=\$_0LEADING"

  assert_success
  assert_output --partial "My_great_key_=value"
  assert_output --partial "_0LEADING=digit"
  unstub aws
}

@test "AWS: json-variables skips nested object values" {
  export BUILDKITE_PLUGIN_SECRETS_JSON_VARIABLES_0_SECRET_ID="my-json-secret"

  stub aws \
    "secretsmanager get-secret-value --secret-id my-json-secret --query SecretString --output text : echo '{\"VALID_KEY\":\"good\",\"NESTED\":{\"a\":1}}'"

  run bash -c "source $PWD/hooks/environment && echo VALID_KEY=\$VALID_KEY && echo \"NESTED is set: \${NESTED+yes}\""

  assert_success
  assert_output --partial "VALID_KEY=good"
  assert_output --partial "NESTED is set: "
  refute_output --partial "NESTED is set: yes"
  unstub aws
}

@test "AWS: json-variables fails on non-JSON secret" {
  export BUILDKITE_PLUGIN_SECRETS_JSON_VARIABLES_0_SECRET_ID="not-json-secret"

  stub aws \
    "secretsmanager get-secret-value --secret-id not-json-secret --query SecretString --output text : echo 'plain-text-value'"

  run bash -c "$PWD/hooks/environment"

  assert_failure
  assert_output --partial "is not valid JSON"
  unstub aws
}

@test "AWS: json-variables fails when json-key resolves to a non-object" {
  export BUILDKITE_PLUGIN_SECRETS_JSON_VARIABLES_0_SECRET_ID="my-json-secret"
  export BUILDKITE_PLUGIN_SECRETS_JSON_VARIABLES_0_JSON_KEY=".Password"

  stub aws \
    "secretsmanager get-secret-value --secret-id my-json-secret --query SecretString --output text : echo '{\"Password\":\"a-string-not-an-object\"}'"

  run bash -c "$PWD/hooks/environment"

  assert_failure
  assert_output --partial "is not an object"
  unstub aws
}

@test "AWS: Combines variables and json-variables" {
  export BUILDKITE_PLUGIN_SECRETS_VARIABLES_API_KEY="my-api-secret"
  export BUILDKITE_PLUGIN_SECRETS_JSON_VARIABLES_0_SECRET_ID="my-json-secret"

  stub aws \
    "secretsmanager get-secret-value --secret-id my-api-secret --query SecretString --output text : echo api-secret-value" \
    "secretsmanager get-secret-value --secret-id my-json-secret --query SecretString --output text : echo '{\"DB_HOST\":\"db.example.com\"}'"

  run bash -c "source $PWD/hooks/environment && echo API_KEY=\$API_KEY && echo DB_HOST=\$DB_HOST"

  assert_success
  assert_output --partial "API_KEY=api-secret-value"
  assert_output --partial "DB_HOST=db.example.com"
  unstub aws
}
