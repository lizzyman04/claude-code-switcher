#!/usr/bin/env bash

set -euo pipefail

INSTALL_DIR="$HOME/.local/bin"
SCRIPT_NAME="ccs"
CCS_DIR="$HOME/.config/claude-profiles"
PROFILES_DIR="$CCS_DIR/profiles"
RAW_BASE="https://raw.githubusercontent.com/lizzyman04/claude-code-switcher/main"

mkdir -p "$INSTALL_DIR"
mkdir -p "$PROFILES_DIR"

echo "Installing ccs to $INSTALL_DIR/$SCRIPT_NAME..."

curl -fsSL "$RAW_BASE/ccs.sh" -o "$INSTALL_DIR/$SCRIPT_NAME"
chmod +x "$INSTALL_DIR/$SCRIPT_NAME"

echo "Installing default profiles..."

for provider in anthropic deepseek openai; do
  curl -fsSL "$RAW_BASE/profiles/$provider.json" -o "$PROFILES_DIR/$provider.json"
done

ln -sf "$PROFILES_DIR/anthropic.json" "$CCS_DIR/active"

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
alias openai='ccs run openai'
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