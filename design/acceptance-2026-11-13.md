# Bawan local acceptance — 2026-11-13

**Bawan v1 accepted for normal use on 2026-11-14.** Current-build testing found no functional or memory-growth defect in the exercised paths. The user confirmed both physical-key shortcuts, including source-app focus preservation for selection translation. Advanced GPU/allocation tracing and sleep/wake recovery remain unverified; this acceptance does not claim that every historical QA criterion has passed.

## Build and environment

- Commit `3550b6a`, Release, Apple M4 MacBook Air, 16 GiB RAM, macOS 27.0.1 (26A434).
- Updated `/Applications/Bawan.app` from the current build after quitting the older installed version. Installed/build executable SHA256 both `d659c513cfc256a140cf4060359403ea2589ead18233ee49eb355924643b53d9`.
- `cmake --build build --parallel 3`: passed. Strict installed-app signature check: passed. CTest: **9/9 passed**, 9.20 seconds.
- Official installed model SHA256 `70891ec70dc7ab4205745a38307867c2881b99239f20327927633abfe4bc9ec6`.
- Raw evidence, sampler source, model/input conditions, cycle timestamps, `vmmap` and `leaks` output: `build/ui-validation/2026-11-13/` (local ignored build artifacts).

## Live interaction

- Actual model inference: English → Japanese and Japanese → English completed in both Light and Dark appearances. Short source: “The meeting has been moved to next Monday. Please send the updated schedule by Friday.” Translation and reverse translation preserved the meaning.
- Completed **20 cycles** of reopen → short translation completion → long translation → cancel after nonempty streaming output → close. No stuck busy state or crash. Long input was a fixed three-sentence English passage repeated 20 times; exact text is in the local conditions record.
- Settings navigation preserved text and translation. Full-window screenshots showed native traffic lights clear of the mascot and settings control; Light, Dark and Increase Contrast appearances remained legible and unclipped at 720×500 pt.
- Enabled macOS Reduce Motion, clicked the mascot, and verified the app remained responsive. This is a live setting/interaction check, not a frame-by-frame motion trace. Existing mascot smoke test passed. Increase Contrast visibly strengthened the control and pane outlines.
- Restored Light appearance, Reduce Motion off, and Increase Contrast off after testing.
- After updating the ad-hoc-signed binary, macOS initially displayed old grants while the app reported missing permissions. Refreshed Bawan's Input Monitoring registration and Accessibility grant with explicit user permission; the app then reported both shortcuts available.
- `⌥T` twice: **user confirmed working on the physical keyboard**. CUA-generated key events did not exercise the global shortcut path and are not accepted as physical-key evidence.
- `⌘C` twice: **user confirmed on 2026-11-14 that translation appeared and the source app retained input focus**, using the physical keyboard.
- Sleep/wake recovery was not exercised in this session.

## Whole-app memory and CPU

One Bawan process (PID 83376), 0.5-second `proc_pid_rusage` sampling. Values below are MiB. RSS includes resident mapped pages; physical footprint is reported separately. CPU counters were converted from Mach absolute ticks with timebase 125/3 ns per tick. The raw sampler's initial `user_ns/system_ns` headers are misnamed; corrected copies use `user_ticks/system_ticks`.

| Settled checkpoint | RSS | Physical footprint |
| --- | ---: | ---: |
| 5 completed cycles | 648.5 | 173.0 |
| 10 completed cycles | 553.2 | 173.2 |
| 20 completed cycles | 549.6 | 173.6 |
| Closed, ~80 seconds after final cancellation | 43.4 | 139.8 |
| Dark window open, ~90 seconds after final translation | 85.0 | 118.2 |
| Light window open, model released | 58.8 | 118.9 |

The 5→20-cycle physical-footprint change was about **0.6 MiB**, while RSS declined. This does not show cycle-proportional growth in the measured interval. After the 60-second release deadline, model residency disappeared and memory settled substantially lower. Idle closed CPU averaged **0.44% of one core** over a 15.18-second settled interval. Across ~217 seconds containing the 20 cycles and inspection overhead, CPU time was 17.26 seconds (7.94% average of one core); this is not an inference-speed benchmark.

The 0.5-second sampler observed a 310.2 MiB physical-footprint peak; `vmmap` recorded a lifetime peak of 333.3 MiB. Diagnostic tools ran between batches and can perturb these figures.

`leaks` after cycles 5 and 20 reported the same **416 allocations / 19,936 bytes**, with shown root cycles in macOS AppIntents/NSXPCConnection. No increase was observed between those checkpoints. The tool warns that the release process is not debuggable and restricts object inspection; this cannot establish the absence of all app-owned retention.

## Evidence limits

Instruments / `xctrace` are not available in the installed Command Line Tools environment. No Metal System Trace, Allocations generations or Xcode Memory Graph was recorded. Consequently idle per-process GPU work and exact retained-owner counts remain unverified. There was no old-version resource comparison. Repeated inputs used AX replacement, so repeated typing/paste undo-history growth is outside this run. The 20-cycle stress run used Light appearance; Dark received live bidirectional translation and idle measurement, not another independent 20-cycle run.
