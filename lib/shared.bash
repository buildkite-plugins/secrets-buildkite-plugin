#!/bin/bash
set -euo pipefail

log_info() {
  echo "[INFO]: $*" >&2
}

log_success() {
  echo "[SUCCESS]: $*" >&2
}

log_warning() {
  echo "[WARNING]: $*" >&2
}

log_error() {
  echo "[ERROR]: $*" >&2
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

unknown_provider() {
  local provider="$1"
  log_error "Unknown provider: $provider"
  exit 1
}

check_dependencies() {
  local missing_deps=()

  # Requiring this here so we can use buildkite-agent secret redact
  if ! command_exists buildkite-agent; then
    missing_deps+=("buildkite-agent")
    log_error "buildkite-agent command is required"
    log_info "Please install buildkite-agent and try again."
  fi

  if [[ -n "${BUILDKITE_PLUGIN_SECRETS_ENV:-}" ]] && ! command_exists base64; then
    missing_deps+=("base64")
    log_error "base64 is required when using env files"
    log_info "Please install base64 and try again."
  fi

  case "${BUILDKITE_PLUGIN_SECRETS_PROVIDER}" in
    buildkite)
      # No additional deps beyond the base checks above
      ;;
    gcp)
      if ! command_exists gcloud; then
        missing_deps+=("gcloud")
        log_error "gcloud CLI is required for GCP Secret Manager"
        log_info "Install: https://cloud.google.com/sdk/docs/install"
      fi
      ;;
    *)
      unknown_provider "${BUILDKITE_PLUGIN_SECRETS_PROVIDER}"
      ;;
  esac

  if [[ ${#missing_deps[@]} -gt 0 ]]; then
    log_error "Missing required dependencies: ${missing_deps[*]}"
    log_error "Please install the missing dependencies and try again."
    exit 1
  fi
}

calculate_backoff_delay() {
  local BASE_DELAY="$1"
  local ATTEMPT="$2"
  local DELAY=$((BASE_DELAY * (2 ** (ATTEMPT - 1))))
  local JITTER=$((RANDOM % (DELAY / 4 + 1)))
  local TOTAL_DELAY=$((DELAY + JITTER))

  if [ "$TOTAL_DELAY" -gt 60 ]; then
    TOTAL_DELAY=60
  fi

  echo "$TOTAL_DELAY"
}

# This function is to be used inside providers get secrets functions
# See the buildkite provider for an example usage
redact_secrets() {
  local secrets_array_name=$1

  # Check if redaction is explicitly disabled
  if [[ "${BUILDKITE_PLUGIN_SECRETS_SKIP_REDACTION:-}" == "true" ]]; then
    log_warning "Secret redaction is disabled via skip-redaction option"
    return 0
  fi

  # We should validate the array name, to avoid command injection, low risk, but
  # better safe than sorry
  if [[ ! "$secrets_array_name" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
    log_error "Invalid array name: $secrets_array_name"
    return 1
  fi

  local secrets_array=()
  eval "secrets_array=(\"\${${secrets_array_name}[@]}\")"

  if [[ ${#secrets_array[@]} -eq 0 ]]; then
    log_info "No secrets to redact"
    return 0
  fi

  # Disable debug tracing for this function to prevent secret leaks
  local xtrace_was_set=0
  [[ -o xtrace ]] && xtrace_was_set=1
  if [[ $xtrace_was_set -eq 1 ]]; then
    log_info "Disabling debug tracing to prevent secret leaks"
  fi
  { set +x; } 2>/dev/null

  if ! buildkite-agent redactor add --help &>/dev/null; then
    log_warning "Your buildkite-agent version doesn't support secret redaction"
    log_warning "Upgrade to buildkite-agent v3.67.0 or later for automatic secret redaction"
    if [[ $xtrace_was_set -eq 1 ]]; then set -x; else { set +x; } 2>/dev/null; fi
    return 0
  fi

  log_info "Redacting ${#secrets_array[@]} secret(s)"

  for secret in "${secrets_array[@]}"; do
    if ! buildkite-agent redactor add <<< "$secret" 2>/dev/null; then
      log_warning "Failed to redact a secret value"
    fi

    # Account for shell-escaped versions of the secret, think JWT tokens, etc.
    local escaped
    escaped=$(printf '%q' "$secret")
    if [[ "$escaped" != "$secret" ]]; then
      buildkite-agent redactor add <<< "$escaped" 2>/dev/null || true
    fi

    # Try to decode as base64 and redact the decoded value as well.
    # This catches secrets that are stored base64-encoded.
    # We attempt decode on all secrets - if it's not valid base64, we skip it.
    if command_exists base64; then
      local decoded
      local is_valid_base64=false

      # Only attempt base64 decode on strings that:
      # 1. Are at least 4 characters (minimum valid base64)
      # 2. Contain only base64 characters
       if [[ ${#secret} -ge 4 ]] && [[ "$secret" =~ ^[A-Za-z0-9+/_-]+(={0,2})?$ ]]; then
        # Try decoding with different padding scenarios (standard, +1 pad, +2 pads)
        # This handles both padded and unpadded base64 strings
        for padding in "" "=" "=="; do
          if decoded=$(echo "${secret}${padding}" | base64 -d 2>/dev/null) && [[ -n "$decoded" ]]; then
            # Skip if decoded value contains non-printable/binary data
            # This prevents false positives where random strings decode to garbage
            if ! LC_ALL=C grep -q '[^[:print:][:space:]]' <<< "$decoded" 2>/dev/null; then
              # Validate with round-trip: encode the decoded value and check if it matches
              # Check both with and without trailing newline as different base64 implementations vary
              local reencoded_with_newline reencoded_without_newline
              reencoded_with_newline=$(echo "$decoded" | base64 2>/dev/null)
              reencoded_without_newline=$(echo -n "$decoded" | base64 2>/dev/null)

              # Remove any padding from reencoded values for comparison with potentially unpadded input
              reencoded_with_newline="${reencoded_with_newline//=/}"
              reencoded_without_newline="${reencoded_without_newline//=/}"
              local secret_no_padding="${secret//=/}"

              if [[ "$reencoded_with_newline" == "$secret_no_padding" ]] || \
                 [[ "$reencoded_without_newline" == "$secret_no_padding" ]] || \
                 [[ "$(echo "$decoded" | base64 2>/dev/null)" == "$secret" ]] || \
                 [[ "$(echo -n "$decoded" | base64 2>/dev/null)" == "$secret" ]]; then
                is_valid_base64=true
                break
              fi
            fi
          fi
        done
      fi

      # Only redact if we successfully validated it's real base64 and decoded value differs from original
      if [[ "$is_valid_base64" == "true" ]] && [[ "$decoded" != "$secret" ]]; then
        buildkite-agent redactor add <<< "$decoded" 2>/dev/null || true

        local decoded_escaped
        decoded_escaped=$(printf '%q' "$decoded")
        if [[ "$decoded_escaped" != "$decoded" ]]; then
          buildkite-agent redactor add <<< "$decoded_escaped" 2>/dev/null || true
        fi
      fi
    fi
  done

  if [[ $xtrace_was_set -eq 1 ]]; then set -x; else { set +x; } 2>/dev/null; fi
}
