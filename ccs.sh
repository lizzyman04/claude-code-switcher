#!/usr/bin/env bash

set -euo pipefail

CCS_DIR="$HOME/.config/claude-profiles"
PROFILES_DIR="$CCS_DIR/profiles"
ACTIVE_LINK="$CCS_DIR/active"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=src/_core.sh
source "$SCRIPT_DIR/src/_core.sh"
# shellcheck source=src/_help.sh
source "$SCRIPT_DIR/src/_help.sh"
# shellcheck source=src/cmd_list.sh
source "$SCRIPT_DIR/src/cmd_list.sh"
# shellcheck source=src/cmd_switch.sh
source "$SCRIPT_DIR/src/cmd_switch.sh"
# shellcheck source=src/cmd_current.sh
source "$SCRIPT_DIR/src/cmd_current.sh"
# shellcheck source=src/cmd_add.sh
source "$SCRIPT_DIR/src/cmd_add.sh"
# shellcheck source=src/cmd_edit.sh
source "$SCRIPT_DIR/src/cmd_edit.sh"
# shellcheck source=src/cmd_key.sh
source "$SCRIPT_DIR/src/cmd_key.sh"
# shellcheck source=src/cmd_remove.sh
source "$SCRIPT_DIR/src/cmd_remove.sh"
# shellcheck source=src/cmd_test.sh
source "$SCRIPT_DIR/src/cmd_test.sh"
# shellcheck source=src/cmd_run.sh
source "$SCRIPT_DIR/src/cmd_run.sh"

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
