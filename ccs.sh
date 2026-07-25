#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# src/MANIFEST is the single source of truth for which files make up ccs, and in
# which order. install.sh reads the same list to build the standalone binary.
while IFS= read -r _ccs_src; do
  [[ -z "$_ccs_src" || "$_ccs_src" == \#* ]] && continue
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/src/$_ccs_src"
done < "$SCRIPT_DIR/src/MANIFEST"
unset _ccs_src

ccs_main "$@"
