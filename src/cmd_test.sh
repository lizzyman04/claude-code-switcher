cmd_test() {
  _require_jq
  [[ ! -L "$ACTIVE_LINK" ]] && { echo "error: no active profile (run: ccs switch <name>)" >&2; exit 1; }

  local base_url auth_token model
  base_url="$(_read_env_field "$ACTIVE_LINK" ANTHROPIC_BASE_URL)"
  auth_token="$(_read_env_field "$ACTIVE_LINK" ANTHROPIC_AUTH_TOKEN)"
  model="$(_read_env_field "$ACTIVE_LINK" ANTHROPIC_MODEL)"

  printf "Testing %s (%s)... " "$(_active_name)" "$model"

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
    echo "FAIL (HTTP $status${msg:+: $msg})"
    exit 1
  fi
}
