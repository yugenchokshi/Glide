# Benchmark results

## 2026-10-16: 12/12 passed (three consecutive full runs)

`latest.json`, `2026-10-16-rerun-1.json`, `2026-10-16-rerun-2.json`. Fixes since the first run:

- The element matcher now matches labels that contain stop words ("Go to page two").
- Notes test cleanup targets the note row by label.
- TextEdit's save sheet gets a retry through File › Save….

```
#  Scenario                                   OK  Actions  Duration  Obs(ms)  Recov  OCR  Model  Vision  Cost
1  Open an application                        ✓         1      0.6s       30      0    0      0       0  $0.00
2  Create a new note                          ✓         5      1.8s       67      0    0      0       0  $0.00
3  Save a TextEdit document                   ✓         9      3.7s       73      0    0      0       0  $0.00
4  Rename a file in Finder                    ✓         3      1.6s       54      0    0      0       0  $0.00
5  Navigate a browser page                    ✓         1      0.7s       39      0    0      0       0  $0.00
6  Fill out a web form                        ✓         4      1.2s       22      0    0      0       0  $0.00
7  Switch between two applications            ✓         3      1.0s      240      0    0      0       0  $0.00
8  Interact with a system dialog              ✓         2      1.1s      187      0    0      0       0  $0.00
9  Recover from a missing element             ✓         2      3.3s        6      1    0      0       0  $0.00
10 Stop a task mid-execution                  ✓         2      0.5s        4      0    0      0       0  $0.00
11 Request approval before a sensitive action ✓         1      0.2s        5      0    0      0       0  $0.00
12 Handle an inaccessible control             ✓         1      0.4s        5      0    1      0       0  $0.00
passed 12/12
wrote docs/benchmarks/latest.json
```

The Finder → Notes workflow (`nbctl workflow`, the Phase 2 acceptance test) passed in 3.4 s with 8 actions, and its test note was deleted afterwards.

Earlier: produced by `nbctl bench --json …` on a MacBook (macOS 26.6, Apple silicon). Deterministic: there are no model calls, so cost is $0.

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
