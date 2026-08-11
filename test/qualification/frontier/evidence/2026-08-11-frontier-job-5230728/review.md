# Frontier qualification review

Disposition: accepted and retained for issue #46.

## Run identity

- Source commit: `c6f0eb685ae7c78c38de582e92dfe48765c02fe7`
- Source archive SHA-256: `486348393a76b43e6f281f96b7699b7885a9da69e8217150af2b126aa0bdc41e`
- Manifest SHA-256: `e726c4346626c352e4540cbced253e6694cd6b73efcc897f1e4cb6836819d310`
- Slurm job: `5230728`
- Resources: one node, one task, seven CPUs, one GPU, `00:20:00` limit
- Environment: Frontier MI250X, CCE 20.0.2, ROCm 6.4.2, hipfort 6.4.2

## Evidence review

- The tracked manifest validator passed.
- Clean CPU and GPU builds passed with the required recorded variables,
  executable hashes, and link evidence.
- The GPU linear-algebra probe found one device, confirmed target offload and
  mapped data, returned zero factor/solve status for both batches, and measured
  relative residuals of `0` and `3.552713678800501e-17` against the `1e-12`
  limit.
- The partial-batch fixture retained zones 1-10 exactly once with two inactive
  final lanes. All normalized endpoint, composition, bounded neutrino-loss,
  and timestep differences were zero.
- The report-only final energy-generation rate differed only in zone 9: GPU
  `-2.51e9`, CPU `5.48e10`, absolute difference `5.731e10`. The compared
  composition and thermodynamic endpoint for that zone were identical.
- The six-zone `heat_sn160` check passed. Maximum selected-species use was
  `0.0438619` of allowed; maximum scalar use was `0.0799805` of allowed;
  maximum composition L1 was `8.16763e-7` against `5e-5`; maximum composition
  Linf was `2.9e-7` against `1e-5`.
- The manifest records 38 inputs and a finalized inventory of 192 artifacts,
  including the redacted submission record and closed Slurm logs.

This evidence qualifies the named HIP/ROCm OpenMP-offload configuration for
the bounded correctness claims in issue #46. It does not establish performance,
scaling, another compiler/runtime stack, another GPU target, or automatic CI.
