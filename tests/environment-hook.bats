#!/usr/bin/env bats

# export BUILDKITE_AGENT_STUB_DEBUG=/dev/tty

setup() {
  load "${BATS_PLUGIN_PATH}/load.bash"

  export BUILDKITE_PIPELINE_SLUG=testpipe
  export BUILDKITE_PLUGIN_SECRETS_DUMP_ENV=true
}

@test "Download default env from Buildkite secrets" {
    export TESTDATA="Rk9PPWJhcgpCQVI9QmF6ClNFQ1JFVD1sbGFtYXMK"

    stub buildkite-agent "secret get env : echo ${TESTDATA}"

    run bash -c "$PWD/hooks/environment"

    assert_success
    assert_output --partial "FOO=bar"
    refute_output --partial "blah=blah"
}

@test "Download custom env from Buildkite secrets" {
    export TESTDATA='Rk9PPWJhcgpCQVI9QmF6ClNFQ1JFVD1sbGFtYXMK'
    export BUILDKITE_PLUGIN_SECRETS_ENV="llamas"

    stub buildkite-agent "secret get llamas : echo ${TESTDATA}"

    run bash -c "$PWD/hooks/environment"

    assert_success
    assert_output --partial "FOO=bar"
}


@test "Download single variable from Buildkite secrets" {
    export TESTDATA='Rk9PPWJhcgpCQVI9QmF6ClNFQ1JFVD1sbGFtYXMK'
    export BUILDKITE_PLUGIN_SECRETS_VARIABLES_ANIMAL="best"

    stub buildkite-agent \
        "secret get env : echo ${TESTDATA}" \
        "secret get best : echo llama"

    run bash -c "$PWD/hooks/environment"

    assert_success
    assert_output --partial "ANIMAL=llama"
    unstub buildkite-agent
}

@test "Download multiple variables from Buildkite secrets" {
    export TESTDATA='Rk9PPWJhcgpCQVI9QmF6ClNFQ1JFVD1sbGFtYXMK'
    export BUILDKITE_PLUGIN_SECRETS_VARIABLES_ANIMAL="best"
    export BUILDKITE_PLUGIN_SECRETS_VARIABLES_COUNTRY="great-north"
    export BUILDKITE_PLUGIN_SECRETS_VARIABLES_FOOD="chips"

    stub buildkite-agent \
        "secret get env : echo ${TESTDATA}" \
        "secret get best : echo llama" \
        "secret get great-north : echo Canada" \
        "secret get chips : echo Poutine"

    run bash -c "$PWD/hooks/environment"

    assert_success
    assert_output --partial "ANIMAL=llama"
    assert_output --partial "COUNTRY=Canada"
    assert_output --partial "FOOD=Poutine"
    unstub buildkite-agent
}

@test "If no key env found in Buildkite secrets the plugin does nothing - but doesn't fail" {

    stub buildkite-agent "secret get env : echo 'not found'"

    run bash -c "$PWD/hooks/environment"

    assert_success
    assert_output --partial "No secret found"
    unstub buildkite-agent
}

@test "If no key from parameters found in Buildkite secrets the plugin fails" {
    export BUILDKITE_PLUGIN_SECRETS_VARIABLES_ANIMAL="best"

    stub buildkite-agent \
        "secret get env : echo 'not found'" \
        "secret get best : exit 1"

    run bash -c "$PWD/hooks/environment"

    assert_failure
    assert_output --partial "⚠️ Unable to find secret at"
    unstub buildkite-agent
}
