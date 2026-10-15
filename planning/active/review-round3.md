# Review round 3: chunk-status-read-back

Scope: diff.patch (NEWS.md, src/gdalcubes/src/cube.cpp read_ncdf, inst/tinytest/test_chunk_readback.R),
read against src/multiprocess.cpp, inst/scripts/worker.R, R/config.R, R/zzz.R, cube.h chunk_data,
the write_ncdf merge callback (cube.cpp ~963-1112), and TinyProcessLib try_get_exit_status.

## Mechanism

The R1/R2 defects share one cause: **the worker protocol is reconstructed twice, and each
copy is checked only where its author thought to look.**

1. **Per-process build resolution.** The main process, the real worker 0 (`library(gdalcubes)`
   and `system.file("scripts/worker.R")` inside the child) and the stand-in each find
   gdalcubes through their *own* `.libPaths()`. The user default library holds the `newgraph`
   build, which carries worker-log-hang. Any run where the main process got that library
   hid the hang at multiprocess.cpp:205-216, a hang this branch still has.
2. **Partial imitation.** The stand-in matches the main process only on the protocol items
   its author listed. Each item missing from that list (R2: log file existence, command
   flags) diverged silently and passed, because the environment covered for it.

Every place this reaches, measured or traced:

| # | Place | Status |
|---|-------|--------|
| 1 | read_ncdf (the code under test) runs in the main process, built from main's `.libPaths()` | **Handled.** Measured: R_LIBS=lib_fix 9/9 pass. lib_nofix 3/9 fail. Installed newgraph (lacks the read-back fix) 3/9 fail. Every build layout fails in the safe direction. |
| 2 | Log loop `while(!wlogf.eof())` (multiprocess.cpp:205-216, main build) on a missing log | **Handled** for any worker failure after stand-in line 4, because both workers create their log first. **Not handled** for a death before line 4 (`jsonlite::fromJSON` fails, Rscript startup failure, signal at startup). Probed on lib_fix with a stand-in that quits before `file.create`: hung until the 25 s timeout. This is pre-existing upstream behaviour. The real worker has the same exposure on every test in the suite, and worse, since it logs nothing unless something is logged. Fixed by worker-log-hang. Not introduced by this diff. |
| 3 | Worker 0's gdalcubes build (`system.file`/`library` in the child) can differ from main's under load_all, or when R_LIBS does not carry the tested lib | **Handled.** It only writes the clean control chunks, and the chunk file format is the same across builds. If gdalcubes is missing, worker 0 errors after its log exists, so the run fails loudly instead of hanging. The default worker has the same dependency. |
| 4 | Log path: stand-in uses `j$gdalcubes_options$log_file`. Main hard-codes `join(work_dir, "worker_<pid>.log")` (multiprocess.cpp:58 vs :205, "TODO: take path from JSON") | **Handled.** Both come from the same `work_dir`, so the paths match today. |
| 5 | Chunk ownership: stand-in hard-codes stride 2 starting at 1, plus `GCBS_TEST_NCHUNKS`. Test hard-codes `gc_set_process_execution(2, ...)` and `nchunks = 4`. Real `exec()` uses `i = pid; i += nworker` | **Handled.** These agree today. A mismatch leaves a broken chunk unmerged, its status reads as fill, which maps to 0 and fails `c(1L, 1L)`. That is the safe direction. |
| 6 | File naming and atomicity: dot-temp then rename, and main skips dot-prefixed names (`stoi` throws) | **Handled.** The stand-in copies the real worker's dot-temp then `move`. |
| 7 | Exit status: worker 1 exits 0, like a successful real worker | **Handled.** |
| 8 | Command line `--no-save --no-restore` | **Handled.** Matches zzz.R:34 (R2 fix). |
| 9 | File format: the stand-in writes classic netCDF through ncdf4's default. The real worker writes netCDF-4 | **Handled** for what is asserted. nc_open, nc_inq_dimid and nc_inq_varid fail the same way in both formats. The nc_get_var_double branch stays unreachable (accepted). |
| 10 | Test maps fill -2147483647 to 0 | **Handled.** On the ERROR chunks, fill gives 0, which fails the test. On the clean chunks, fill would read as OK, but `sum(values == 500) == 800` requires both clean chunks to be merged with data. |
| 11 | Debug flag | **Handled.** The test passes FALSE. With TRUE, the log loop also runs on success, and both logs exist. |
| 12 | Restore | **Handled.** `on.exit` runs `gdalcubes_options(parallel = current)`, which re-installs `.pkgenv$worker.cmd` and the other `.pkgenv` worker settings. The test never mutates `.pkgenv`. The env vars are unset. |
| 13 | Child environment | **Handled.** TinyProcessLib is passed a nullptr environment, so children inherit `GDALCUBES_TEST_*`. Confirmed by passing runs. |

Residual, not a finding: row 2's pre-line-4 window. It exists only until worker-log-hang
merges, it is shared with every other worker-spawning test, and its triggers (an Imports
dependency missing at runtime, or a signal at startup) cannot happen in a sound check
environment.

## C++ (cube.cpp read_ncdf)

Traced every exit path. nc_open failure leaves the buffer null and size 0, so the chunk is
empty and only its ERROR status is written. A dimid, varid or dimlen failure closes the file
and returns ERROR. The `nx == 0` path now closes the file (this fixes a handle leak). On
nc_get_var_double failure, `buf(nullptr)` frees the buffer while size is still non-zero,
size is then zeroed, and the destructor sees a null buffer, so there is no double free.
The only caller is multiprocess.cpp:129, which still removes the file after the merge, so a
broken file is not re-read on later poll iterations. No issues.

## Clean

No issues found.
