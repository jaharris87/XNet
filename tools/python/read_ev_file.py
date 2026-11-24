"""Read condensed XNet ASCII evolution histories."""


def read_ev_file(datafile):
    """Return time, rho, T9, edot, dt, species, structured data and filename.

    Read the fixed-width format from xnet_output, including its two adjacent
    iteration counters under the single ``It`` header. Species are selected
    by the writer and may be absent. NumPy field names (TGK, dEdt) and the
    existing return tuple are preserved; counters are available as I and t.
    """
    import numpy as np

    with open(datafile) as stream:
        headers = stream.readline().split()
    if headers[:7] != ['k', 'Time', 'T(GK)', 'Density', 'dE/dt', 'sqnu', 'Timestep'] or headers[-1:] != ['It']:
        raise ValueError("Unrecognized XNet evolution header")
    species = headers[7:-1]
    names = ['k', 'Time', 'TGK', 'Density', 'dEdt', 'sqnu', 'Timestep'] + species + ['I', 't']
    widths = [4, 15, 10, 10, 10, 10, 10] + [9] * len(species) + [2, 2]
    data = np.genfromtxt(datafile, skip_header=1, delimiter=widths, names=names, ndmin=1)
    return (data['Time'], data['Density'], data['TGK'], data['dEdt'],
            data['Timestep'], species, data, datafile)
