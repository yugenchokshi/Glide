# Benchmark results

Produced by `nbctl bench --json …` on a MacBook (macOS 26.6, Apple silicon). Deterministic: there are no model calls, so cost is $0.

## 2026-10-15: first run, 8/12 passed

`2026-10-15-first-run.json`. The four failures happened while a macOS Automation permission alert was frontmost and holding focus:

- 1, 3 and 7 timed out bringing TextEdit to the front.
- 5 looked for the link before the page had loaded. The scenario now waits for it.

The passing scenarios measured:

| Measurement | Result |
|---|---|
| Accessibility snapshot | 5–170 ms (avg 6–72 ms for typical windows) |
| Cached element lookup | 0.01 ms |
| Click including move | 80–110 ms |
| Stop latency during typing | 2 ms |

## Other measurements

| Measurement | Result |
|---|---|
| Notch open (first open after launch) | 56–76 ms (opt-in `NBPerfLog`) |
| Idle CPU | 0.0 % |
| Idle memory (RSS) | ~18 MB |
| Full agent loop with the scripted model (3 steps, fixture) | 0.25–0.6 s end to end |
