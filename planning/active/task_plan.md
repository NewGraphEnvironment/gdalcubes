# Task: Record a failed chunk read-back in read_ncdf() as ERROR (add to appelmar/gdalcubes#114) (#9)

## Problem

Closed fork PR #2 (`99-chunk-status-read-failures`) set `set_status(ERROR)` in `chunk_data::read_ncdf()` (`src/gdalcubes/src/cube.cpp`) in four places, and it also closed the file on the empty-chunk return. When #2 was split into #3 (`chunk-status-read-failures`, appelmar/gdalcubes#114), #4 and #5, those hunks were left out. Measured 2026-10-14 by diffing `cube.cpp` tip to tip: the two branches differ by exactly these lines.

- `nc_open` fails → ERROR.
- A dimension lookup fails, or the `value` variable lookup fails → ERROR.
- Any `nc_inq_dimlen` fails → ERROR. These four calls are unchecked today.
- `nc_get_var_double` fails → ERROR, and the buffer is freed. It is unchecked today, so the uninitialised buffer is merged as data.
- The empty-chunk early return leaks the open file → add `nc_close`.

The exact hunks: `git diff origin/chunk-status-read-failures origin/99-chunk-status-read-failures -- src/gdalcubes/src/cube.cpp`.

### Phase 1: Branch and port
- [ ] Cut `chunk-status-read-back` off `origin/chunk-status-read-failures`. No `planning/` or CLAUDE.md commits on it; PWF files are excluded via `.git/info/exclude`.
- [ ] Apply the `cube.cpp` hunks from `origin/99-chunk-status-read-failures` (diff the file to the branch tip, then `git apply`), changing nothing in them.
- [ ] NEWS.md: extend the branch's existing `chunk_status` line to cover a worker chunk file the main process cannot read back.

### Phase 2: Trigger and test
- [ ] `inst/tinytest/test_chunk_readback.R`, Unix only. Set up 2 workers through `gc_set_process_execution()`, as `test_worker_failure.R` does. Worker 1 is a stand-in script that writes bad files for its chunks (1, 3) and exits 0. The cube is a `.raster_cube_dummy()` with 4 chunks. Cases:
  - not a netCDF file → `nc_open` fails;
  - a netCDF file with `chunk_status = 0` and the x/y/t/b dimensions but no `value` variable → variable lookup fails;
  - a netCDF file with `chunk_status = 0` and no x/y/t/b dimensions → dimension lookup fails;
  - if reachable: a compressed netCDF-4 `value` whose data bytes are corrupted → `nc_get_var_double` fails. If R cannot reach this case, say so in the test file and in findings.
- [ ] Assert that chunk_status = 1 (ERROR) for the stand-in's chunks and 0 for worker 0's chunks, and that worker 0's cells hold the data.
- [ ] Show the test fails without the hunks (stash `cube.cpp`, rebuild, run) and passes with them.
- [ ] Run #114's `test_chunk_status.R` and the full suite on the branch.
- [ ] `/code-check`, then commit the fix and the test.

### Phase 3: Merge into newgraph
- [ ] Push the branch to origin. Open a fork PR (`-R NewGraphEnvironment/gdalcubes`, `--base newgraph`) whose body is the drafted #114 addition (a short paragraph plus a reprex for the read-back case) above a `---` footer.
- [ ] Merge into `newgraph` (merge commit), resolving NEWS.md. Rebuild `newgraph` and run the full suite.

### Phase 4: Downstream check
- [ ] Install `NewGraphEnvironment/gdalcubes@newgraph`. Run drift's gdalcubes-dependent tests, then flooded's full suite.

### Phase 5: Update appelmar/gdalcubes#114 (only on the user's explicit go)
- [ ] Show the user the test result and the drafted text.
- [ ] `git push origin chunk-status-read-back:chunk-status-read-failures`, a fast-forward with no force. Check that `gh pr view 114 -R appelmar/gdalcubes --json headRefOid` equals the branch tip.
- [ ] Append the drafted paragraph and reprex (footer stripped) to #114's existing body with `gh pr edit 114 -R appelmar/gdalcubes --body-file`. Do not rewrite the existing text, and do not comment on the PR.
- [ ] Comment on #9 with what was pushed and the head SHA, close #9 by hand, and update drift#99's table if it changes.

## Validation

- [ ] Tests pass
- [ ] `/code-check` clean (each commit, or once over the branch with `/code-check branch`)
- [ ] PWF checkboxes match landed work
- [ ] `/planning-archive` on completion
