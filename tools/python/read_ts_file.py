"""Read XNet unformatted sequential time-series histories."""


def read_ts_file(file_name, debug=False, last=False, print_positions=False):
    """Return zz, aa, X, time, T9, rho, dt, edot, flux endpoints and flux.

    Supports native-endian 4-byte record markers and integers, and 8-byte
    reals. Other compiler record conventions and byte orders are unsupported.
    Current step records include sqnu (not returned); the older five-scalar
    layout, also written by nse_slice, remains readable. Malformed or truncated
    records raise ValueError when read. ``last=True`` checks the headers and
    final row without scanning intervening steps.
    """
    import numpy as np

    with open(file_name, 'rb') as file_id:
        def read_record(expected=None, eof=False):
            position = file_id.tell()
            marker = file_id.read(4)
            if not marker and eof:
                return None
            if len(marker) != 4:
                raise ValueError("Missing record marker at byte %d" % position)
            size = int(np.frombuffer(marker, dtype='uint32')[0])
            if expected is not None and size != expected:
                raise ValueError("Unexpected record length at byte %d: %d != %d; "
                                 "requires native byte order and 4-byte markers"
                                 % (position, size, expected))
            payload = file_id.read(size)
            if len(payload) != size or file_id.read(4) != marker:
                raise ValueError("Truncated record or mismatched markers at byte %d" % position)
            if print_positions:
                print("Position after record:", file_id.tell())
            return payload

        read_record(320)  # Three run descriptions and the network description.
        read_record(76)   # Run settings.
        read_record(160)  # Initial abundance source and description.
        read_record(160)  # Thermodynamic source and description.

        payload = read_record()
        if len(payload) < 4:
            raise ValueError("Missing nuclear species count")
        ny = int(np.frombuffer(payload, dtype='int32', count=1)[0])
        if ny < 0 or len(payload) != 4 + 16 * ny:
            raise ValueError("Invalid nuclear information record")
        zz = np.frombuffer(payload, dtype='float64', count=ny, offset=4).copy()
        aa = np.frombuffer(payload, dtype='float64', count=ny, offset=4 + 8 * ny).copy()

        payload = read_record()
        if len(payload) < 4:
            raise ValueError("Missing flux count")
        nflx = int(np.frombuffer(payload, dtype='int32', count=1)[0])
        if nflx < 0 or len(payload) != 4 + 8 * nflx:
            raise ValueError("Invalid flux information record")
        flx_end = np.frombuffer(payload, dtype='int32', offset=4).reshape(2, nflx).T.copy()

        start = file_id.tell()
        marker = file_id.read(4)
        file_id.seek(start)
        nscalar = 6
        if marker:
            if len(marker) != 4:
                raise ValueError("Truncated step record marker")
            size = int(np.frombuffer(marker, dtype='uint32')[0])
            if size == 4 + 8 * (5 + ny + nflx):
                nscalar = 5
            elif size != 4 + 8 * (6 + ny + nflx):
                raise ValueError("Unsupported step record length: %d" % size)
            if last:
                file_id.seek(0, 2)
                if (file_id.tell() - start) % (size + 8):
                    raise ValueError("Truncated step records")
                file_id.seek(-(size + 8), 2)

        rows = []
        size = 4 + 8 * (nscalar + ny + nflx)
        while True:
            payload = read_record(size, eof=True)
            if payload is None:
                break
            rows.append(np.frombuffer(payload, dtype='float64', offset=4))
            if debug:
                print(len(rows) - 1, np.frombuffer(payload, dtype='int32', count=1)[0], rows[-1][0])
            if last:
                break

    values = np.asarray(rows).reshape(len(rows), nscalar + ny + nflx)
    time, temperature, density = values[:, :3].T
    # sqnu precedes dt and edot in current histories; keep the caller tuple.
    timestep, edot = values[:, nscalar-2:nscalar].T
    xmf = values[:, nscalar:nscalar+ny] * aa
    flx = values[:, nscalar+ny:]
    return zz, aa, xmf, time, temperature, density, timestep, edot, flx_end, flx


def build_element_symbol():
    """
    Builds symbols for Chemical Elements
    Input < None
    Output> element
    """
    element = ('n ','H ','He','Li','Be','B ','C ','N ','O ','F ','Ne',
               'Na','Mg','Al','Si','P ','S ','Cl','Ar','K ','Ca','Sc','Ti',
               'V ','Cr','Mn','Fe','Co','Ni','Cu','Zn','Ga','Ge','As','Se',
               'Br','Kr','Rb','Sr',' Y','Zr','Nb','Mo','Tc','Ru','Rh','Pd',
               'Ag','Cd','In','Sn','Sb','Te',' I','Xe','Cs','Ba','La','Ce',
               'Pr','Nd','Pm','Sm','Eu','Gd','Tb','Dy','Ho','Er','Tm','Yb',
               'Lu','Hf','Ta','W ','Re','Os','Ir','Pt','Au','Hg','Tl','Pb',
               'Bi','Po','At','Rn','Fr','Ra','Ac','Th','Pa','U ','Np','Pu',
               'Am','Cm','Bk','Cf','Es','Fm','Md','No','Lr','Rf','Db','Sg',
               'Bh','Hs','Mt','Ds','Rg','Cn')

    return element
    
def build_isotope_symbol(zz,aa,latex=True):
    """
    Builds isotope symbols, with superscripts
    Input < zz, proton number for each isotope in the network
            aa, atomic mass number of each isotope in the network
    Ouputs> nuc_name, isotopic symbol
    """
    import numpy as np
    element = build_element_symbol()
    zint=zz.astype(np.intp)
    aint=aa.astype(np.intp)
    n_iso=np.size(zint)
    nuc_name=[None] * n_iso
    for k in range(n_iso):
        if latex:
           nuc_name[k] = "$^{%u}$" % aint[k]
           nuc_name[k] = nuc_name[k] + element[zint[k]]
        else:  
           nuc_name[k] = str(element[zint[k]]).lower().strip()+str(aint[k])

    return nuc_name
