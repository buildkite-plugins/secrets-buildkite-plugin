#!/bin/bash
set -euo pipefail

log_info() {
  echo "[INFO]: $*"
}

log_success() {
  echo "[SUCCESS]: $*"
}

log_warning() {
  echo "[WARNING]: $*"
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

  case "${BUILDKITE_PLUGIN_SECRETS_PROVIDER}" in
    buildkite)
      # No deps here, feels redundant checking for buildkite-agent again
      return 0
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

