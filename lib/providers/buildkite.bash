#!/bin/bash

setup_buildkite_environment() {

  check_dependencies
}

buildkite_agent_secret_get_with_retry() {
  local KEY="$1"
  local MAX_ATTEMPTS="${BUILDKITE_PLUGIN_SECRETS_RETRY_MAX_ATTEMPTS:-5}"
  local BASE_DELAY="${BUILDKITE_PLUGIN_SECRETS_RETRY_BASE_DELAY:-2}"
  local ATTEMPT=1
  local EXIT_CODE
  local OUTPUT

  while [ "$ATTEMPT" -le "$MAX_ATTEMPTS" ]; do
    set +e
    OUTPUT=$(buildkite-agent secret get "${KEY}" 2>&1)
    EXIT_CODE=$?
    set -e

    if [ "$EXIT_CODE" -eq 0 ]; then
      echo "$OUTPUT"
      return 0
    fi

    if echo "$OUTPUT" | grep -qiE "(not found|unauthorized|forbidden|bad request)"; then
      echo "$OUTPUT"
      return "$EXIT_CODE"
    fi

    if [ "$ATTEMPT" -lt "$MAX_ATTEMPTS" ]; then
      local TOTAL_DELAY
      TOTAL_DELAY=$(calculate_backoff_delay "$BASE_DELAY" "$ATTEMPT")

      log_info "Failed to fetch secret $KEY (attempt $ATTEMPT/$MAX_ATTEMPTS). Retrying in ${TOTAL_DELAY}s..."
      echo "Error: $OUTPUT" >&2

      sleep "$TOTAL_DELAY"
      ATTEMPT=$((ATTEMPT + 1))
    else
      log_error "Failed to fetch secret $KEY after $MAX_ATTEMPTS attempts"
      echo "Error: $OUTPUT" >&2
      return "$EXIT_CODE"
    fi
  done
}

# downloads the secret by provided key using the buildkite-agent secret command
download_secret() {
  local key=$1
  local output

  if output=$(buildkite_agent_secret_get_with_retry "${key}"); then
    echo "${output}"
  else
    log_warning "Failed to fetch ${key}: ${output}"
    return 0 # Treat as non-fatal, preserving previous behavior, just improving logging
  fi
}

# decodes a base64 encoded secret, expects decoded secret to be in the format KEY=value:
# FOO=BAR
# BAR=BAZ
decode_secrets() {
    local encoded_secret=$1
    local envscript=''
    local key value

    while IFS='=' read -r key value; do
        # Check if both key and value are non-empty
        if [ -n "$key" ] && [ -n "$value" ]; then
            # Update envscript
            envscript+="${key}=${value}"$'\n'
        fi
    done <<< "$(echo "$encoded_secret" | base64 -d)"

    echo "$envscript"
}

process_secrets() {
    local encoded_secret=$1
    local envscript=''

    if ! envscript=$(decode_secrets "${encoded_secret}"); then
        log_error "Unable to decode secrets"
        exit 1
    fi

    # BUILDKITE_SECRETS_TO_REDACT is inherited from parent. This is not exposed to the shell.
    while IFS='=' read -r key value; do
        if [ -n "$key" ] && [ -n "$value" ]; then
            BUILDKITE_SECRETS_TO_REDACT+=("$value")
        fi
    done <<< "$envscript"

    set -o allexport
    eval "$envscript"
    set +o allexport
}

process_variables() {
  # Extract the environment variable keys and Buildkite secret paths.
  for param in ${!BUILDKITE_PLUGIN_SECRETS_VARIABLES_*}; do
    key="${param/BUILDKITE_PLUGIN_SECRETS_VARIABLES_/}"
    path="${!param}"

    if ! value=$(buildkite_agent_secret_get_with_retry "${path}"); then
        log_error "Unable to find secret at ${path}"
        exit 1
    else
        # BUILDKITE_SECRETS_TO_REDACT is inherited from parent. This is not exposed to the shell.
        BUILDKITE_SECRETS_TO_REDACT+=("$value")
        export "${key}=${value}"
    fi
  done
}

# primarily used for debugging; The job log will show what env vars have changed after this hook is executed
# this will occur BEFORE redaction, so it will echo to stdout the actual secret values
dump_env_secrets() {
  if [[ "${BUILDKITE_PLUGIN_SECRETS_DUMP_ENV:-}" =~ ^(true|1)$ ]] ; then
    echo "~~~ 🔎 Environment variables that were set" >&2;
    comm -13 <(echo "$env_before") <(env | sort) || true
  fi
}

fetch_buildkite_secrets() {
  env_before="$(env | sort)"

  local BUILDKITE_SECRETS_TO_REDACT=()
  local secret

  log_info "🔐 Fetching env secrets from Buildkite secrets"

  # If we are using a specific key we should download and evaluate it
  if [[ -n "${BUILDKITE_PLUGIN_SECRETS_ENV+x}" ]]; then
      secret=$(download_secret "${BUILDKITE_PLUGIN_SECRETS_ENV:-env}")
      if [[ -z ${secret} ]]; then
          log_warning "No secret found at ${BUILDKITE_PLUGIN_SECRETS_ENV:-env}"
      else
          process_secrets "${secret}"
      fi
  fi

  # Now download and set ENV specified using the `variables` plugin param
  process_variables

  dump_env_secrets

  if [[ "${BUILDKITE_PLUGIN_SECRETS_SKIP_REDACTION:-}" != "true" ]] && [[ ${#BUILDKITE_SECRETS_TO_REDACT[@]} -gt 0 ]]; then
    redact_secrets BUILDKITE_SECRETS_TO_REDACT
  fi
}
