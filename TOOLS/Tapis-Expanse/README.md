# FIRETEC 1.5.0 on SDSC Expanse via Tapis (ZIP runtime)

Runs HIGRAD/FIRETEC 1.5.0 (`firerad`) from
[national-data-platform/FIRETEC](https://github.com/national-data-platform/FIRETEC), branch
`main`, on Expanse through Tapis. `main` is `FIRETEC-1.5.0` plus NDP tooling under `TOOLS/`; the
FIRETEC source in `CODE-1.5.0` is identical. It is built natively against SDSC's MPI and launched
with the Tapis ZIP runtime.

```
site.env.example              the only file you edit (copy to site.env)
expanse/build_firetec.sh      build, self-test and package FIRETEC (run on an Expanse compute node)
expanse/make_smoke_cases.sh   four small test cases
expanse/tapisjob_app.sh       launcher Tapis runs inside the Slurm job (packaged into the archive)
tapis/expanse-system.json     Tapis execution system with debug, shared and compute queues
tapis/firetec-app.json        Tapis app (runtime ZIP, jobType BATCH)
tapis/jobs/*.json             smoke tests and a production example
tapis/deploy.py               registers everything and runs the smoke tests (tapipy)
```

## 1. Build on Expanse

Do this as the Expanse account Tapis logs in as, so that account owns the archive and cases.

```bash
# Login node: get the source, and copy this bundle's expanse/ folder over (e.g. to ~/tapis-expanse/expanse)
git clone --branch main https://github.com/national-data-platform/FIRETEC.git ~/src/FIRETEC-1.5.0

# Compute node: build, run a 4-rank self-test, package
srun -p debug -A <project> -N 1 -n 16 --mem=32G -t 00:30:00 --pty --wait=0 --export=ALL /bin/bash
bash ~/Tapis-Expanse/expanse/build_firetec.sh
# or overwrite with firetec-build.env (overwrites FIRETEC_SRC, see above for more env vars)
source ~/Tapis-Expanse/expanse/firetec-build.env && bash expanse/build_firetec.sh

bash ~/Tapis-Expanse/expanse/make_smoke_cases.sh
```

The build script refuses to build a checkout from another repository or branch, so an older
clone elsewhere can't be picked up by mistake. If you already cloned the `FIRETEC-1.5.0` branch
into that directory, switch it with `git -C ~/src/FIRETEC-1.5.0 checkout main`.

It also works around three problems in 1.5.0's own CMake setup:

- its `-O2` never reaches the compiler, so a plain build is unoptimized; the script passes
  `-O2 -g -march=znver2` itself
- GCC 10 and newer reject its MPI calls; the script adds `-fallow-argument-mismatch`
- parallel `make` races on a shared module directory; the script builds serially

The default modules match the ones FIRETEC has been compiled with on Expanse before:

- **Build and run:** `cpu/0.17.3b gcc/10.2.0/npcyll4 openmpi/4.1.1 slurm`. `slurm` is on this list
  because the launcher clears modules before loading the recorded ones, and OpenMPI's `mpirun`
  uses `srun` to start ranks on other nodes.
- **Build only:** `cmake/3.21.4/teqow32`, which isn't loaded at run time.

Ranks are launched with `mpirun`. Override any of these with `FIRETEC_MODULES`,
`FIRETEC_BUILD_MODULES` or `FIRETEC_MPI_LAUNCH`.

The build script prints `APP_ARCHIVE` and `APP_VERSION`, and the smoke-case script prints
`CASES_DIR`. Copy those into `site.env`. The archive records the exact modules and MPI launcher,
and the launcher loads exactly those at run time.

## 2. Fill in site.env
Make a copy of the `site.env.example` file:
```
cp site.env.example site.env
```
Note that `site.env` is gitignore

Set `TAPIS_BASE_URL`, `TAPIS_USERNAME` (or export `TAPIS_JWT`), `EXPANSE_USER`, `EXPANSE_PROJECT`,
`SSH_PRIVATE_KEY_FILE`, plus the three paths printed in step 1. Check that the scratch area exists:
`ls -d /expanse/lustre/scratch/$USER/temp_project`.

## 3. Register with Tapis (from any machine with Python 3.8+)

```bash
python3 -m venv venvs-ndp-tapis
source venvs-ndp-tapis/bin/activate
pip install -r requirements.txt
python3 tapis/deploy.py render             # writes filled-in JSON to rendered/ for review; no Tapis calls
python3 tapis/deploy.py system             # create the execution system
python3 tapis/deploy.py system --update    # update the execution system
python3 tapis/deploy.py credential         # register the key; Tapis logs in to verify it
python3 tapis/deploy.py check              # confirm Tapis sees the archive, cases and scratch
python3 tapis/deploy.py app                # create the app version
```

Skip `credential` if a key is already registered for this system id. Use `--update` on `system`
or `app` to change an existing one.

## 4. Smoke tests

```bash
python3 tapis/deploy.py smoke
```

| Test | Expected | What it proves |
|---|---|---|
| smoke-nofire | FINISHED | archive extraction, modules, OpenMPI's `mpirun`, Lustre paths |
| smoke-fire | FINISHED | ignition, fuel and radiation code paths, 100 steps |
| smoke-bad-decomp | FAILED, exit 1 | the launcher catches a rank-count mismatch before starting FIRETEC |
| smoke-bad-input | FAILED, exit 3 | `irad = 1` makes FIRETEC stop after one step with status 0; the launcher catches it |

## FIRETEC 1.5.0 behaviors the launcher handles

FIRETEC 1.5.0 has several behaviors that would otherwise produce failed runs that Tapis reports as
FINISHED, or runs that crash for avoidable reasons.

- **No rank-count check.** 1.5.0 never compares the MPI rank count with `nprocx × nprocy`, so a
  mismatch crashes in MPI or computes on the wrong layout. The launcher refuses mismatched or
  non-divisible decompositions before starting FIRETEC.
- **Exit status 0 on fatal errors.** Several fatal paths exit with status 0, for example
  "Diffusive Radiation Not implemented", "NaNs in XV array", and bare STOPs. The launcher treats
  a run as successful only if the exit status is 0, no fatal message was printed, and the last
  `it total=` step equals `nt`.
- **No output directory creation.** 1.5.0 doesn't create the directory in `outname` (for example
  `./comp/`) and crashes with "Cannot open file". The launcher creates the directories named by
  `outname`, `outname_fb` and `sensorfile`.
- **Fixed gridlist name.** 1.5.0 always reads `./gridlist`. If you set `FIRETEC_GRIDLIST` to
  another name, the launcher links `./gridlist` to it.

**Gridlist format.** 1.5.0 only reads a setting written as lowercase `key = value`, with spaces
around `=`. It ignores `nprocx=2` and `NPROCX = 2` without any warning and uses the default
instead. The launcher reads the gridlist by the same rules, so its rank check uses the values
FIRETEC will actually use, and it prints a note for lines FIRETEC would skip. If a key appears
twice, the first one wins.

**Radiation without fire.** `irad = 2`, as in the example gridlist, only works with `ifire >= 1`.
Atmosphere-only runs need `irad = 0`.

## Running real cases

A case directory holds the gridlist plus every file it references: `ignite.dat` when
`ifire > 0`, the `trees*.dat` fuel files when `ivegread = 1`, the `topofile`, and any restart
files. FIRETEC runs inside that directory, so its outputs land next to the inputs.

There are two ways to supply a case in a job request.

- **Already on Expanse:** set `FIRETEC_CASE_DIR`. The launcher copies the directory into the
  job, so the original is never modified:
  `"parameterSet": {"envVariables": [{"key": "FIRETEC_CASE_DIR", "value": "/expanse/lustre/projects/.../my-burn"}]}`
- **Somewhere Tapis can reach:** use the `case` file input. Tapis stages it to `run/case`:
  `"fileInputs": [{"name": "case", "sourceUrl": "tapis://<storage-system>/path/to/my-burn"}]`

**Sizing rule.** `nodeCount × coresPerNode` must equal `nprocx × nprocy`, and `n` must divide
by `nprocx` and `m` by `nprocy`. If the gridlist omits nprocx or nprocy, FIRETEC uses 8.

| Queue | Limits | memoryMB |
|---|---|---|
| debug | up to 2 nodes, 30 min | about 1900 per core |
| shared | 1 node, fewer than 128 cores, 48 h | about 1900 per core (billed by cores or memory, whichever is larger) |
| compute | whole 128-core nodes, billed in full, up to 32 nodes, 48 h | 249208 (the whole node) |

`tapis/jobs/example-compute.json` shows 2 nodes = 256 ranks, so its gridlist needs
nprocx × nprocy = 256 (for example 16 × 16). Set `MY_CASE_DIR` and `MY_CASE_NAME` in `site.env`,
then run `python3 tapis/deploy.py submit tapis/jobs/example-compute.json --watch`.

## Where outputs go

Each job's results are in `<JOB_WORKING_DIR>/jobs/<jobUuid>/run/case/`. That directory holds
FIRETEC's output, `firetec.log`, and `run-info.txt`, which records the job ids, repository,
commit, modules, rank layout, the last step reached, and timing. The launcher's own log is
`run/tapisjob.out`.

The app sets `archiveSystemDir` equal to `execSystemOutputDir`, so Tapis's archive step leaves
outputs in place instead of copying them (only `tapisjob.sh` and `tapisjob.env` get added). The
Tapis job-output API lists that directory.

Lustre scratch is purged 90 days after file creation, so copy runs you want to keep into
`/expanse/lustre/projects/...`. You can point `archiveSystemDir` elsewhere in a job request, but
then Tapis copies every file through its Files service, which is fine for small runs and slow for
large ones.

## Troubleshooting

- **"note: FIRETEC 1.5.0 ignores the gridlist line ..."** Rewrite that line as lowercase
  `key = value`.
- **"FIRETEC stopped at step X of N and exited with status 0".** FIRETEC hit a fatal path that
  prints nothing recognizable. Check the end of `firetec.log`.
- **Submission fails with `sbatch: command not found`.** Tapis submits from a non-interactive
  SSH session. Add `module load slurm` to the Expanse account's `~/.bashrc`.
- **`module load failed` or `unresolved shared libraries`.** The recorded modules no longer
  match what's on Expanse. Check with `module spider`, then rebuild.
- **`credential` fails.** Possible causes:
  - the key has a passphrase
  - the key isn't in `~/.ssh/authorized_keys`
  - SDSC's MFA arrangement doesn't cover the Tapis hosts
- **Lustre errors at startup.** Every queue in the system template passes
  `--constraint=lustre`. Expanse jobs without it can land on nodes without Lustre.
- **A job sits in QUEUED.** That's a normal queue wait. The debug partition runs one job per
  user at a time.
- **A multi-node job fails with "srun is not on PATH".** `mpirun` needs `srun` to start ranks on
  other nodes. Keep `slurm` in `FIRETEC_MODULES`, then rebuild.
- **Self-test hangs in an interactive session with an `srun`-based launcher.** A nested `srun`
  needs `--overlap`. The build script adds it automatically when it detects an `srun --pty`
  shell. The default `mpirun` doesn't need it.
