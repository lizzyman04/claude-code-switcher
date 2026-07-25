cmd_test() {
  local spec="${1:-}"
  local provider account

  if [[ -n "$spec" ]]; then
    _resolve_spec_or_die "$spec"
    provider="$SPEC_PROVIDER"
    account="$SPEC_ACCOUNT"
  else
    _active_spec || { echo "error: no active account (run: ccs switch <provider>)" >&2; exit 1; }
    provider="$ACTIVE_PROVIDER"
    account="$ACTIVE_ACCOUNT"
  fi

  # OAuth accounts have no API key, so there is no request to sign. Ask Claude
  # Code about the account's config dir instead -- which also works on macOS,
  # where the token is in the Keychain and never on disk.
  if [[ "$(_provider_auth "$provider")" == "oauth" ]]; then
    _test_oauth "$provider" "$account"
    return
  fi

  _test_token "$provider" "$account"
}

_test_oauth() {
  local provider="$1" account="$2" home out
  home="$(_resolve_home "$provider" "$account")"

  printf "Testing %s@%s... " "$provider" "$account"

  if _is_native_home "$home"; then
    out="$(claude auth status --json 2>&1)" || true
  else
    out="$(env CLAUDE_CONFIG_DIR="$home" claude auth status --json 2>&1)" || true
  fi

  if ! command -v jq &>/dev/null; then
    echo ""
    printf '%s\n' "$out"
    return
  fi

  local logged email plan
  logged="$(printf '%s' "$out" | jq -r '.loggedIn // false' 2>/dev/null || echo false)"
  email="$(printf '%s' "$out" | jq -r '.email // empty' 2>/dev/null || true)"
  plan="$(printf '%s' "$out" | jq -r '.subscriptionType // empty' 2>/dev/null || true)"

  if [[ "$logged" == "true" ]]; then
    echo "OK${email:+ ($email${plan:+, $plan})}"
  else
    echo "NOT LOGGED IN"
    echo "Sign in with: ccs login $provider@$account" >&2
    exit 1
  fi
}

_test_token() {
  local provider="$1" account="$2" path
  path="$(_account_path "$provider" "$account")"
  _require_jq

  local base_url auth_token model
  base_url="$(_read_env_field "$path" ANTHROPIC_BASE_URL)"
  auth_token="$(_read_env_field "$path" ANTHROPIC_AUTH_TOKEN)"
  model="$(_read_env_field "$path" ANTHROPIC_MODEL)"

  if [[ -z "$auth_token" ]]; then
    echo "error: '$provider@$account' has no API key set (ccs key $provider@$account)" >&2
    exit 1
  fi

  printf "Testing %s@%s (%s)... " "$provider" "$account" "$model"

  local tmp status body
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' RETURN

  status="$(curl -s -o "$tmp" -w "%{http_code}" \
    -X POST "$base_url/messages" \
    -H "x-api-key: $auth_token" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d "{\"model\":\"$model\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}")"

  body="$(cat "$tmp")"

  if [[ "$status" =~ ^2 ]]; then
    echo "OK"
  else
    local msg
    msg="$(echo "$body" | jq -r '.error.message // .error // empty' 2>/dev/null || true)"
    # Some providers echo the rejected key back in the error text (DeepSeek does).
    # Never relay that to the terminal or a scrollback buffer.
    msg="${msg//"$auth_token"/***}"
    echo "FAIL (HTTP $status${msg:+: $msg})"
    exit 1
  fi
}
