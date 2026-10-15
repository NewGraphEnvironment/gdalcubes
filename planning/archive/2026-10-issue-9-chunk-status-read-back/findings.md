# Findings — Record a failed chunk read-back in read_ncdf() as ERROR (add to appelmar/gdalcubes#114) (#9)

## Exploration (plan mode, 2026-10-15)

- **The hunks:** `git diff origin/chunk-status-read-failures origin/99-chunk-status-read-failures -- src/gdalcubes/src/cube.cpp`. Five changes in `read_ncdf()` (cube.cpp:1857):
  - ERROR on `nc_open` failure;
  - ERROR on a dimension lookup failure;
  - ERROR on a `value` variable lookup failure;
  - the four `nc_inq_dimlen` calls checked;
  - `nc_get_var_double` checked, with its buffer freed;
  - an `nc_close` added on the empty-chunk return.

  This is the only remaining difference to #2 that belongs in #114. The `warp.cpp`, `multiprocess.cpp` and test differences between the two branches are #113's and #115's work.
- **Where it is called:** the main process's loop in `src/multiprocess.cpp` (`chunk_processor_multiprocess::exec`, about line 129). It picks up **any** file named `<int>.nc` in the work directory, calls `dat->read_ncdf()`, and passes the result to the write callback. That callback writes `(int)dat->status()` into the output's `chunk_status` (cube.cpp:966).
- **Why it reads as OK today:** `chunk_data` starts as `OK` (cube.h:276). On an `nc_open` failure `read_ncdf()` returns before reading the file's `chunk_status` attribute, so the chunk stays OK, empty, and NA.
  - If the file opens but has no `chunk_status` attribute, the status becomes `UNKNOWN` (128), which is already non-OK.
  - So any test file that opens must carry `chunk_status = 0` as a global attribute, as a real worker file does (cube.cpp:1833). Otherwise the test would pass even without the fix.
- **How to trigger it:** chunks are assigned round-robin, with worker `pid` taking chunks `pid, pid+n, …` (multiprocess.cpp:237). `test_worker_failure.R` already swaps in a worker script through `gdalcubes:::gc_set_process_execution()`.
  - A stand-in worker 1 can write unreadable `<id>.nc` files for its chunks into `j$workdir` and exit 0, writing to a dotted temp name and then renaming, as real workers do.
  - Worker 0 runs normally, so its chunks are the clean control.
  - This needs no C++ fault-injection build.
- **Planning convention** (`planning/README.md` on `newgraph`): PWF files are kept untracked on the fix branch via `.git/info/exclude` and committed on `newgraph`.
- **Downstream:**
  - drift's gdalcubes tests: `tests/testthat/test-dft_stac_{cube,composite,fetch}.R` and `test-dft_index_expr.R`, plus `helper-gdalcubes.R` and `helper-break.R`.
  - flooded lists gdalcubes only in DESCRIPTION, with no gdalcubes tests, so its full suite is the check.

## Issue context

**If we do it:** a worker chunk file that the main process cannot read back is recorded as ERROR, so drift's `chunk_status` check aborts on it rather than merging a hole (or an uninitialised buffer) as data.
**If we never do:** on `newgraph` and upstream appelmar/gdalcubes#114 that case is still recorded OK, with only a C++ stderr line. drift's notes say so (NewGraphEnvironment/drift#104).

## Problem

Closed fork PR #2 (`99-chunk-status-read-failures`) set `set_status(ERROR)` in `chunk_data::read_ncdf()` (`src/gdalcubes/src/cube.cpp`) in four places, and it also closed the file on the empty-chunk return. When #2 was split into #3 (`chunk-status-read-failures`, appelmar/gdalcubes#114), #4 and #5, those hunks were left out. Measured 2026-10-14 by diffing `cube.cpp` tip to tip: the two branches differ by exactly these lines.

- `nc_open` fails → ERROR.
- A dimension lookup fails, or the `value` variable lookup fails → ERROR.
- Any `nc_inq_dimlen` fails → ERROR. These four calls are unchecked today.
- `nc_get_var_double` fails → ERROR, and the buffer is freed. It is unchecked today, so the uninitialised buffer is merged as data.
- The empty-chunk early return leaks the open file → add `nc_close`.

The exact hunks: `git diff origin/chunk-status-read-failures origin/99-chunk-status-read-failures -- src/gdalcubes/src/cube.cpp`.

## Decision (2026-10-15)

**(a): add them to `chunk-status-read-failures`, so they ride in appelmar/gdalcubes#114.** That PR records failed reads in `chunk_status` and is unreviewed, so updating it costs the maintainer nothing. We are **not** closing it and opening a new PR. (b), a fourth upstream PR, and (c), leaving them out, were rejected.

## Plan

**A push to `chunk-status-read-failures` updates appelmar/gdalcubes#114 at once, so that branch is touched only in the last step, and only with approval.**

1. **Branch:** cut `chunk-status-read-back` off `origin/chunk-status-read-failures`, so it already carries appelmar/gdalcubes#114's work. Following CLAUDE.md, it holds no `planning/` or CLAUDE.md commits; planning files go on `newgraph`.
2. **Port:** bring in the hunks from `99-chunk-status-read-failures`. Do not reinvent them.
3. **Trigger:** find a way to make the read-back fail on purpose: a parallel run (`gdalcubes_options(parallel = 2)`) whose worker chunk file is unreadable or truncated by the time the main process reads it. If R has no clean hook for this, say so, and test at the C++ level or with a fault-injection build. A test that can only pass is not a test.
4. **Test:** add a tinytest (`inst/tinytest/`) that sees `chunk_status` = ERROR for that chunk.
   - Restore the bug (revert the hunks) and show the test fails, then re-apply and show it passes.
   - Also run the existing appelmar/gdalcubes#114 tests.
5. **Merge into `newgraph`:** open a fork PR, base `newgraph`, merge it. Leave this issue open until step 7 is done, then close it by hand (a merge into `newgraph` does not auto-close).
6. **Check downstream:** reinstall `@newgraph`, then rerun drift's and flooded's gdalcubes-dependent tests.
7. **Update appelmar/gdalcubes#114. Do this only after steps 4-6 pass, and only on the user's explicit go.** Show them the test result and the drafted text first, then:
   - Fast-forward and push. This is the moment appelmar/gdalcubes#114 changes. No force-push: it must be a fast-forward of the branch the PR already shows.
     ```bash
     git push origin chunk-status-read-back:chunk-status-read-failures
     ```
   - Check that `gh pr view 114 -R appelmar/gdalcubes --json headRefOid` now equals the tip of `chunk-status-read-back`.
   - Edit the description: `gh pr view 114 -R appelmar/gdalcubes --json body -q .body` into a file, then add a short paragraph and a reprex for the read-back case under the existing text. Do not rewrite what the maintainer may already have read.
     - Draft it first in the step 5 fork PR body, above a `---` footer. Strip the footer and anything fork- or org-specific before posting (CLAUDE.md, "Issue and PR drafts meant for upstream").
     - Post it with `gh pr edit 114 -R appelmar/gdalcubes --body-file <file>`.
   - Do not comment on the PR to announce the update. The new commits show in its timeline.
   - Then record what was pushed, and the head SHA, in a comment on this issue.

