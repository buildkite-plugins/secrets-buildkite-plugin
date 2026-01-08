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
  fi

  if ! command_exists base64; then
    missing_deps+=("base64")
  fi

  case "${BUILDKITE_PLUGIN_SECRETS_PROVIDER}" in
    buildkite)
      # No additional deps beyond the base checks above
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
  local secrets_array=()
  eval "secrets_array=(\"\${${secrets_array_name}[@]}\")"

  # Disable debug tracing for this function to prevent secret leaks
  local xtrace_was_set=0
  [[ -o xtrace ]] && xtrace_was_set=1
  { set +x; } 2>/dev/null
  log_info "Disabling debug tracing to prevent secret leaks"

  if [[ ${#secrets_array[@]} -eq 0 ]]; then
    log_warning "No secrets detected to redact"
    if [[ $xtrace_was_set -eq 1 ]]; then set -x; else { set +x; } 2>/dev/null; fi
    return 0
  fi

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

    # Shout out to https://stackoverflow.com/questions/8571501/how-to-check-whether-a-string-is-base64-encoded-or-not for this regex
    # We should redact decoded base64 secrets as well
    if [[ "$secret" =~ ^([A-Za-z0-9+/]{4})*([A-Za-z0-9+/]{3}=|[A-Za-z0-9+/]{2}==)?$ ]]; then
      if ! command_exists base64; then
        log_warning "base64 secrets found, but base64 command is not available. Only the encoded values will be redacted."
      else
        local decoded
        if decoded=$(echo "$secret" | base64 -d 2>/dev/null) && [[ -n "$decoded" ]]; then

          buildkite-agent redactor add <<< "$decoded" 2>/dev/null || true

          local decoded_escaped
          decoded_escaped=$(printf '%q' "$decoded")
          if [[ "$decoded_escaped" != "$decoded" ]]; then
            buildkite-agent redactor add <<< "$decoded_escaped" 2>/dev/null || true
          fi
        fi
      fi
    fi
  done

  if [[ $xtrace_was_set -eq 1 ]]; then set -x; else { set +x; } 2>/dev/null; fi
}