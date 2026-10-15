# Archive: chunk read-back failures recorded as ERROR (#9, appelmar/gdalcubes#114)

## Outcome

Ported the `chunk_data::read_ncdf()` hunks that were dropped when fork PR #2 was
split, so a worker chunk file the main process cannot read back (not netCDF, no
x/y/t/b dimensions, no `value` variable, a failed `nc_inq_dimlen` or
`nc_get_var_double`) is recorded as ERROR instead of an OK chunk of NA or of an
uninitialised buffer. The trigger needs no C++ fault injection: a stand-in worker
script swapped in through `gc_set_process_execution()` writes broken `<id>.nc`
files for its round-robin chunks while worker 0 runs normally as the control.
Each opened test file must carry `chunk_status = 0`, otherwise the missing
attribute already yields UNKNOWN and the test passes without the fix. Learned:
workers write netCDF-4, so the `nc_get_var_double` branch is unreachable from R
(truncation fails at `nc_open`, damaged data bytes read back without error); a
stand-in worker must create its log file up front, because without #113's fix the
main process waits forever for a missing log; and test builds need `R_LIBS` so
worker processes load the build under test. Follow-up candidate: the worker's own
netCDF writes, `nc_close` and `CPLMoveFile` are unchecked, so a worker can corrupt
its own chunk file silently.

## Measurement

- New `test_chunk_readback.R`: 3/9 fail without the hunks, 9/9 pass with them.
- Full suite: 169/169 on `chunk-status-read-back`, 174/174 on `newgraph` after merge.
- Read-back reprex `chunk_status`: `0 0 0 0` on #114's old tip, `0 1 0 1` with the fix.
- Forced worker failure in the test: hung 60 s before the log fix, errors in 1 s after.
- Downstream on the `newgraph` build: drift gdalcubes tests 590 pass / 0 fail / 10 skip; flooded 578/578.
- code-check: 3 rounds, ended on an enumeration of 13 places (round 3).

Closed by: commit 457ed5f / fork PR NewGraphEnvironment/gdalcubes#10 (merged into
`newgraph` as 20cda4f) / upstream https://github.com/appelmar/gdalcubes/pull/114
(head 457ed5f)
