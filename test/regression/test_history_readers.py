"""Exercise bundled readers against fresh public alpha-network histories."""

from dataclasses import replace
import importlib.util
from pathlib import Path
import re
import struct

import pytest

from xnet_regression import parse_diagnostic, prepare_work_directory, run_xnet, tnsn_alpha_case

np = pytest.importorskip("numpy", reason="bundled history readers require NumPy")
ROOT = Path(__file__).resolve().parents[2]


def load_reader(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "tools/python" / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return getattr(module, name)


read_ts_file = load_reader("read_ts_file")
read_ev_file = load_reader("read_ev_file")


@pytest.mark.parametrize("nuclei", [(), ("ni56", "he4"), tnsn_alpha_case(ROOT).expected_species])
def test_fresh_histories(tmp_path, xnet_executable, xnet_timeout, nuclei):
    case = replace(tnsn_alpha_case(ROOT), expected_zones=(1,))
    work = prepare_work_directory(case, tmp_path / "run")
    control = work / "controls.nml"
    text = control.read_text().replace("nzone = 10,", "nzone = 1,")
    text = re.sub(r"^  (?:inab_files|thermo_files)\((?:[2-9]|10)\).*\n", "", text, flags=re.M)
    text = text.replace("nnucout = 14,", "nnucout = %d," % len(nuclei))
    # Override selected names after the original assignments in the namelist.
    text = text.rsplit("/", 1)[0] + "\n" + "\n".join(
        " output_nuclei(%d) = '%s'," % (i + 1, name) for i, name in enumerate(nuclei)
    ) + "\n/\n"
    control.write_text(text)
    result = run_xnet(xnet_executable, case, work, timeout_seconds=xnet_timeout)
    assert result.return_code == 0
    binary = work / "ts_tnsn_alpha_1"
    ascii_file = work / "ev_tnsn_alpha_1"
    zz, aa, xmf, time, temp, rho, dt, edot, endpoints, flux = read_ts_file(binary)
    atime, arho, atemp, aedot, adt, species, data, filename = read_ev_file(ascii_file)
    assert tuple(species) == nuclei
    assert filename == ascii_file
    assert len(time) == len(ascii_file.read_text().splitlines()) - 1 > 2
    assert xmf.shape == (len(time), 14)
    assert flux.shape == (len(time), len(endpoints))
    assert len(endpoints) > 0
    np.testing.assert_array_equal(aa, [4] + list(range(12, 61, 4)))
    np.testing.assert_array_equal(zz, aa / 2)
    assert np.isfinite(data['I']).all() and np.isfinite(data['t']).all()
    assert time[0] == 0.02 and time[-1] > time[0]
    # ab_co stores rounded number abundances; XNet normalizes their mass sum.
    initial = np.array([0, 12 * 4.1667e-2, 16 * 3.125e-2])
    np.testing.assert_allclose(xmf[0, :3], initial / initial.sum(), rtol=1e-14)
    state, = parse_diagnostic((work / 'net_diag01').read_text(), (1,), case.expected_species)
    np.testing.assert_allclose(time[-1], state.time, rtol=5e-8)
    np.testing.assert_allclose(xmf[-1], [state.mass_fractions[name] for name in case.expected_species],
                               rtol=5e-8, atol=1e-99)
    for values, printed, rtol in [(time, atime, 5e-8), (temp, atemp, 5e-4),
                                   (rho, arho, 5e-4), (dt, adt, 5e-3), (edot, aedot, 5e-3)]:
        np.testing.assert_allclose(values, printed, rtol=rtol, atol=1e-99)
    for name in species:
        index = case.expected_species.index(name)
        np.testing.assert_allclose(xmf[:, index], data[name], rtol=5e-3, atol=1e-99)
    assert 'sqnu' not in species and 'I' not in species and 't' not in species
    for index, values in enumerate(read_ts_file(binary, last=True)):
        expected = (zz, aa, xmf, time, temp, rho, dt, edot, endpoints, flux)[index]
        np.testing.assert_array_equal(values, expected if index in (0, 1, 8) else expected[-1:])

    # Use freshly written bytes to check truncation, trailer mismatch and foreign
    # record conventions, rather than accepting misaligned arrays as success.
    content = binary.read_bytes()
    mutations = [content[:-1], content[:324] + b'BAD!' + content[328:],
                 struct.pack('>I' if np.little_endian else '<I', 320) + content[4:],
                 struct.pack('=Q', 320) + content[4:]]
    for i, content in enumerate(mutations):
        bad = tmp_path / ("bad%d" % i)
        bad.write_bytes(content)
        with pytest.raises(ValueError):
            read_ts_file(bad)
        with pytest.raises(ValueError):
            read_ts_file(bad, last=True)

    # Single-record and no-flux histories use records copied from the real run.
    content = binary.read_bytes()
    records = []
    offset = 0
    while offset < len(content):
        size = struct.unpack_from('=I', content, offset)[0]
        records.append(content[offset:offset + size + 8])
        offset += size + 8
    expected_flux = struct.unpack_from('=%dd' % len(endpoints), records[-1], 8 + 8 * (6 + 14))
    np.testing.assert_array_equal(flux[-1], expected_flux)
    single = tmp_path / 'single'
    single.write_bytes(b''.join(records[:7]))
    assert len(read_ts_file(single)[3]) == 1
    np.testing.assert_array_equal(read_ts_file(single, last=True)[2], xmf[:1])
    empty = tmp_path / 'empty'
    empty.write_bytes(b''.join(records[:6]))
    assert read_ts_file(empty)[2].shape == (0, 14)
    assert read_ts_file(empty, last=True)[9].shape == (0, len(endpoints))
    # Strip flux entries and the sqnu scalar to exercise the historical layout.
    payload = records[6][4:-4]
    payload = payload[:28] + payload[36:4 + 8 * (6 + 14)]
    legacy = tmp_path / 'legacy'
    legacy.write_bytes(b''.join(records[:5]) + struct.pack('=III', 4, 0, 4)
                       + struct.pack('=I', len(payload)) + payload + struct.pack('=I', len(payload)))
    legacy_result = read_ts_file(legacy)
    for index in (2, 3, 4, 5, 6, 7):
        np.testing.assert_array_equal(legacy_result[index], read_ts_file(single)[index])
        np.testing.assert_array_equal(read_ts_file(legacy, last=True)[index], legacy_result[index])
    assert legacy_result[9].shape == (1, 0)
    assert legacy_result[8].shape == (0, 2)
