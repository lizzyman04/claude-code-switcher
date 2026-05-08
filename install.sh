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

# Download all source files and combine into a single script
{
  # Header and core functions
  curl -fsSL "$RAW_BASE/src/_core.sh"
  echo ""

  # All command implementations
  curl -fsSL "$RAW_BASE/src/cmd_list.sh"
  echo ""
  curl -fsSL "$RAW_BASE/src/cmd_switch.sh"
  echo ""
  curl -fsSL "$RAW_BASE/src/cmd_current.sh"
  echo ""
  curl -fsSL "$RAW_BASE/src/cmd_add.sh"
  echo ""
  curl -fsSL "$RAW_BASE/src/cmd_edit.sh"
  echo ""
  curl -fsSL "$RAW_BASE/src/cmd_key.sh"
  echo ""
  curl -fsSL "$RAW_BASE/src/cmd_remove.sh"
  echo ""
  curl -fsSL "$RAW_BASE/src/cmd_test.sh"
  echo ""
  curl -fsSL "$RAW_BASE/src/cmd_run.sh"
  echo ""
  curl -fsSL "$RAW_BASE/src/_help.sh"
  echo ""

  # Main entry point
  cat << 'ENTRY'
#!/usr/bin/env bash

set -euo pipefail

CCS_DIR="$HOME/.config/claude-profiles"
PROFILES_DIR="$CCS_DIR/profiles"
ACTIVE_LINK="$CCS_DIR/active"

mkdir -p "$PROFILES_DIR"

case "${1:-}" in
  list|"") cmd_list ;;
  switch)  cmd_switch "${2:-}" ;;
  current) cmd_current ;;
  add)     cmd_add "${2:-}" ;;
  edit)    cmd_edit "${2:-}" ;;
  key)     cmd_key "${2:-}" ;;
  remove)  cmd_remove "${2:-}" ;;
  test)    cmd_test ;;
  run)     cmd_run "${@:2}" ;;
  help|--help|-h) cmd_help ;;
  *)
    echo "Unknown command: $1"
    echo ""
    cmd_list
    ;;
esac
ENTRY
} > "$INSTALL_DIR/$SCRIPT_NAME"

chmod +x "$INSTALL_DIR/$SCRIPT_NAME"

echo "Installing default profiles..."

for provider in anthropic deepseek; do
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