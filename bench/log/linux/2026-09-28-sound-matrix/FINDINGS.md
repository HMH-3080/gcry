# Sound against tuned after the parked-SP scan

CI run `36413548919` on `6c3e1b8`, `bench/sound_matrix.py`, 10 rounds per
platform, paired (`sound-matrix-*.json`). Pause p50:

| shape | Linux tuned | Linux sound | macOS tuned | macOS sound |
|---|---:|---:|---:|---:|
| EC1 | 1.234 ms | 1.216 ms | 0.808 ms | 0.831 ms |
| EC1 + one extra thread | **1.405 ms** | 6.452 ms | **0.897 ms** | 4.014 ms |
| EC4 | **1.697 ms** | 5.840 ms | **1.107 ms** | 4.399 ms |

Sound ÷ tuned, per round:

| shape | Linux req/s | Linux pause | macOS req/s | macOS pause |
|---|---|---:|---|---:|
| EC1 | 1.016 | 0.99× | 0.938 | 1.07× |
| EC1 + one thread | 0.951 | 4.56× | 1.050 | 4.46× |
| EC4 | 0.995 | 3.46× | 1.040 | 3.93× |

Tuned multi-mutator pause fell from the 2026-09-26 matrix: Linux EC4 3.07 →
1.70 ms, macOS 3.33 → 1.11 ms. That is the parked-SP scan
(`../2026-09-27-parked-fiber-sp/`). `GCRY_SOUND=1` keeps its whole scan,
because lag 0 opts out of that path, so its pause did not move and the ratio
grew. Throughput is in the noise on every multi-mutator shape except Linux
EC1 + one thread (0.951).

The macOS post-GC footprint is equal across the profiles. RSS after
`GC.collect` on Linux EC4 is 18.3 MB for both, which is release-on-collect
(`../2026-09-28-release-on-collect/`).
