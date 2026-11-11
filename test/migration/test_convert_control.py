"""Public v8 conversion cases and focused compatibility/failure checks."""

import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
TOOL = ROOT / "tools/convert_control.py"
SPEC = importlib.util.spec_from_file_location("convert_control", TOOL)
CONVERTER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CONVERTER)
EXPECTED = json.loads(Path(__file__).with_name("v8_values.json").read_text())
BASE = (ROOT / "test/regression/cases/tnsn_torch47/control").read_text()


def public_cases():
    for name, case in EXPECTED["recipes"].items():
        text = (ROOT / case["settings"]).read_text()
        text += (ROOT / f"test/Test_Problems/setup_{name}").read_text()
        yield f"recipe/{name}", text, case["values"]
    for name, values in EXPECTED["fixtures"].items():
        yield f"fixture/{name}", (ROOT / f"test/regression/cases/{name}/control").read_text(), values


def assignments(namelist):
    result = {}
    for line in namelist.splitlines()[1:-1]:
        key, value = line.strip().split(" = ", 1)
        result[key] = value[1:-1].replace("''", "'") if value.startswith("'") else value
    return result


def resolved_values(namelist):
    """Project emitted values onto the old-reader probe's field order."""
    fields = assignments(namelist)
    # Both runtime applications disable the supplied BE change limits under BDF.
    if int(fields["isolv"]) == 3:
        fields["changemx"] = fields["changemxt"] = "1.0e10"
    names = EXPECTED["fields"] + [f"output_nuclei({i})" for i in range(1, int(fields["nnucout"]) + 1)]
    for i in range(1, int(fields["nzone"]) + 1):
        names += [f"inab_files({i})", f"thermo_files({i})"]
    return [fields[name].rstrip(" ") for name in names]


def assert_values(test, actual, expected):
    test.assertEqual(len(actual), len(expected))
    for index, (value, reference) in enumerate(zip(actual, expected)):
        if index in range(3, 28):  # Sixteen integer and nine real controls.
            test.assertEqual(float(value.replace("D", "E").replace("d", "e")),
                             float(reference.replace("D", "E").replace("d", "e")))
        else:
            test.assertEqual(value.rstrip(" "), reference)


def remove_block(text, title):
    return re.sub(rf"^## {re.escape(title)}[^\n]*\n(?:(?!^##).*(?:\n|$))*", "", text, flags=re.M)


def pad_records(text, count):
    records = text.splitlines()
    return "\n".join(records + [""] * (count - len(records))) + "\n"


class ConversionTests(unittest.TestCase):
    def test_all_public_values(self):
        cases = list(public_cases())
        self.assertEqual(len(cases), 34)
        self.assertEqual(len(list((ROOT / "test/Test_Problems").glob("setup_*"))), 26)
        self.assertEqual(len(list((ROOT / "test/regression/cases").glob("*/control"))), 8)
        for name, text, expected in cases:
            with self.subTest(name=name):
                namelist, warnings = CONVERTER.convert(text)
                assert_values(self, resolved_values(namelist), expected)
                self.assertEqual(bool(warnings), name in {
                    "recipe/ccsn_alpha", "recipe/tnsn_torch47", "fixture/tnsn_torch47"})

    def test_optional_defaults(self):
        text = BASE
        for title in CONVERTER.DEFAULTS:
            text = remove_block(text, title)
        namelist, _ = CONVERTER.convert(text)
        fields = assignments(namelist)
        self.assertEqual(fields["nzbatchmx"], "1")
        self.assertEqual(fields["iheat"], "0")
        self.assertEqual(fields["t9nse"], "8.0")
        self.assertEqual(fields["ineutrino"], "0")
        assert_values(self, resolved_values(namelist), EXPECTED["optional_defaults"])

    def test_optional_scan_limit(self):
        for title in CONVERTER.DEFAULTS:
            text = remove_block(BASE, title)
            with self.subTest(title=title, records=999):
                namelist, _ = CONVERTER.convert(pad_records(text, 999))
                expected = EXPECTED["fixtures"]["tnsn_torch47"].copy()
                for field in CONVERTER.SCALARS[title]:
                    index = EXPECTED["fields"].index(field)
                    expected[index] = EXPECTED["optional_defaults"][index]
                assert_values(self, resolved_values(namelist), expected)
            for count in (1000, 1001):
                with self.subTest(title=title, records=count):
                    with self.assertRaisesRegex(CONVERTER.ConversionError, "scan exhaustion.*" + title):
                        CONVERTER.convert(pad_records(text, 1000) + ("1\n" if count == 1001 else ""))
        # A matched title at record 1000 is supported, even with its value after the scan.
        text = pad_records(remove_block(BASE, "NSE Initial Conditions"), 999)
        fields = assignments(CONVERTER.convert(text + "## NSE Initial Conditions\n7.5\n")[0])
        self.assertEqual(fields["t9nse"], "7.5")
        # Long inputs remain supported when every optional title was found.
        self.assertEqual(CONVERTER.convert(pad_records(BASE, 1001))[0], CONVERTER.convert(BASE)[0])

    def test_scan_exhaustion_creates_no_output(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "control"
            text = remove_block(BASE, "Neutrinos")
            for count in (1000, 1001):
                with self.subTest(records=count):
                    output = Path(directory) / f"controls-{count}.nml"
                    source.write_text(pad_records(text, 1000) + ("1\n" if count == 1001 else ""))
                    command = [os.sys.executable, str(TOOL), str(source), "-o", str(output)]
                    result = subprocess.run(command, capture_output=True, text=True)
                    self.assertEqual(result.returncode, 2)
                    self.assertIn("scan exhaustion", result.stderr)
                    self.assertIn("Neutrinos", result.stderr)
                    self.assertEqual(result.stdout, "")
                    self.assertFalse(output.exists())

    def test_tokens_flags_and_szone(self):
        text = BASE.replace("1.00E-01", "+1.00000000000000001D-01", 1)
        text = text.replace("1         Include Weak", "-2        Include Weak", 1)
        text = text.replace("1         Initial Zone", "+01       Initial Zone", 1)
        fields = assignments(CONVERTER.convert(text)[0])
        self.assertEqual(fields["changemx"], "+1.00000000000000001D-01")
        self.assertEqual(fields["iweak0"], "-2")
        self.assertEqual(fields["szone"], "+01")
        # szone does not renumber or shorten the consumed list or generated suffixes.
        text = (ROOT / "test/test_settings_parallel").read_text()
        text += (ROOT / "test/Test_Problems/setup_parallel_alpha").read_text()
        text = text.replace("1         Initial Zone", "3         Initial Zone", 1)
        fields = assignments(CONVERTER.convert(text)[0])
        self.assertEqual(fields["szone"], "3")
        self.assertTrue(fields["inab_files(1)"].endswith("1"))
        self.assertTrue(fields["inab_files(4)"].endswith("4"))

    def test_fixed_columns_a80_and_quotes(self):
        text = BASE.replace("2000 timesteps", "  O'Brien, \"quoted\" ! / &" + "x" * 100, 1)
        text = text.replace("ev_tnsn_torch47_", "  O'Brien/ev_", 1)
        text = text.replace("# Species to output in ASCII output (format 14a5): 14",
                            "ignored 99".ljust(50) + "  15")
        text = text.replace("## Input Controls", "x0001\n## Input Controls", 1)
        fields = assignments(CONVERTER.convert(text)[0])
        self.assertEqual(len(fields["description(1)"]), 80)
        self.assertTrue(fields["description(1)"].startswith("  O'Brien"))
        self.assertEqual(fields["ev_file_base"], "  O'Brien/ev_")
        self.assertEqual(fields["output_nuclei(1)"], "  he4")
        self.assertEqual(fields["output_nuclei(15)"], "x0001")
        self.assertEqual(fields["nnucout"], "15")

    def test_marker_columns_and_title_substring(self):
        text = BASE.replace("## Job Controls", "## prefix Job Controls suffix", 1)
        self.assertIn("nzone = 1", CONVERTER.convert(text)[0])
        for changed in (" ## Job Controls", "## job Controls", "##" + " " * 80 + "Job Controls"):
            with self.subTest(changed=changed), self.assertRaisesRegex(CONVERTER.ConversionError, "missing required Job"):
                CONVERTER.convert(BASE.replace("## Job Controls", changed, 1))

    def test_suffix_a80_truncation_and_zero_species(self):
        text = (ROOT / "test/test_settings_parallel").read_text()
        setup = (ROOT / "test/Test_Problems/setup_parallel_alpha").read_text()
        lines = setup.splitlines()
        lines[-2:] = [" " + "a" * 78, "t" * 80]
        fields = assignments(CONVERTER.convert(text + "\n".join(lines) + "\n")[0])
        self.assertEqual(fields["inab_files(1)"], " " + "a" * 78 + "1")
        self.assertEqual(fields["thermo_files(4)"], "t" * 80)
        text = BASE.replace("# Species to output in ASCII output (format 14a5): 14", "label".ljust(50) + "   0")
        fields = assignments(CONVERTER.convert(text)[0])
        self.assertEqual(fields["nnucout"], "0")
        self.assertNotIn("output_nuclei(1)", fields)

    def test_failures(self):
        first_pair = "Data_torch47/ab_co\nth_sn1aflame"
        cases = [
            (remove_block(BASE, "Integration Controls"), "missing required Integration"),
            (BASE + "\n## Job Controls\n", "duplicate Job"),
            (BASE.replace("## Job Controls", "## Job Controls Integration Controls", 1), "ambiguous block"),
            (BASE.replace("6000", "2*6000", 1), "unsupported numeric.*kstmx"),
            (BASE.replace("6000", ",", 1), "unsupported numeric.*kstmx"),
            (BASE.replace("6000", "", 1), "unsupported numeric.*kstmx"),
            (BASE.replace("1         # of Zones", "0         # of Zones", 1), "nzone must be positive"),
            (BASE.replace("# Species to output in ASCII output (format 14a5): 14", "label".ljust(50) + "x 14"), "invalid nnucout"),
            (BASE.replace("  he4", "     ", 1), "blank output species"),
            (BASE.split("## Input Controls")[0] + "## Input Controls\n", "missing record"),
            (BASE[:BASE.index(first_pair)] + "Data_torch47/ab_co\n", "missing record.*thermo_files"),
            (BASE.replace("1         # of Zones", "3         # of Zones", 1)[:BASE.index(first_pair)] +
             first_pair + "\n" + first_pair + "\n", "expected one base pair or 3"),
            (BASE.replace("th_sn1aflame", "history.h5", 1), "HDF input"),
            ("\n" * 1000 + BASE, "missing required"),
            (BASE.replace("2000 timesteps", "non-ASCII é"), "only ASCII"),
        ]
        for text, error in cases:
            with self.subTest(error=error), self.assertRaisesRegex(CONVERTER.ConversionError, error):
                CONVERTER.convert(text)

    def test_cli_stdout_and_no_clobber(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "control"
            output = Path(directory) / "controls.nml"
            source.write_text(BASE)
            command = [os.sys.executable, str(TOOL), str(source)]
            result = subprocess.run(command, capture_output=True, text=True, check=True)
            self.assertEqual(result.stdout, CONVERTER.convert(BASE)[0])
            self.assertIn("18 unused", result.stderr)
            subprocess.run(command + ["-o", str(output)], capture_output=True, check=True)
            before = output.read_bytes()
            result = subprocess.run(command + ["-o", str(output)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertIn("File exists", result.stderr)
            self.assertEqual(output.read_bytes(), before)
            source.write_text("bad input")
            output.unlink()
            result = subprocess.run(command + ["-o", str(output)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertFalse(output.exists())


@unittest.skipUnless(os.environ.get("XNET_TEST_FORTRAN"), "set XNET_TEST_FORTRAN=1 to compile the current reader")
class FortranReaderTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.work = Path(cls.temporary.name)
        compiler = shlex.split(os.environ.get("FC", "gfortran"))
        sources = [ROOT / "source" / f"{name}.F90" for name in (
            "xnet_types", "xnet_constants", "xnet_parallel_stubs", "xnet_util", "xnet_controls")]
        sources.append(Path(__file__).with_name("controls_probe.F90"))
        command = compiler + ["-cpp", "-O0", "-g", "-fcheck=all", "-ffree-line-length-none",
                              "-I" + str(ROOT / "source"), *map(str, sources), "-o", "controls_probe"]
        subprocess.run(command, cwd=cls.work, capture_output=True, text=True, check=True)

    def probe(self, text):
        namelist = CONVERTER.convert(text)[0]
        (self.work / "controls.nml").write_text(namelist)
        result = subprocess.run([str(self.work / "controls_probe")], cwd=self.work,
                                capture_output=True, text=True, check=True)
        return result.stdout.split("BEGIN VALUES\n", 1)[1].splitlines()

    def test_all_public_values(self):
        for name, text, expected in public_cases():
            with self.subTest(name=name):
                assert_values(self, self.probe(text), expected)

    def test_defaults_and_quoted_strings(self):
        text = BASE
        for title in CONVERTER.DEFAULTS:
            text = remove_block(text, title)
        assert_values(self, self.probe(text), EXPECTED["optional_defaults"])
        text = text.replace("2000 timesteps", "  O'Brien, \"quoted\" ! / &", 1)
        expected = EXPECTED["optional_defaults"].copy()
        expected[0] = "  O'Brien, \"quoted\" ! / &"
        assert_values(self, self.probe(text), expected)
        text = pad_records(remove_block(BASE, "Neutrinos"), 999)
        assert_values(self, self.probe(text), EXPECTED["fixtures"]["tnsn_torch47"])
        text = pad_records(remove_block(BASE, "NSE Initial Conditions"), 999)
        text += "## NSE Initial Conditions\n7.5\n"
        expected = EXPECTED["fixtures"]["tnsn_torch47"].copy()
        expected[EXPECTED["fields"].index("t9nse")] = "7.5"
        assert_values(self, self.probe(text), expected)

    def test_fixed_columns_tokens_and_szone(self):
        text = (ROOT / "test/test_settings_parallel").read_text()
        text += (ROOT / "test/Test_Problems/setup_parallel_alpha").read_text()
        text = text.replace("1         Initial Zone", "3         Initial Zone", 1)
        text = text.replace("1.00E-01", "+1.00000000000000001D-01", 1)
        text = text.replace("# Species to output in ASCII output (format 14a5): 14",
                            "ignored 99".ljust(50) + "  15")
        text = text.replace("## Input Controls", "x0001\n## Input Controls", 1)
        assert_values(self, self.probe(text), resolved_values(CONVERTER.convert(text)[0]))


if __name__ == "__main__":
    unittest.main()
