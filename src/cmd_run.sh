cmd_run() {
  local provider="" model="" key="" small_model="" ephemeral=0
  local -a extra_args=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --provider)    provider="$2";    shift 2 ;;
      --model)       model="$2";       shift 2 ;;
      --key)         key="$2";         shift 2 ;;
      --small-model) small_model="$2"; shift 2 ;;
      --ephemeral)   ephemeral=1;      shift ;;
      --)            shift; extra_args+=("$@"); break ;;
      *)             break ;;
    esac
  done

  # Existing profile-name mode (backward compatible)
  if [[ -z "$provider" && $ephemeral -eq 0 ]]; then
    local name="${1:-}"
    [[ -z "$name" ]] && { echo "usage: ccs run <name> [claude args...]" >&2; exit 1; }
    local path
    path="$(_profile_path "$name")"
    [[ -f "$path" ]] || { echo "error: profile '$name' not found" >&2; exit 1; }
    shift
    exec claude --settings "$path" "$@"
  fi

  # Dynamic provider mode
  [[ -z "$provider" ]] && { echo "error: --provider is required" >&2; exit 1; }
  [[ -z "$model" ]]    && { echo "error: --model is required" >&2; exit 1; }

  declare -A PROVIDER_URLS=(
    ["deepseek"]="https://api.deepseek.com/anthropic"
    ["openrouter"]="https://openrouter.ai/api"
    ["fireworks"]="https://api.fireworks.ai/inference"
  )

  declare -A PROVIDER_ENV_VARS=(
    ["deepseek"]="DEEPSEEK_API_KEY"
    ["openrouter"]="OPENROUTER_API_KEY"
    ["fireworks"]="FIREWORKS_API_KEY"
  )

  local base_url="${PROVIDER_URLS[$provider]:-}"
  [[ -z "$base_url" ]] && { echo "error: unknown provider '$provider'" >&2; exit 1; }

  if [[ -z "$key" ]]; then
    local env_var="${PROVIDER_ENV_VARS[$provider]}"
    key="${!env_var:-}"
    [[ -z "$key" ]] && { echo "error: no API key — pass --key or set \$$env_var" >&2; exit 1; }
  fi

  local tmp
  tmp="$(mktemp /tmp/ccs-ephemeral-XXXX.json)"
  trap "rm -f '$tmp'" EXIT

  local json="{\"env\":{\"ANTHROPIC_BASE_URL\":\"$base_url\",\"ANTHROPIC_AUTH_TOKEN\":\"$key\",\"ANTHROPIC_MODEL\":\"$model\""
  [[ -n "$small_model" ]] && json+=",\"ANTHROPIC_SMALL_FAST_MODEL\":\"$small_model\""
  json+="}}"
  printf '%s\n' "$json" > "$tmp"

  exec claude --settings "$tmp" "$@" "${extra_args[@]}"
}
