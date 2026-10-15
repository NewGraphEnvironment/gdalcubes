# Progress — Record a failed chunk read-back in read_ncdf() as ERROR (add to appelmar/gdalcubes#114) (#9)

## Session 2026-10-15

- Plan-mode exploration — phases approved by user
- Created branch `chunk-status-read-back` off `origin/chunk-status-read-failures` (no tracking; PWF excluded via `.git/info/exclude`)
- Scaffolded PWF baseline on `newgraph` (committed through a worktree)
- User: "go to phase 5" — taken as the go for Phase 5, which runs only after Phases 1–4 pass
- Next: Phase 1

### Phase 1–2 (2026-10-15)

- Ported the `cube.cpp` hunks unchanged; file is byte-identical to `origin/99-chunk-status-read-failures`. NEWS line extended.
- `test_chunk_readback.R`: stand-in worker 1 writes broken chunk files (not netCDF / no x-y-t-b dims / no `value` variable, each with `chunk_status = 0`). Scratch builds of this branch with and without the hunks (`R_LIBS` so workers load them too): **3/9 fail without, 9/9 pass with**. Full suite on the branch: 169/169 (before the round-1/2 test-only edits).
- Truncation probe: workers write netCDF-4 (`USE_NCDF4`, all but Solaris). A truncated netCDF-4 file fails at `nc_open` (covered); one with damaged data bytes reads back with no error, so the `nc_get_var_double` check is unreachable from R. Documented in the test header.
- A file truncated or corrupted silently is a **worker-side** gap: the worker's own netCDF writes and `nc_close`/`CPLMoveFile` are unchecked (noted in the original issue draft #6). Out of scope for #9; candidate follow-up.
- code-check: round 1 Clean, with notes (ncdf4 is in Imports, so the guards I added were redundant and are removed; the header's format reason was wrong; one assertion could never pass). Round 2: the stand-in never wrote its log, and this branch lacks #113's hang fix, so a failing worker would hang the run; `--vanilla` → `--no-save --no-restore`. My first fix (worker 1's log only) still hung because worker 0 also writes no log; fixed by having every worker create its log. Probe with a failing stand-in: hung 60 s → errors in 1 s.
- Read-back reprex (`#114` addition draft): `chunk_status` `0 0 0 0` on #114's tip, `0 1 0 1` with the fix.

### Phase 3–5 (2026-10-15)

- code-check: 3 rounds; ended on an enumeration (round 3: the mechanism is that the worker protocol is written twice, once by the main process and once by the stand-in, and each process loads its own gdalcubes; it reaches 13 places, all handled or accepted). Committed `457ed5f`.
- Fork PR #10 (base `newgraph`) merged as `20cda4f`; NEWS resolved to a single extended `chunk_status` line. `newgraph` suite 174/174.
- Downstream on the `newgraph` build: drift's gdalcubes tests 590 pass, 10 skipped (network/flags); flooded 578/578.
- Phase 5 (user: "go to phase 5"): `chunk-status-read-failures` fast-forwarded `0c501ac..457ed5f`; appelmar/gdalcubes#114 head confirmed `457ed5f`; read-back section and reprex appended to its description (existing text unchanged, checked against a fresh fetch before editing); no PR comment. #9 commented and closed.
- Follow-up candidate: worker-side unchecked netCDF writes / `nc_close` / `CPLMoveFile` (silent corruption of a worker's own chunk file).
- Next: `/planning-archive`.
