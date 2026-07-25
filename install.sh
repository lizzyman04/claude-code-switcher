#!/usr/bin/env bash

set -euo pipefail

INSTALL_DIR="$HOME/.local/bin"
SCRIPT_NAME="ccs"
CCS_DIR="$HOME/.config/claude-profiles"
PROFILES_DIR="$CCS_DIR/profiles"
RAW_BASE="https://raw.githubusercontent.com/lizzyman04/claude-code-switcher/main"

mkdir -p "$INSTALL_DIR"
mkdir -p "$PROFILES_DIR"

echo "Building ccs..."

# src/MANIFEST lists the source files, in order. It is the same list ccs.sh
# sources, so a new file is registered in exactly one place.
MANIFEST="$(curl -fsSL "$RAW_BASE/src/MANIFEST")"

{
  echo "#!/usr/bin/env bash"
  echo ""
  echo "set -euo pipefail"
  echo ""

  while IFS= read -r src; do
    [[ -z "$src" || "$src" == \#* ]] && continue
    curl -fsSL "$RAW_BASE/src/$src"
    echo ""
  done <<< "$MANIFEST"

  echo 'ccs_main "$@"'
} > "$INSTALL_DIR/$SCRIPT_NAME"

chmod +x "$INSTALL_DIR/$SCRIPT_NAME"

echo "Installing default profiles..."

# Only seed a provider that is absent, so re-running the installer never
# overwrites an account file the user has put an API key in.
for provider in anthropic deepseek; do
  if [[ ! -d "$PROFILES_DIR/$provider/accounts" ]]; then
    mkdir -p "$PROFILES_DIR/$provider/accounts"
    curl -fsSL "$RAW_BASE/profiles/$provider/profile.json" \
      -o "$PROFILES_DIR/$provider/profile.json"
    curl -fsSL "$RAW_BASE/profiles/$provider/accounts/main.json" \
      -o "$PROFILES_DIR/$provider/accounts/main.json"
  fi
done

[[ -L "$CCS_DIR/active" ]] || \
  ln -sfn "$PROFILES_DIR/anthropic/accounts/main.json" "$CCS_DIR/active"

if ! echo ":$PATH:" | grep -q ":$INSTALL_DIR:"; then
  echo ""
  echo "~/.local/bin is not in your PATH. Add it:"
  echo "  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc && source ~/.bashrc"
fi

SHELL_CONFIG=""
for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
  if [[ -f "$rc" ]]; then
    SHELL_CONFIG="$rc"
    break
  fi
done

if [[ -n "$SHELL_CONFIG" ]]; then
  if ! grep -q "alias claude=.*claude-profiles/active" "$SHELL_CONFIG" 2>/dev/null; then
    cat >> "$SHELL_CONFIG" << 'ALIASES'

# ccs — Claude Code Switcher aliases
alias claude='claude --settings $HOME/.config/claude-profiles/active'
alias deepseek='ccs run deepseek'
ALIASES
    echo ""
    echo "Aliases added to $SHELL_CONFIG"
    echo "→ Open a new terminal or run: source $SHELL_CONFIG"
  fi
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "ccs installed successfully!"
echo ""
"$INSTALL_DIR/$SCRIPT_NAME" --help