cmd_add() {
  local name="${1:-}"
  [[ -z "$name" ]] && { echo "usage: ccs add <name>" >&2; exit 1; }
  local path
  path="$(_profile_path "$name")"
  [[ -f "$path" ]] && { echo "error: profile '$name' already exists (use: ccs edit $name)" >&2; exit 1; }
  mkdir -p "$PROFILES_DIR"

  read -rp "BASE URL: " base_url
  read -rp "AUTH TOKEN: " auth_token
  read -rp "MAIN MODEL: " model
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
