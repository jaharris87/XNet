# Focused MPI wrapper tests

This opt-in test exercises XNet's 64-bit integer reductions without running an
XNet physics problem. It checks scalar and vector `MPI_MIN`, `MPI_MAX`, and
`MPI_SUM` with values outside the 32-bit integer range. It covers all-reduce
and rooted-reduce paths, wrapper-owned MPI initialization, caller-owned MPI
initialization, and an optional caller communicator.

The test requires GNU Fortran and an Open MPI installation that provides
`mpifort` and `mpirun`. From the repository root, run:

```bash
make -C test/mpi test
```

Override the compiler or launcher when necessary:

```bash
make -C test/mpi test MPIFC=/path/to/mpifort MPIEXEC=/path/to/mpirun
```

The positive checks require exactly two ranks. A final one-rank negative probe
must fail with the expected topology diagnostic, preventing a substituted
serial launch from passing. Build products are written beneath the ignored
`test/unit/build/mpi/` directory.

This focused test does not qualify an MPI implementation, launcher, placement,
or XNet physics result. Facility confirmation must separately record the exact
source revision, modules, compiler, launcher, rank affinity, output, and status.
