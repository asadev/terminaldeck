#!/bin/bash
# Source-only wrapper for the final combined integration gate. No build/install.
set -euo pipefail
if [ "$#" -ne 4 ]; then
  echo 'usage: BackendNodelessPackagingGate.sh <native helper> <scratch build root> <relative app> <relative gate receipt>' >&2
  exit 2
fi
td_gate_helper="$1"
td_gate_root="$2"
td_gate_app="$3"
td_gate_receipt="$4"
case "$td_gate_helper" in /*) ;; *) echo 'native helper must be absolute' >&2; exit 2 ;; esac
[ -x "$td_gate_helper" ] || { echo 'native packaging helper is unavailable' >&2; exit 1; }
exec "$td_gate_helper" --nodeless-package-gate "$td_gate_root" "$td_gate_app" "$td_gate_receipt"
