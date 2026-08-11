# Frontier qualification review

Disposition: accepted and retained for issue #46.

## Run identity

- Source commit: `97174bc0b382ed2c580eb517b05479e0ee63b184`
- Source archive SHA-256: `f9e089a4abdea93bb3e0c289823878f78f6df981235d13d15e87c156d2e8e498`
- Extracted source-tree SHA-256: `92c0a330b9b3057db6d9c4c29f1f2e1c9b526d2a5983968dfd60c83db6dafee2`
- Manifest SHA-256: `550924544d60a6ff9f9a8d55b7289ea0b13e2167bbde5d4d1a3e014741237269`
- Slurm job: `5231295`
- Resources: one node, one task, seven CPUs, one GPU, `00:20:00` limit
- Environment: Frontier MI250X, CCE 20.0.2, ROCm 6.4.2, hipfort 6.4.2

## Evidence review

- The tracked manifest validator and Draft 2020-12 JSON Schema validation
  passed. The manifest binds the clean exact source archive, embedded commit,
  and extracted source tree before the build.
- Clean CPU and GPU builds passed with the required requested and resolved
  variables. The GPU build used the Cray wrapper over `ftn`, OpenMP offload,
  HIP/ROCm, Starkiller EOS, dense solve, and MPI off. Executable and nested
  artifact claims agree with the finalized inventory.
- The GPU linear-algebra probe found one device, confirmed target offload and
  mapped data, returned zero factor/solve status for both batches, and measured
  relative residuals of `0` and `3.552713678800501e-17` against the `1e-12`
  limit.
- The partial-batch fixture retained zones 1-10 exactly once with two inactive
  final lanes. All endpoint, composition, bounded neutrino-loss, and timestep
  differences were zero.
- The partial-batch report-only final energy-generation rate differed most in
  zone 9: GPU `-2.51e9`, CPU `5.48e10`, absolute difference `5.731e10`. The
  compared composition and thermodynamic endpoint for that zone were
  identical, and final energy-generation-rate correctness remains explicitly
  outside the qualified claim.
- The six-zone `heat_sn160` check passed and all six final neutrino-loss rates
  were nonzero and identical in the formatted CPU/GPU output. Maximum
  selected-species use was `0.202688` of allowed; maximum scalar use was
  `0.409868` of allowed; maximum composition L1 was `2.50152e-6` against
  `5e-5`; maximum composition Linf was `4.12e-7` against `1e-5`.
- The largest report-only `heat_sn160` final energy-generation-rate difference
  was `1e17` in zone 6 (GPU `2.05e18`, CPU `2.15e18`). This does not affect
  the bounded support claim.
- The manifest records 38 inputs and a finalized inventory of 193 artifacts,
  including the redacted submission record and closed Slurm logs.

This evidence qualifies the named HIP/ROCm OpenMP-offload configuration for
the bounded correctness claims in issue #46. It does not establish performance,
scaling, another compiler/runtime stack, another GPU target, MPI-enabled
execution, or automatic CI.
