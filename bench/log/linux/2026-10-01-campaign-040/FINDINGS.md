# Stress campaign-040: `pattern_fuzz` only (2026-10-01)

Same `pattern_fuzz` binary as campaign-039 (`c5265d7`), four lanes for five
hours, alternating the diagnostic environment and the plain one. This is the
harness whose large-object freelist walk spun for 900 s once
(campaign-037); since then the walk is bounded and aborts with a report on a
cycle. The question was whether that cycle comes back at a higher sampling
rate.

**611 runs, 20.1 lane-hours, 0 failures, 0 timeouts.**

| lane | runs | failed | lane-hours |
|---|---:|---:|---:|
| `pattern_fuzz+diag` | 306 | 0 | 13.2 |
| `pattern_fuzz` | 305 | 0 | 6.9 |

No FATAL cycle report. With campaigns 038 and 039 that is about 1 180 bounded
runs of the bucket walk and none hit the bound. [INFERENCE] The one spin was
1 in 288 runs before the bound; at that rate, 0 in 1 180 has probability
about 1.7%. So either what made the cycle stopped happening in these trees,
or the cycle needed something the campaign shape does not provide.
