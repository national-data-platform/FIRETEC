#!/usr/bin/env bash
#-------------------------------------------------------------------------
# FIRETEC installer for the NDP (National Data Platform) JupyterHub
#
# Checks the environment and installs what FIRETEC needs to compile and
# run: a Fortran compiler (gfortran >= 10), CMake (>= 3.10), make, an MPI
# library with Fortran bindings (OpenMPI), and numpy for the Python tools.
#
# Run with --help for options. Typical use:
#   bash TOOLS/NDP/install.sh --build --test     # install, build, smoke-test
#   source TOOLS/NDP/firetec-env.sh              # in every new terminal
#
# Files it uses from this directory:
#   apt-packages.txt, conda-packages.txt  packages for --method apt / conda
#   python-modules.txt                    Python modules the conda env must have
#   openmpi4.conf, openmpi5.conf          OpenMPI settings the NDP pod needs
#   mpi_check.F90                          MPI check program
#   smoke_test.gridlist                   FIRETEC input for --test
#   firetec-env.sh.in                     template for firetec-env.sh
#
# With the conda toolchain it also registers the env as the "Python (FIRETEC)"
# Jupyter kernel used by TOOLS/Postprocessing/visualize_firetec.ipynb.
#-------------------------------------------------------------------------
set -Eeuo pipefail
unset CDPATH   # an exported CDPATH makes 'cd' print paths into $(...)

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd -P)
ENV_FILE="$SCRIPT_DIR/firetec-env.sh"
ENV_TEMPLATE="$SCRIPT_DIR/firetec-env.sh.in"
MPI_CHECK="$SCRIPT_DIR/mpi_check.F90"
SMOKE_GRIDLIST="$SCRIPT_DIR/smoke_test.gridlist"

MIN_GFORTRAN=10   # -fallow-argument-mismatch (CMakeLists.txt), SELECT RANK (rmaxmin.F90)
MIN_CMAKE=3.10
KERNEL_NAME=firetec                    # must match the notebooks' kernelspec
KERNEL_DISPLAY_NAME="Python (FIRETEC)"

#------------------------------- defaults --------------------------------
METHOD=auto
DO_INSTALL=1
DO_BUILD=0
DO_TEST=0
JOBS=$(nproc 2>/dev/null || echo 4)
CODE_DIR=""
BUILD_DIR=""
BUILD_ARGS=()
ENV_PREFIX="${FIRETEC_ENV_PREFIX:-}"

usage() {
  cat <<EOF
Usage: bash TOOLS/NDP/install.sh [options]

Checks the NDP environment and installs the dependencies needed to compile
and run FIRETEC (gfortran, CMake, make, OpenMPI, numpy), then writes
TOOLS/NDP/firetec-env.sh to source in each new terminal.

Options:
  --method auto|conda|apt  Where to install missing dependencies (default: auto)
                             conda - conda-forge env on persistent storage
                                     (~1.6 GB). Survives NDP server restarts.
                             apt   - Ubuntu packages via sudo. Removed when
                                     the NDP server restarts (re-run then).
                             auto  - use the conda env if it exists, else the
                                     system tools if they already work, else
                                     install with conda (apt if no conda).
  --prefix DIR             Location of the conda env
                           (default: <persistent storage>/envs/firetec)
  --check                  Only report what is installed; change nothing
  --build                  Build FIRETEC (firerad) after installing
  --test                   Run a short MPI smoke test of firerad (implies --build)
  --code-dir DIR           FIRETEC source directory (default: newest CODE-*)
  --build-dir DIR          CMake build directory (default: <code-dir>/build)
  --cmake-arg ARG          Extra CMake argument, repeatable
                           (e.g. --cmake-arg -DDBL_PREC=ON)
  -j, --jobs N             Parallel build jobs (default: $JOBS)
  -h, --help               Show this help

Environment overrides: FIRETEC_ENV_PREFIX (same as --prefix).
EOF
}

#------------------------------- logging ---------------------------------
if [[ -t 1 ]]; then
  C_B=$'\e[1m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_R=$'\e[31m'; C_0=$'\e[0m'
else
  C_B=""; C_G=""; C_Y=""; C_R=""; C_0=""
fi
section() { printf '\n%s== %s ==%s\n' "$C_B" "$*" "$C_0"; }
info()    { printf '   %s\n' "$*"; }
ok()      { printf '   %s[ OK ]%s %s\n' "$C_G" "$C_0" "$*"; }
warn()    { printf '   %s[WARN]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
fail()    { printf '   %s[FAIL]%s %s\n' "$C_R" "$C_0" "$*" >&2; }
die()     { printf '\n%sERROR:%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
trap 'die "command failed (line $LINENO): $BASH_COMMAND"' ERR

# version_ge A B -> true if version A >= version B
version_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]; }

# read_list FILE -> its lines without '#' comments, blank lines or edge spaces
read_list() { sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' "$1"; }

# gridlist_value KEY FILE -> value of 'KEY = value' (quotes, ! comments stripped)
gridlist_value() {
  sed -n -E "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*([^[:space:]!]+).*/\1/p" "$2" \
    | head -n1 | tr -d "'\""
}

#------------------------------- arguments -------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --method)      METHOD="${2:?--method needs a value}"; shift 2 ;;
    --method=*)    METHOD="${1#*=}"; shift ;;
    --prefix)      ENV_PREFIX="${2:?--prefix needs a value}"; shift 2 ;;
    --prefix=*)    ENV_PREFIX="${1#*=}"; shift ;;
    --check)       DO_INSTALL=0; shift ;;
    --build)       DO_BUILD=1; shift ;;
    --test)        DO_BUILD=1; DO_TEST=1; shift ;;
    --code-dir)    CODE_DIR="${2:?--code-dir needs a value}"; shift 2 ;;
    --code-dir=*)  CODE_DIR="${1#*=}"; shift ;;
    --build-dir)   BUILD_DIR="${2:?--build-dir needs a value}"; shift 2 ;;
    --build-dir=*) BUILD_DIR="${1#*=}"; shift ;;
    --cmake-arg)   BUILD_ARGS+=("${2:?--cmake-arg needs a value}"); shift 2 ;;
    --cmake-arg=*) BUILD_ARGS+=("${1#*=}"); shift ;;
    -j|--jobs)     JOBS="${2:?--jobs needs a value}"; shift 2 ;;
    -j*)           JOBS="${1#-j}"; shift ;;
    --jobs=*)      JOBS="${1#*=}"; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             usage >&2; die "unknown option: $1" ;;
  esac
done
case "$METHOD" in auto|apt|conda) ;; *) die "--method must be auto, conda or apt" ;; esac
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "--jobs must be a positive integer"
if [[ $DO_INSTALL -eq 0 && $DO_BUILD -eq 1 ]]; then
  die "--check cannot be combined with --build/--test"
fi

for f in apt-packages.txt conda-packages.txt python-modules.txt mpi_check.F90 \
         smoke_test.gridlist firetec-env.sh.in; do
  [[ -r "$SCRIPT_DIR/$f" ]] || die "missing $SCRIPT_DIR/$f (install.sh needs the files next to it)"
done
mapfile -t APT_PACKAGES < <(read_list "$SCRIPT_DIR/apt-packages.txt")
mapfile -t CONDA_PACKAGES < <(read_list "$SCRIPT_DIR/conda-packages.txt")
mapfile -t PYTHON_MODULES < <(read_list "$SCRIPT_DIR/python-modules.txt")

# Source directory: newest CODE-x.y.z that has a CMakeLists.txt
if [[ -z "$CODE_DIR" ]]; then
  shopt -s nullglob
  candidates=("$REPO_ROOT"/CODE-*/CMakeLists.txt)
  shopt -u nullglob
  [[ ${#candidates[@]} -gt 0 ]] || die "no CODE-*/CMakeLists.txt found under $REPO_ROOT"
  CODE_DIR=$(printf '%s\n' "${candidates[@]%/CMakeLists.txt}" | sort -V | tail -n1)
fi
[[ -f "$CODE_DIR/CMakeLists.txt" ]] || die "no CMakeLists.txt in $CODE_DIR"
CODE_DIR=$(realpath -- "$CODE_DIR")
BUILD_DIR=$(realpath -m -- "${BUILD_DIR:-$CODE_DIR/build}")
# A compiler switch deletes the build dir, so it must never hold the sources.
if [[ "$CODE_DIR/" == "$BUILD_DIR"/* || "$REPO_ROOT/" == "$BUILD_DIR"/* ]]; then
  die "--build-dir must not be (or contain) the source tree: $BUILD_DIR"
fi

# mount_of PATH -> mount point holding PATH (or its nearest existing parent)
mount_of() {
  local d="$1"
  while [[ ! -e "$d" ]]; do d=$(dirname "$d"); done
  df --output=target "$d" 2>/dev/null | tail -n1
}

# Persistent storage = the mount that holds the repository
PERSIST_ROOT=$(mount_of "$REPO_ROOT" || true)
if [[ -z "$PERSIST_ROOT" || "$PERSIST_ROOT" == "/" ]]; then
  PERSIST_ROOT="$REPO_ROOT"
  PERSIST_OK=0
else
  PERSIST_OK=1
fi
ENV_PREFIX=$(realpath -m -- "${ENV_PREFIX:-$PERSIST_ROOT/envs/firetec}")
# make (and so CMake) cannot run tools from a directory with spaces in it.
[[ "$ENV_PREFIX" != *[[:space:]]* ]] || die "--prefix must not contain spaces: $ENV_PREFIX"

if [[ -n "${TMPDIR:-}" ]] && ! [[ -d "$TMPDIR" && -w "$TMPDIR" ]]; then
  die "TMPDIR=$TMPDIR is not a writable directory"
fi

#------------------------------- environment -----------------------------
check_environment() {
  section "Environment"
  local os="unknown"
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    os=$(. /etc/os-release && echo "${PRETTY_NAME:-$ID}")
  fi
  info "OS:          $os ($(uname -m))"
  if [[ "${JUPYTER_IMAGE:-}${JUPYTER_IMAGE_SPEC:-}" == *ndp* ]]; then
    info "Platform:    NDP JupyterHub (${JUPYTER_IMAGE:-${JUPYTER_IMAGE_SPEC}})"
  elif [[ -n "${JUPYTERHUB_USER:-}${JUPYTERHUB_API_URL:-}" ]]; then
    info "Platform:    JupyterHub (not recognised as NDP; continuing)"
  else
    info "Platform:    not NDP JupyterHub (continuing anyway)"
  fi
  info "CPUs:        $(nproc 2>/dev/null || echo '?')"
  local mem_max
  mem_max=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || echo max)
  if [[ "$mem_max" =~ ^[0-9]+$ ]]; then
    info "Memory:      $((mem_max / 1024 / 1024 / 1024)) GiB (container limit)"
  else
    info "Memory:      $(free -g 2>/dev/null | awk '/^Mem:/{print $2" GiB"}')"
  fi
  info "Repository:  $REPO_ROOT"
  info "Source:      $CODE_DIR"
  if [[ $PERSIST_OK -eq 1 ]]; then
    info "Persistent:  $PERSIST_ROOT ($(df -h --output=avail "$PERSIST_ROOT" | tail -n1 | tr -d ' ') free)"
  else
    warn "repository is not on a separate (persistent) mount; files may be lost on restart"
  fi
  info "/dev/shm:    $(df -h --output=size /dev/shm 2>/dev/null | tail -n1 | tr -d ' ' || echo '?')"
  if sudo -n true 2>/dev/null; then
    HAVE_SUDO=1; info "sudo:        passwordless sudo available"
  else
    HAVE_SUDO=0; info "sudo:        not available"
  fi
}

#------------------------------- toolchain selection ---------------------
# Puts the conda env first on PATH (conda) or removes it from PATH (system),
# so a shell that already sourced firetec-env.sh cannot mix the two.
use_toolchain() {
  local p="" d
  local IFS=:
  for d in $PATH; do
    [[ "$d" == "$ENV_PREFIX/bin" ]] || p="${p:+$p:}$d"
  done
  unset IFS
  if [[ "$1" == conda ]]; then
    PATH="$ENV_PREFIX/bin:$p"
    export FC="$ENV_PREFIX/bin/gfortran"
  else
    PATH="$p"
    if [[ "${FC:-}" == "$ENV_PREFIX"/* ]]; then unset FC; fi
  fi
  export PATH
  hash -r
  TOOLCHAIN="$1"
}

# Prints the OpenMPI major version of the mpirun on PATH (empty if not OpenMPI).
ompi_major() {
  mpirun --version 2>/dev/null | sed -n 's/.*(Open MPI) \([0-9]*\)\..*/\1/p' | head -n1
}

# Prints the names of every setting in openmpi*.conf, one per line.
mpi_setting_names() {
  local f
  for f in "$SCRIPT_DIR"/openmpi*.conf; do
    if [[ -e "$f" ]]; then read_list "$f" | cut -d= -f1; fi
  done | sort -u
}

# Clears every setting from openmpi*.conf, then exports the ones from the
# openmpi<major>.conf matching the OpenMPI on PATH (a stale OpenMPI 5
# 'btl=self,sm' breaks 4.x). Sets MPI_CONF and MPI_SETTINGS.
apply_mpi_settings() {
  local name major
  while IFS= read -r name; do unset "$name"; done < <(mpi_setting_names)
  MPI_CONF="" MPI_SETTINGS=()
  major=$(ompi_major)
  [[ -n "$major" && -f "$SCRIPT_DIR/openmpi$major.conf" ]] || return 0
  MPI_CONF="openmpi$major.conf"
  mapfile -t MPI_SETTINGS < <(read_list "$SCRIPT_DIR/$MPI_CONF")
  if [[ ${#MPI_SETTINGS[@]} -gt 0 ]]; then export "${MPI_SETTINGS[@]}"; fi
}

#------------------------------- dependency checks -----------------------
# Each check prints one line and returns 0 when the dependency is usable.
check_gfortran() {
  local fc="${FC:-gfortran}" ver
  if ! command -v "$fc" >/dev/null 2>&1; then
    fail "Fortran compiler: '$fc' not found"; return 1
  fi
  if ! "$fc" --version 2>/dev/null | head -n1 | grep -q 'GNU Fortran'; then
    ok "Fortran compiler: $(command -v "$fc") (non-GNU; not version-checked)"; return 0
  fi
  ver=$("$fc" -dumpfullversion 2>/dev/null || "$fc" -dumpversion 2>/dev/null || echo 0)
  if version_ge "$ver" "$MIN_GFORTRAN"; then
    ok "Fortran compiler: $(command -v "$fc") (GNU Fortran $ver)"
  else
    fail "Fortran compiler: GNU Fortran $ver is older than $MIN_GFORTRAN"; return 1
  fi
}

check_cmake() {
  local ver
  if ! command -v cmake >/dev/null 2>&1; then fail "CMake: not found"; return 1; fi
  ver=$(cmake --version | awk 'NR==1{print $3}')
  if version_ge "$ver" "$MIN_CMAKE"; then
    ok "CMake: $(command -v cmake) ($ver)"
  else
    fail "CMake: $ver is older than $MIN_CMAKE"; return 1
  fi
}

check_make() {
  if command -v make >/dev/null 2>&1; then
    ok "make: $(command -v make) ($(make --version | head -n1))"
  else
    fail "make: not found"; return 1
  fi
}

check_cxx() {
  if command -v c++ >/dev/null 2>&1 || command -v g++ >/dev/null 2>&1; then
    ok "C++ compiler (probed by CMake): $(command -v g++ || command -v c++)"
  else
    fail "C++ compiler: not found (CMake's project() requires one)"; return 1
  fi
}

check_mpi() {
  local w
  MPIFC=""
  for w in mpifort mpif90; do
    if command -v "$w" >/dev/null 2>&1; then MPIFC=$(command -v "$w"); break; fi
  done
  if [[ -z "$MPIFC" ]]; then fail "MPI Fortran wrapper (mpifort/mpif90): not found"; return 1; fi
  if ! command -v mpirun >/dev/null 2>&1; then fail "mpirun: not found"; return 1; fi
  apply_mpi_settings
  ok "MPI: $MPIFC, $(mpirun --version 2>&1 | head -n1)"
  if [[ -n "$MPI_CONF" ]]; then
    info "     with the NDP settings from $MPI_CONF"
  elif [[ -n "$(ompi_major)" ]]; then
    warn "no openmpi$(ompi_major).conf in $SCRIPT_DIR; running without NDP settings"
  fi
}

# Compile and run mpi_check.F90 on every CPU (see that file for what it proves).
check_mpi_runtime() {
  local tmp rc=0 out np
  np=$(nproc 2>/dev/null || echo 2)
  if (( np > 64 )); then np=64; fi
  if (( np < 2 )); then np=2; fi
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/firetec-mpitest.XXXXXX") \
    || { fail "MPI Fortran test: cannot create a temp dir in ${TMPDIR:-/tmp}"; return 1; }
  cp "$MPI_CHECK" "$tmp/"
  if ! out=$(cd "$tmp" && "$MPIFC" -o mpi_check "$(basename "$MPI_CHECK")" 2>&1); then
    fail "MPI Fortran test: compiling $(basename "$MPI_CHECK") (uses the 'mpi' module) failed:"
    printf '%s\n' "$out" | tail -n 20 | sed 's/^/          /' >&2
    rc=1
  elif ! out=$(cd "$tmp" && timeout 120 mpirun -np "$np" ./mpi_check 2>&1); then
    fail "MPI Fortran test: 'mpirun -np $np' failed:"
    printf '%s\n' "$out" | tail -n 20 | sed 's/^/          /' >&2
    rc=1
  elif ! grep -q "ranks=$np sum=$(( np * (np + 1) / 2 ))" <<<"$out" \
       || grep -Eq 'errno = |Unable to find reachable' <<<"$out"; then
    fail "MPI Fortran test: unexpected output:"
    printf '%s\n' "$out" | tail -n 20 | sed 's/^/          /' >&2
    rc=1
  else
    ok "MPI Fortran test: $(basename "$MPI_CHECK") ran on $np ranks"
  fi
  rm -rf "$tmp"
  return $rc
}

check_numpy() {
  local ver
  if ! command -v python3 >/dev/null 2>&1; then
    fail "Python: python3 not found (needed for TOOLS/Ignition/ign_mkr.py)"; return 1
  fi
  if ver=$(python3 -c 'import numpy; print(numpy.__version__)' 2>/dev/null); then
    ok "Python: $(command -v python3) with numpy $ver"
  else
    fail "Python: numpy missing for $(command -v python3) (needed for TOOLS/Ignition/ign_mkr.py)"
    return 1
  fi
}

# With the conda toolchain, every tool must come from the env itself, not
# from whatever else is on PATH.
check_conda_env() {
  local t bad=()
  if [[ ! -d "$ENV_PREFIX/conda-meta" ]]; then
    fail "conda env: not found at $ENV_PREFIX"; return 1
  fi
  for t in gfortran g++ cmake make mpifort mpirun python3; do
    [[ -x "$ENV_PREFIX/bin/$t" ]] || bad+=("$t")
  done
  if [[ ${#bad[@]} -gt 0 ]]; then
    fail "conda env: $ENV_PREFIX is missing ${bad[*]}"; return 1
  fi
  local missing_modules
  missing_modules=$("$ENV_PREFIX/bin/python3" -c 'import importlib.util, sys
print(" ".join(m for m in sys.argv[1:] if importlib.util.find_spec(m) is None))' \
                    ${PYTHON_MODULES[@]+"${PYTHON_MODULES[@]}"}) || missing_modules="(python3 failed)"
  if [[ -n "$missing_modules" ]]; then
    fail "conda env: $ENV_PREFIX lacks the Python modules $missing_modules"; return 1
  fi
  ok "conda env: $ENV_PREFIX"
}

# Runs every check; sets MISSING to the number of failures.
check_dependencies() {
  if [[ "$TOOLCHAIN" == conda ]]; then
    section "Dependencies (conda env)"
  else
    section "Dependencies (system)"
  fi
  MISSING=0
  if [[ "$TOOLCHAIN" == conda ]] && ! check_conda_env; then
    MISSING=1
    return 0
  fi
  check_gfortran || MISSING=$((MISSING + 1))
  check_cxx      || MISSING=$((MISSING + 1))
  check_cmake    || MISSING=$((MISSING + 1))
  check_make     || MISSING=$((MISSING + 1))
  if check_mpi; then
    check_mpi_runtime || MISSING=$((MISSING + 1))
  else
    MISSING=$((MISSING + 1))
  fi
  check_numpy    || MISSING=$((MISSING + 1))
}

#------------------------------- installers ------------------------------
install_apt() {
  section "Installing with apt (system packages)"
  [[ "$HAVE_SUDO" -eq 1 ]] || die "--method apt needs passwordless sudo; try --method conda"
  command -v apt-get >/dev/null 2>&1 || die "apt-get not found; try --method conda"
  local missing=() p log py wanted=("${APT_PACKAGES[@]}")
  # numpy: from apt for Ubuntu's own python3 (it has no pip), else via pip.
  py=$(command -v python3 || true)
  if [[ -z "$py" || "$py" == /usr/bin/python3 ]]; then
    wanted+=(python3 python3-numpy)
  fi
  for p in "${wanted[@]}"; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' \
      || missing+=("$p")
  done
  if [[ ${#missing[@]} -eq 0 ]]; then
    ok "apt packages already installed: ${wanted[*]}"
  else
    info "installing: ${missing[*]}"
    log=$(mktemp "${TMPDIR:-/tmp}/firetec-apt.XXXXXX")
    if ! { sudo -n apt-get update -q &&
           sudo -n env DEBIAN_FRONTEND=noninteractive \
             apt-get install -y -q --no-install-recommends "${missing[@]}"; } >"$log" 2>&1; then
      tail -n 20 "$log" >&2
      die "apt-get failed (full log: $log)"
    fi
    rm -f "$log"
    ok "installed: ${missing[*]}"
  fi
  hash -r
  if ! python3 -c 'import numpy' 2>/dev/null; then
    info "installing numpy with pip into $(command -v python3)"
    python3 -m pip install --quiet --disable-pip-version-check numpy \
      || die "could not install numpy for $(command -v python3)"
    ok "installed numpy"
  fi
  warn "apt packages are removed when the NDP server restarts; re-run this"
  warn "script then, or use --method conda for an install that persists."
}

find_conda() {
  local c
  for c in mamba conda /opt/conda/bin/mamba /opt/conda/bin/conda; do
    if command -v "$c" >/dev/null 2>&1; then command -v "$c"; return 0; fi
  done
  return 1
}

install_conda() {
  section "Installing with conda (persistent env)"
  local conda log action
  conda=$(find_conda) || die "neither mamba nor conda found; try --method apt"
  if [[ "$(mount_of "$ENV_PREFIX")" == / ]]; then
    warn "$ENV_PREFIX is not on persistent storage; it will be lost on restart"
  fi
  if [[ -d "$ENV_PREFIX/conda-meta" ]]; then
    action=install
    info "repairing env $ENV_PREFIX"
  elif [[ -e "$ENV_PREFIX" && -n "$(ls -A "$ENV_PREFIX" 2>/dev/null)" ]]; then
    die "$ENV_PREFIX exists but is not a conda env; remove it or use --prefix"
  else
    action=create
    info "creating env $ENV_PREFIX (about 1-2 minutes, 1.6 GB)"
    mkdir -p "$(dirname "$ENV_PREFIX")"
  fi
  # Keep the ~1.4 GB package cache on ephemeral disk, not persistent storage.
  log=$(mktemp "${TMPDIR:-/tmp}/firetec-conda.XXXXXX")
  if ! CONDA_PKGS_DIRS="${TMPDIR:-/tmp}/firetec-conda-pkgs" \
       "$conda" "$action" -y -p "$ENV_PREFIX" -c conda-forge --override-channels \
       "${CONDA_PACKAGES[@]}" >"$log" 2>&1; then
    tail -n 20 "$log" >&2
    die "conda $action failed (full log: $log)"
  fi
  rm -f "$log"
  ok "conda env ready: $ENV_PREFIX"
}

#------------------------------- env file --------------------------------
# render_template FILE KEY VALUE ... -> FILE with each @KEY@ replaced by VALUE
render_template() {
  local text
  text=$(<"$1"); shift
  while [[ $# -ge 2 ]]; do text=${text//"@$1@"/"$2"}; shift 2; done
  if [[ "$text" =~ @[A-Z_]+@ ]]; then die "no value for ${BASH_REMATCH[0]} in $ENV_TEMPLATE"; fi
  printf '%s\n' "$text"
}

# Writes firetec-env.sh from firetec-env.sh.in for the current toolchain.
write_env_file() {
  section "Writing $ENV_FILE"
  local name s mpi="" prefix=""
  if [[ "$TOOLCHAIN" == conda ]]; then prefix="$ENV_PREFIX"; fi
  while IFS= read -r name; do mpi+="unset $name"$'\n'; done < <(mpi_setting_names)
  # Quote values: zsh with extendedglob would expand e.g. ^cma.
  for s in ${MPI_SETTINGS[@]+"${MPI_SETTINGS[@]}"}; do
    mpi+="export ${s%%=*}='${s#*=}'"$'\n'
  done
  render_template "$ENV_TEMPLATE" \
    FIRETEC_HOME "$REPO_ROOT" \
    FIRETEC_CODE_DIR "$CODE_DIR" \
    FIRETEC_BUILD_DIR "$BUILD_DIR" \
    FIRETEC_TOOLCHAIN "$TOOLCHAIN" \
    FIRETEC_ENV_PREFIX "$prefix" \
    MPI_SETTINGS "${mpi%$'\n'}" > "$ENV_FILE.tmp"
  mv "$ENV_FILE.tmp" "$ENV_FILE"
  ok "wrote $ENV_FILE"
}

# Registers the conda env as a Jupyter kernel for the notebooks in
# TOOLS/Postprocessing. The registration lives in $HOME, which NDP resets on
# restart, so it is redone on every run.
register_jupyter_kernel() {
  [[ "$TOOLCHAIN" == conda ]] && command -v jupyter >/dev/null 2>&1 || return 0
  section "Jupyter kernel"
  if "$ENV_PREFIX/bin/python3" -m ipykernel install --user --name "$KERNEL_NAME" \
       --display-name "$KERNEL_DISPLAY_NAME" >/dev/null 2>&1; then
    ok "registered the \"$KERNEL_DISPLAY_NAME\" kernel"
  else
    warn "could not register the \"$KERNEL_DISPLAY_NAME\" Jupyter kernel"
  fi
}

#------------------------------- build / test ----------------------------
build_firetec() {
  section "Building FIRETEC ($CODE_DIR)"
  local fc log="$BUILD_DIR/ndp-build.log" cache="$BUILD_DIR/CMakeCache.txt" old_fc old_src
  local stamp="$CODE_DIR/opt/.ndp-build-dir" clean=()
  fc=$(command -v "${FC:-gfortran}")
  info "build dir: $BUILD_DIR"
  # A build made with another compiler (e.g. apt <-> conda gfortran) has
  # objects and .mod files the new gfortran cannot use, so start clean --
  # but only if the directory is a CMake build of this source tree.
  if [[ -f "$cache" ]]; then
    old_fc=$(sed -n 's/^CMAKE_Fortran_COMPILER:[A-Z]*=//p' "$cache")
    old_src=$(sed -n 's/^CMAKE_HOME_DIRECTORY:INTERNAL=//p' "$cache")
    if [[ -n "$old_fc" && "$old_fc" != "$fc" ]]; then
      if [[ "$old_src" != "$CODE_DIR" || ! -f "$log" ]]; then
        die "$BUILD_DIR was configured elsewhere (with $old_fc); remove it or use another --build-dir"
      fi
      info "compiler changed ($old_fc -> $fc); removing the old build"
      rm -rf "$BUILD_DIR"
      rm -f "$CODE_DIR"/opt/*.mod "$CODE_DIR"/opt/*.smod
    fi
  fi
  # Every build dir of a source tree writes its .mod files to <code-dir>/opt
  # (set in FIRETEC's CMakeLists.txt). If another build dir wrote them last,
  # e.g. a double-precision build, rebuild everything here.
  if [[ -d "$CODE_DIR/opt" && "$(cat "$stamp" 2>/dev/null)" != "$BUILD_DIR" ]]; then
    rm -f "$CODE_DIR"/opt/*.mod "$CODE_DIR"/opt/*.smod
    clean=(--clean-first)
  fi
  # FIRETEC 1.5.0's CMakeLists test Fortran_COMPILER_NAME but never set it, so
  # gfortran-only flags (-fallow-argument-mismatch for Firebrands, required by
  # gfortran >= 10) are silently skipped. Supply it the way they expect.
  local name_arg=()
  if grep -rqs --include=CMakeLists.txt 'Fortran_COMPILER_NAME' "$CODE_DIR"; then
    name_arg=(-DFortran_COMPILER_NAME="$(basename "$fc")")
  fi
  mkdir -p "$BUILD_DIR"
  if ! cmake -S "$CODE_DIR" -B "$BUILD_DIR" \
         -DCMAKE_Fortran_COMPILER="$fc" \
         -DMPI_Fortran_COMPILER="$MPIFC" \
         ${name_arg[@]+"${name_arg[@]}"} \
         ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"} >"$log" 2>&1; then
    tail -n 30 "$log" >&2
    die "CMake configure failed (full log: $log)"
  fi
  if ! cmake --build "$BUILD_DIR" ${clean[@]+"${clean[@]}"} -j "$JOBS" >>"$log" 2>&1; then
    # FIRETEC 1.5.0's libraries each compile variables.F90 etc. into the
    # shared opt/ dir with no build order between them, so parallel builds
    # race on the .mod files. The losing compiles can leave a module missing
    # whose object make already counts as built, so resuming is not enough:
    # rebuild from clean with one job. A real compile error then shows up
    # unscrambled.
    if [[ "$JOBS" -eq 1 ]]; then
      tail -n 30 "$log" >&2
      die "build failed (full log: $log)"
    fi
    info "parallel build failed; rebuilding from clean with 1 job (about a minute)"
    printf '\n==== ndp: rebuilding from clean with 1 job ====\n' >>"$log"
    rm -f "$CODE_DIR"/opt/*.mod "$CODE_DIR"/opt/*.smod
    if ! cmake --build "$BUILD_DIR" --clean-first -j 1 >>"$log" 2>&1; then
      tail -n 30 "$log" >&2
      die "build failed (full log: $log)"
    fi
  fi
  [[ -x "$BUILD_DIR/firerad" ]] || die "build finished but $BUILD_DIR/firerad is missing"
  printf '%s\n' "$BUILD_DIR" > "$stamp"
  ok "built $BUILD_DIR/firerad (log: $log)"
}

# Runs firerad on smoke_test.gridlist (see that file for the setup).
smoke_test() {
  section "Smoke test"
  local nt frq nx ny outname np v run rc=0 out0 outn mpi_args
  nt=$(gridlist_value nt "$SMOKE_GRIDLIST")
  frq=$(gridlist_value frqoutput "$SMOKE_GRIDLIST")
  nx=$(gridlist_value nprocx "$SMOKE_GRIDLIST")
  ny=$(gridlist_value nprocy "$SMOKE_GRIDLIST")
  outname=$(gridlist_value outname "$SMOKE_GRIDLIST")
  for v in "$nt" "$frq" "$nx" "$ny"; do
    [[ "$v" =~ ^[1-9][0-9]*$ ]] \
      || die "$SMOKE_GRIDLIST must set nt, frqoutput, nprocx and nprocy to positive integers"
  done
  [[ -n "$outname" ]] || die "$SMOKE_GRIDLIST must set outname"
  (( nt % frq == 0 )) || die "$SMOKE_GRIDLIST: nt must be a multiple of frqoutput"
  np=$(( nx * ny ))
  mpi_args=(-np "$np")
  if (( $(nproc 2>/dev/null || echo 1) < np )); then mpi_args+=(--oversubscribe); fi

  run=$(mktemp -d "${TMPDIR:-/tmp}/firetec-smoke.XXXXXX")
  cp "$SMOKE_GRIDLIST" "$run/gridlist"
  # FIRETEC 1.5.0 neither creates the output directory nor takes a gridlist
  # argument (it always reads ./gridlist), so do both the portable way.
  mkdir -p "$run/$(dirname "$outname")"
  info "running: mpirun ${mpi_args[*]} firerad   (in $run)"
  (cd "$run" && timeout 120 mpirun "${mpi_args[@]}" "$BUILD_DIR/firerad") \
    >"$run/run.log" 2>&1 || rc=$?
  # FIRETEC exits 0 on input errors, so check the log and outputs too.
  out0="$run/$outname.0"
  outn="$run/$outname.$nt"
  # 1.5.1 also writes the initial state (.0); 1.5.0 does not.
  if [[ $rc -eq 0 && -s "$outn" ]] \
     && { [[ ! -e "$out0" ]] || [[ $(stat -c %s "$out0") -eq $(stat -c %s "$outn") ]]; } \
     && grep -Eq "it total= +$nt +it= +$nt( |\$)" "$run/run.log" \
     && ! grep -Eq 'ERROR|INVALID|Fortran runtime error|NaNs' "$run/run.log"; then
    ok "firerad ran $nt timesteps on $np MPI ranks and wrote its output files"
    rm -rf "$run"
  else
    tail -n 30 "$run/run.log" >&2
    if [[ $rc -eq 124 ]]; then
      die "smoke test timed out after 120 s; run directory kept at $run"
    fi
    die "smoke test failed (exit code $rc); run directory kept at $run"
  fi
}

#------------------------------- main ------------------------------------
check_environment

# Which toolchain to check first: an existing conda env wins under auto.
if [[ "$METHOD" == conda ]] || { [[ "$METHOD" == auto ]] && [[ -d "$ENV_PREFIX/conda-meta" ]]; }; then
  use_toolchain conda
else
  use_toolchain system
fi
check_dependencies

if [[ $DO_INSTALL -eq 0 ]]; then
  section "Summary"
  if [[ $MISSING -eq 0 ]]; then
    ok "all dependencies present ($TOOLCHAIN toolchain)"
  else
    warn "$MISSING dependency check(s) failed; run without --check to install"
  fi
  exit $(( MISSING > 0 ))
fi

if [[ $MISSING -gt 0 ]]; then
  INSTALL="$METHOD"
  if [[ "$METHOD" == auto ]]; then
    if [[ "$TOOLCHAIN" == conda ]] || find_conda >/dev/null; then INSTALL=conda
    elif [[ $HAVE_SUDO -eq 1 ]]; then INSTALL=apt
    else die "cannot install: no conda/mamba and no passwordless sudo"; fi
    info ""
    info "auto: installing with $INSTALL"
  fi
  case "$INSTALL" in
    apt)   install_apt;   use_toolchain system ;;
    conda) install_conda; use_toolchain conda ;;
  esac
  check_dependencies
  [[ $MISSING -eq 0 ]] || die "$MISSING dependency check(s) still failing after install"
fi
write_env_file
register_jupyter_kernel

if [[ $DO_BUILD -eq 1 ]]; then build_firetec; fi
if [[ $DO_TEST -eq 1 ]]; then smoke_test; fi

section "Done"
ok "FIRETEC dependencies are ready ($TOOLCHAIN toolchain)."
info "In each new terminal:  source $ENV_FILE"
if [[ $DO_BUILD -eq 0 ]]; then
  info "Build FIRETEC:         bash $SCRIPT_DIR/install.sh --build"
fi
info "Run in a case folder:  mpirun -np <nprocx*nprocy> \$FIRETEC_EXE   (reads ./gridlist)"
info "(fire runs need an ignite.dat; TOOLS/Ignition/ign_mkr.py writes one)"
