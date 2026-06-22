#!/usr/bin/env bats

setup() {
  load "${BATS_PLUGIN_PATH}/load.bash"

  export BUILDKITE_PIPELINE_SLUG=testpipe
  export BUILDKITE_PLUGIN_SECRETS_RETRY_BASE_DELAY=0
  export BUILDKITE_PLUGIN_SECRETS_SKIP_REDACTION=true

  TEST_TEMP_DIR=$(mktemp -d)
  export TMPDIR="$TEST_TEMP_DIR"
  unset BUILDKITE_JOB_ID
  SSH_KEY_FILE="$TEST_TEMP_DIR/buildkite-secrets-git-ssh-key"
  KNOWN_HOSTS_FILE="$TEST_TEMP_DIR/buildkite-secrets-git-ssh-known-hosts"

  printf '#!/bin/bash\nexit 0\n' >"$TEST_TEMP_DIR/buildkite-agent"
  printf '#!/bin/bash\nexit 0\n' >"$TEST_TEMP_DIR/git"
  printf '#!/bin/bash\nexit 0\n' >"$TEST_TEMP_DIR/ssh"
  chmod +x "$TEST_TEMP_DIR/buildkite-agent" "$TEST_TEMP_DIR/git" "$TEST_TEMP_DIR/ssh"
  export PATH="$PATH:$TEST_TEMP_DIR"
}

teardown() {
  rm -rf "$TEST_TEMP_DIR"
}

@test "Writes SSH key and injects core.sshCommand with GitHub known_hosts (buildkite provider)" {
  export BUILDKITE_PLUGIN_SECRETS_GIT_SSH_KEY="deploy-key"

  stub buildkite-agent "secret get deploy-key : echo 'ssh-key:FAKEDATA'"

  run bash -c "source $PWD/hooks/environment; env | grep '^GIT_CONFIG_'"

  assert_success
  assert_output --partial "Configured git SSH key"
  assert_output --partial "GIT_CONFIG_KEY_0=core.sshCommand"
  assert_output --partial "GIT_CONFIG_VALUE_0=ssh -F /dev/null -i '$SSH_KEY_FILE'"
  assert_output --partial "IdentityAgent=none"
  assert_output --partial "BatchMode=yes"
  assert_output --partial "UserKnownHostsFile='$KNOWN_HOSTS_FILE'"
  assert_output --partial "StrictHostKeyChecking=yes"

  assert [ -f "$SSH_KEY_FILE" ]
  run cat "$SSH_KEY_FILE"
  assert_output "ssh-key:FAKEDATA"

  run bash -c "stat -c '%a' '$SSH_KEY_FILE' 2>/dev/null || stat -f '%Lp' '$SSH_KEY_FILE'"
  assert_output "600"

  assert [ -f "$KNOWN_HOSTS_FILE" ]
  run cat "$KNOWN_HOSTS_FILE"
  assert_output --partial "github.com ssh-ed25519"

  unstub buildkite-agent
}

@test "Uses custom known_hosts when git-ssh-known-hosts is provided" {
  export BUILDKITE_PLUGIN_SECRETS_GIT_SSH_KEY="deploy-key"
  export BUILDKITE_PLUGIN_SECRETS_GIT_SSH_KNOWN_HOSTS="git.internal.example.com ssh-ed25519 AAAACustomHostKey"

  stub buildkite-agent "secret get deploy-key : echo 'ssh-key:FAKEDATA'"

  run bash -c "$PWD/hooks/environment"

  assert_success
  assert [ -f "$KNOWN_HOSTS_FILE" ]
  run cat "$KNOWN_HOSTS_FILE"
  assert_output "git.internal.example.com ssh-ed25519 AAAACustomHostKey"
  refute_output --partial "github.com"

  unstub buildkite-agent
}

@test "Fails when git is missing and git-ssh-key is set" {
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

  run env PATH="$tmp" BUILDKITE_PLUGIN_SECRETS_GIT_SSH_KEY=deploy-key /bin/bash -c "$PWD/hooks/environment"

  assert_failure
  assert_output --partial "git is required when using the git-ssh-key option"

  rm -rf "$tmp"
}

@test "Injects SSH key via the gcp provider" {
  export BUILDKITE_PLUGIN_SECRETS_PROVIDER=gcp
  export BUILDKITE_PLUGIN_SECRETS_GCP_PROJECT=test-project
  export BUILDKITE_PLUGIN_SECRETS_GIT_SSH_KEY="deploy-key"

  stub gcloud "secrets versions access latest --secret=deploy-key --project=test-project : echo 'ssh-key:FAKEDATA'"

  run bash -c "$PWD/hooks/environment"

  assert_success
  assert [ -f "$SSH_KEY_FILE" ]
  run cat "$SSH_KEY_FILE"
  assert_output "ssh-key:FAKEDATA"

  unstub gcloud
}

@test "Redacts the fetched SSH key" {
  export BUILDKITE_PLUGIN_SECRETS_GIT_SSH_KEY="deploy-key"
  unset BUILDKITE_PLUGIN_SECRETS_SKIP_REDACTION

  stub buildkite-agent \
    "secret get deploy-key : echo 'ssh-key:FAKEDATA'" \
    "redactor add --help : echo usage && exit 0" \
    "redactor add : cat"

  run bash -c "$PWD/hooks/environment"

  assert_success
  assert_output --partial "Redacting"

  unstub buildkite-agent
}

@test "Fails when both git-credentials and git-ssh-key are set" {
  export BUILDKITE_PLUGIN_SECRETS_GIT_CREDENTIALS="git-creds"
  export BUILDKITE_PLUGIN_SECRETS_GIT_SSH_KEY="deploy-key"

  run bash -c "$PWD/hooks/environment"

  assert_failure
  assert_output --partial "git-credentials and git-ssh-key are mutually exclusive"
}

@test "Accepts a base64-encoded SSH key" {
  export BUILDKITE_PLUGIN_SECRETS_GIT_SSH_KEY="deploy-key"

  local key b64
  key="-----BEGIN OPENSSH PRIVATE KEY-----
FAKEKEYBODY
-----END OPENSSH PRIVATE KEY-----"
  b64="$(printf '%s' "$key" | base64 | tr -d '\n')"

  stub buildkite-agent "secret get deploy-key : echo $b64"

  run bash -c "$PWD/hooks/environment"

  assert_success
  run cat "$SSH_KEY_FILE"
  assert_output "$key"

  unstub buildkite-agent
}

@test "Fails when ssh is missing and git-ssh-key is set" {
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
  cat <<'EOF' >"$tmp/git"
#!/bin/bash
exit 0
EOF
  chmod +x "$tmp/dirname" "$tmp/buildkite-agent" "$tmp/git"

  run env PATH="$tmp" BUILDKITE_PLUGIN_SECRETS_GIT_SSH_KEY=deploy-key /bin/bash -c "$PWD/hooks/environment"

  assert_failure
  assert_output --partial "ssh is required when using the git-ssh-key option"

  rm -rf "$tmp"
}

@test "Leaves a base64-looking key unchanged when it lacks a private-key header" {
  export BUILDKITE_PLUGIN_SECRETS_GIT_SSH_KEY="deploy-key"
  stub buildkite-agent "secret get deploy-key : echo dXNlcg=="

  run bash -c "$PWD/hooks/environment"

  assert_success
  run cat "$SSH_KEY_FILE"
  assert_output "dXNlcg=="

  unstub buildkite-agent
}

@test "Empty SSH key secret is rejected" {
  export BUILDKITE_PLUGIN_SECRETS_GIT_SSH_KEY="deploy-key"
  stub buildkite-agent "secret get deploy-key : printf ''"

  run bash -c "$PWD/hooks/environment"

  assert_failure
  assert_output --partial "is empty"
  assert [ ! -f "$SSH_KEY_FILE" ]

  unstub buildkite-agent
}

@test "Strips carriage returns from a CRLF-stored SSH key" {
  export BUILDKITE_PLUGIN_SECRETS_GIT_SSH_KEY="deploy-key"
  stub buildkite-agent "secret get deploy-key : printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\r\nBODY\r\n-----END OPENSSH PRIVATE KEY-----\r\n'"

  run bash -c "$PWD/hooks/environment"

  assert_success
  run cat "$SSH_KEY_FILE"
  refute_output --partial $'\r'
  assert_output --partial "BEGIN OPENSSH PRIVATE KEY"

  unstub buildkite-agent
}

@test "pre-exit is a no-op when the SSH files are absent" {
  export BUILDKITE_PLUGIN_SECRETS_GIT_SSH_KEY="deploy-key"

  run bash -c "$PWD/hooks/pre-exit"

  assert_success
  refute_output --partial "Removed git SSH key files"
}

@test "pre-exit removes the SSH key and known_hosts files" {
  export BUILDKITE_PLUGIN_SECRETS_GIT_SSH_KEY="deploy-key"
  printf 'ssh-key:FAKEDATA\n' >"$SSH_KEY_FILE"
  printf 'github.com ssh-ed25519 AAAA\n' >"$KNOWN_HOSTS_FILE"
  assert [ -f "$SSH_KEY_FILE" ]
  assert [ -f "$KNOWN_HOSTS_FILE" ]

  run bash -c "$PWD/hooks/pre-exit"

  assert_success
  assert [ ! -f "$SSH_KEY_FILE" ]
  assert [ ! -f "$KNOWN_HOSTS_FILE" ]
}
