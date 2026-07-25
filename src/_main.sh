ccs_main() {
  mkdir -p "$PROFILES_DIR"
  _migrate_flat_layout

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
    clean)
      if [[ "${2:-}" == "--restore" ]]; then
        if [[ -d "$HOME/.claude/agents.ccs-disabled" ]]; then
          mv "$HOME/.claude/agents.ccs-disabled" "$HOME/.claude/agents"
          echo "ccs: restored agents"
        fi
        if [[ -d "$HOME/.claude/skills.ccs-disabled" ]]; then
          mv "$HOME/.claude/skills.ccs-disabled" "$HOME/.claude/skills"
          echo "ccs: restored skills"
        fi
        echo "ccs: cleanup complete"
      else
        cmd_clean "${@:2}"
      fi
      ;;
    doctor)  cmd_doctor ;;
    shell-install) _shell_install ;;
    help|--help|-h) cmd_help ;;
    *)
      # Bare <provider> or <provider>@<account> is shorthand for switch. A known
      # provider with an unknown account still routes to switch, so the user
      # gets "account not found" instead of a wall of help text.
      if _parse_spec "$1" || _provider_exists "${1%%@*}"; then
        cmd_switch "$1"
      else
        cmd_help
      fi
      ;;
  esac
}
