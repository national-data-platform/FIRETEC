# FIRETEC post-processing

`firetec_to_zarr.py` converts the output of a FIRETEC 1.5.0 run into a single
[Zarr](https://zarr.dev) store that opens directly in xarray, with the grid,
the ignition pattern, every run parameter and provenance stored as metadata.

## Setup

On NDP, `source TOOLS/NDP/firetec-env.sh`: the conda environment it uses
includes numpy, xarray and zarr. Elsewhere, with Python 3.11 or newer:

```bash
python3 -m pip install -r TOOLS/Postprocessing/requirements.txt
```

## Usage

```bash
python3 TOOLS/Postprocessing/firetec_to_zarr.py CASE_DIR [-o OUTPUT.zarr]
```

`CASE_DIR` is the folder FIRETEC ran in. The converter reads its `gridlist`,
the output files named by `outname` (`comp/comp.out.<step>` by default), the
ignition file, the topography file if the run used one, and `run.log` (FIRETEC's
printed output) if present. The store goes to `CASE_DIR/<case name>.zarr`
unless you pass `-o`.

| Option | Effect |
|---|---|
| `-o, --output PATH` | Where to write the store |
| `--gridlist PATH` | Use another gridlist than `CASE_DIR/gridlist` |
| `--log PATH` | FIRETEC's printed output, for the start-up profile |
| `--density-weighted` | Keep fields as FIRETEC stores them (ρu, ρθ, …) |
| `--zarr-format 3` | Write Zarr format 3 instead of 2 |
| `--overwrite` | Replace an existing store |
| `-q, --quiet` | Only print warnings |

The gridlist must be the one the run used: the field names, grid and time
step all come from it, with FIRETEC 1.5.0's defaults for every key it leaves
out. The converter checks the record count and sizes against it and, when a
`run.log` is present, the vertical grid too.

## What the store contains

| Name | Dimensions | Contents |
|---|---|---|
| `time`, `step` | time | Simulated time in s (step × `nts` × `dts`) and FIRETEC step number |
| `x`, `y` | x, y | Cell centres in m, measured from the domain's lower boundaries |
| `z`, `z_bounds`, `sigma` | z | Stretched cell-centre heights above flat ground, cell edges, and the unstretched coordinate |
| `u`, `v`, `w`, `theta`, `ka`, `kb`, `rho` | time, z, y, x | Wind (m s⁻¹), potential temperature (K), subgrid turbulent kinetic energies (m² s⁻²), air density (kg m⁻³) |
| gas species (e.g. `O2`), aerosol moments, `mixfrac` | time, z, y, x | Present when the run has them |
| `rhoFuel`, `rhoWater`, `sies`, `psiwmax` | time, fuel_type, z_fuel, y, x | Fuel and fuel-water bulk densities, fuel internal energy, evaporation progress |
| `ignition_*` | ignition_point | Ignited cells, their positions and start times, ramp rate and target temperature |
| `initial_*` | z | Start-up ambient profile, from `run.log` |
| `terrain_height`, `height` | y, x / z, y, x | Ground height and terrain-following cell heights, for runs with topography |

FIRETEC stores every atmosphere field except `rho` multiplied by the air
density; the converter divides them by `rho`, so they hold physical values.
Every variable has a `long_name`, `units` unless it is an index or count, and
a CF `standard_name` where one exists.

The global attributes hold:

- `firetec_parameters`: all 149 gridlist parameters FIRETEC 1.5.0 reads, each with its value, whether it came from the gridlist or the default, and its description
- `firetec_gridlist`: the gridlist text
- `firetec_record_order`: the order of the records in each output file
- `firetec_missing_output_steps`: expected steps that have no output file
- `firetec_repository`: the git repository the converter came from: its `url`
  (origin remote, with any embedded credentials removed), `commit`, `branch`, and
  `uncommitted_changes` (whether tracked files differed from that commit)
- `input_files`, `output_files`: every file used, with size and SHA-256 checksum
- `history`, `date_created`, `software`: when, how and with which versions the store was made

## Reading the store

```python
import xarray as xr

ds = xr.open_zarr("case.zarr")
hottest = ds.theta.isel(time=-1).max()             # K
ground_wind = ds.u.isel(z=0).mean(["x", "y"])      # m/s, per output step
ds.attrs["firetec_parameters"]["dx"]               # {'value': 2.0, 'source': 'default', ...}
```

## Visualizing a store

`visualize_firetec.ipynb` plots a converted run:

- tables of the run's setup and of the gridlist values
- maps of the fraction of fuel consumed and of when the fire reached each cell
- fire progress over time (burned area, fuel consumed, peak heating, plume top), with a table of the same numbers
- heating and wind streamlines at the lowest level, at moments spread over the burn
- a vertical cross-section through the plume at its tallest
- the fire from start to finish as an animation with play buttons and a slider:
  heating at the lowest level with the burned area as it grows, above a vertical
  slice through the plume, on a logarithmic color scale so the faint plume shows
  next to the flames
- the start-up ambient profile, when the store has one

Maps draw the model's cell edges as hairlines. Plots with a height axis leave
them out, because the stretched vertical cells crowd together near the ground,
but the slices still color the model's actual cells: stretched, and following
the terrain in runs with topography.

On NDP, open the notebook and choose the **Python (FIRETEC)** kernel.
`TOOLS/NDP/install.sh` registers it; run that script again after the server
restarts, because the registration lives in your home folder. The settings are
in the first code cell:

| Setting | Effect |
|---|---|
| `STORE` (or `FIRETEC_ZARR`) | The store to plot |
| `THEME` (or `FIRETEC_PLOT_THEME`) | `"dark"` for JupyterLab's dark theme |
| `SHOW_CELL_GRID`, `MAX_GRID_LINES` | Draw the cell edges on maps; on finer grids only every n-th edge, at most this many lines per direction |
| `MAX_ANIMATION_FRAMES` | Outputs the animation shows at most; each adds about 60 kB to the notebook |
| `SAVE_FIGURES_TO` (or `FIRETEC_FIGURES`) | Also save each figure as PNG, and the animation as `fire_animation.html`, which opens in any browser |

The animation's buttons are JavaScript, which Jupyter runs only for notebooks you
trust. If they do nothing in a notebook you did not run yourself, run the cell
again or choose **Trust Notebook** in the command palette; on NDP the trust is
forgotten when the server restarts. With its outputs, the notebook is a few MB:
clear them (`jupyter nbconvert --clear-output --inplace visualize_firetec.ipynb`)
before committing changes to it. To run it without opening Jupyter:

```bash
FIRETEC_ZARR=run.zarr FIRETEC_FIGURES=figures jupyter nbconvert --to notebook \
  --execute --ExecutePreprocessor.kernel_name=firetec visualize_firetec.ipynb
```

## Files

| File | Purpose |
|---|---|
| `firetec_to_zarr.py` | The converter |
| `visualize_firetec.ipynb` | Plots a converted run |
| `firetec_1.5.0_parameters.json` | FIRETEC 1.5.0's gridlist keys, types, defaults and descriptions |
| `build_parameter_catalog.py` | Rebuilds that JSON from `CODE-1.5.0` |
| `test_firetec_to_zarr.py` | Tests: `python3 -m unittest -v test_firetec_to_zarr`, run in this folder |
| `requirements.txt` | Python packages needed |

Not converted: firebrand, sensor and wind-field output files.
