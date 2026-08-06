# Issue #30 empirical-policy derivation record

This is a provenance record for the executable policy in
`empirical_policy.json`.  It is not a reference-update mechanism and does not
contain raw XNet output or histories.

## Retained study inputs

The study retained parsed endpoint records at these locations when this policy
was derived:

| Configuration | Endpoint record | SHA-256 |
| --- | --- | --- |
| `mac-gnu16` | `/private/tmp/xnet-issue30/results/mac-gnu16/endpoints.json` | `10fb159a113910170f43efe753357c46d912e54891bb5478308809e44d598afe` |
| `mac-llvm` | `/private/tmp/xnet-issue30/results/mac-llvm/endpoints.json` | `cf2c62cbe9bbb42664f3e36473301004e68fc94a7ed140818e73748db00acecc` |
| `etacar-gnu16` | `/private/tmp/xnet-issue30/results/etacar-gnu16-endpoints.json` | `e18109c1234f0e34aa001d6bb2659324687d5df9e484e8c608f312dbb264e9ce` |

Together the inputs contain all 45 parsed observations: three repeatable runs
for each of the five cases under each accepted configuration.  They retain
configuration identity, target and achieved time, T, rho, Ye, ordered complete
composition, parsed printed composition sum, `End`, and every counter.
They also preserve the required-output inventory for each run.  Raw runtime
directories are intentionally not committed.

## Deterministic derivation

At Issue #30 revision `96277db1cd466015f4f510628b23c312f5b985df`, run:

```bash
python test/regression/derive_issue30_policy.py . \
  /private/tmp/xnet-issue30/results/mac-gnu16/endpoints.json \
  /private/tmp/xnet-issue30/results/mac-llvm/endpoints.json \
  /private/tmp/xnet-issue30/results/etacar-gnu16-endpoints.json \
  | cmp -s - test/regression/empirical_policy.json
```

This exits zero for the committed policy.  The tool emits no files: output is
the complete policy and can be captured for review.  Its `--report` output
records, for every generated scalar, selected-species, L1, L-infinity, and
printed-sum gate, the canonical value, three representative (one per
configuration) values, maximum absolute deviation, printed decimal unit, and
candidate limit.  It hashes to
`424b7bb022308e30c12aef814b5e1bed9acbaecca2289766c7892400ae88eee0` for
the retained study inputs; that hash is recorded in the policy.

Within-configuration repeatability was exact at parsed precision, so the
three representative values preserve the same extrema as all nine per-case
observations.  The algorithm uses the canonical `mac-gnu16` value and computes
each nonexact limit as `1.5 * maximum absolute deviation + 0.5 * final printed
decimal unit`. L1 uses one half of the sum of composition print units and
L-infinity uses one half of their maximum. Invariant parsed fields are represented as exact, as required
by the accepted characterization; the printed composition-sum gate remains
separate.
