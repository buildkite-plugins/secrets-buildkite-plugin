#!/bin/bash

setup_gcp_environment() {
  check_dependencies

  # Validate GCP project is configured (either via plugin option, env var, or gcloud config)
  local project="${BUILDKITE_PLUGIN_SECRETS_GCP_PROJECT:-}"
  if [[ -z "$project" ]] && [[ -z "${CLOUDSDK_CORE_PROJECT:-}" ]]; then
    # Try to get from gcloud config
    if ! project=$(gcloud config get-value project 2>/dev/null) || [[ -z "$project" ]]; then
      log_error "GCP project not configured. Set gcp-project plugin option, CLOUDSDK_CORE_PROJECT, or run 'gcloud config set project PROJECT_ID'"
      exit 1
    fi
  fi

  log_info "GCP Secret Manager provider initialized"
}

gcp_secret_get_with_retry() {
  local SECRET_ID="$1"
  local VERSION="${BUILDKITE_PLUGIN_SECRETS_GCP_SECRET_VERSION:-latest}"
  local PROJECT="${BUILDKITE_PLUGIN_SECRETS_GCP_PROJECT:-${CLOUDSDK_CORE_PROJECT:-}}"
  local MAX_ATTEMPTS="${BUILDKITE_PLUGIN_SECRETS_RETRY_MAX_ATTEMPTS:-5}"
  local BASE_DELAY="${BUILDKITE_PLUGIN_SECRETS_RETRY_BASE_DELAY:-2}"
  local ATTEMPT=1
  local EXIT_CODE
  local OUTPUT
  local ERROR_OUTPUT
  local STDERR_TMP

  STDERR_TMP=$(mktemp)
  # shellcheck disable=SC2064
  trap "rm -f '$STDERR_TMP'" RETURN

  # Build command as an array to avoid eval
  local cmd=(gcloud secrets versions access "${VERSION}" --secret="${SECRET_ID}")
  if [[ -n "$PROJECT" ]]; then
    cmd+=(--project="${PROJECT}")
  fi

  while [ "$ATTEMPT" -le "$MAX_ATTEMPTS" ]; do
    set +e
    OUTPUT=$("${cmd[@]}" 2>"$STDERR_TMP")
    EXIT_CODE=$?
    ERROR_OUTPUT=$(cat "$STDERR_TMP")
    set -e

    if [ "$EXIT_CODE" -eq 0 ]; then
      echo "$OUTPUT"
      return 0
    fi

    # Non-retryable errors: INVALID_ARGUMENT, UNAUTHENTICATED, PERMISSION_DENIED, NOT_FOUND
    if echo "$ERROR_OUTPUT" | grep -qiE "(INVALID_ARGUMENT|UNAUTHENTICATED|PERMISSION_DENIED|NOT_FOUND|400|401|403|404)"; then
      echo "$ERROR_OUTPUT"
      return "$EXIT_CODE"
    fi

    # Retryable errors: UNAVAILABLE, RESOURCE_EXHAUSTED, network errors
    if [ "$ATTEMPT" -lt "$MAX_ATTEMPTS" ]; then
      local TOTAL_DELAY
      TOTAL_DELAY=$(calculate_backoff_delay "$BASE_DELAY" "$ATTEMPT")

      log_info "Failed to fetch GCP secret $SECRET_ID (attempt $ATTEMPT/$MAX_ATTEMPTS). Retrying in ${TOTAL_DELAY}s..."
      echo "Error: $ERROR_OUTPUT" >&2

      sleep "$TOTAL_DELAY"
      ATTEMPT=$((ATTEMPT + 1))
    else
      log_error "Failed to fetch GCP secret $SECRET_ID after $MAX_ATTEMPTS attempts"
      echo "Error: $ERROR_OUTPUT" >&2
      return "$EXIT_CODE"
    fi
  done
}

download_gcp_secret() {
  local key=$1
  local output

  if output=$(gcp_secret_get_with_retry "${key}"); then
    echo "${output}"
  else
    log_error "Failed to fetch GCP secret ${key}"
    return 1
  fi
}

process_gcp_secrets() {
  local encoded_secret=$1
  local key_name=$2
  local decoded_secret
  local key value

  if ! decoded_secret=$(echo "$encoded_secret" | base64 -d 2>&1); then
    log_error "Failed to decode base64 secret for key: ${key_name}"
    log_error "The secret may be malformed or not properly base64-encoded"
    exit 1
  fi

  if [[ -z "$decoded_secret" ]] || [[ "$decoded_secret" =~ ^[[:space:]]+$ ]]; then
    log_error "Decoded secret for key: ${key_name} is empty or contains only whitespace"
    exit 1
  fi

  while IFS='=' read -r key value; do
    if [ -n "$key" ] && [ -n "$value" ]; then
      if [[ ! "$key" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
        log_warning "Skipping invalid variable name '${key}' in secret '${key_name}' (must start with letter or underscore)"
        continue
      fi

      GCP_SECRETS_TO_REDACT+=("$value")
      export "$key=$value"
    fi
  done <<< "$decoded_secret"
}

process_gcp_variables() {
  for param in ${!BUILDKITE_PLUGIN_SECRETS_VARIABLES_*}; do
    key="${param/BUILDKITE_PLUGIN_SECRETS_VARIABLES_/}"
    path="${!param}"

    if ! value=$(gcp_secret_get_with_retry "${path}"); then
      log_error "Unable to find GCP secret at ${path}"
      exit 1
    else
      GCP_SECRETS_TO_REDACT+=("$value")
      export "${key}=${value}"
    fi
  done
}

fetch_gcp_secrets() {
  local GCP_SECRETS_TO_REDACT=()
  local secret

  log_info "Fetching secrets from GCP Secret Manager"

  # If we are using a specific key we should download and evaluate it
  if [[ -n "${BUILDKITE_PLUGIN_SECRETS_ENV+x}" ]]; then
    if secret=$(download_gcp_secret "${BUILDKITE_PLUGIN_SECRETS_ENV}"); then
      process_gcp_secrets "${secret}" "${BUILDKITE_PLUGIN_SECRETS_ENV}"
    else
      log_error "No secret found at ${BUILDKITE_PLUGIN_SECRETS_ENV}"
      return 1
    fi
  fi

  # Now download and set ENV specified using the `variables` plugin param
  process_gcp_variables

  if [[ "${BUILDKITE_PLUGIN_SECRETS_SKIP_REDACTION:-}" != "true" ]] && [[ ${#GCP_SECRETS_TO_REDACT[@]} -gt 0 ]]; then
    redact_secrets GCP_SECRETS_TO_REDACT
  fi
}
