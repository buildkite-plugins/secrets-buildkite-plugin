#!/usr/bin/env bats

# export BUILDKITE_AGENT_STUB_DEBUG=/dev/tty

setup() {
  load "${BATS_PLUGIN_PATH}/load.bash"

  export BUILDKITE_PIPELINE_SLUG=testpipe
  export BUILDKITE_PLUGIN_SECRETS_RETRY_BASE_DELAY=0
  export BUILDKITE_PLUGIN_SECRETS_SKIP_REDACTION=true
}

@test "Fails when buildkite-agent is missing" {
    local tmp
    tmp=$(mktemp -d)

    cat <<'EOF' >"$tmp/dirname"
#!/bin/bash
/usr/bin/dirname "$@"
EOF
    chmod +x "$tmp/dirname"

    run env PATH="$tmp" /bin/bash -c "$PWD/hooks/environment"

    assert_failure
    assert_output --partial "buildkite-agent command is required"
    assert_output --partial "Missing required dependencies: buildkite-agent"
}

@test "Fails when base64 is missing and env is set" {
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
    chmod +x "$tmp/buildkite-agent"
    chmod +x "$tmp/dirname"

    run env PATH="$tmp" BUILDKITE_PLUGIN_SECRETS_ENV=env /bin/bash -c "$PWD/hooks/environment"

    assert_failure
    assert_output --partial "base64 is required when using env files"
    assert_output --partial "Missing required dependencies: base64"
}

@test "Download default env from Buildkite secrets" {
    export TESTDATA="Rk9PPWJhcgpCQVI9QmF6ClNFQ1JFVD1sbGFtYXMK"
    export BUILDKITE_PLUGIN_SECRETS_ENV="env"

    stub buildkite-agent "secret get env : echo ${TESTDATA}"

    run bash -c "source $PWD/hooks/environment && echo FOO=\$FOO && echo BAR=\$BAR && echo SECRET=\$SECRET"

    assert_success
    assert_output --partial "FOO=bar"
    assert_output --partial "BAR=Baz"
    assert_output --partial "SECRET=llamas"
}

@test "Download custom env from Buildkite secrets" {
    export TESTDATA='Rk9PPWJhcgpCQVI9QmF6ClNFQ1JFVD1sbGFtYXMK'
    export BUILDKITE_PLUGIN_SECRETS_ENV="llamas"

    stub buildkite-agent "secret get llamas : echo ${TESTDATA}"

    run bash -c "source $PWD/hooks/environment && echo FOO=\$FOO"

    assert_success
    assert_output --partial "FOO=bar"
}


@test "Download single variable from Buildkite secrets" {
    export TESTDATA='Rk9PPWJhcgpCQVI9QmF6ClNFQ1JFVD1sbGFtYXMK'
    export BUILDKITE_PLUGIN_SECRETS_ENV="env"
    export BUILDKITE_PLUGIN_SECRETS_VARIABLES_ANIMAL="best"

    stub buildkite-agent \
        "secret get env : echo ${TESTDATA}" \
        "secret get best : echo llama"

    run bash -c "source $PWD/hooks/environment && echo ANIMAL=\$ANIMAL"

    assert_success
    assert_output --partial "ANIMAL=llama"
    unstub buildkite-agent
}

@test "Download multiple variables from Buildkite secrets" {
    export TESTDATA='Rk9PPWJhcgpCQVI9QmF6ClNFQ1JFVD1sbGFtYXMK'
    export BUILDKITE_PLUGIN_SECRETS_ENV="env"
    export BUILDKITE_PLUGIN_SECRETS_VARIABLES_ANIMAL="best"
    export BUILDKITE_PLUGIN_SECRETS_VARIABLES_COUNTRY="great-north"
    export BUILDKITE_PLUGIN_SECRETS_VARIABLES_FOOD="chips"

    stub buildkite-agent \
        "secret get env : echo ${TESTDATA}" \
        "secret get best : echo llama" \
        "secret get great-north : echo Canada" \
        "secret get chips : echo Poutine"

    run bash -c "source $PWD/hooks/environment && echo ANIMAL=\$ANIMAL && echo COUNTRY=\$COUNTRY && echo FOOD=\$FOOD"

    assert_success
    assert_output --partial "ANIMAL=llama"
    assert_output --partial "COUNTRY=Canada"
    assert_output --partial "FOOD=Poutine"
    unstub buildkite-agent
}

@test "If env is defined and a secret is not found in Buildkite secrets, the plugin fails" {
    export BUILDKITE_PLUGIN_SECRETS_ENV="env"

    stub buildkite-agent "secret get env : echo 'not found' && exit 1"

    run bash -c "$PWD/hooks/environment"

    assert_failure
    assert_output --partial "Failed to fetch env"
    unstub buildkite-agent
}

@test "If no key from parameters found in Buildkite secrets the plugin fails" {
    export BUILDKITE_PLUGIN_SECRETS_VARIABLES_ANIMAL="best"

    stub buildkite-agent \
        "secret get best : echo 'not found' && exit 1"

    run bash -c "$PWD/hooks/environment"

    assert_failure
    assert_output --partial "Unable to find secret at"
    refute_output --partial "Retrying"
    unstub buildkite-agent
}

@test "Retry on transient failure" {
    export TESTDATA='Rk9PPWJhcgpCQVI9QmF6ClNFQ1JFVD1sbGFtYXMK'
    export BUILDKITE_PLUGIN_SECRETS_ENV="env"
    export BUILDKITE_PLUGIN_SECRETS_RETRY_MAX_ATTEMPTS=3

    stub buildkite-agent \
        "secret get env : exit 1" \
        "secret get env : exit 1" \
        "secret get env : echo ${TESTDATA}"

    run bash -c "$PWD/hooks/environment"

    assert_success
    assert_output --partial "Failed to fetch secret env (attempt 1/3)"
    assert_output --partial "Failed to fetch secret env (attempt 2/3)"
    unstub buildkite-agent
}

@test "Fails after max attempts" {
    export BUILDKITE_PLUGIN_SECRETS_VARIABLES_ANIMAL="best"
    export BUILDKITE_PLUGIN_SECRETS_RETRY_MAX_ATTEMPTS=3

    stub buildkite-agent \
        "secret get best : exit 1" \
        "secret get best : exit 1" \
        "secret get best : exit 1"

    run bash -c "$PWD/hooks/environment"

    assert_failure
    assert_output --partial "Failed to fetch secret best after 3 attempts"
    unstub buildkite-agent
}

@test "No retry on 4xx" {
    export BUILDKITE_PLUGIN_SECRETS_VARIABLES_ANIMAL="best"
    export BUILDKITE_PLUGIN_SECRETS_RETRY_MAX_ATTEMPTS=3

    stub buildkite-agent \
        "secret get best : echo 'unauthorized' && exit 1"

    run bash -c "$PWD/hooks/environment"

    assert_failure
    refute_output --partial "Retrying"
    unstub buildkite-agent
}

@test "Redact secrets when redaction is not skipped" {
    export TESTDATA='Rk9PPWJhcgpCQVI9QmF6ClNFQ1JFVD1sbGFtYXMK'
    export BUILDKITE_PLUGIN_SECRETS_ENV="env"
    export BUILDKITE_PLUGIN_SECRETS_VARIABLES_API_KEY="secret/api-key"
    unset BUILDKITE_PLUGIN_SECRETS_SKIP_REDACTION

    stub buildkite-agent \
        "secret get env : echo ${TESTDATA}" \
        "secret get secret/api-key : echo my-secret-key" \
        "redactor add --help : echo 'usage info' && exit 0" \
        "redactor add : cat" \
        "redactor add : cat" \
        "redactor add : cat" \
        "redactor add : cat"

    run bash -c "$PWD/hooks/environment"

    assert_success
    assert_output --partial "Redacting"
    assert_output --partial "secret(s)"
    unstub buildkite-agent
}

@test "Skip redaction when BUILDKITE_PLUGIN_SECRETS_SKIP_REDACTION is true" {
    export TESTDATA='Rk9PPWJhcgpCQVI9QmF6ClNFQ1JFVD1sbGFtYXMK'
    export BUILDKITE_PLUGIN_SECRETS_ENV="env"
    export BUILDKITE_PLUGIN_SECRETS_SKIP_REDACTION=true

    stub buildkite-agent \
        "secret get env : echo ${TESTDATA}"

    run bash -c "$PWD/hooks/environment"

    assert_success
    refute_output --partial "Redacting"
    unstub buildkite-agent
}

@test "Warn when buildkite-agent doesn't support redaction" {
    export TESTDATA='Rk9PPWJhcgpCQVI9QmF6ClNFQ1JFVD1sbGFtYXMK'
    export BUILDKITE_PLUGIN_SECRETS_ENV="env"
    unset BUILDKITE_PLUGIN_SECRETS_SKIP_REDACTION

    stub buildkite-agent \
        "secret get env : echo ${TESTDATA}" \
        "redactor add --help : exit 1"

    run bash -c "$PWD/hooks/environment"

    assert_success
    assert_output --partial "doesn't support secret redaction"
    assert_output --partial "Upgrade to buildkite-agent v3.67.0"
    unstub buildkite-agent
}

@test "Skip invalid variable names in decoded secrets" {
    # Create secret with invalid variable name (starts with number)
    export TESTDATA=$(echo -e "VALID=goodvalue\n0INVALID=badvalue\nALSO_VALID=anothervalue" | base64)
    export BUILDKITE_PLUGIN_SECRETS_ENV="env"

    stub buildkite-agent "secret get env : echo \${TESTDATA}"

    run bash -c "source $PWD/hooks/environment && echo VALID=\$VALID && echo ALSO_VALID=\$ALSO_VALID"

    assert_success
    assert_output --partial "VALID=goodvalue"
    assert_output --partial "ALSO_VALID=anothervalue"
    assert_output --partial "Skipping invalid variable name"
    assert_output --partial "0INVALID"
    unstub buildkite-agent
}
