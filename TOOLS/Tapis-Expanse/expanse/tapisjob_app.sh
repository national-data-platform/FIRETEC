#!/bin/bash
# =============================================================================
# tapisjob_app.sh -- FIRETEC 1.5.0 launcher for the Tapis ZIP runtime on SDSC Expanse
# =============================================================================
# How Tapis calls this (runtime ZIP, jobType BATCH):
#   cd <execSystemExecDir>; sbatch tapisjob.sh
#   tapisjob.sh:  . ./tapisjob.env
#                 ./tapisjob_app.sh <appArgs> > <execSystemOutputDir>/tapisjob.out 2>&1
# So this runs inside the Slurm allocation, in the directory where the app
# archive was unpacked, with all Tapis and user variables already exported.
# Its exit status becomes the Slurm job's, which Tapis reports as the outcome.
#
# Where the case comes from (exactly one of):
#   * Tapis file input "case"  -> staged to <outputDir>/case; path in $FIRETEC_CASE_INPUT
#   * FIRETEC_CASE_DIR=/abs    -> a case directory already on Expanse, copied to <outputDir>/case
# FIRETEC 1.5.0 always reads ./gridlist and opens every file the gridlist names
# relative to where it runs, so the launcher runs it inside the case directory.
#
# Why the extra checks: FIRETEC 1.5.0 never checks that the MPI rank count
# matches nprocx x nprocy, doesn't create its output directory, and several of
# its fatal paths ("... Not implemented", "NaNs in XV array", bare STOPs) exit
# with status 0. So the launcher checks the decomposition before srun, creates
# the output directories, and afterwards requires that the run reached step nt.
#
# Overrides for testing off Expanse: FIRETEC_SKIP_MODULES=1, FIRETEC_MPI_LAUNCH="mpirun ..."
# =============================================================================
set -o pipefail

APP_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FIRERAD="$APP_DIR/bin/firerad"
MANIFEST="$APP_DIR/tapisjob.manifest"
RUN_ROOT="${_tapisExecSystemOutputDir:-$PWD}"
INPUT_ROOT="${_tapisExecSystemInputDir:-$RUN_ROOT}"
GRIDLIST_NAME="${FIRETEC_GRIDLIST:-gridlist}"
# Messages FIRETEC prints on fatal paths that still exit with status 0
FATAL_PATTERN='(^|[^A-Za-z])ERROR([^A-Za-z0-9_]|$)|Not implemented|NaNs in XV array|incompatible with'

log()  { printf '[firetec %s] %s\n' "$(date '+%F %T')" "$*"; }
fail() { log "FAILED: $1"; exit "${2:-1}"; }
manifest_get() { [[ -f "$MANIFEST" ]] && sed -n "s/^$1=//p" "$MANIFEST" | tail -n 1; }

# Mirrors FIRETEC 1.5.0's QueryGridlist_*: the key must be the first
# blank-separated token on a line, matched case-sensitively, followed by a
# separate '=' token, and the first matching line wins. Prints the value
# (quotes stripped), nothing if the key is absent, or BADFORMAT if the matching
# line would not parse. Lines FIRETEC silently skips but that look like the key
# (other case, or no spaces around '=') are reported, since they're likely typos.
gridlist_get() {
  awk -v key="$1" '
    { line = $0; sub(/^[ \t]+/, "", line); if (line == "") next
      n = split(line, tok, /[ \t,]+/)
      if (tok[1] == key) {
        if (found) { dups++; next }
        found = 1; val = (tok[2] == "=" && n >= 3) ? tok[3] : "BADFORMAT"; next
      }
      t = tolower(tok[1]); sub(/=.*/, "", t)
      if (t == key) printf "[firetec] note: FIRETEC 1.5.0 ignores the gridlist line \"%s\" (keys are case-sensitive and need spaces around =)\n", line > "/dev/stderr"
    }
    END {
      if (dups) printf "[firetec] note: \"%s\" appears %d times in the gridlist; FIRETEC 1.5.0 uses the first\n", key, dups + 1 > "/dev/stderr"
      if (found) { gsub(/^[\047"]|[\047"]$/, "", val); print val }
    }' "$2"
}

# read_int VAR key default : integer from the gridlist, or FIRETEC's built-in default
read_int() {
  local raw
  raw=$(gridlist_get "$2" "$CASE_GRIDLIST")
  [[ -z "$raw" ]] && raw="$3"
  [[ "$raw" == BADFORMAT ]] && fail "can't read '$2' from the gridlist; FIRETEC 1.5.0 needs the form '$2 = <value>' with spaces around '='"
  [[ "$raw" =~ ^[0-9]+$ ]] || fail "the gridlist value for '$2' is not a whole number: '$raw'"
  printf -v "$1" '%d' "$((10#$raw))"
}

load_modules() {
  local mods="${FIRETEC_MODULES:-$(manifest_get firetec_modules)}"
  if [[ "${FIRETEC_SKIP_MODULES:-0}" == 1 || -z "$mods" ]]; then
    log "module loading skipped"
    return
  fi
  # 'module' is a shell function that batch shells on Expanse may not have.
  type module >/dev/null 2>&1 || { [[ -r /etc/profile.d/modules.sh ]] && source /etc/profile.d/modules.sh; }
  type module >/dev/null 2>&1 || fail "the 'module' command is not available on $(hostname)"
  module purge >/dev/null 2>&1
  # shellcheck disable=SC2086  # word splitting of the module list is intended
  module load $mods || fail "module load failed for: $mods (did SDSC retire a version? rebuild with build_firetec.sh)"
  log "modules: $(module -t list 2>&1 | grep -v ':$' | tr '\n' ' ')"
}

# Decide where the case comes from and find its gridlist, without copying yet,
# so a bad decomposition fails before any large fuel files are copied.
locate_case() {
  if [[ -n "${FIRETEC_CASE_DIR:-}" && -n "${FIRETEC_CASE_INPUT:-}" ]]; then
    fail "both FIRETEC_CASE_DIR and the 'case' file input are set; use one"
  fi
  if [[ -n "${FIRETEC_CASE_DIR:-}" ]]; then
    [[ "$FIRETEC_CASE_DIR" == /* ]] || fail "FIRETEC_CASE_DIR must be an absolute path on Expanse (got '$FIRETEC_CASE_DIR')"
    [[ -d "$FIRETEC_CASE_DIR" ]] || fail "FIRETEC_CASE_DIR does not exist or is not readable: $FIRETEC_CASE_DIR"
    CASE_SRC="$FIRETEC_CASE_DIR"
    CASE_SOURCE="FIRETEC_CASE_DIR=$FIRETEC_CASE_DIR"
  elif [[ -n "${FIRETEC_CASE_INPUT:-}" ]]; then
    CASE_SRC="$FIRETEC_CASE_INPUT"
    [[ "$CASE_SRC" == /* ]] || CASE_SRC="$INPUT_ROOT/$CASE_SRC"
    [[ -d "$CASE_SRC" ]] || fail "the staged 'case' input is not a directory: $CASE_SRC"
    CASE_SOURCE="Tapis file input 'case'"
  else
    fail "no case given: set the 'case' file input or the FIRETEC_CASE_DIR environment variable"
  fi
  # A transferred directory can end up nested one level down; descend if so.
  if [[ ! -f "$CASE_SRC/$GRIDLIST_NAME" ]]; then
    local hits=( "$CASE_SRC"/*/"$GRIDLIST_NAME" )
    [[ ${#hits[@]} -eq 1 && -f "${hits[0]}" ]] && CASE_SRC=$(dirname "${hits[0]}")
  fi
  [[ -f "$CASE_SRC/$GRIDLIST_NAME" ]] || fail "no '$GRIDLIST_NAME' found in the case directory $CASE_SRC"
  CASE_GRIDLIST="$CASE_SRC/$GRIDLIST_NAME"
  log "case: $CASE_SOURCE"
}

check_decomposition() {
  read_int NPROCX nprocx 8
  read_int NPROCY nprocy 8
  read_int NX n 200
  read_int NY m 200
  read_int NT nt 10000
  NODES="${_tapisNodes:-${SLURM_JOB_NUM_NODES:-1}}"
  local cpn="${_tapisCoresPerNode:-1}"
  NTASKS=$(( NODES * cpn ))
  if [[ -n "${SLURM_NTASKS:-}" && "$SLURM_NTASKS" != "$NTASKS" ]]; then
    log "note: SLURM_NTASKS=$SLURM_NTASKS differs from nodeCount x coresPerNode=$NTASKS; using SLURM_NTASKS"
    NTASKS=$SLURM_NTASKS
  fi
  (( NPROCX > 0 && NPROCY > 0 )) || fail "nprocx and nprocy must be greater than zero"
  local need=$(( NPROCX * NPROCY ))
  (( need == NTASKS )) || fail "the gridlist needs nprocx x nprocy = ${NPROCX} x ${NPROCY} = ${need} MPI ranks, but this job has ${NTASKS} (nodeCount x coresPerNode). Change the gridlist or the job size so they match."
  (( NX % NPROCX == 0 )) || fail "n=$NX is not divisible by nprocx=$NPROCX"
  (( NY % NPROCY == 0 )) || fail "m=$NY is not divisible by nprocy=$NPROCY"
  (( NT > 0 )) || fail "nt must be greater than zero"
  log "decomposition OK: ${NPROCX} x ${NPROCY} ranks over a ${NX} x ${NY} grid, ${NT} steps"
}

materialize_case() {
  if [[ -n "${FIRETEC_CASE_DIR:-}" ]]; then
    CASE_DIR="$RUN_ROOT/case"
    mkdir -p "$CASE_DIR" || fail "cannot create $CASE_DIR"
    log "copying $CASE_SRC -> $CASE_DIR ($(du -sh "$CASE_SRC" 2>/dev/null | cut -f1))"
    cp -R "$CASE_SRC"/. "$CASE_DIR"/ || fail "copying the case from $CASE_SRC failed"
  else
    CASE_DIR="$CASE_SRC"
  fi
  chmod -R u+w "$CASE_DIR" 2>/dev/null   # copies of a read-only case library must be writable
  # FIRETEC 1.5.0 always opens ./gridlist, so point that name at the chosen file.
  if [[ "$GRIDLIST_NAME" != gridlist ]]; then
    if [[ -e "$CASE_DIR/gridlist" && ! "$CASE_DIR/gridlist" -ef "$CASE_DIR/$GRIDLIST_NAME" ]]; then
      fail "FIRETEC 1.5.0 always reads ./gridlist, and this case already has a different 'gridlist'; rename one of them"
    fi
    ln -sfn "$GRIDLIST_NAME" "$CASE_DIR/gridlist" || fail "cannot link $GRIDLIST_NAME to ./gridlist"
    log "linked ./gridlist -> $GRIDLIST_NAME"
  fi
}

# FIRETEC 1.5.0 fails with "Cannot open file" if an output prefix's directory is missing.
make_output_dirs() {
  local key val dir
  for key in outname outname_fb sensorfile; do
    val=$(gridlist_get "$key" gridlist)
    [[ -z "$val" || "$val" == BADFORMAT ]] && continue
    dir=$(dirname "$val")
    [[ "$dir" == . || -d "$dir" ]] && continue
    mkdir -p "$dir" || fail "cannot create the output directory '$dir' named by $key"
    log "created output directory $dir (from $key)"
  done
}

write_run_info() {
  {
    echo "tapis_job_uuid=${_tapisJobUUID:-}"
    echo "tapis_job_name=${_tapisJobName:-}"
    echo "slurm_job_id=${SLURM_JOB_ID:-}"
    echo "slurm_nodes=${SLURM_JOB_NODELIST:-$(hostname)}"
    echo "start_time=$(date -Iseconds)"
    echo "case_source=$CASE_SOURCE"
    echo "gridlist=$GRIDLIST_NAME"
    echo "mpi_ranks=$NTASKS nprocx=$NPROCX nprocy=$NPROCY n=$NX m=$NY nt=$NT"
    echo "mpi_launch=$LAUNCH"
    [[ -f "$MANIFEST" ]] && grep -v '^#' "$MANIFEST"
  } > run-info.txt
}

run_firetec() {
  LAUNCH="${FIRETEC_MPI_LAUNCH:-$(manifest_get firetec_mpi_launch)}"
  LAUNCH="${LAUNCH:-mpirun}"
  command -v "${LAUNCH%% *}" >/dev/null 2>&1 || fail "MPI launcher '${LAUNCH%% *}' not found after loading modules"
  # OpenMPI's mpirun starts ranks on other nodes through srun.
  if [[ -n "${SLURM_JOB_ID:-}" ]] && (( NODES > 1 )) && ! command -v srun >/dev/null 2>&1; then
    fail "srun is not on PATH after loading modules, so mpirun can't start ranks on other nodes; add 'slurm' to FIRETEC_MODULES and rebuild"
  fi
  [[ -x "$FIRERAD" ]] || fail "missing executable $FIRERAD (is the app archive complete?)"
  local missing
  missing=$(ldd "$FIRERAD" 2>/dev/null | grep 'not found')
  [[ -z "$missing" ]] || fail "firerad has unresolved shared libraries (module mismatch?): $(echo "$missing" | tr -s ' \t\n' ' ')"

  ulimit -s unlimited 2>/dev/null || log "note: could not raise the stack limit (now $(ulimit -s))"
  export OMP_NUM_THREADS=1
  cd "$CASE_DIR" || fail "cannot cd to $CASE_DIR"
  make_output_dirs
  write_run_info

  log "launch: $LAUNCH -n $NTASKS $FIRERAD   (in $CASE_DIR)"
  local t0=$SECONDS
  # shellcheck disable=SC2086  # LAUNCH is a command plus options
  $LAUNCH -n "$NTASKS" "$FIRERAD" 2>&1 | tee firetec.log
  RC=${PIPESTATUS[0]}
  ELAPSED=$(( SECONDS - t0 ))
  log "FIRETEC exited with status $RC after $ELAPSED s"
}

check_result() {
  local last
  last=$(awk '$1 == "it" && $2 == "total=" { v = $3 } END { print v }' firetec.log)
  echo "end_time=$(date -Iseconds) exit_status=$RC elapsed_s=$ELAPSED last_step=${last:-none}" >> run-info.txt
  (( RC == 0 )) || fail "FIRETEC exited with status $RC (see $CASE_DIR/firetec.log)" "$RC"
  if grep -Eq "$FATAL_PATTERN" firetec.log; then
    log "FIRETEC reported a fatal problem but exited with status 0:"
    grep -E -m 5 "$FATAL_PATTERN" firetec.log | sed 's/^/    /'
    fail "treating this run as failed" 3
  fi
  [[ "$last" =~ ^[0-9]+$ ]] || fail "FIRETEC exited before its first time step (no 'it total=' lines in firetec.log)" 3
  (( last >= NT )) || fail "FIRETEC stopped at step $last of $NT and exited with status 0 (see firetec.log)" 3
  log "reached step $last of $NT"
  log "outputs: $(find . -type f | wc -l) files, $(du -sh . 2>/dev/null | cut -f1) in $CASE_DIR"
}

log "FIRETEC launcher on $(hostname): Tapis job ${_tapisJobUUID:-n/a}, Slurm job ${SLURM_JOB_ID:-n/a}"
(( $# > 0 )) && log "note: ignoring app arguments ($*); set FIRETEC_GRIDLIST to choose the gridlist"
load_modules
locate_case
check_decomposition
materialize_case
run_firetec
check_result
log "done"
exit 0
