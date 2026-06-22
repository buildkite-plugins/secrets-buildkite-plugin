#!/usr/bin/env bats

setup() {
  load "${BATS_PLUGIN_PATH}/load.bash"

  export BUILDKITE_PIPELINE_SLUG=testpipe
  export BUILDKITE_PLUGIN_SECRETS_RETRY_BASE_DELAY=0
  export BUILDKITE_PLUGIN_SECRETS_SKIP_REDACTION=true

  TEST_TEMP_DIR=$(mktemp -d)
  export BUILDKITE_PLUGIN_SECRETS_GIT_CREDENTIALS_FILE="$TEST_TEMP_DIR/.git-credentials"

  printf '#!/bin/bash\nexit 0\n' >"$TEST_TEMP_DIR/buildkite-agent"
  printf '#!/bin/bash\nexit 0\n' >"$TEST_TEMP_DIR/git"
  chmod +x "$TEST_TEMP_DIR/buildkite-agent" "$TEST_TEMP_DIR/git"
  export PATH="$PATH:$TEST_TEMP_DIR"
}

teardown() {
  rm -rf "$TEST_TEMP_DIR"
}

@test "Writes the file and injects the store helper via GIT_CONFIG (buildkite provider)" {
  export BUILDKITE_PLUGIN_SECRETS_GIT_CREDENTIALS="git-creds"

  stub buildkite-agent "secret get git-creds : echo 'https://x-access-token:ghs_token@github.com'"

  run bash -c "source $PWD/hooks/environment; env | grep '^GIT_CONFIG_'"

  assert_success
  assert_output --partial "Configured git 'store' credential helper"
  assert_line "GIT_CONFIG_KEY_0=credential.https://github.com.helper"
  assert_line "GIT_CONFIG_VALUE_0="
  assert_line "GIT_CONFIG_KEY_1=credential.https://github.com.helper"
  assert_line "GIT_CONFIG_VALUE_1=store --file='$BUILDKITE_PLUGIN_SECRETS_GIT_CREDENTIALS_FILE'"

  assert [ -f "$BUILDKITE_PLUGIN_SECRETS_GIT_CREDENTIALS_FILE" ]
  run cat "$BUILDKITE_PLUGIN_SECRETS_GIT_CREDENTIALS_FILE"
  assert_output "https://x-access-token:ghs_token@github.com"

  run bash -c "stat -c '%a' '$BUILDKITE_PLUGIN_SECRETS_GIT_CREDENTIALS_FILE' 2>/dev/null || stat -f '%Lp' '$BUILDKITE_PLUGIN_SECRETS_GIT_CREDENTIALS_FILE'"
  assert_output "600"

  unstub buildkite-agent
}

@test "Does nothing when git-credentials is not set" {
  run bash -c "$PWD/hooks/environment"

  assert_success
  refute_output --partial "Configuring git credentials"
  assert [ ! -f "$BUILDKITE_PLUGIN_SECRETS_GIT_CREDENTIALS_FILE" ]
}

@test "Fails when git is missing and git-credentials is set" {
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

  run env PATH="$tmp" BUILDKITE_PLUGIN_SECRETS_GIT_CREDENTIALS=git-creds /bin/bash -c "$PWD/hooks/environment"

  assert_failure
  assert_output --partial "git is required when using the git-credentials option"
  assert_output --partial "Missing required dependencies: git"

  rm -rf "$tmp"
}

@test "Injects credentials via the gcp provider" {
  export BUILDKITE_PLUGIN_SECRETS_PROVIDER=gcp
  export BUILDKITE_PLUGIN_SECRETS_GCP_PROJECT=test-project
  export BUILDKITE_PLUGIN_SECRETS_GIT_CREDENTIALS="git-creds"

  stub gcloud "secrets versions access latest --secret=git-creds --project=test-project : echo 'https://x-access-token:ghs_gcp@github.com'"

  run bash -c "$PWD/hooks/environment"

  assert_success
  assert [ -f "$BUILDKITE_PLUGIN_SECRETS_GIT_CREDENTIALS_FILE" ]
  run cat "$BUILDKITE_PLUGIN_SECRETS_GIT_CREDENTIALS_FILE"
  assert_output "https://x-access-token:ghs_gcp@github.com"

  unstub gcloud
}

@test "Redacts the fetched git credentials value" {
  export BUILDKITE_PLUGIN_SECRETS_GIT_CREDENTIALS="git-creds"
  unset BUILDKITE_PLUGIN_SECRETS_SKIP_REDACTION

  stub buildkite-agent \
    "secret get git-creds : echo 'https://x-access-token:ghs_secret@github.com'" \
    "redactor add --help : echo usage && exit 0" \
    "redactor add : cat"

  run bash -c "$PWD/hooks/environment"

  assert_success
  assert_output --partial "Redacting"

  unstub buildkite-agent
}

@test "Accepts a base64-encoded credentials secret" {
  export BUILDKITE_PLUGIN_SECRETS_GIT_CREDENTIALS="git-creds"

  local url b64
  url="https://x-access-token:ghs_b64token@github.com"
  b64="$(printf '%s' "$url" | base64 | tr -d '\n')"

  stub buildkite-agent "secret get git-creds : echo $b64"

  run bash -c "$PWD/hooks/environment"

  assert_success
  run cat "$BUILDKITE_PLUGIN_SECRETS_GIT_CREDENTIALS_FILE"
  assert_output "$url"

  unstub buildkite-agent
}

@test "Leaves a base64-looking credentials secret unchanged when it lacks a URL" {
  export BUILDKITE_PLUGIN_SECRETS_GIT_CREDENTIALS="git-creds"
  stub buildkite-agent "secret get git-creds : echo dXNlcg=="

  run bash -c "$PWD/hooks/environment"

  assert_success
  run cat "$BUILDKITE_PLUGIN_SECRETS_GIT_CREDENTIALS_FILE"
  assert_output "dXNlcg=="

  unstub buildkite-agent
}

@test "Empty credentials secret is rejected" {
  export BUILDKITE_PLUGIN_SECRETS_GIT_CREDENTIALS="git-creds"
  stub buildkite-agent "secret get git-creds : printf ''"

  run bash -c "$PWD/hooks/environment"

  assert_failure
  assert_output --partial "is empty"
  assert [ ! -f "$BUILDKITE_PLUGIN_SECRETS_GIT_CREDENTIALS_FILE" ]

  unstub buildkite-agent
}

@test "Directory-valued git-credentials-file is rejected (no orphaned secret)" {
  export BUILDKITE_PLUGIN_SECRETS_GIT_CREDENTIALS="git-creds"
  export BUILDKITE_PLUGIN_SECRETS_GIT_CREDENTIALS_FILE="$TEST_TEMP_DIR"
  stub buildkite-agent "secret get git-creds : echo 'https://x-access-token:tok@github.com'"

  run bash -c "$PWD/hooks/environment"

  assert_failure
  refute_output --partial "Configured git"
  assert_equal "$(ls -a "$TEST_TEMP_DIR" | grep -c bk-secret)" "0"

  unstub buildkite-agent
}

@test "Relative git-credentials-file is rejected" {
  export BUILDKITE_PLUGIN_SECRETS_GIT_CREDENTIALS="git-creds"
  export BUILDKITE_PLUGIN_SECRETS_GIT_CREDENTIALS_FILE="relative/creds"
  stub buildkite-agent "secret get git-creds : echo 'https://x-access-token:tok@github.com'"

  run bash -c "$PWD/hooks/environment"

  assert_failure
  assert_output --partial "must be an absolute path"

  unstub buildkite-agent
}

@test "pre-exit removes the git credentials file" {
  export BUILDKITE_PLUGIN_SECRETS_GIT_CREDENTIALS="git-creds"
  printf 'https://x-access-token:tok@github.com\n' >"$BUILDKITE_PLUGIN_SECRETS_GIT_CREDENTIALS_FILE"
  assert [ -f "$BUILDKITE_PLUGIN_SECRETS_GIT_CREDENTIALS_FILE" ]

  run bash -c "$PWD/hooks/pre-exit"

  assert_success
  assert [ ! -f "$BUILDKITE_PLUGIN_SECRETS_GIT_CREDENTIALS_FILE" ]
}

@test "pre-exit is a no-op when the credentials file is absent" {
  export BUILDKITE_PLUGIN_SECRETS_GIT_CREDENTIALS="git-creds"

  run bash -c "$PWD/hooks/pre-exit"

  assert_success
  refute_output --partial "Removed git credentials file"
}

@test "pre-exit is a no-op when no git auth option is set" {
  run bash -c "$PWD/hooks/pre-exit"

  assert_success
  refute_output --partial "Removed"
}

@test "sh_quote safely quotes paths with single quotes and shell metacharacters" {
  source "$PWD/lib/shared.bash"
  local input q back
  for input in "a'b" "/tmp/joe's-dir/x" 'x$(echo PWNED)y' 'semi;colon' "two''quotes"; do
    q="$(sh_quote "$input")"
    back="$(eval "printf %s $q")"
    assert_equal "$back" "$input"
  done
}
