#!/usr/bin/env bats

setup() {
  load "${BATS_PLUGIN_PATH}/load.bash"

  export BUILDKITE_PIPELINE_SLUG=testpipe
  export BUILDKITE_PLUGIN_SECRETS_RETRY_BASE_DELAY=0
  export BUILDKITE_PLUGIN_SECRETS_SKIP_REDACTION=true

  TEST_TEMP_DIR=$(mktemp -d)
  # The SSH key/known_hosts file paths derive from TMPDIR + job id
  export TMPDIR="$TEST_TEMP_DIR"
  unset BUILDKITE_JOB_ID
  SSH_KEY_FILE="$TEST_TEMP_DIR/buildkite-secrets-git-ssh-key"
  KNOWN_HOSTS_FILE="$TEST_TEMP_DIR/buildkite-secrets-git-ssh-known-hosts"

  # Stand-in binaries so dependency checks pass when we don't stub them. The
  # plugin never executes ssh here (git is stubbed), it only checks ssh exists.
  # Appended to the end of PATH so bats-mock stubs take precedence.
  cat <<'EOF' >"$TEST_TEMP_DIR/buildkite-agent"
#!/bin/bash
exit 0
EOF
  cat <<'EOF' >"$TEST_TEMP_DIR/ssh"
#!/bin/bash
exit 0
EOF
  chmod +x "$TEST_TEMP_DIR/buildkite-agent" "$TEST_TEMP_DIR/ssh"
  export PATH="$PATH:$TEST_TEMP_DIR"
}

teardown() {
  rm -rf "$TEST_TEMP_DIR"
}

@test "Writes SSH key and configures core.sshCommand with GitHub known_hosts (buildkite provider)" {
  export BUILDKITE_PLUGIN_SECRETS_GIT_SSH_KEY="deploy-key"

  stub buildkite-agent "secret get deploy-key : echo 'ssh-key:FAKEDATA'"
  stub git "config --global core.sshCommand * : echo \"git \$*\" > '$TEST_TEMP_DIR/git.log'"

  run bash -c "$PWD/hooks/environment"

  assert_success
  assert_output --partial "Configured git SSH key"

  # The fetched key is written verbatim to a private file
  assert [ -f "$SSH_KEY_FILE" ]
  run cat "$SSH_KEY_FILE"
  assert_output "ssh-key:FAKEDATA"

  # known_hosts defaults to GitHub's published host keys
  assert [ -f "$KNOWN_HOSTS_FILE" ]
  run cat "$KNOWN_HOSTS_FILE"
  assert_output --partial "github.com ssh-ed25519"

  # git is pointed at the key + known_hosts, with verification left on
  run cat "$TEST_TEMP_DIR/git.log"
  assert_output --partial "core.sshCommand ssh -i $SSH_KEY_FILE"
  assert_output --partial "UserKnownHostsFile=$KNOWN_HOSTS_FILE"
  assert_output --partial "StrictHostKeyChecking=yes"

  unstub buildkite-agent
  unstub git
}

@test "Uses custom known_hosts when git-ssh-known-hosts is provided" {
  export BUILDKITE_PLUGIN_SECRETS_GIT_SSH_KEY="deploy-key"
  export BUILDKITE_PLUGIN_SECRETS_GIT_SSH_KNOWN_HOSTS="git.internal.example.com ssh-ed25519 AAAACustomHostKey"

  stub buildkite-agent "secret get deploy-key : echo 'ssh-key:FAKEDATA'"
  stub git "config --global core.sshCommand * : exit 0"

  run bash -c "$PWD/hooks/environment"

  assert_success
  assert [ -f "$KNOWN_HOSTS_FILE" ]
  run cat "$KNOWN_HOSTS_FILE"
  assert_output "git.internal.example.com ssh-ed25519 AAAACustomHostKey"
  refute_output --partial "github.com"

  unstub buildkite-agent
  unstub git
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

@test "Configures SSH key via the gcp provider" {
  export BUILDKITE_PLUGIN_SECRETS_PROVIDER=gcp
  export BUILDKITE_PLUGIN_SECRETS_GCP_PROJECT=test-project
  export BUILDKITE_PLUGIN_SECRETS_GIT_SSH_KEY="deploy-key"

  stub gcloud "secrets versions access latest --secret=deploy-key --project=test-project : echo 'ssh-key:FAKEDATA'"
  stub git "config --global core.sshCommand * : exit 0"

  run bash -c "$PWD/hooks/environment"

  assert_success
  assert [ -f "$SSH_KEY_FILE" ]
  run cat "$SSH_KEY_FILE"
  assert_output "ssh-key:FAKEDATA"

  unstub gcloud
  unstub git
}

@test "Redacts the fetched SSH key" {
  export BUILDKITE_PLUGIN_SECRETS_GIT_SSH_KEY="deploy-key"
  unset BUILDKITE_PLUGIN_SECRETS_SKIP_REDACTION

  stub buildkite-agent \
    "secret get deploy-key : echo 'ssh-key:FAKEDATA'" \
    "redactor add --help : echo usage && exit 0" \
    "redactor add : cat"
  stub git "config --global core.sshCommand * : exit 0"

  run bash -c "$PWD/hooks/environment"

  assert_success
  assert_output --partial "Redacting"

  unstub buildkite-agent
  unstub git
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
  stub git "config --global core.sshCommand * : exit 0"

  run bash -c "$PWD/hooks/environment"

  assert_success
  run cat "$SSH_KEY_FILE"
  assert_output "$key"

  unstub buildkite-agent
  unstub git
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
