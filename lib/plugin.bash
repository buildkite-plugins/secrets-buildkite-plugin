#!/bin/bash

# Initialise default config values (exported env-vars)
plugin_read_config() {
# Defaulting to base plugin values in order to not break backwards compatibility
  export BUILDKITE_PLUGIN_SECRETS_PROVIDER="${BUILDKITE_PLUGIN_SECRETS_PROVIDER:-buildkite}"
  export BUILDKITE_PLUGIN_SECRETS_RETRY_MAX_ATTEMPTS="${BUILDKITE_PLUGIN_SECRETS_RETRY_MAX_ATTEMPTS:-5}"
  export BUILDKITE_PLUGIN_SECRETS_RETRY_BASE_DELAY="${BUILDKITE_PLUGIN_SECRETS_RETRY_BASE_DELAY:-2}"
  export BUILDKITE_PLUGIN_SECRETS_SKIP_REDACTION="${BUILDKITE_PLUGIN_SECRETS_SKIP_REDACTION:-false}"

  # Optional vars
  [[ -n "${BUILDKITE_PLUGIN_SECRETS_ENV:-}" ]] && export BUILDKITE_PLUGIN_SECRETS_ENV

  # Export variables array
  for ((i=0; ; i++)); do
    local var_name="BUILDKITE_PLUGIN_SECRETS_VARIABLES_$i"
    if [[ -n "${!var_name:-}" ]]; then
      export "BUILDKITE_PLUGIN_SECRETS_VARIABLES_$i"
    else
      break
    fi
  done
}

# Load shared utilities
# shellcheck source=lib/shared.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/shared.bash"

# Export default configuration values so that later functions have them even
# when the user omits optional plugin keys
plugin_read_config

# Load provider implementations
# shellcheck source=lib/providers/buildkite.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/providers/buildkite.bash"

setup_provider_environment() {
  case "${BUILDKITE_PLUGIN_SECRETS_PROVIDER}" in
    buildkite)
      setup_buildkite_environment
      ;;
    *)
      unknown_provider "${BUILDKITE_PLUGIN_SECRETS_PROVIDER}"
      ;;
  esac
}

fetch_secrets() {
  case "${BUILDKITE_PLUGIN_SECRETS_PROVIDER}" in
    buildkite)
      fetch_buildkite_secrets
      ;;
    *)
      unknown_provider "${BUILDKITE_PLUGIN_SECRETS_PROVIDER}"
      ;;
  esac
}
