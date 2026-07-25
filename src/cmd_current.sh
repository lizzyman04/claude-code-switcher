cmd_current() {
  if ! _active_spec; then
    echo "No active profile. Run: ccs switch <provider>[@<account>]"
    return
  fi

  local provider="$ACTIVE_PROVIDER" account="$ACTIVE_ACCOUNT" auth home email
  auth="$(_provider_auth "$provider")"
  home="$(_resolve_home "$provider" "$account")"

  echo "Provider: $provider"
  echo "Account:  $account"
  echo "Auth:     $auth"

  if [[ "$auth" == "oauth" ]]; then
    email="$(_account_email "$home")"
    echo "Email:    ${email:-(not logged in)}"
    echo "Home:     $home"
  fi

  _require_jq
  jq 'del(.env.ANTHROPIC_AUTH_TOKEN)' "$ACTIVE_LINK"
}
