#!/bin/bash
# =============================================================================
# build_firetec.sh -- build FIRETEC 1.5.0 (NDP main) on Expanse and package it for Tapis (ZIP runtime)
# =============================================================================
# Run on a compute node (login nodes differ from compute nodes), for example:
#   srun -p debug -A <project> -N 1 -n 16 --mem=32G -t 00:30:00 --pty --wait=0 --export=ALL /bin/bash
#   bash build_firetec.sh
#
# Produces $FIRETEC_OUT_DIR/firetec-<version>-<commit>.tgz containing:
#   tapisjob_app.sh     launcher that Tapis runs inside the Slurm job
#   tapisjob.manifest   build provenance + the modules and MPI launcher to run with
#   bin/firerad         the FIRETEC executable
#   LICENSE             FIRETEC's BSD-3-Clause license (must travel with the binary)
#
# Three things FIRETEC 1.5.0's own CMake setup gets wrong, handled here:
#   * its -O2 never reaches the compiler, so a plain build is unoptimized;
#     this script passes -O2 -g itself
#   * GCC 10+ rejects its MPI calls ("Type mismatch between actual argument");
#     this script adds -fallow-argument-mismatch for GCC 10+
#   * parallel make races on the shared opt/ module directory; this script
#     builds serially
#
# Settings (environment variables, all optional):
#   FIRETEC_REPO          git repository        (default https://github.com/national-data-platform/FIRETEC.git;
#                         HTTPS and SSH URLs for the same repository count as the same, so an
#                         existing clone from git@github.com:national-data-platform/FIRETEC.git is fine)
#   FIRETEC_REF           branch to build       (default main: FIRETEC-1.5.0 plus NDP tooling)
#   FIRETEC_SRC           checkout directory    (default $HOME/src/FIRETEC-1.5.0; cloned if missing)
#   FIRETEC_MODULES       modules to build AND run with
#                         (default "cpu/0.17.3b gcc/10.2.0/npcyll4 openmpi/4.1.1 slurm"; keep slurm:
#                         the launcher purges modules first, and mpirun uses srun to reach other nodes)
#   FIRETEC_BUILD_MODULES modules for the build only, not loaded at run time
#                         (default "cmake/3.21.4/teqow32"; set to "" to use a cmake already on PATH)
#   FIRETEC_MPI_LAUNCH    MPI launch command    (default "mpirun", OpenMPI's launcher)
#   FIRETEC_FFLAGS        Fortran flags         (default "-O2 -g -march=znver2"; -march=znver2 targets AMD Rome)
#   FIRETEC_DBL_PREC      ON for double precision (adds -DDBL_PREC; default OFF)
#   FIRETEC_OUT_DIR       where the archive goes (default $HOME/tapis-apps)
#   FIRETEC_SELFTEST      1 runs a 4-rank test  (default 1 inside a Slurm job, else 0)
#   FIRETEC_SKIP_MODULES  1 leaves modules alone (building off Expanse)
# =============================================================================
set -eo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO="${FIRETEC_REPO:-https://github.com/national-data-platform/FIRETEC.git}"
REF="${FIRETEC_REF:-main}"
SRC="${FIRETEC_SRC:-$HOME/src/FIRETEC-1.5.0}"
MODULES="${FIRETEC_MODULES:-cpu/0.17.3b gcc/10.2.0/npcyll4 openmpi/4.1.1 slurm}"
BUILD_MODULES="${FIRETEC_BUILD_MODULES-cmake/3.21.4/teqow32}"
MPI_LAUNCH="${FIRETEC_MPI_LAUNCH:-mpirun}"
FFLAGS="${FIRETEC_FFLAGS--O2 -g -march=znver2}"
DBL_PREC="${FIRETEC_DBL_PREC:-OFF}"
OUT_DIR="${FIRETEC_OUT_DIR:-$HOME/tapis-apps}"
if [[ -n "${SLURM_JOB_ID:-}" ]]; then SELFTEST="${FIRETEC_SELFTEST:-1}"; else SELFTEST="${FIRETEC_SELFTEST:-0}"; fi
FATAL_PATTERN='(^|[^A-Za-z])ERROR([^A-Za-z0-9_]|$)|Not implemented|NaNs in XV array|incompatible with'

step() { printf '\n==> %s\n' "$*"; }
die()  { printf '\nbuild_firetec.sh: %s\n' "$*" >&2; exit 1; }

# Reduce a git URL to host/owner/repo so HTTPS and SSH clones of the same
# repository compare equal. All of these become github.com/org/firetec:
#   https://github.com/org/FIRETEC.git   git@github.com:org/FIRETEC.git   ssh://git@github.com/org/FIRETEC
repo_id() {
  local url="${1%/}"
  url="${url%.git}"
  url="${url#*://}"   # drop the scheme (https://, ssh://, git://)
  url="${url#*@}"     # drop a user (git@ or user:token@)
  url="${url/://}"    # SSH shorthand host:owner/repo -> host/owner/repo
  printf '%s\n' "${url,,}"
}

# --- 1. Source ----------------------------------------------------------------
if [[ ! -d "$SRC/.git" ]]; then
  step "Cloning $REPO ($REF) into $SRC"
  git clone --branch "$REF" "$REPO" "$SRC" \
    || die "git clone failed. Compute nodes may not reach GitHub: clone on a login node first, then rerun."
fi
REMOTE=$(git -C "$SRC" remote get-url origin 2>/dev/null || echo unknown)
BRANCH=$(git -C "$SRC" rev-parse --abbrev-ref HEAD)
[[ "$(repo_id "$REMOTE")" == "$(repo_id "$REPO")" ]] \
  || die "$SRC is a clone of $REMOTE, not $REPO (its HTTPS or SSH URL). Set FIRETEC_SRC to another directory, or FIRETEC_REPO to build this one."
[[ "$BRANCH" == "$REF" ]] \
  || die "$SRC is on '$BRANCH', not '$REF'. Run: git -C $SRC checkout $REF   (or set FIRETEC_REF=$BRANCH)"
CODE_DIR=$(find "$SRC" -maxdepth 1 -type d -name 'CODE-*' | sort | tail -n 1)
[[ -n "$CODE_DIR" && -f "$CODE_DIR/CMakeLists.txt" ]] || die "no CODE-*/CMakeLists.txt under $SRC"
VERSION="${CODE_DIR##*/CODE-}"
COMMIT=$(git -C "$SRC" rev-parse HEAD)
SHORT=$(git -C "$SRC" rev-parse --short=7 HEAD)
DIRTY=""
[[ -n "$(git -C "$SRC" status --porcelain --untracked-files=no)" ]] && DIRTY="-dirty"
step "FIRETEC $VERSION from $REPO, $BRANCH @ $SHORT$DIRTY"

# --- 2. Toolchain -------------------------------------------------------------
RESOLVED=""
if [[ "${FIRETEC_SKIP_MODULES:-0}" == 1 ]]; then
  MODULES=""
  BUILD_MODULES=""
  step "Skipping modules (FIRETEC_SKIP_MODULES=1)"
else
  type module >/dev/null 2>&1 || { [[ -r /etc/profile.d/modules.sh ]] && source /etc/profile.d/modules.sh; }
  type module >/dev/null 2>&1 || die "'module' is unavailable (set FIRETEC_SKIP_MODULES=1 to build without modules)"
  step "Loading modules: $MODULES"
  module purge || true
  # shellcheck disable=SC2086
  module load $MODULES || die "module load failed for: $MODULES (check names with module spider)"
  # Recorded before the build-only modules are added, so the run-time list stays exact.
  RESOLVED=$(module -t list 2>&1 | grep -v ':$' | tr '\n' ' ' | sed 's/ *$//' || true)
  if [[ -n "$BUILD_MODULES" ]]; then
    step "Loading build-only modules: $BUILD_MODULES"
    # shellcheck disable=SC2086
    module load $BUILD_MODULES || die "module load failed for: $BUILD_MODULES (check names with module spider cmake)"
  fi
fi
for tool in gfortran mpif90 mpicc cmake make git; do
  command -v "$tool" >/dev/null 2>&1 || die "'$tool' not found in PATH"
done
GCC_MAJOR=$(gfortran -dumpversion | cut -d. -f1)
if (( GCC_MAJOR >= 10 )); then
  FFLAGS="$FFLAGS -fallow-argument-mismatch"   # FIRETEC 1.5.0's MPI calls fail to compile on GCC 10+ without it
fi
[[ "$DBL_PREC" == ON ]] && FFLAGS="$FFLAGS -DDBL_PREC"

# --- 3. Configure and build ---------------------------------------------------
BUILD_DIR="${FIRETEC_BUILD_DIR:-$SRC/build-expanse}"
step "Configuring in $BUILD_DIR (gfortran $GCC_MAJOR, Fortran flags: $FFLAGS)"
# FIRETEC's CMake writes Fortran .mod files into CODE-*/opt; clear stale ones.
rm -rf "$BUILD_DIR" "$CODE_DIR/opt"
cmake -S "$CODE_DIR" -B "$BUILD_DIR" \
  -DCMAKE_Fortran_COMPILER="$(command -v gfortran)" \
  -DMPI_Fortran_COMPILER="$(command -v mpif90)" \
  -DCMAKE_Fortran_FLAGS="$FFLAGS"
step "Building (serially: FIRETEC's sub-libraries share one module directory)"
make -C "$BUILD_DIR" -j1
[[ -x "$BUILD_DIR/firerad" ]] || die "build finished but $BUILD_DIR/firerad is missing"

# --- 4. Self-test: 4 ranks, 20 steps, no fire ---------------------------------
if [[ "$SELFTEST" == 1 ]]; then
  step "Self-test: example gridlist, 2 x 2 ranks, 20 steps, no fire"
  TEST_DIR="$BUILD_DIR/selftest"
  bash "$SCRIPT_DIR/make_smoke_cases.sh" --src "$SRC" --dest "$TEST_DIR" >/dev/null
  launch="$MPI_LAUNCH"
  # Inside an interactive 'srun --pty' shell, a nested srun needs --overlap to start.
  [[ "$launch" == srun* && -n "${SLURM_STEP_ID:-}" ]] && launch="${launch/srun/srun --overlap}"
  LOG="$TEST_DIR/smoke-nofire/selftest.log"
  (
    cd "$TEST_DIR/smoke-nofire"
    ulimit -s unlimited 2>/dev/null || true
    # shellcheck disable=SC2086
    $launch -n 4 "$BUILD_DIR/firerad" > selftest.log 2>&1
  ) || die "self-test run failed; see $LOG"
  if grep -Eq "$FATAL_PATTERN" "$LOG"; then die "self-test reported a fatal problem; see $LOG"; fi
  LAST=$(awk '$1 == "it" && $2 == "total=" { v = $3 } END { print v }' "$LOG")
  [[ "$LAST" == 20 && -f "$TEST_DIR/smoke-nofire/comp/comp.out.20" ]] \
    || die "self-test stopped early (last step: ${LAST:-none} of 20); see $LOG"
  echo "self-test passed: 20 of 20 steps, outputs in $TEST_DIR/smoke-nofire/comp"
else
  step "Skipping self-test (not inside a Slurm allocation; set FIRETEC_SELFTEST=1 to force)"
fi

# --- 5. Package -----------------------------------------------------------------
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/firetec-pkg.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
chmod 755 "$STAGE"   # tar records this mode for ./, which extraction applies to the exec dir
mkdir -p "$STAGE/bin"
install -m 755 "$BUILD_DIR/firerad"         "$STAGE/bin/firerad"
install -m 755 "$SCRIPT_DIR/tapisjob_app.sh" "$STAGE/tapisjob_app.sh"
install -m 644 "$SRC/LICENSE"               "$STAGE/LICENSE"
cat > "$STAGE/tapisjob.manifest" <<MANIFEST
# FIRETEC app archive for the Tapis ZIP runtime.
# tapisjob_app.sh reads the firetec_* keys; Tapis ignores keys it doesn't know.
firetec_version=$VERSION
firetec_git_remote=$REPO
firetec_git_branch=$BRANCH
firetec_git_commit=$COMMIT$DIRTY
firetec_modules=$MODULES
firetec_modules_resolved=$RESOLVED
firetec_build_modules=$BUILD_MODULES
firetec_mpi_launch=$MPI_LAUNCH
firetec_fortran_flags=$FFLAGS
firetec_compiler=$(gfortran --version | head -n 1)
firetec_build_host=$(hostname)
firetec_build_user=${USER:-$(id -un)}
firetec_build_date=$(date -Iseconds)
MANIFEST

mkdir -p "$OUT_DIR"
OUT_DIR=$(cd "$OUT_DIR" && pwd)
ARCHIVE="$OUT_DIR/firetec-$VERSION-$SHORT$DIRTY.tgz"
tar -C "$STAGE" -czf "$ARCHIVE" .
chmod 644 "$ARCHIVE"

step "Done"
tar -tzvf "$ARCHIVE"
cat <<DONE

Archive: $ARCHIVE
Put these in site.env:
  APP_ARCHIVE=$ARCHIVE
  APP_VERSION=$VERSION-$SHORT$DIRTY
DONE