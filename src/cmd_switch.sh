cmd_switch() {
  local spec="${1:-}"
  if [[ -z "$spec" ]]; then
    echo "Available profiles:"
    cmd_list
    echo ""
    echo "Usage: ccs switch <provider>[@<account>]"
    return 1
  fi

  _resolve_spec_or_die "$spec"
  local provider="$SPEC_PROVIDER" account="$SPEC_ACCOUNT" path
  path="$(_account_path "$provider" "$account")"

  local token base_url
  token="$(_read_env_field "$path" ANTHROPIC_AUTH_TOKEN)"
  base_url="$(_read_env_field "$path" ANTHROPIC_BASE_URL)"

  if [[ -n "$base_url" ]]; then
    if [[ -z "$token" || "$token" == '""' ]]; then
      echo "error: '$provider@$account' has no API key set" >&2
      echo "Set it with: ccs key $provider@$account" >&2
      return 1
    fi
  fi

  ln -sfn "$path" "$ACTIVE_LINK"
  _set_last_account "$provider" "$account"

  if [[ "$(_list_accounts "$provider" | wc -l | tr -d ' ')" -le 1 ]]; then
    echo "Switched to $provider"
  else
    echo "Switched to $provider@$account"
  fi
}
