#!/usr/bin/env python3
"""Convert FIRETEC 1.5.0 output files to a self-describing Zarr store.

FIRETEC writes one binary file per output step, named <outname>.<step> (for
example comp/comp.out.250). Each file is a sequence of Fortran unformatted
records: one (n, m, l) record per atmosphere field, then one (n, m, lfuel)
record per fuel field and fuel type. This script

  * reads the case's gridlist, filling in FIRETEC 1.5.0's defaults for the
    keys it leaves out, to name the fields and rebuild the grid;
  * divides FIRETEC's density-weighted fields (rho*u, rho*theta, ...) by the
    air density to get physical values;
  * writes the fields to an xarray-compatible Zarr store, together with the
    grid, the ignition pattern, every run parameter and provenance metadata.

Usage:
    python3 firetec_to_zarr.py CASE_DIR [-o OUTPUT.zarr]

Read the result with xarray.open_zarr("OUTPUT.zarr"). See README.md.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import logging
import platform
import re
import subprocess
import sys
import warnings
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

try:
    import numpy as np
    import xarray as xr
    import zarr
except ImportError as missing:
    sys.exit(f"firetec_to_zarr.py needs numpy, xarray and zarr ({missing}).\n"
             "Install them with: python3 -m pip install -r "
             f"{Path(__file__).resolve().with_name('requirements.txt')}")

CONVERTER_VERSION = "1.0.0"
FIRETEC_VERSION = "1.5.0"
CONVERTER_DIR = Path(__file__).resolve().parent
CATALOG_PATH = CONVERTER_DIR / f"firetec_{FIRETEC_VERSION}_parameters.json"

FLOAT_TYPES = {4: np.dtype("<f4"), 8: np.dtype("<f8")}  # default and DBL_PREC builds
MARKER_BYTES = 4              # gfortran record markers are 4-byte signed integers
HORIZONTAL_CHUNK = 256        # Zarr chunk length along x and y
TIME_COORDINATE_CHUNK = 512   # Zarr chunk length of the time coordinates
GAS_NAME_LENGTH = 6           # character(len=6) :: spEmit    (Emissions/variables_ems.F90)
AEROSOL_NAME_LENGTH = 12      # character(len=12) :: spAero
FIRE_OXIDIZER = "O2"          # gas FIRETEC adds when ifire = 1 (Emissions/input_ems.F90)

# FIRETEC's atmosphere fields (the xv array). All but rho are stored
# multiplied by the air density.
ATMOSPHERE_ATTRS = {
    "u": {"long_name": "wind velocity along x", "units": "m s-1", "standard_name": "x_wind"},
    "v": {"long_name": "wind velocity along y", "units": "m s-1", "standard_name": "y_wind"},
    "w": {"long_name": "vertical wind velocity", "units": "m s-1",
          "standard_name": "upward_air_velocity"},
    "theta": {"long_name": "potential temperature", "units": "K",
              "standard_name": "air_potential_temperature"},
    "ka": {"long_name": "subgrid turbulent kinetic energy at scale a", "units": "m2 s-2"},
    "kb": {"long_name": "subgrid turbulent kinetic energy at scale b", "units": "m2 s-2"},
    "mixfrac": {"long_name": "mixture fraction for non-local burning", "units": "1"},
    "rho": {"long_name": "air density", "units": "kg m-3", "standard_name": "air_density"},
}
# FIRETEC's fuel fields (the xvfuel array), stored as they are.
FUEL_ATTRS = {
    "rhoFuel": {"long_name": "bulk density of dry fuel", "units": "kg m-3"},
    "rhoWater": {"long_name": "bulk density of water in the fuel", "units": "kg m-3"},
    "sies": {"long_name": "specific internal energy of the fuel and its water",
             "units": "J kg-1"},
    "psiwmax": {"long_name": "highest water-evaporation progress reached", "units": "1",
                "comment": "psi_w rises from 0 to 1 as the fuel temperature crosses the "
                           "evaporation range (fuel.F90)"},
}

LOG = logging.getLogger("firetec_to_zarr")


class ConversionError(Exception):
    """A problem with the case's files, reported to the user without a traceback."""


# ---------------------------------------------------------------- gridlist --

def list_directed_tokens(text: str) -> list[str]:
    """Split text into items the way Fortran list-directed input reads them.

    Items are separated by blanks or commas and quotes delimit strings. An
    unquoted '/' ends the input, as in Fortran, and '!' starts a comment.
    """
    tokens: list[str] = []
    current, quote, in_item = "", None, False
    for char in text:
        if quote:
            if char == quote:
                quote = None
            else:
                current += char
        elif char in "'\"":
            quote, in_item = char, True
        elif char in " \t,":
            if in_item:
                tokens.append(current)
                current, in_item = "", False
        elif char in "/!":
            break
        else:
            current += char
            in_item = True
    if in_item:
        tokens.append(current)
    return tokens


def fortran_float(text: str) -> float:
    return float(text.replace("d", "e").replace("D", "E"))


@dataclass(frozen=True)
class Gridlist:
    """The 'key = value' entries of a gridlist, as FIRETEC 1.5.0 reads them:
    keys are case-sensitive and the first entry for a key wins."""
    path: Path
    text: str
    entries: dict[str, list[str]]   # key -> value items

    @classmethod
    def read(cls, path: Path) -> Gridlist:
        if not path.is_file():
            raise ConversionError(f"no gridlist at {path}")
        text = path.read_text()
        entries: dict[str, list[str]] = {}
        for line in text.splitlines():
            tokens = list_directed_tokens(line)
            if len(tokens) >= 3 and tokens[1] == "=":
                entries.setdefault(tokens[0], tokens[2:])
        return cls(path, text, entries)


# -------------------------------------------------------------- parameters --

@dataclass(frozen=True)
class ParameterSpec:
    name: str
    kind: str          # integer, real, string, real array, string array
    default: object    # None where FIRETEC sets the value in code
    description: str


@dataclass(frozen=True)
class Catalog:
    """Every gridlist key FIRETEC 1.5.0 reads (see build_parameter_catalog.py)."""
    parameters: dict[str, ParameterSpec]
    provenance: dict    # FIRETEC version, source commit, ...


def load_catalog(path: Path = CATALOG_PATH) -> Catalog:
    content = json.loads(path.read_text())
    parameters = {name: ParameterSpec(name, entry["type"], entry["default"], entry["description"])
                  for name, entry in content["parameters"].items()}
    provenance = {key: value for key, value in content.items() if key != "parameters"}
    return Catalog(parameters, provenance)


SCALAR_PARSERS = {"integer": int, "real": fortran_float, "string": str}


def parse_value(tokens: list[str], spec: ParameterSpec):
    base_kind, _, array = spec.kind.partition(" ")
    parse = SCALAR_PARSERS[base_kind]
    try:
        values = [parse(token) for token in tokens]
    except ValueError as error:
        raise ConversionError(f"gridlist value {' '.join(tokens)!r} for {spec.name} is not "
                              f"a valid {base_kind}") from error
    return values if array else values[0]


class RunParameters:
    """The parameters of a run: gridlist values, with FIRETEC 1.5.0's defaults
    for every key the gridlist leaves out."""

    def __init__(self, gridlist: Gridlist, catalog: Catalog):
        self.gridlist = gridlist
        self.catalog = catalog
        self._values = {name: self._resolve(spec) for name, spec in catalog.parameters.items()}

    def __getitem__(self, name: str):
        return self._values[name]

    def _resolve(self, spec: ParameterSpec):
        tokens = self.gridlist.entries.get(spec.name)
        return spec.default if tokens is None else parse_value(tokens, spec)

    @property
    def unrecognized_keys(self) -> list[str]:
        """Gridlist keys FIRETEC 1.5.0 does not read (and so ignored)."""
        return [key for key in self.gridlist.entries if key not in self.catalog.parameters]

    def metadata(self) -> dict:
        """Every parameter's value, where it came from and what it means."""
        return {name: {"value": self._values[name],
                       "source": "gridlist" if name in self.gridlist.entries else "default",
                       "description": spec.description}
                for name, spec in self.catalog.parameters.items()}


def emissions_option(params: RunParameters) -> int:
    """iemissions as FIRETEC uses it: fire switches emissions on (input.F90)."""
    if params["ifire"] == 1 and params["iemissions"] == 0:
        return 2
    return params["iemissions"]


def time_step(params: RunParameters) -> float:
    """The large time step, dt = nts * dts (rinit.F90)."""
    return params["nts"] * params["dts"]


def restart_step(params: RunParameters) -> int:
    """The step a restarted run started from: the number after 'out.' in the
    restart file name (io.F90, irstreadio); 0 for a fresh start."""
    if params["irst"] != 1:
        return 0
    try:
        return int(params["restartfile"].split("out.", 1)[1])
    except (IndexError, ValueError) as error:
        raise ConversionError(
            f"cannot read the restart step from {params['restartfile']!r}") from error


def expected_output_steps(params: RunParameters) -> list[int]:
    """Steps FIRETEC writes output for: every frqoutput steps after the start."""
    start, every = restart_step(params), params["frqoutput"]
    return list(range(start + every, params["nt"] + 1, every))


def missing_output_steps(params: RunParameters, outputs: list[OutputFile]) -> list[int]:
    missing = sorted(set(expected_output_steps(params)) - {output.step for output in outputs})
    if missing:
        LOG.warning("warning: %d expected output step(s) are missing, e.g. %s (the run may "
                    "have stopped early)", len(missing), missing[:5])
    return missing


# ------------------------------------------------------------------ fields --

@dataclass(frozen=True)
class Field:
    """One FIRETEC output variable."""
    name: str
    attrs: dict
    density_weighted: bool = False


def gas_species(params: RunParameters) -> list[str]:
    """Gas species names as FIRETEC sets them (Emissions/input_ems.F90)."""
    count = params["nEmit"]
    names = [name[:GAS_NAME_LENGTH] for name in (params["Species"] or [])][:count]
    names += [f"species{index}" for index in range(len(names) + 1, count + 1)]
    if params["ifire"] == 1 and FIRE_OXIDIZER not in names:
        names.insert(0, FIRE_OXIDIZER)
    return names


def aerosol_species(params: RunParameters) -> list[str]:
    count = params["nAero"]
    names = [name[:AEROSOL_NAME_LENGTH] for name in (params["SpeciesAero"] or [])][:count]
    return names + [f"aerosol{index}" for index in range(len(names) + 1, count + 1)]


def emission_fields(params: RunParameters) -> list[Field]:
    """Gas mass fractions, then the moments of each aerosol size distribution."""
    gases = [Field(name, {"long_name": f"mass fraction of {name}", "units": "kg kg-1"},
                   density_weighted=True)
             for name in gas_species(params)]
    aerosols = [Field(f"{name}{moment}",
                      {"long_name": f"moment {moment} of the {name} aerosol size distribution",
                       "comment": "units are not documented by FIRETEC"},
                      density_weighted=True)
                for name in aerosol_species(params)
                for moment in range(1, params["nMAero"] + 1)]
    return gases + aerosols


def atmosphere_fields(params: RunParameters) -> list[Field]:
    """The atmosphere fields in file order (definearray.F90, xvpointers)."""
    names = ["u", "v", "w", "theta"]
    if params["iturb"] >= 1:
        names.append("ka")
    if params["iturb"] >= 2:
        names.append("kb")
    fields = [Field(name, ATMOSPHERE_ATTRS[name], density_weighted=True) for name in names]
    if emissions_option(params) > 0:
        fields += emission_fields(params)
    if params["inonlocal"] == 1:
        fields.append(Field("mixfrac", ATMOSPHERE_ATTRS["mixfrac"], density_weighted=True))
    fields.append(Field("rho", ATMOSPHERE_ATTRS["rho"]))
    return fields


def fuel_fields(params: RunParameters) -> list[Field]:
    """The fuel fields in file order (definearray.F90, xvpointers)."""
    names = ["rhoFuel", "rhoWater"] + (["sies", "psiwmax"] if params["ifire"] == 1 else [])
    return [Field(name, FUEL_ATTRS[name]) for name in names]


# ------------------------------------------------------------ binary files --

def read_marker(data: memoryview, offset: int, path: Path) -> int:
    if offset + MARKER_BYTES > len(data):
        raise ConversionError(f"{path} is truncated")
    return int.from_bytes(data[offset:offset + MARKER_BYTES], "little", signed=True)


def split_records(data: bytes, path: Path) -> list[memoryview]:
    """Split a gfortran sequential unformatted file into its records.

    Each (sub)record is framed by its length before and after. Records over
    2 GiB are split into subrecords, and a negative leading marker means
    another subrecord follows.
    """
    view, records, parts, offset = memoryview(data), [], [], 0
    while offset < len(view):
        head = read_marker(view, offset, path)
        start, length = offset + MARKER_BYTES, abs(head)
        end = start + length
        if abs(read_marker(view, end, path)) != length:
            raise ConversionError(f"{path} is not a FIRETEC output file (bad record framing)")
        parts.append(view[start:end])
        offset = end + MARKER_BYTES
        if head >= 0:
            records.append(parts[0] if len(parts) == 1 else memoryview(b"".join(parts)))
            parts = []
    if parts:
        raise ConversionError(f"{path} ends inside a record")
    return records


@dataclass(frozen=True)
class OutputFile:
    path: Path
    step: int


def find_output_files(case_dir: Path, outname: str) -> list[OutputFile]:
    """The case's <outname>.<step> files, in step order."""
    prefix = (case_dir / outname).resolve()
    pattern = re.compile(re.escape(prefix.name) + r"\.(\d+)$")
    files = [OutputFile(path, int(match[1]))
             for path in prefix.parent.glob(f"{prefix.name}.*")
             if (match := pattern.match(path.name))]
    if not files:
        raise ConversionError(f"no output files {prefix}.<step> (outname = {outname!r})")
    return sorted(files, key=lambda output: output.step)


@dataclass(frozen=True)
class OutputLayout:
    """Which records of an output file hold which fields, and their shapes."""
    atmosphere: list[Field]
    fuel: list[Field]
    fuel_types: int
    grid_shape: tuple[int, int, int]    # (z, y, x)
    fuel_shape: tuple[int, int, int]    # (fuel layer, y, x)
    dtype: np.dtype

    @property
    def record_count(self) -> int:
        return len(self.atmosphere) + len(self.fuel) * self.fuel_types

    def record_names(self) -> list[str]:
        names = [field.name for field in self.atmosphere]
        for field in self.fuel:
            names += [f"{field.name} (fuel type {kind})" for kind in range(1, self.fuel_types + 1)]
        return names


def detect_layout(records: list[memoryview], params: RunParameters, name: str) -> OutputLayout:
    """Match the records of the first output file to the fields the gridlist
    implies, and work out the precision and number of fuel layers."""
    atmosphere, fuel = atmosphere_fields(params), fuel_fields(params)
    fuel_types = params["nfuel"]
    expected = len(atmosphere) + len(fuel) * fuel_types
    if len(records) != expected:
        raise ConversionError(
            f"{name} has {len(records)} records, but the gridlist implies {expected} "
            f"({len(atmosphere)} atmosphere fields + {len(fuel)} fuel fields x {fuel_types} "
            "fuel types). Check that this gridlist is the one the run used.")
    nx, ny, nz = params["n"], params["m"], params["l"]
    itemsize, remainder = divmod(len(records[0]), nx * ny * nz)
    if remainder or itemsize not in FLOAT_TYPES:
        raise ConversionError(f"the records of {name} do not fit an {nx} x {ny} x {nz} grid; "
                              "check n, m and l in the gridlist")
    fuel_layers = len(records[len(atmosphere)]) // (nx * ny * itemsize)
    return OutputLayout(atmosphere, fuel, fuel_types, (nz, ny, nx), (fuel_layers, ny, nx),
                        FLOAT_TYPES[itemsize])


def decode_step(records: list[memoryview], layout: OutputLayout, name: str) -> dict:
    """Arrays of one output file, keyed by field name. Fortran writes (x, y, z)
    column-major, which reads directly as C-order (z, y, x)."""
    if len(records) != layout.record_count:
        raise ConversionError(f"{name} has {len(records)} records, expected {layout.record_count}")

    def as_array(record: memoryview, shape: tuple) -> np.ndarray:
        if len(record) != layout.dtype.itemsize * int(np.prod(shape)):
            raise ConversionError(f"{name} has a record of unexpected size")
        return np.frombuffer(record, layout.dtype).reshape(shape)

    atmosphere_records = records[:len(layout.atmosphere)]
    fuel_records = records[len(layout.atmosphere):]
    arrays = {field.name: as_array(record, layout.grid_shape)
              for field, record in zip(layout.atmosphere, atmosphere_records, strict=True)}
    for index, field in enumerate(layout.fuel):
        per_type = fuel_records[index * layout.fuel_types:(index + 1) * layout.fuel_types]
        arrays[field.name] = np.stack([as_array(record, layout.fuel_shape) for record in per_type])
    return arrays


def to_physical(arrays: dict, layout: OutputLayout) -> dict:
    """Divide the density-weighted fields by the air density."""
    density = arrays["rho"]
    weighted = {field.name for field in layout.atmosphere if field.density_weighted}
    return {name: array / density if name in weighted else array
            for name, array in arrays.items()}


# -------------------------------------------------------------------- grid --

def stretched_height(sigma, aa1: float, top: float):
    """FIRETEC's vertical stretching (metric.F90, with f = 0): a cubic mapping
    the uniform computational coordinate sigma onto height above flat ground."""
    return aa1 * sigma + (1.0 - aa1) * sigma**3 / top**2


@dataclass(frozen=True)
class Grid:
    """Cell-centre coordinates (rinit.F90). x and y are measured from the
    domain's lower x and y boundaries, as FIRETEC's sensors and firebrands do."""
    x: np.ndarray
    y: np.ndarray
    sigma: np.ndarray           # computational vertical coordinate, (k - 1/2) dz
    sigma_edges: np.ndarray
    top: float                  # zb = l dz, the domain top
    aa1: float
    terrain: np.ndarray | None  # (y, x) ground height, if the run used topography

    @property
    def z(self) -> np.ndarray:
        return stretched_height(self.sigma, self.aa1, self.top)

    @property
    def z_bounds(self) -> np.ndarray:
        edges = stretched_height(self.sigma_edges, self.aa1, self.top)
        return np.stack([edges[:-1], edges[1:]], axis=1)

    def height(self) -> np.ndarray:
        """(z, y, x) height of cell centres above the terrain datum (zcart)."""
        ground = self.terrain[np.newaxis]
        return self.z[:, np.newaxis, np.newaxis] * (self.top - ground) / self.top + ground


def build_grid(params: RunParameters, terrain: np.ndarray | None) -> Grid:
    nx, ny, nz, dz = params["n"], params["m"], params["l"], params["dz"]
    sigma_edges = np.arange(nz + 1) * dz
    return Grid(x=(np.arange(nx) + 0.5) * params["dx"],
                y=(np.arange(ny) + 0.5) * params["dy"],
                sigma=sigma_edges[:-1] + 0.5 * dz,
                sigma_edges=sigma_edges,
                top=nz * dz,
                aa1=params["aa1"],
                terrain=terrain)


def topography_path(params: RunParameters, case_dir: Path) -> Path | None:
    """The topography file, if the run used one (rinit.F90)."""
    name = params["topofile"].strip()
    return None if not name or name.startswith("*") else case_dir / name


def read_terrain(path: Path, params: RunParameters, dtype: np.dtype) -> np.ndarray:
    """Read the (y, x) ground height and repeat its edge treatment (topo.F90:
    the outermost cells copy their inner neighbours)."""
    if not path.is_file():
        raise ConversionError(f"the topography file {path} is missing")
    records = split_records(path.read_bytes(), path)
    shape = (params["m"], params["n"])
    if len(records) != 1 or len(records[0]) != dtype.itemsize * shape[0] * shape[1]:
        raise ConversionError(f"{path} does not hold one {shape[1]} x {shape[0]} record")
    terrain = np.frombuffer(records[0], dtype).reshape(shape).astype(np.float64)
    terrain[:, 0], terrain[:, -1] = terrain[:, 1], terrain[:, -2]
    terrain[0, :], terrain[-1, :] = terrain[1, :], terrain[-2, :]
    return terrain


# ---------------------------------------------------------------- ignition --

@dataclass(frozen=True)
class Ignition:
    """The ignition pattern: 1-based cells (i, j, fuel layer k) and start times."""
    path: Path
    ramp_rate: float            # K/s
    target_temperature: float   # K
    cells: np.ndarray           # (points, 3)
    times: np.ndarray           # (points,) s


def read_ignition(path: Path) -> Ignition:
    """Read an ignition file: an &ignitelist namelist followed by nIgn rows of
    'i j k time' (rinitfire.F90)."""
    text = "\n".join(line.split("!", 1)[0] for line in path.read_text().splitlines())
    match = re.search(r"&ignitelist\b(.*?)/(.*)", text, re.IGNORECASE | re.DOTALL)
    if not match:
        raise ConversionError(f"{path} has no &ignitelist ... / namelist")
    settings = {key.lower(): value
                for key, value in re.findall(r"(\w+)\s*=\s*([^,\s]+)", match[1])}
    try:
        count = int(settings["nign"])
        rows = np.array(match[2].split(), dtype=float)[:4 * count].reshape(count, 4)
        return Ignition(path, fortran_float(settings["ramprate"]),
                        fortran_float(settings["targettemp"]),
                        rows[:, :3].astype(np.int32), rows[:, 3])
    except (KeyError, ValueError) as error:
        raise ConversionError(f"cannot read the ignition points in {path} ({error})") from error


# ----------------------------------------------------------------- run log --

BASE_STATE_LINE = re.compile(r"^\s*z:\s+(\d+)" + r"\s+(\S+)" * 4 + r"\s*$")


@dataclass(frozen=True)
class BaseState:
    """The initial ambient profile FIRETEC prints at start-up (rinit.F90) for
    the column i = 1, j = 1: height above zgroundref, potential temperature,
    density and pressure."""
    path: Path
    height: np.ndarray
    potential_temperature: np.ndarray
    density: np.ndarray
    pressure: np.ndarray


def read_base_state(path: Path, levels: int) -> BaseState | None:
    rows: dict[int, list[float]] = {}
    for line in path.read_text(errors="replace").splitlines():
        if match := BASE_STATE_LINE.match(line):
            rows.setdefault(int(match[1]), [float(value) for value in match.groups()[1:]])
    if sorted(rows) != list(range(1, levels + 1)):
        LOG.warning("warning: %s has no complete start-up profile; not using it", path)
        return None
    columns = np.array([rows[level] for level in range(1, levels + 1)]).T
    return BaseState(path, *columns)


def check_heights(base_state: BaseState, grid: Grid, params: RunParameters) -> None:
    """Warn if the logged start-up heights disagree with the rebuilt grid,
    which means the gridlist does not match the run."""
    if grid.terrain is not None or params["zgroundref"] != 0:
        return
    if not np.allclose(base_state.height, grid.z, rtol=1e-4, atol=1e-3):
        LOG.warning("warning: the heights in %s differ from the grid rebuilt from the "
                    "gridlist; the gridlist may not match this run", base_state.path)


# ---------------------------------------------------------------- datasets --

def coordinates(grid: Grid, layout: OutputLayout, params: RunParameters) -> dict:
    fuel_layers = layout.fuel_shape[0]
    coords = {
        "x": ("x", grid.x, {"long_name": "x position of cell centres", "units": "m",
                            "axis": "X", "grid_spacing": params["dx"],
                            "comment": "measured from the domain's lower x boundary"}),
        "y": ("y", grid.y, {"long_name": "y position of cell centres", "units": "m",
                            "axis": "Y", "grid_spacing": params["dy"],
                            "comment": "measured from the domain's lower y boundary"}),
        "z": ("z", grid.z, {
            "long_name": "height of cell centres above flat ground", "units": "m",
            "axis": "Z", "positive": "up", "bounds": "z_bounds",
            "comment": "FIRETEC's stretched grid: z = aa1*s + (1 - aa1)*s**3/zb**2 with "
                       "s = (k - 1/2)*dz and domain top zb = l*dz (rinit.F90, metric.F90)",
            "aa1": grid.aa1, "dz": params["dz"], "domain_top": grid.top}),
        "z_bounds": (("z", "bnds"), grid.z_bounds,
                     {"long_name": "heights of cell bottoms and tops", "units": "m"}),
        "sigma": ("z", grid.sigma, {"long_name": "computational (unstretched) vertical "
                                                 "coordinate of cell centres", "units": "m"}),
        "z_fuel": ("z_fuel", grid.z[:fuel_layers],
                   {"long_name": "height of fuel-layer centres above flat ground",
                    "units": "m", "positive": "up",
                    "comment": "fuel layer k shares atmosphere cell k"}),
        "fuel_type": ("fuel_type", np.arange(1, layout.fuel_types + 1, dtype=np.int32),
                      {"long_name": "FIRETEC fuel type number"}),
    }
    if grid.terrain is not None:
        coords["terrain_height"] = (("y", "x"), grid.terrain,
                                    {"long_name": "ground height", "units": "m"})
        coords["height"] = (("z", "y", "x"), grid.height(), {
            "long_name": "height of cell centres above the terrain datum", "units": "m",
            "comment": "terrain-following grid: height = z*(zb - terrain)/zb + terrain"})
    return coords


def ignition_variables(ignition: Ignition, grid: Grid) -> dict:
    i, j, k = ignition.cells.T
    point = "ignition_point"
    return {
        "ignition_i": (point, i, {"long_name": "x index of ignited cell (1-based)"}),
        "ignition_j": (point, j, {"long_name": "y index of ignited cell (1-based)"}),
        "ignition_k": (point, k, {"long_name": "fuel layer of ignited cell (1-based)"}),
        "ignition_x": (point, grid.x[i - 1], {"long_name": "x position of ignited cell",
                                              "units": "m"}),
        "ignition_y": (point, grid.y[j - 1], {"long_name": "y position of ignited cell",
                                              "units": "m"}),
        "ignition_time": (point, ignition.times, {"long_name": "ignition start time",
                                                  "units": "s"}),
        "ignition_ramp_rate": ((), ignition.ramp_rate,
                               {"long_name": "ignition temperature ramp rate", "units": "K s-1"}),
        "ignition_target_temperature": ((), ignition.target_temperature,
                                        {"long_name": "ignition target temperature",
                                         "units": "K"}),
    }


def base_state_variables(base_state: BaseState) -> dict:
    comment = "start-up ambient profile printed by FIRETEC for the column i = 1, j = 1"
    return {
        f"initial_{name}": ("z", values, {"long_name": f"initial ambient {long_name}",
                                          "units": units, "comment": comment})
        for name, long_name, units, values in [
            ("potential_temperature", "potential temperature", "K",
             base_state.potential_temperature),
            ("density", "air density", "kg m-3", base_state.density),
            ("pressure", "air pressure", "Pa", base_state.pressure)]
    }


def static_dataset(grid: Grid, layout: OutputLayout, params: RunParameters,
                   ignition: Ignition | None, base_state: BaseState | None) -> xr.Dataset:
    """Everything that does not change with time."""
    data_vars = {}
    if ignition is not None:
        data_vars.update(ignition_variables(ignition, grid))
    if base_state is not None:
        data_vars.update(base_state_variables(base_state))
    return xr.Dataset(data_vars, coords=coordinates(grid, layout, params))


def field_attrs(field: Field, density_weighted_output: bool) -> dict:
    attrs = dict(field.attrs, firetec_name=field.name)
    if not field.density_weighted:
        return attrs
    if density_weighted_output:
        attrs["long_name"] = f"air density times {attrs['long_name']}"
        attrs["units"] = " ".join(unit for unit in ("kg m-3", attrs.get("units", ""))
                                  if unit and unit != "1")
        attrs.pop("standard_name", None)
        attrs["comment"] = "as FIRETEC stores it, multiplied by the air density"
    else:
        attrs["comment"] = "FIRETEC stores this field multiplied by the air density; " \
                           "divided by the air density (rho) here"
    return attrs


def step_dataset(output: OutputFile, arrays: dict, layout: OutputLayout, dt: float,
                 density_weighted_output: bool) -> xr.Dataset:
    """One output step, with a time dimension of length one."""
    data_vars = {}
    for field in layout.atmosphere:
        data_vars[field.name] = (("time", "z", "y", "x"), arrays[field.name][np.newaxis],
                                 field_attrs(field, density_weighted_output))
    for field in layout.fuel:
        data_vars[field.name] = (("time", "fuel_type", "z_fuel", "y", "x"),
                                 arrays[field.name][np.newaxis],
                                 field_attrs(field, density_weighted_output))
    coords = {
        "time": ("time", [output.step * dt], {
            "long_name": "simulated time since the start of the run", "units": "s",
            "time_step": dt, "comment": "time = step * dt with dt = nts * dts"}),
        "step": ("time", [output.step], {"long_name": "FIRETEC large time step number"}),
    }
    return xr.Dataset(data_vars, coords=coords)


def chunk_encoding(dataset: xr.Dataset) -> dict:
    """One chunk per output step and per HORIZONTAL_CHUNK x HORIZONTAL_CHUNK tile."""
    def chunks(variable: xr.Variable) -> tuple:
        return tuple(1 if dim == "time" else
                     min(size, HORIZONTAL_CHUNK) if dim in ("x", "y") else size
                     for dim, size in zip(variable.dims, variable.shape, strict=True))
    encoding = {name: {"chunks": chunks(variable)}
                for name, variable in dataset.data_vars.items() if "time" in variable.dims}
    encoding.update({name: {"chunks": (TIME_COORDINATE_CHUNK,)} for name in ("time", "step")})
    return encoding


# ------------------------------------------------------------- provenance --

def file_record(path: Path, case_dir: Path, data: bytes | None = None) -> dict:
    data = path.read_bytes() if data is None else data
    try:
        name = str(path.resolve().relative_to(case_dir.resolve()))
    except ValueError:
        name = str(path.resolve())
    return {"path": name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}


def software_versions() -> dict:
    return {"converter": f"{Path(__file__).name} {CONVERTER_VERSION}",
            "python": platform.python_version(), "numpy": np.__version__,
            "xarray": xr.__version__, "zarr": zarr.__version__}


def git(directory: Path, *arguments: str) -> str | None:
    """Output of a git command run in directory, or None if it fails."""
    try:
        result = subprocess.run(["git", "-C", str(directory), *arguments],
                                capture_output=True, text=True, timeout=10, check=False)
    except (OSError, subprocess.SubprocessError):
        return None
    return result.stdout.strip() if result.returncode == 0 else None


def without_credentials(url: str) -> str:
    """The URL without a user name or access token (https://user:token@host/...)."""
    parts = urlsplit(url)
    if parts.scheme not in ("http", "https") or "@" not in parts.netloc:
        return url
    host = parts.hostname + (f":{parts.port}" if parts.port else "")
    return urlunsplit(parts._replace(netloc=host))


def repository_provenance(directory: Path = CONVERTER_DIR) -> dict:
    """The git repository this converter belongs to (the FIRETEC repository):
    its origin URL, commit and branch, and whether tracked files differ from that
    commit. Empty when the converter is not inside a git checkout."""
    commit = git(directory, "rev-parse", "HEAD")
    if commit is None:
        return {}
    url = git(directory, "remote", "get-url", "origin")
    return {"url": without_credentials(url) if url else None,
            "commit": commit,
            "branch": git(directory, "branch", "--show-current") or None,
            "uncommitted_changes": bool(git(directory, "status", "--porcelain",
                                            "--untracked-files=no"))}


# -------------------------------------------------------------- conversion --

@dataclass(frozen=True)
class Options:
    case_dir: Path
    output: Path
    gridlist: Path
    log: Path | None
    density_weighted: bool
    zarr_format: int
    overwrite: bool


@dataclass(frozen=True)
class Case:
    """Everything known about a FIRETEC run before its fields are converted."""
    params: RunParameters
    outputs: list[OutputFile]
    missing_steps: list[int]
    layout: OutputLayout
    grid: Grid
    ignition: Ignition | None
    base_state: BaseState | None
    input_files: list[Path]


def convert(options: Options) -> None:
    if options.output.exists() and not options.overwrite:
        raise ConversionError(f"{options.output} exists; use --overwrite to replace it")
    case = load_case(options)
    LOG.info("converting %d output steps of %s (%s, %d atmosphere + %d fuel fields) to %s",
             len(case.outputs), options.case_dir, case.layout.dtype,
             len(case.layout.atmosphere), len(case.layout.fuel), options.output)
    output_files = write_store(options, case)
    finalize_store(options.output, global_attributes(options, case, output_files),
                   options.zarr_format)
    LOG.info("wrote %s", options.output)


def load_case(options: Options) -> Case:
    params = RunParameters(Gridlist.read(options.gridlist), load_catalog())
    for key in params.unrecognized_keys:
        LOG.warning("warning: FIRETEC %s ignores the gridlist key %r", FIRETEC_VERSION, key)
    outputs = find_output_files(options.case_dir, params["outname"])
    first = outputs[0].path
    layout = detect_layout(split_records(first.read_bytes(), first), params, first.name)
    terrain_file = topography_path(params, options.case_dir)
    terrain = read_terrain(terrain_file, params, layout.dtype) if terrain_file else None
    grid = build_grid(params, terrain)
    ignition = load_ignition(params, options.case_dir)
    input_files = [path for path in (options.gridlist, terrain_file, options.log,
                                     ignition.path if ignition else None) if path]
    return Case(params, outputs, missing_output_steps(params, outputs), layout, grid,
                ignition, load_base_state(options.log, grid, params), input_files)


def load_ignition(params: RunParameters, case_dir: Path) -> Ignition | None:
    if params["ifire"] != 1:
        return None
    path = case_dir / params["ignfile"]
    if not path.is_file():
        LOG.warning("warning: the ignition file %s is missing; storing no ignition data", path)
        return None
    return read_ignition(path)


def load_base_state(log: Path | None, grid: Grid, params: RunParameters) -> BaseState | None:
    base_state = read_base_state(log, grid.z.size) if log else None
    if base_state is not None:
        check_heights(base_state, grid, params)
    return base_state


@contextmanager
def consolidated_metadata_allowed():
    """Zarr warns that consolidated metadata is not yet part of the format 3
    specification. xarray uses it to open stores quickly, so keep it quietly."""
    with warnings.catch_warnings():
        warnings.filterwarnings("ignore", message="Consolidated metadata is currently not part")
        yield


def write_store(options: Options, case: Case) -> list[dict]:
    """Write the first step together with the static data, then append the
    other steps one at a time so that only one step is ever in memory.
    Returns a provenance record for each output file."""
    static = static_dataset(case.grid, case.layout, case.params, case.ignition, case.base_state)
    dt = time_step(case.params)
    output_files = []
    for index, output in enumerate(case.outputs):
        data = output.path.read_bytes()
        output_files.append(dict(file_record(output.path, options.case_dir, data),
                                 step=output.step))
        arrays = decode_step(split_records(data, output.path), case.layout, output.path.name)
        if not options.density_weighted:
            arrays = to_physical(arrays, case.layout)
        step = step_dataset(output, arrays, case.layout, dt, options.density_weighted)
        with consolidated_metadata_allowed():
            if index == 0:
                first = xr.merge([static, step])
                first.to_zarr(options.output, mode="w", encoding=chunk_encoding(first),
                              zarr_format=options.zarr_format, consolidated=True)
            else:
                step.to_zarr(options.output, append_dim="time",
                             zarr_format=options.zarr_format, consolidated=True)
        LOG.info("  step %d (%d/%d)", output.step, index + 1, len(case.outputs))
    return output_files


def global_attributes(options: Options, case: Case, output_files: list[dict]) -> dict:
    params = case.params
    created = datetime.now(UTC).isoformat(timespec="seconds")
    parameters = params.metadata()
    parameters["iemissions"]["value_used"] = emissions_option(params)
    return {
        "title": f"FIRETEC {FIRETEC_VERSION} simulation {options.case_dir.resolve().name}",
        "summary": "Atmosphere and fuel fields of a FIRETEC coupled fire-atmosphere "
                   "simulation, converted from FIRETEC's binary output files.",
        "source": f"FIRETEC {FIRETEC_VERSION} (Los Alamos National Laboratory)",
        "Conventions": "CF-1.10",
        "date_created": created,
        "history": f"{created}: {' '.join([Path(sys.argv[0]).name, *sys.argv[1:]])}",
        "firetec_version": FIRETEC_VERSION,
        "firetec_case_directory": str(options.case_dir.resolve()),
        "firetec_output_prefix": params["outname"],
        "firetec_float_type": str(case.layout.dtype),
        "firetec_record_order": case.layout.record_names(),
        "firetec_density_weighted_fields": "kept" if options.density_weighted
                                           else "divided by rho",
        "firetec_parameters": parameters,
        "firetec_parameter_catalog": params.catalog.provenance,
        "firetec_unrecognized_gridlist_keys": params.unrecognized_keys,
        "firetec_missing_output_steps": case.missing_steps,
        "firetec_gridlist": params.gridlist.text,
        "input_files": [file_record(path, options.case_dir) for path in case.input_files],
        "output_files": output_files,
        "firetec_repository": repository_provenance(),
        "software": software_versions(),
    }


def finalize_store(path: Path, attrs: dict, zarr_format: int) -> None:
    """Write the global attributes once all steps are in, then consolidate."""
    group = zarr.open_group(str(path), mode="r+", zarr_format=zarr_format)
    group.attrs.update(json.loads(json.dumps(attrs)))   # plain JSON types only
    with consolidated_metadata_allowed():
        zarr.consolidate_metadata(str(path))


# --------------------------------------------------------------------- cli --

def parse_options(argv: list[str] | None = None) -> tuple[Options, bool]:
    parser = argparse.ArgumentParser(
        description=f"Convert FIRETEC {FIRETEC_VERSION} output files to a Zarr store.",
        epilog="Example: python3 firetec_to_zarr.py runs/sample -o sample.zarr")
    parser.add_argument("case_dir", type=Path,
                        help="the folder FIRETEC ran in (with gridlist and the outputs)")
    parser.add_argument("-o", "--output", type=Path,
                        help="Zarr store to write (default: CASE_DIR/<case name>.zarr)")
    parser.add_argument("--gridlist", type=Path, help="default: CASE_DIR/gridlist")
    parser.add_argument("--log", type=Path, help="FIRETEC's printed output, for the start-up "
                        "profile (default: CASE_DIR/run.log, if present)")
    parser.add_argument("--density-weighted", action="store_true",
                        help="keep fields as FIRETEC stores them (rho*u, rho*theta, ...) "
                             "instead of dividing by rho")
    parser.add_argument("--zarr-format", type=int, choices=(2, 3), default=2,
                        help="Zarr format version (default: 2, readable by more tools)")
    parser.add_argument("--overwrite", action="store_true", help="replace an existing store")
    parser.add_argument("-q", "--quiet", action="store_true", help="only print warnings")
    args = parser.parse_args(argv)

    case_dir = args.case_dir
    default_log = case_dir / "run.log"
    options = Options(
        case_dir=case_dir,
        output=args.output or case_dir / f"{case_dir.resolve().name}.zarr",
        gridlist=args.gridlist or case_dir / "gridlist",
        log=args.log or (default_log if default_log.is_file() else None),
        density_weighted=args.density_weighted,
        zarr_format=args.zarr_format,
        overwrite=args.overwrite)
    return options, args.quiet


def main(argv: list[str] | None = None) -> int:
    options, quiet = parse_options(argv)
    logging.basicConfig(level=logging.WARNING if quiet else logging.INFO, format="%(message)s")
    try:
        convert(options)
    except ConversionError as error:
        LOG.error("error: %s", error)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
