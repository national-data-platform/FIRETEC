# FIRETEC environment for NDP. TOOLS/NDP/install.sh writes firetec-env.sh
# from the template firetec-env.sh.in, filling in the @...@ values. Source
# firetec-env.sh in every new terminal:
#   source /home/jovyan/work/_User-Persistent-Storage_CephBlock_/FIRETEC/TOOLS/NDP/firetec-env.sh

export FIRETEC_HOME="/home/jovyan/work/_User-Persistent-Storage_CephBlock_/FIRETEC"
export FIRETEC_CODE_DIR="/home/jovyan/work/_User-Persistent-Storage_CephBlock_/FIRETEC/CODE-1.5.0"
export FIRETEC_BUILD_DIR="/home/jovyan/work/_User-Persistent-Storage_CephBlock_/FIRETEC/CODE-1.5.0/build"
export FIRETEC_EXE="$FIRETEC_BUILD_DIR/firerad"
export FIRETEC_TOOLCHAIN="conda"   # conda or system

# Undo the conda toolchain if an earlier firetec-env.sh set it up in this shell.
if [ -n "${FIRETEC_ENV_PREFIX:-}" ]; then
  PATH=$(printf '%s\n' "$PATH" | tr ':' '\n' | { grep -vxF "$FIRETEC_ENV_PREFIX/bin" || true; } | paste -sd: -)
  export PATH
  case "${FC:-}" in "$FIRETEC_ENV_PREFIX"/*) unset FC ;; esac
  unset FIRETEC_ENV_PREFIX
fi

if [ "$FIRETEC_TOOLCHAIN" = conda ]; then
  export FIRETEC_ENV_PREFIX="/home/jovyan/work/_User-Persistent-Storage_CephBlock_/envs/firetec"
  export PATH="$FIRETEC_ENV_PREFIX/bin:$PATH"
  export FC="$FIRETEC_ENV_PREFIX/bin/gfortran"
fi

# OpenMPI settings for the NDP pod, from TOOLS/NDP/openmpi*.conf (see there
# for why each is needed). Every version's settings are cleared first, since
# a stale OpenMPI 5 setting such as btl=self,sm breaks OpenMPI 4.
unset OMPI_MCA_btl
unset OMPI_MCA_btl_sm_backing_directory
unset OMPI_MCA_btl_vader_backing_directory
unset OMPI_MCA_btl_vader_single_copy_mechanism
unset OMPI_MCA_hwloc_base_binding_policy
unset OMPI_MCA_hwloc_base_use_hwthreads_as_cpus
unset OMPI_MCA_smsc
unset PRTE_MCA_hwloc_default_binding_policy
unset PRTE_MCA_prte_set_default_slots
export OMPI_MCA_btl='self,sm'
export OMPI_MCA_btl_sm_backing_directory='/tmp'
export OMPI_MCA_smsc='^cma'
export PRTE_MCA_prte_set_default_slots='hwthreads'
export PRTE_MCA_hwloc_default_binding_policy='none'

if ! command -v mpirun >/dev/null 2>&1; then
  echo "[firetec-env] mpirun not found -- the NDP server was probably restarted;" >&2
  echo "[firetec-env] re-run: bash $FIRETEC_HOME/TOOLS/NDP/install.sh" >&2
fi
