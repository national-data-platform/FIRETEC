#!/bin/bash
# =============================================================================
# make_smoke_cases.sh -- small FIRETEC 1.5.0 cases for testing the Tapis app
# =============================================================================
# Usage: bash make_smoke_cases.sh [--src FIRETEC_CHECKOUT] [--dest DIR]
#   defaults: --src $HOME/src/FIRETEC-1.5.0   --dest $HOME/tapis-apps/firetec-cases
#
# All four start from FIRETEC's TOOLS/Gridlist/gridlist (50 x 50 x 20 cells,
# nprocx x nprocy = 2 x 2), so run them with nodeCount=1, coresPerNode=4.
#   smoke-nofire      20 steps, ifire=0, irad=0, no other input files      -> FINISHED
#   smoke-fire        100 steps, ifire=1, 21-cell line ignition            -> FINISHED
#   smoke-bad-decomp  nprocx=3: the launcher refuses before srun           -> FAILED (exit 1)
#   smoke-bad-input   irad=1: FIRETEC stops after 1 step with status 0     -> FAILED (exit 3)
# In 1.5.0, irad=2 (the template's setting) only works with ifire >= 1, so the
# no-fire cases also set irad=0. Each case gets the comp/ directory its outname
# needs, because FIRETEC 1.5.0 doesn't create it.
# =============================================================================
set -eo pipefail

SRC="${FIRETEC_SRC:-$HOME/src/FIRETEC-1.5.0}"
DEST="${FIRETEC_CASES_DIR:-$HOME/tapis-apps/firetec-cases}"
while (( $# )); do
  case "$1" in
    --src)  SRC="$2"; shift 2 ;;
    --dest) DEST="$2"; shift 2 ;;
    *) echo "usage: $0 [--src DIR] [--dest DIR]" >&2; exit 2 ;;
  esac
done

TEMPLATE="$SRC/TOOLS/Gridlist/gridlist"
[[ -f "$TEMPLATE" ]] || { echo "make_smoke_cases.sh: $TEMPLATE not found (set --src)" >&2; exit 1; }

# set_key FILE KEY VALUE: replace an existing "KEY = ..." line or append one.
# FIRETEC 1.5.0 needs lowercase keys with spaces around '=', which this writes.
set_key() {
  if grep -qiE "^ *$2 *=" "$1"; then
    sed -i -E "s/^ *$2 *=.*/$2 = $3/I" "$1"
  else
    printf '%s = %s\n' "$2" "$3" >> "$1"
  fi
}

new_case() {  # new_case NAME KEY=VALUE...
  local dir="$DEST/$1"; shift
  rm -rf "$dir"; mkdir -p "$dir/comp"
  cp "$TEMPLATE" "$dir/gridlist"
  local kv
  for kv in "$@"; do set_key "$dir/gridlist" "${kv%%=*}" "${kv#*=}"; done
  echo "$dir"
}

new_case smoke-nofire     nt=20  frqoutput=10 ifire=0 irad=0
new_case smoke-bad-decomp nt=20  frqoutput=10 ifire=0 irad=0 nprocx=3
new_case smoke-bad-input  nt=20  frqoutput=10 ifire=0 irad=1
fire=$(new_case smoke-fire nt=100 frqoutput=50 ifire=1)

# Line ignition at x = 10, y = 15..35 (cells), ground level, lit at t = 0 s.
# Same layout TOOLS/Ignition/ign_mkr.py writes: namelist header, then x y z t rows.
{
  printf '&ignitelist\n  nIgn=21\n  rampRate=350\n  targetTemp=1000\n/ \n'
  for y in $(seq 15 35); do printf '    10    %d    1    0.0\n' "$y"; done
} > "$fire/ignite.dat"

echo
echo "Smoke cases are in: $DEST"
echo "Put this in site.env:  CASES_DIR=$(cd "$DEST" && pwd)"
