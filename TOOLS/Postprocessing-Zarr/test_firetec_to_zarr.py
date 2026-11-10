"""Tests for firetec_to_zarr.py. Run them from this directory with:

    python3 -m unittest -v test_firetec_to_zarr
"""
import tempfile
import unittest
from pathlib import Path

import numpy as np
import xarray as xr

import firetec_to_zarr as f2z

NX, NY, NZ = 4, 3, 5
AIR_DENSITY = 2.0
GRIDLIST = f"""! a tiny FIRETEC case (fire, radiation and turbulence on by default)
nt = 4
frqoutput = 2
n = {NX}
m = {NY}
l = {NZ}
outname = './comp/comp.out'
"""
IGNITION = """&ignitelist
  nIgn=2
  rampRate=350
  targetTemp=1000
! X  Y  Z  Time
/
  1  2  1  0.0
  3  1  1  2.5
"""
ATMOSPHERE = ["u", "v", "w", "theta", "ka", "kb", "O2", "rho"]
FUEL = ["rhoFuel", "rhoWater", "sies", "psiwmax"]


def fortran_file(arrays: list[np.ndarray]) -> bytes:
    """gfortran sequential unformatted records; C-order (z, y, x) arrays have
    the byte layout of Fortran (x, y, z) arrays."""
    data = bytearray()
    for array in arrays:
        payload = np.asarray(array, "<f4").tobytes()
        marker = len(payload).to_bytes(4, "little", signed=True)
        data += marker + payload + marker
    return bytes(data)


def physical_value(index: int, step: int) -> float:
    return float(index + step)


def step_arrays(step: int) -> list[np.ndarray]:
    """Atmosphere fields hold rho * value (rho itself is AIR_DENSITY); fuel
    fields hold their value."""
    atmosphere = [np.full((NZ, NY, NX), AIR_DENSITY * physical_value(index, step))
                  for index, _ in enumerate(ATMOSPHERE[:-1])]
    atmosphere.append(np.full((NZ, NY, NX), AIR_DENSITY))
    fuel = [np.full((1, NY, NX), 10.0 * index + step) for index, _ in enumerate(FUEL)]
    return atmosphere + fuel


def write_case(directory: Path, gridlist: str = GRIDLIST, steps=(2, 4)) -> Path:
    (directory / "gridlist").write_text(gridlist)
    (directory / "ignite.dat").write_text(IGNITION)
    (directory / "comp").mkdir()
    for step in steps:
        (directory / "comp" / f"comp.out.{step}").write_bytes(fortran_file(step_arrays(step)))
    return directory


def parameters(gridlist: str) -> f2z.RunParameters:
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "gridlist"
        path.write_text(gridlist)
        return f2z.RunParameters(f2z.Gridlist.read(path), f2z.load_catalog())


class GridlistTests(unittest.TestCase):
    def test_tokens_follow_fortran_list_directed_input(self):
        self.assertEqual(f2z.list_directed_tokens("Species = 'CO2', CO  ! gases"),
                         ["Species", "=", "CO2", "CO"])

    def test_unquoted_slash_ends_the_value_as_in_fortran(self):
        self.assertEqual(f2z.list_directed_tokens("outname = ./comp/x"), ["outname", "=", "."])

    def test_defaults_fill_the_keys_a_gridlist_leaves_out(self):
        params = parameters(GRIDLIST + "nonsense = 1\n")
        self.assertEqual(params["n"], NX)
        self.assertEqual(params["dx"], 2.0)
        self.assertEqual(params.metadata()["dx"]["source"], "default")
        self.assertEqual(params.unrecognized_keys, ["nonsense"])

    def test_invalid_value_is_reported(self):
        with self.assertRaisesRegex(f2z.ConversionError, "not a valid integer"):
            parameters("n = 4.5\n")


class FieldLayoutTests(unittest.TestCase):
    def names(self, gridlist: str) -> tuple[list[str], list[str]]:
        params = parameters(gridlist)
        return ([field.name for field in f2z.atmosphere_fields(params)],
                [field.name for field in f2z.fuel_fields(params)])

    def test_default_fire_run(self):
        self.assertEqual(self.names(GRIDLIST), (ATMOSPHERE, FUEL))

    def test_no_fire_and_no_turbulence(self):
        self.assertEqual(self.names("ifire = 0\niturb = 0\n"),
                         (["u", "v", "w", "theta", "rho"], ["rhoFuel", "rhoWater"]))

    def test_emitted_species_and_aerosol_moments(self):
        atmosphere, _ = self.names("iemissions = 1\nnEmit = 2\nSpecies = CO2 SMOKEPM\n"
                                   "nAero = 1\nSpeciesAero = soot\n")
        self.assertEqual(atmosphere[6:], ["O2", "CO2", "SMOKEP", "soot1", "soot2", "rho"])


class GridTests(unittest.TestCase):
    def test_heights_match_those_firetec_prints(self):
        grid = f2z.build_grid(parameters("l = 10\n"), terrain=None)
        printed = [0.766875029, 2.70562506, 5.85937500, 11.0381250, 19.0518761]
        np.testing.assert_allclose(grid.z[:5], printed, rtol=1e-6)
        self.assertEqual(grid.z_bounds[-1, 1], 10 * 15.0)

    def test_cell_centres_start_half_a_cell_in(self):
        grid = f2z.build_grid(parameters(GRIDLIST), terrain=None)
        np.testing.assert_allclose(grid.x, [1.0, 3.0, 5.0, 7.0])


class RecordTests(unittest.TestCase):
    def test_subrecords_are_joined(self):
        payload = bytes(range(12))
        first, rest = payload[:8], payload[8:]
        data = ((-8).to_bytes(4, "little", signed=True) + first + (8).to_bytes(4, "little")
                + (4).to_bytes(4, "little") + rest + (-4).to_bytes(4, "little", signed=True))
        self.assertEqual([bytes(record) for record in f2z.split_records(data, Path("x"))],
                         [payload])

    def test_truncated_file_is_reported(self):
        data = fortran_file([np.zeros(3)])[:-2]
        with self.assertRaises(f2z.ConversionError):
            f2z.split_records(data, Path("x"))


class IgnitionTests(unittest.TestCase):
    def test_namelist_with_comment_and_points(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "ignite.dat"
            path.write_text(IGNITION)
            ignition = f2z.read_ignition(path)
        self.assertEqual((ignition.ramp_rate, ignition.target_temperature), (350.0, 1000.0))
        np.testing.assert_array_equal(ignition.cells, [[1, 2, 1], [3, 1, 1]])
        np.testing.assert_array_equal(ignition.times, [0.0, 2.5])


class ProvenanceTests(unittest.TestCase):
    def test_credentials_are_removed_from_remote_urls(self):
        self.assertEqual(
            f2z.without_credentials("https://user:ghp_secret@github.com:8443/org/FIRETEC.git"),
            "https://github.com:8443/org/FIRETEC.git")
        self.assertEqual(f2z.without_credentials("git@github.com:org/FIRETEC.git"),
                         "git@github.com:org/FIRETEC.git")

    def test_no_repository_outside_a_git_checkout(self):
        with tempfile.TemporaryDirectory() as directory:
            self.assertEqual(f2z.repository_provenance(Path(directory)), {})


class ConversionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name)
        self.output = self.directory / "case.zarr"

    def tearDown(self):
        self.temporary.cleanup()

    def convert(self, *options: str) -> int:
        return f2z.main([str(self.directory), "-o", str(self.output), "-q", *options])

    def test_fields_coordinates_and_metadata(self):
        write_case(self.directory)
        self.assertEqual(self.convert(), 0)
        dataset = xr.open_zarr(self.output)

        np.testing.assert_allclose(dataset.time, [0.02, 0.04])
        np.testing.assert_array_equal(dataset.step, [2, 4])
        for index, name in enumerate(ATMOSPHERE[:-1]):
            np.testing.assert_allclose(dataset[name].isel(time=1), physical_value(index, 4))
        np.testing.assert_allclose(dataset.rho, AIR_DENSITY)
        np.testing.assert_allclose(dataset.sies.isel(time=0), 10.0 * 2 + 2)
        self.assertEqual(dataset.u.dims, ("time", "z", "y", "x"))
        self.assertEqual(dataset.rhoFuel.dims, ("time", "fuel_type", "z_fuel", "y", "x"))
        np.testing.assert_allclose(dataset.ignition_x, [1.0, 5.0])

        attrs = dataset.attrs
        self.assertEqual(attrs["firetec_parameters"]["n"]["source"], "gridlist")
        self.assertEqual(attrs["firetec_parameters"]["iemissions"]["value_used"], 2)
        self.assertEqual(attrs["firetec_record_order"][:2], ["u", "v"])
        self.assertEqual([entry["step"] for entry in attrs["output_files"]], [2, 4])
        self.assertEqual(attrs["firetec_missing_output_steps"], [])
        self.assertEqual(attrs["firetec_repository"], f2z.repository_provenance())

    def test_density_weighted_option_keeps_firetec_values(self):
        write_case(self.directory)
        self.assertEqual(self.convert("--density-weighted"), 0)
        dataset = xr.open_zarr(self.output)
        np.testing.assert_allclose(dataset.u.isel(time=0), AIR_DENSITY * physical_value(0, 2))
        self.assertEqual(dataset.u.attrs["units"], "kg m-3 m s-1")

    def test_zarr_format_3(self):
        write_case(self.directory)
        self.assertEqual(self.convert("--zarr-format", "3"), 0)
        self.assertEqual(xr.open_zarr(self.output).sizes["time"], 2)

    def test_missing_steps_are_reported_and_recorded(self):
        write_case(self.directory, steps=(2,))
        with self.assertLogs("firetec_to_zarr", "WARNING") as logged:
            self.assertEqual(self.convert(), 0)
        self.assertIn("missing", logged.output[0])
        self.assertEqual(xr.open_zarr(self.output).attrs["firetec_missing_output_steps"], [4])

    def test_gridlist_that_does_not_match_the_files_is_reported(self):
        write_case(self.directory, gridlist=GRIDLIST + "iturb = 0\n")
        with self.assertLogs("firetec_to_zarr", "ERROR") as logged:
            self.assertEqual(self.convert(), 1)
        self.assertIn("the gridlist implies 10", logged.output[0])

    def test_existing_store_is_kept_without_overwrite(self):
        write_case(self.directory)
        self.assertEqual(self.convert(), 0)
        with self.assertLogs("firetec_to_zarr", "ERROR"):
            self.assertEqual(self.convert(), 1)
        self.assertEqual(self.convert("--overwrite"), 0)


if __name__ == "__main__":
    unittest.main()
