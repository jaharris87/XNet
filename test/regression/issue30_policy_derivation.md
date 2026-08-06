# Issue #30 empirical-policy derivation record

This is a provenance record for the executable policy in
`empirical_policy.json`.  It is not a reference-update mechanism and does not
contain raw XNet output or histories.

## Retained study inputs

The exact parsed endpoint records are committed under
`test/regression/study/issue30/`. They are compact structured study evidence,
not raw runtime directories, diagnostics, ASCII histories, or binary histories:

| Configuration | Endpoint record | SHA-256 |
| --- | --- | --- |
| `mac-gnu16` | `test/regression/study/issue30/mac-gnu16-endpoints.json` | `10fb159a113910170f43efe753357c46d912e54891bb5478308809e44d598afe` |
| `mac-llvm` | `test/regression/study/issue30/mac-llvm-endpoints.json` | `cf2c62cbe9bbb42664f3e36473301004e68fc94a7ed140818e73748db00acecc` |
| `etacar-gnu16` | `test/regression/study/issue30/etacar-gnu16-endpoints.json` | `e18109c1234f0e34aa001d6bb2659324687d5df9e484e8c608f312dbb264e9ce` |

Together the inputs contain all 45 parsed observations: three repeatable runs
for each of the five cases under each accepted configuration.  They retain
configuration identity, target and achieved time, T, rho, Ye, complete
composition keyed by species, parsed printed composition sum, `End`, and every
counter. The strict canonical species order is separately retained and checked
by each case's `sunet` input and canonical reference.
They also preserve the required-output inventory for each run.

## Deterministic derivation

The retained study itself was run from Issue #30 source revision
`96277db1cd466015f4f510628b23c312f5b985df`. Run the derivation command from
this implementation candidate (which contains `derive_issue30_policy.py`):

```bash
python test/regression/derive_issue30_policy.py . \
  test/regression/study/issue30/mac-gnu16-endpoints.json \
  test/regression/study/issue30/mac-llvm-endpoints.json \
  test/regression/study/issue30/etacar-gnu16-endpoints.json \
  | cmp -s - test/regression/empirical_policy.json
```

This exits zero for the committed policy.  The tool emits no files: output is
the complete policy and can be captured for review.  Its `--report` output
records, for every generated scalar, selected-species, L1, L-infinity, and
printed-sum gate, the canonical value, three representative (one per
configuration) values, maximum absolute deviation, printed decimal unit, and
candidate limit.  It hashes to
`e44e04c6e8fdae216ebb7f7df876920a98e0dd4e125869d3db321c22c8d45eaf` for
the retained study inputs; that hash is recorded in the policy.

Within-configuration repeatability was exact at parsed precision, so the
three representative values preserve the same extrema as all nine per-case
observations.  The algorithm uses the canonical `mac-gnu16` value and computes
each nonexact limit as `1.5 * maximum absolute deviation + 0.5 * final printed
decimal unit`. L1 uses one half of the `math.fsum` of composition print units
and L-infinity uses one half of their maximum. Parsed printed composition sums
come from the recorded `mass_fraction_sum` field, not a reconstruction from
JSON object order. A zero printed mass fraction uses its `0.0000000E+00`
decimal unit, `1e-7`. Invariant parsed fields are represented as exact, as required
by the accepted characterization; the printed composition-sum gate remains
separate.
