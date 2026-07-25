cmd_key() {
  local spec="${1:-}"
  [[ -z "$spec" ]] && { echo "usage: ccs key <provider>[@<account>]" >&2; exit 1; }
  _resolve_spec_or_die "$spec"
  local provider="$SPEC_PROVIDER" account="$SPEC_ACCOUNT" path
  path="$(_account_path "$provider" "$account")"

  # An OAuth account has no API key to set: its credentials live in the account's
  # own config dir (or the macOS Keychain), not in this file.
  if [[ "$(_provider_auth "$provider")" == "oauth" ]]; then
    echo "error: '$provider' signs in with OAuth — there is no API key to set" >&2
    echo "Sign in with: ccs login $provider@$account" >&2
    exit 1
  fi

  _require_jq
  read -rsp "New API key for '$provider@$account': " new_key
  echo
  local tmp
  tmp="$(mktemp)"
  jq --arg k "$new_key" '.env.ANTHROPIC_AUTH_TOKEN = $k' "$path" > "$tmp" && mv "$tmp" "$path"
  chmod 600 "$path"
  echo "Updated API key for $provider@$account"
}
