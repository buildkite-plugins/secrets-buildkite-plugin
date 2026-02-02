#!/bin/bash

setup_azure_environment() {
  check_dependencies

  if [[ -z "${BUILDKITE_PLUGIN_SECRETS_AZURE_VAULT_NAME:-}" ]]; then
    log_error "azure-vault-name is required when using the Azure provider"
    log_info "Set 'azure-vault-name' in your plugin configuration"
    exit 1
  fi
}

az_secret_get_with_retry() {
  local SECRET_NAME="$1"
  local VAULT_NAME="${BUILDKITE_PLUGIN_SECRETS_AZURE_VAULT_NAME}"
  local MAX_ATTEMPTS="${BUILDKITE_PLUGIN_SECRETS_RETRY_MAX_ATTEMPTS:-5}"
  local BASE_DELAY="${BUILDKITE_PLUGIN_SECRETS_RETRY_BASE_DELAY:-2}"
  local ATTEMPT=1
  local EXIT_CODE
  local OUTPUT

  local cmd=(az keyvault secret show
    --vault-name "${VAULT_NAME}"
    --name "${SECRET_NAME}"
    --query "value"
    -o tsv
  )

  # Add version if specified
  if [[ -n "${BUILDKITE_PLUGIN_SECRETS_AZURE_SECRET_VERSION:-}" ]]; then
    cmd+=(--version "${BUILDKITE_PLUGIN_SECRETS_AZURE_SECRET_VERSION}")
  fi

  while [ "$ATTEMPT" -le "$MAX_ATTEMPTS" ]; do
    local STDERR_TMP
    STDERR_TMP=$(mktemp)
    trap "rm -f '$STDERR_TMP'" RETURN

    set +e
    OUTPUT=$("${cmd[@]}" 2>"$STDERR_TMP")
    EXIT_CODE=$?
    set -e

    local STDERR_OUTPUT
    STDERR_OUTPUT=$(cat "$STDERR_TMP")
    rm -f "$STDERR_TMP"

    if [ "$EXIT_CODE" -eq 0 ]; then
      echo "$OUTPUT"
      return 0
    fi

    # Check for non-retryable errors (4xx equivalents)
    if echo "$STDERR_OUTPUT" | grep -qiE "SecretNotFound|ResourceNotFound|\(404\)|Forbidden|\(403\)|Unauthorized|\(401\)|BadParameter|\(400\)"; then
      echo "$STDERR_OUTPUT" >&2
      return "$EXIT_CODE"
    fi

    if [ "$ATTEMPT" -lt "$MAX_ATTEMPTS" ]; then
      local TOTAL_DELAY
      TOTAL_DELAY=$(calculate_backoff_delay "$BASE_DELAY" "$ATTEMPT")

      log_info "Failed to fetch secret ${SECRET_NAME} (attempt ${ATTEMPT}/${MAX_ATTEMPTS}). Retrying in ${TOTAL_DELAY}s..."
      echo "Error: $STDERR_OUTPUT" >&2

      sleep "$TOTAL_DELAY"
      ATTEMPT=$((ATTEMPT + 1))
    else
      log_error "Failed to fetch secret ${SECRET_NAME} after ${MAX_ATTEMPTS} attempts"
      echo "Error: $STDERR_OUTPUT" >&2
      return "$EXIT_CODE"
    fi
  done
}

download_azure_secret() {
  local secret_name="$1"

  # Validate secret name (Azure allows alphanumeric and hyphens, must start with alphanumeric)
  if [[ ! "$secret_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]]; then
    log_error "Invalid Azure secret name: '${secret_name}' (must contain only alphanumeric characters and hyphens, and start with an alphanumeric character)"
    return 1
  fi

  local output
  if output=$(az_secret_get_with_retry "${secret_name}"); then
    echo "${output}"
  else
    log_error "Failed to fetch Azure secret: ${secret_name}"
    return 1
  fi
}

process_azure_secrets() {
  local encoded_secret="$1"
  local key_name="$2"
  local decoded_secret
  local key value

  if ! decoded_secret=$(echo "$encoded_secret" | base64 -d 2>&1); then
    log_error "Failed to decode base64 secret for key: ${key_name}"
    log_error "The secret may be malformed or not properly base64-encoded"
    return 1
  fi

  if [[ -z "$decoded_secret" ]] || [[ "$decoded_secret" =~ ^[[:space:]]+$ ]]; then
    log_error "Decoded secret for key: ${key_name} is empty or contains only whitespace"
    return 1
  fi

  while IFS='=' read -r key value; do
    if [ -n "$key" ] && [ -n "$value" ]; then
      # Validate the key is a valid shell variable name
      if [[ ! "$key" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
        log_warning "Skipping invalid variable name '${key}' in secret '${key_name}' (must start with letter or underscore)"
        continue
      fi

      AZURE_SECRETS_TO_REDACT+=("$value")
      export "$key=$value"
    fi
  done <<< "$decoded_secret"
}

process_azure_variables() {
  for param in ${!BUILDKITE_PLUGIN_SECRETS_VARIABLES_*}; do
    key="${param/BUILDKITE_PLUGIN_SECRETS_VARIABLES_/}"
    path="${!param}"

    # Validate the variable name
    if [[ ! "$key" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
      log_warning "Skipping invalid variable name '${key}'"
      continue
    fi

    if ! value=$(download_azure_secret "${path}"); then
      log_error "Unable to find secret at ${path}"
      exit 1
    else
      AZURE_SECRETS_TO_REDACT+=("$value")
      export "$key=$value"
    fi
  done
}

fetch_azure_secrets() {
  local AZURE_SECRETS_TO_REDACT=()
  local secret

  # Disable debug tracing to prevent secret leaks
  local xtrace_was_set=0
  [[ -o xtrace ]] && xtrace_was_set=1
  { set +x; } 2>/dev/null

  log_info "Fetching Azure Key Vault secrets"

  if [[ -n "${BUILDKITE_PLUGIN_SECRETS_ENV+x}" ]]; then
    if secret=$(download_azure_secret "${BUILDKITE_PLUGIN_SECRETS_ENV}"); then
      process_azure_secrets "${secret}" "${BUILDKITE_PLUGIN_SECRETS_ENV}"
    else
      log_error "No secret found at ${BUILDKITE_PLUGIN_SECRETS_ENV}"
      if [[ $xtrace_was_set -eq 1 ]]; then set -x; else { set +x; } 2>/dev/null; fi
      return 1
    fi
  fi

  process_azure_variables

  if [[ "${BUILDKITE_PLUGIN_SECRETS_SKIP_REDACTION:-}" != "true" ]] && [[ ${#AZURE_SECRETS_TO_REDACT[@]} -gt 0 ]]; then
    redact_secrets AZURE_SECRETS_TO_REDACT
  fi

  if [[ $xtrace_was_set -eq 1 ]]; then set -x; else { set +x; } 2>/dev/null; fi
}
