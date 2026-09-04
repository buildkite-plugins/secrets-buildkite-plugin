#!/usr/bin/env bats

setup() {
  load "${BATS_PLUGIN_PATH}/load.bash"

  export BUILDKITE_PIPELINE_SLUG=testpipe
  export BUILDKITE_PLUGIN_SECRETS_RETRY_BASE_DELAY=0
  export BUILDKITE_PLUGIN_SECRETS_SKIP_REDACTION=true
  unset BUILDKITE_BOOTSTRAP_PHASES
  unset BUILDKITE_CONTAINER_ID
  unset BUILDKITE_PLUGIN_SECRETS_HOOK
}

@test "pre-command hook is a no-op when hook is unset" {
  export BUILDKITE_PLUGIN_SECRETS_ENV="env"

  run "$PWD/hooks/pre-command"

  assert_success
  assert_output --partial "Skipping pre-command hook"
  refute_output --partial ":closed_lock_with_key: Fetching secrets"
}

@test "pre-command hook is a no-op when configured to use the environment hook" {
  export BUILDKITE_PLUGIN_SECRETS_HOOK="environment"
  export BUILDKITE_PLUGIN_SECRETS_ENV="env"

  run "$PWD/hooks/pre-command"

  assert_success
  assert_output --partial "Skipping pre-command hook"
  refute_output --partial ":closed_lock_with_key: Fetching secrets"
}

@test "environment hook is a no-op when configured to use the pre-command hook" {
  export BUILDKITE_PLUGIN_SECRETS_HOOK="pre-command"
  export BUILDKITE_PLUGIN_SECRETS_ENV="env"

  run "$PWD/hooks/environment"

  assert_success
  assert_output --partial "Skipping environment hook"
  refute_output --partial ":closed_lock_with_key: Fetching secrets"
}

@test "pre-command hook fetches when configured for pre-command" {
  export TESTDATA='Rk9PPWJhcgpCQVI9QmF6ClNFQ1JFVD1sbGFtYXMK'
  export BUILDKITE_PLUGIN_SECRETS_ENV="env"
  export BUILDKITE_PLUGIN_SECRETS_HOOK="pre-command"

  stub buildkite-agent "secret get env : echo ${TESTDATA}"

  run bash -c "source $PWD/hooks/pre-command && echo FOO=\$FOO && echo BAR=\$BAR && echo SECRET=\$SECRET"

  assert_success
  assert_output --partial "Running in the pre-command hook"
  assert_output --partial "FOO=bar"
  assert_output --partial "BAR=Baz"
  assert_output --partial "SECRET=llamas"
  unstub buildkite-agent
}

@test "environment hook fails on an unrecognised hook value" {
  export BUILDKITE_PLUGIN_SECRETS_HOOK="Pre-Command"
  export BUILDKITE_PLUGIN_SECRETS_ENV="env"

  run "$PWD/hooks/environment"

  assert_failure
  assert_output --partial "Invalid hook 'Pre-Command'"
  refute_output --partial ":closed_lock_with_key: Fetching secrets"
}

@test "environment hook fails on a misspelled hook value" {
  export BUILDKITE_PLUGIN_SECRETS_HOOK="enviroment"
  export BUILDKITE_PLUGIN_SECRETS_ENV="env"

  run "$PWD/hooks/environment"

  assert_failure
  assert_output --partial "Invalid hook 'enviroment'"
  refute_output --partial ":closed_lock_with_key: Fetching secrets"
}

@test "pre-command hook fetches in the command container even when phases is checkout-only" {
  export TESTDATA='Rk9PPWJhcgpCQVI9QmF6ClNFQ1JFVD1sbGFtYXMK'
  export BUILDKITE_PLUGIN_SECRETS_ENV="env"
  export BUILDKITE_PLUGIN_SECRETS_HOOK="pre-command"
  export BUILDKITE_PLUGIN_SECRETS_PHASES_0="checkout"
  export BUILDKITE_BOOTSTRAP_PHASES="plugin,environment,command"
  export BUILDKITE_CONTAINER_ID="1"

  stub buildkite-agent "secret get env : echo ${TESTDATA}"

  run bash -c "$PWD/hooks/pre-command"

  assert_success
  assert_output --partial "Running in the pre-command hook"
  assert_output --partial ":closed_lock_with_key: Fetching secrets"
  unstub buildkite-agent
}