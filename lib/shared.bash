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

  if [[ -n "${BUILDKITE_PLUGIN_SECRETS_GIT_CREDENTIALS:-}" ]] && ! command_exists git; then
    missing_deps+=("git")
    log_error "git is required when using the git-credentials option"
    log_info "Please install git and try again."
  fi

  if [[ -n "${BUILDKITE_PLUGIN_SECRETS_GIT_SSH_KEY:-}" ]] && ! command_exists git; then
    missing_deps+=("git")
    log_error "git is required when using the git-ssh-key option"
    log_info "Please install git and try again."
  fi

  if [[ -n "${BUILDKITE_PLUGIN_SECRETS_GIT_SSH_KEY:-}" ]] && ! command_exists ssh; then
    missing_deps+=("ssh")
    log_error "ssh is required when using the git-ssh-key option"
    log_info "Please install OpenSSH and try again."
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
    azure)
      if ! command_exists az; then
        missing_deps+=("az")
        log_error "Azure CLI (az) is required for Azure Key Vault"
        log_info "Install: https://learn.microsoft.com/en-us/cli/azure/install-azure-cli"
      fi
      ;;
    op)
      if ! command_exists op; then
        missing_deps+=("op")
        log_error "1Password CLI (op) is required for 1Password secrets"
        log_info "Install: https://developer.1password.com/docs/cli/get-started/"
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
        local decode_tmp raw_size clean_size
        decode_tmp=$(mktemp)

        for padding in "" "=" "=="; do
          # Decode to a temp file so we can check for binary/null-byte content
          # before assigning to a bash variable (bash warns and strips null bytes
          # when command substitution output contains them)
          if echo "${secret}${padding}" | base64 -d > "$decode_tmp" 2>/dev/null && [[ -s "$decode_tmp" ]]; then
            # Skip if decoded value contains null bytes — use tr/wc rather than grep
            # because grep implementations vary in how they handle null bytes
            raw_size=$(wc -c < "$decode_tmp")
            clean_size=$(tr -d '\0' < "$decode_tmp" | wc -c)
            if [[ "$raw_size" != "$clean_size" ]]; then
              continue
            fi

            # Skip if decoded value contains other non-printable/binary data
            if LC_ALL=C grep -q '[^[:print:][:space:]]' "$decode_tmp" 2>/dev/null; then
              continue
            fi

            decoded=$(cat "$decode_tmp")
            if [[ -n "$decoded" ]]; then
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

        rm -f "$decode_tmp"
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

provider_download_secret() {
  local key="$1"
  case "${BUILDKITE_PLUGIN_SECRETS_PROVIDER}" in
    buildkite)
      download_secret "$key"
      ;;
    gcp)
      download_gcp_secret "$key"
      ;;
    azure)
      download_azure_secret "$key"
      ;;
    op)
      download_op_secret "$key"
      ;;
    *)
      unknown_provider "${BUILDKITE_PLUGIN_SECRETS_PROVIDER}"
      ;;
  esac
}

# Decode a fetched secret if it is base64 encoded, checking for markers
decode_if_base64() {
  # Disable xtrace to prevent leaks
  local xtrace_was_set=0
  [[ -o xtrace ]] && xtrace_was_set=1
  { set +x; } 2>/dev/null

  local value="$1" marker="$2" decoded result

  if [[ "$value" == *"$marker"* ]]; then
    result="$value"
  elif decoded=$(printf '%s' "$value" | base64 -d 2>/dev/null) && [[ "$decoded" == *"$marker"* ]]; then
    result="$decoded"
  else
    result="$value"
  fi

  printf '%s' "$result"

  if [[ $xtrace_was_set -eq 1 ]]; then set -x; fi
}

validate_git_auth_config() {
  if [[ -n "${BUILDKITE_PLUGIN_SECRETS_GIT_CREDENTIALS:-}" && -n "${BUILDKITE_PLUGIN_SECRETS_GIT_SSH_KEY:-}" ]]; then
    log_error "git-credentials and git-ssh-key are mutually exclusive. Configure one git auth method per step."
    exit 1
  fi
}

git_credentials_file() {
  if [[ -n "${BUILDKITE_PLUGIN_SECRETS_GIT_CREDENTIALS_FILE:-}" ]]; then
    echo "${BUILDKITE_PLUGIN_SECRETS_GIT_CREDENTIALS_FILE}"
  else
    local dir="${TMPDIR:-/tmp}"
    echo "${dir%/}/buildkite-secrets-git-credentials${BUILDKITE_JOB_ID:+-${BUILDKITE_JOB_ID}}"
  fi
}

# Append a git config to the GIT_CONFIG_* environment variables
# so we can make ephemeral git config without touching persistent files
git_config_env_add() {
  local n="${GIT_CONFIG_COUNT:-0}"

  if [[ ! "$n" =~ ^[0-9]+$ ]]; then
    log_warning "Ignoring non-numeric inherited GIT_CONFIG_COUNT '${n}'"
    n=0
  fi

  export "GIT_CONFIG_KEY_${n}=$1"
  export "GIT_CONFIG_VALUE_${n}=$2"
  export "GIT_CONFIG_COUNT=$((n + 1))"
}

write_secret_file() {
  local xtrace_was_set=0
  [[ -o xtrace ]] && xtrace_was_set=1
  { set +x; } 2>/dev/null

  local dest="$1" content="$2" dir src rc=0

  # Refuse a dir, trailing-slash or empty dest
  if [[ -z "$dest" || "$dest" == */ || -d "$dest" ]]; then
    if [[ $xtrace_was_set -eq 1 ]]; then set -x; fi
    return 1
  fi

  dir="$(dirname "$dest")"
  src="$(mktemp "${dir}/.bk-secret.XXXXXX" 2>/dev/null)" || rc=1

  if [[ $rc -eq 0 ]]; then
    chmod 600 "$src" 2>/dev/null || true
    printf '%s\n' "$content" >"$src" || rc=1
  fi

  if [[ $rc -eq 0 ]]; then
    if mv -f "$src" "$dest" 2>/dev/null; then
      src=""   # moved into place, no temp left to clean up
    else
      rc=1
    fi
  fi

  if [[ $rc -eq 0 && ( ! -f "$dest" || -L "$dest" ) ]]; then rc=1; fi
  if [[ -n "${src:-}" ]]; then rm -f "$src" 2>/dev/null || true; fi
  if [[ $xtrace_was_set -eq 1 ]]; then set -x; fi
  return $rc
}

# Single quote $1 for safe embedding in a shell command string, escaping embedded quotes.
sh_quote() {
  local sq="'\''"
  printf "'%s'" "${1//\'/$sq}"
}

# Extract the protocol, host and port from one git credentials line
credential_url_scope() {
  local xtrace_was_set=0
  [[ -o xtrace ]] && xtrace_was_set=1
  { set +x; } 2>/dev/null

  local line proto rest hostport rc=0
  line="${1//[[:space:]]/}"
  if [[ "$line" == *"://"* ]]; then
    proto="${line%%://*}"
    rest="${line#*://}"
    rest="${rest##*@}"
    hostport="${rest%%/*}"
    if [[ -n "$proto" && -n "$hostport" ]]; then
      printf '%s://%s' "$proto" "$hostport"
    else
      rc=1
    fi
  else
    rc=1
  fi

  if [[ $xtrace_was_set -eq 1 ]]; then set -x; fi
  return $rc
}

configure_git_credentials() {
  local key="${BUILDKITE_PLUGIN_SECRETS_GIT_CREDENTIALS:-}"
  [[ -z "$key" ]] && return 0

  # Disable debug tracing to prevent secret values from leaking to logs
  local xtrace_was_set=0
  [[ -o xtrace ]] && xtrace_was_set=1
  { set +x; } 2>/dev/null

  log_info "Configuring git credentials from secret '${key}'"

  local creds

  if ! creds=$(provider_download_secret "$key"); then
    log_error "Unable to fetch git-credentials secret at ${key}"
    exit 1
  fi

  local creds_value

  creds_value="$(decode_if_base64 "$creds" "://")"

  creds_value="${creds_value//$'\r'/}"

  if [[ -z "${creds_value//[[:space:]]/}" ]]; then
    log_error "git-credentials secret '${key}' is empty"
    exit 1
  fi

  # Redact before writing
  if [[ "${BUILDKITE_PLUGIN_SECRETS_SKIP_REDACTION:-}" != "true" ]]; then
    local GIT_CREDENTIALS_TO_REDACT=("$creds")
    if [[ "$creds_value" != "$creds" ]]; then
      GIT_CREDENTIALS_TO_REDACT+=("$creds_value")
    fi
    redact_secrets GIT_CREDENTIALS_TO_REDACT
  fi

  local creds_file

  creds_file="$(git_credentials_file)"
  if [[ "$creds_file" != /* ]]; then
    log_error "git-credentials-file must be an absolute path (got '${creds_file}')"
    exit 1
  fi

  if ! write_secret_file "$creds_file" "$creds_value"; then
    log_error "Unable to write git credentials file at ${creds_file}"
    exit 1
  fi

  # Scope the helper per host and reset inherited helpers for those hosts, so nothing else can intercept or store the token.
  local helper line scope seen=" " scoped=0

  helper="store --file=$(sh_quote "${creds_file}")"

  while IFS= read -r line; do
    scope="$(credential_url_scope "$line")" || continue
    [[ "$seen" == *" ${scope} "* ]] && continue
    seen+="${scope} "
    git_config_env_add "credential.${scope}.helper" ""
    git_config_env_add "credential.${scope}.helper" "$helper"
    scoped=1
  done <<< "$creds_value"

  if [[ $scoped -eq 0 ]]; then
    log_error "git-credentials secret '${key}' has no usable URL lines"
    exit 1
  fi

  log_success "Configured git 'store' credential helper from secret '${key}'"

  if [[ $xtrace_was_set -eq 1 ]]; then set -x; fi
}

# Ripped from here:
# https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints
GITHUB_SSH_KNOWN_HOSTS="github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=
github.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk="

# Written by the environment hook and removed by pre-exit.
git_ssh_key_file() {
  local dir="${TMPDIR:-/tmp}"
  echo "${dir%/}/buildkite-secrets-git-ssh-key${BUILDKITE_JOB_ID:+-${BUILDKITE_JOB_ID}}"
}

git_ssh_known_hosts_file() {
  local dir="${TMPDIR:-/tmp}"
  echo "${dir%/}/buildkite-secrets-git-ssh-known-hosts${BUILDKITE_JOB_ID:+-${BUILDKITE_JOB_ID}}"
}

# Configures core.sshCommand to use the fetched key, keeping host-key
# verification on with known_hosts defaulting to GitHub's, or git-ssh-known-hosts.
configure_git_ssh() {
  local key="${BUILDKITE_PLUGIN_SECRETS_GIT_SSH_KEY:-}"
  [[ -z "$key" ]] && return 0

  # Disable debug tracing to prevent the key from leaking to logs
  local xtrace_was_set=0
  [[ -o xtrace ]] && xtrace_was_set=1
  { set +x; } 2>/dev/null

  log_info "Configuring git SSH key from secret '${key}'"

  local ssh_key
  if ! ssh_key=$(provider_download_secret "$key"); then
    log_error "Unable to fetch git-ssh-key secret at ${key}"
    exit 1
  fi

  local ssh_key_value
  ssh_key_value="$(decode_if_base64 "$ssh_key" "PRIVATE KEY")"
  ssh_key_value="${ssh_key_value//$'\r'/}"
  if [[ -z "${ssh_key_value//[[:space:]]/}" ]]; then
    log_error "git-ssh-key secret '${key}' is empty"
    exit 1
  fi

  # Redact before writing, covering the decoded form too
  if [[ "${BUILDKITE_PLUGIN_SECRETS_SKIP_REDACTION:-}" != "true" ]]; then
    # shellcheck disable=SC2034
    local GIT_SSH_KEY_TO_REDACT=("$ssh_key")
    if [[ "$ssh_key_value" != "$ssh_key" ]]; then
      GIT_SSH_KEY_TO_REDACT+=("$ssh_key_value")
    fi
    redact_secrets GIT_SSH_KEY_TO_REDACT
  fi

  local key_file known_hosts_file
  key_file="$(git_ssh_key_file)"
  known_hosts_file="$(git_ssh_known_hosts_file)"

  if ! write_secret_file "$key_file" "$ssh_key_value"; then
    log_error "Unable to write SSH key file at ${key_file}"
    exit 1
  fi

  local known_hosts="${GITHUB_SSH_KNOWN_HOSTS}"
  if [[ -n "${BUILDKITE_PLUGIN_SECRETS_GIT_SSH_KNOWN_HOSTS:-}" ]]; then
    known_hosts="${BUILDKITE_PLUGIN_SECRETS_GIT_SSH_KNOWN_HOSTS}"
  fi
  if ! write_secret_file "$known_hosts_file" "$known_hosts"; then
    log_error "Unable to write SSH known_hosts file at ${known_hosts_file}"
    exit 1
  fi

  git_config_env_add core.sshCommand \
    "ssh -F /dev/null -i $(sh_quote "${key_file}") -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes -o UserKnownHostsFile=$(sh_quote "${known_hosts_file}") -o StrictHostKeyChecking=yes"

  log_success "Configured git SSH key from secret '${key}'"

  if [[ $xtrace_was_set -eq 1 ]]; then set -x; fi
}
