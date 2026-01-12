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
    log_error "Failed to fetch ${key}"
    return 1
  fi
}

# decodes a base64 encoded secret, expects decoded secret to be in the format KEY=value:
# FOO=BAR
# BAR=BAZ
decode_secrets() {
    local encoded_secret=$1
    local key_name=$2
    local decoded_secret
    local envscript=''
    local key value

    if ! decoded_secret=$(echo "$encoded_secret" | base64 -d 2>&1); then
        log_error "Failed to decode base64 secret for key: ${key_name}"
        log_error "The secret may be malformed or not properly base64-encoded"
        return 1

    else
        if [[ -z "$decoded_secret" ]] || [[ "$decoded_secret" =~ ^[[:space:]]+$ ]]; then
            log_error "Decoded secret for key: ${key_name} is empty or contains only whitespace"
            return 1
        fi
    fi

    while IFS='=' read -r key value; do
        # Check if both key and value are non-empty
        if [ -n "$key" ] && [ -n "$value" ]; then
            # Validate the key is a valid shell variable name
            if [[ ! "$key" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
                log_warning "Skipping invalid variable name '${key}' in secret '${key_name}' (must start with letter or underscore)"
                continue
            fi

            # Properly quote the value to prevent shell interpretation during eval
            # Use printf %q to shell-escape the value safely
            local escaped_value
            escaped_value=$(printf '%q' "$value")
            envscript+="${key}=${escaped_value}"$'\n'
        fi
    done <<< "$decoded_secret"

    echo "$envscript"
}

process_secrets() {
    local encoded_secret=$1
    local key_name=$2
    local envscript=''

    if ! envscript=$(decode_secrets "${encoded_secret}" "${key_name}"); then
        log_error "Unable to decode secrets"
        exit 1
    fi

    # Collect decoded secret values into the BUILDKITE_SECRETS_TO_REDACT array
    # (defined as local in fetch_buildkite_secrets). Bash's dynamic scoping allows
    # this function to append to the parent function's local array
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
        # Collect secret values into the BUILDKITE_SECRETS_TO_REDACT array
        # (defined as local in fetch_buildkite_secrets). Bash's dynamic scoping allows
        # this function to append to the parent function's local array
        BUILDKITE_SECRETS_TO_REDACT+=("$value")
        export "${key}=${value}"
    fi
  done
}

fetch_buildkite_secrets() {
  # Local array to collect secrets for redaction. Child functions (process_secrets
  # and process_variables) can append to this array due to bash's dynamic scoping.
  # The array is automatically cleaned up when this function exits, keeping secrets secure.
  local BUILDKITE_SECRETS_TO_REDACT=()
  local secret

  log_info "Fetching env secrets"

  # If we are using a specific key we should download and evaluate it
  if [[ -n "${BUILDKITE_PLUGIN_SECRETS_ENV+x}" ]]; then
      if secret=$(download_secret "${BUILDKITE_PLUGIN_SECRETS_ENV}"); then
          process_secrets "${secret}" "${BUILDKITE_PLUGIN_SECRETS_ENV}"
      else
          log_error "No secret found at ${BUILDKITE_PLUGIN_SECRETS_ENV}"
          return 1
      fi
  fi

  # Now download and set ENV specified using the `variables` plugin param
  process_variables

  if [[ "${BUILDKITE_PLUGIN_SECRETS_SKIP_REDACTION:-}" != "true" ]] && [[ ${#BUILDKITE_SECRETS_TO_REDACT[@]} -gt 0 ]]; then
    redact_secrets BUILDKITE_SECRETS_TO_REDACT
  fi
}
