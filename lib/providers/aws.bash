#!/bin/bash

setup_aws_environment() {
  check_dependencies

  log_info "AWS Secrets Manager provider initialized"
}

aws_secret_get_with_retry() {
  local SECRET_ID="$1"
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
  local cmd=(aws secretsmanager get-secret-value --secret-id "${SECRET_ID}" --query SecretString --output text)

  if [[ -n "${BUILDKITE_PLUGIN_SECRETS_AWS_REGION:-}" ]]; then
    cmd+=(--region "${BUILDKITE_PLUGIN_SECRETS_AWS_REGION}")
  fi

  if [[ -n "${BUILDKITE_PLUGIN_SECRETS_AWS_SECRET_VERSION_ID:-}" ]]; then
    cmd+=(--version-id "${BUILDKITE_PLUGIN_SECRETS_AWS_SECRET_VERSION_ID}")
  fi

  if [[ -n "${BUILDKITE_PLUGIN_SECRETS_AWS_SECRET_VERSION_STAGE:-}" ]]; then
    cmd+=(--version-stage "${BUILDKITE_PLUGIN_SECRETS_AWS_SECRET_VERSION_STAGE}")
  fi

  while [[ "$ATTEMPT" -le "$MAX_ATTEMPTS" ]]; do
    set +e
    OUTPUT=$("${cmd[@]}" 2>"$STDERR_TMP")
    EXIT_CODE=$?
    ERROR_OUTPUT=$(<"$STDERR_TMP")
    set -e

    if [[ "$EXIT_CODE" -eq 0 ]]; then
      echo "$OUTPUT"
      return 0
    fi

    # Non-retryable errors: resource missing, bad input, auth/permission failures
    if echo "$ERROR_OUTPUT" | grep -qiE "(ResourceNotFoundException|AccessDeniedException|InvalidParameterException|InvalidRequestException|DecryptionFailure|UnrecognizedClientException|ExpiredTokenException|400|403|404)"; then
      log_error "$ERROR_OUTPUT"
      return "$EXIT_CODE"
    fi

    # Retryable errors: throttling, internal/service errors, network issues
    if [[ "$ATTEMPT" -lt "$MAX_ATTEMPTS" ]]; then
      local TOTAL_DELAY
      TOTAL_DELAY=$(calculate_backoff_delay "$BASE_DELAY" "$ATTEMPT")

      log_info "Failed to fetch AWS secret $SECRET_ID (attempt $ATTEMPT/$MAX_ATTEMPTS). Retrying in ${TOTAL_DELAY}s..."
      log_error "$ERROR_OUTPUT"

      sleep "$TOTAL_DELAY"
      ATTEMPT=$((ATTEMPT + 1))
    else
      log_error "Failed to fetch AWS secret $SECRET_ID after $MAX_ATTEMPTS attempts"
      log_error "$ERROR_OUTPUT"
      return "$EXIT_CODE"
    fi
  done
}

download_aws_secret() {
  local key=$1

  # Validate secret ID: allow secret names and ARNs (alphanumerics plus /_+=.@:-)
  if [[ ! "$key" =~ ^[A-Za-z0-9/_+=.@:-]+$ ]]; then
    log_error "Invalid AWS secret ID: '${key}'. Must contain only letters, numbers, and the characters / _ + = . @ : -"
    return 1
  fi

  local output

  if output=$(aws_secret_get_with_retry "${key}"); then
    echo "${output}"
  else
    log_error "Failed to fetch AWS secret ${key}"
    return 1
  fi
}

process_aws_secrets() {
  local encoded_secret="$1"
  local key_name="$2"
  local decoded_secret
  local key value

  local decode_status=0
  decoded_secret=$(echo "$encoded_secret" | base64 -d 2>/dev/null) || decode_status=$?

  if [[ $decode_status -ne 0 ]] || [[ -z "$decoded_secret" ]]; then
    log_error "Failed to decode base64 secret for key: ${key_name}"
    log_error "The secret may be malformed or not properly base64-encoded"
    return 1
  fi

  if [[ "$decoded_secret" =~ ^[[:space:]]+$ ]]; then
    log_error "Decoded secret for key: ${key_name} is empty or contains only whitespace"
    return 1
  fi

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    if [[ "$line" != *"="* ]]; then
      log_warning "Skipping malformed line in secret '${key_name}': missing '=' separator"
      continue
    fi

    key="${line%%=*}"
    value="${line#*=}"

    if [[ -n "$key" ]]; then
      if [[ ! "$key" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
        log_warning "Skipping invalid variable name '${key}' in secret '${key_name}' (must start with letter or underscore)"
        continue
      fi

      AWS_SECRETS_TO_REDACT+=("$value")
      export "$key=$value"
    fi
  done <<< "$decoded_secret"
}

process_aws_variables() {
  local key path value
  for param in ${!BUILDKITE_PLUGIN_SECRETS_VARIABLES_*}; do
    key="${param/BUILDKITE_PLUGIN_SECRETS_VARIABLES_/}"
    path="${!param}"

    if [[ ! "$key" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
      log_warning "Skipping invalid variable name '${key}'"
      continue
    fi

    if ! value=$(download_aws_secret "${path}"); then
      log_error "Unable to find AWS secret at ${path}"
      exit 1
    else
      AWS_SECRETS_TO_REDACT+=("$value")
      export "${key}=${value}"
    fi
  done
}

# Sanitizes a JSON key into a valid shell variable name, mirroring the
# seek-oss/aws-sm-buildkite-plugin convention: non-alphanumeric/underscore
# characters become '_' (e.g. "My-great key!" -> "My_great_key_"), and a
# leading digit is prefixed with '_' since shell variable names can't start
# with a digit.
sanitize_json_env_key() {
  local key="$1"
  local sanitized
  sanitized=$(echo "$key" | sed -E 's/[^A-Za-z0-9_]/_/g')
  [[ "$sanitized" =~ ^[0-9] ]] && sanitized="_${sanitized}"
  echo "$sanitized"
}

# Expands the keys of the JSON object found at json_key (a jq path) within a
# secret's value into individual environment variables, e.g. a secret
# {"Variables": {"DB_HOST": "db.example.com", "DB_PASSWORD": "secret"}} with
# json_key=".Variables" exports DB_HOST and DB_PASSWORD.
process_aws_json_secret() {
  local secret_value="$1"
  local json_key="$2"
  local key_name="$3"
  local key value sanitized_key
  local extracted

  if ! extracted=$(echo "$secret_value" | jq -e "${json_key}" 2>/dev/null); then
    log_error "Secret '${key_name}' is not valid JSON, or has no value at json-key '${json_key}'"
    return 1
  fi

  if ! echo "$extracted" | jq -e 'type == "object"' >/dev/null 2>&1; then
    log_error "JSON path '${json_key}' in secret '${key_name}' is not an object; cannot expand with json-variables"
    return 1
  fi

  while IFS=$'\t' read -r key value; do
    [[ -z "$key" ]] && continue

    sanitized_key=$(sanitize_json_env_key "$key")

    AWS_SECRETS_TO_REDACT+=("$value")
    export "${sanitized_key}=${value}"
  done < <(echo "$extracted" | jq -r 'to_entries[] | select(.value | type == "string" or type == "number" or type == "boolean") | [.key, (.value|tostring)] | @tsv')
}

process_aws_json_variables() {
  local i secret_id json_key value
  for ((i=0; ; i++)); do
    local secret_id_var="BUILDKITE_PLUGIN_SECRETS_JSON_VARIABLES_${i}_SECRET_ID"
    [[ -z "${!secret_id_var:-}" ]] && break

    secret_id="${!secret_id_var}"
    local json_key_var="BUILDKITE_PLUGIN_SECRETS_JSON_VARIABLES_${i}_JSON_KEY"
    json_key="${!json_key_var:-.}"

    if ! value=$(download_aws_secret "${secret_id}"); then
      log_error "Unable to find AWS secret at ${secret_id}"
      exit 1
    fi

    if ! process_aws_json_secret "${value}" "${json_key}" "${secret_id}"; then
      exit 1
    fi
  done
}

fetch_aws_secrets() {
  local AWS_SECRETS_TO_REDACT=()
  local secret

  # Disable debug tracing to prevent secret values from leaking to logs
  local xtrace_was_set=0
  [[ -o xtrace ]] && xtrace_was_set=1
  { set +x; } 2>/dev/null

  log_info "Fetching secrets from AWS Secrets Manager"

  # If we are using a specific key we should download and evaluate it
  if [[ -n "${BUILDKITE_PLUGIN_SECRETS_ENV+x}" ]]; then
    if secret=$(download_aws_secret "${BUILDKITE_PLUGIN_SECRETS_ENV}"); then
      process_aws_secrets "${secret}" "${BUILDKITE_PLUGIN_SECRETS_ENV}"
    else
      log_error "No secret found at ${BUILDKITE_PLUGIN_SECRETS_ENV}"
      if [[ $xtrace_was_set -eq 1 ]]; then set -x; else { set +x; } 2>/dev/null; fi
      return 1
    fi
  fi

  # Now download and set ENV specified using the `variables` plugin param
  process_aws_variables

  # Expand any secrets configured via `json-variables` into multiple env vars
  process_aws_json_variables

  if [[ "${BUILDKITE_PLUGIN_SECRETS_SKIP_REDACTION:-}" != "true" ]] && [[ ${#AWS_SECRETS_TO_REDACT[@]} -gt 0 ]]; then
    redact_secrets AWS_SECRETS_TO_REDACT
  fi

  # Restore xtrace after redaction
  if [[ $xtrace_was_set -eq 1 ]]; then set -x; else { set +x; } 2>/dev/null; fi
}
