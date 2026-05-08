cmd_add() {
  local name="${1:-}"
  [[ -z "$name" ]] && { echo "usage: ccs add <name>" >&2; exit 1; }
  local path
  path="$(_profile_path "$name")"
  [[ -f "$path" ]] && { echo "error: profile '$name' already exists (use: ccs edit $name)" >&2; exit 1; }
  mkdir -p "$PROFILES_DIR"

  declare -A PROVIDER_ENV_VARS=(
    ["deepseek"]="DEEPSEEK_API_KEY"
    ["openrouter"]="OPENROUTER_API_KEY"
    ["fireworks"]="FIREWORKS_API_KEY"
  )

  declare -A PROVIDER_DEFAULT_MODELS=(
    ["deepseek"]="deepseek-v4-pro"
  )

  read -rp "BASE URL: " base_url

  # Detect provider from URL to pre-fill token and model
  local detected_provider=""
  if [[ "$base_url" == *"deepseek"* ]];   then detected_provider="deepseek"
  elif [[ "$base_url" == *"openrouter"* ]]; then detected_provider="openrouter"
  elif [[ "$base_url" == *"fireworks"* ]];  then detected_provider="fireworks"
  fi

  local auth_token_default="" auth_token_hint="" default_model=""
  if [[ -n "$detected_provider" ]]; then
    local env_var="${PROVIDER_ENV_VARS[$detected_provider]:-}"
    if [[ -n "$env_var" ]]; then
      local detected_key="${!env_var:-}"
      if [[ -n "$detected_key" ]]; then
        auth_token_default="$detected_key"
        auth_token_hint=" (detected from \$$env_var) [press Enter to use]"
      fi
    fi
    default_model="${PROVIDER_DEFAULT_MODELS[$detected_provider]:-}"
  fi

  local auth_token
  read -rp "AUTH TOKEN$auth_token_hint: " auth_token
  [[ -z "$auth_token" && -n "$auth_token_default" ]] && auth_token="$auth_token_default"

  local model
  read -rp "MAIN MODEL${default_model:+ [$default_model]}: " model
  [[ -z "$model" && -n "$default_model" ]] && model="$default_model"

  read -rp "SMALL/FAST MODEL: " small_model

  cat > "$path" << EOF
{
  "env": {
    "ANTHROPIC_BASE_URL": "$base_url",
    "ANTHROPIC_AUTH_TOKEN": "$auth_token",
    "ANTHROPIC_MODEL": "$model",
    "ANTHROPIC_SMALL_FAST_MODEL": "$small_model"
  }
}
EOF
  echo "Created: $name"
}
