# Code review, round 2: chunk-status-read-back

## Findings

- **[severity: fragile]** inst/tinytest/test_chunk_readback.R:19-38 (stand-in worker script), together with src/multiprocess.cpp:203-215
  The stand-in never creates `worker_1.log` (the real worker gets it from `gdalcubes_options(log_file = ...)` in worker.R). On this branch, `apply()` reads every worker's log whenever `_debug || any_failed` with `while (!wlogf.eof()) getline(...)`. On a missing file the stream is in a failed state and never reaches eof, so the loop spins forever. In this test, any worker failure therefore hangs the test run (R CMD check) instead of failing: worker 0 failing to load jsonlite or gdalcubes, an ncdf4 error in the stand-in, or a non-zero exit.
  - Verified: a 5-line C++ program with that loop on a missing file never exits. A forced worker-1 failure returned only because the installed gdalcubes is from `newgraph` (RemoteSha 2fad187), which includes 58dddb9 "Fix hang when a worker dies before writing its log". That fix is on the `worker-log-hang` branch, not on this branch or master. Under R CMD check the package is built from this branch, so the hang applies.
  - Fix: make the stand-in's first statement `file.create(j$gdalcubes_options$log_file)` (or create it in the worker_id == 1 block), or land worker-log-hang first.

- **[severity: fragile]** inst/tinytest/test_chunk_readback.R:51 (`cmd = ... " --vanilla ..."`)
  The default worker command (R/zzz.R:34) uses `--no-save --no-restore`. `--vanilla` also adds `--no-environ --no-site-file --no-init-file`. If a library path comes from ~/.Renviron, Renviron.site or a project .Rprofile (renv), the child cannot load jsonlite, gdalcubes or ncdf4. The rest of the suite, which uses the default worker, passes in that setup. Combined with the finding above, this becomes a hang rather than an error. CI and this machine are not affected: setup-r exports R_LIBS_USER as an environment variable, and there is no ~/.Renviron R_LIBS or Renviron.site here. Using `--no-save --no-restore` matches production.

## Checked, no issue

- cube.cpp read_ncdf: ERROR is set after the attribute read on every early-return path, so a worker's chunk_status = 0 cannot mask the failure. The nc_get_var_double failure path frees the buffer through `buf(nullptr)` while size is still non-zero (cube.h:335-337), then zeroes size, so there is no leak or double free in ~chunk_data. The empty-chunk path now closes the file (it used to leak the handle). Callers: only multiprocess.cpp:129. The only status consumer is the write_ncdf callback (cube.cpp:966-971). Other apply() callbacks ignore status, and the empty buffer is the same as before, so nothing regresses.
- `nc_inq_dimid` and `nc_inq_varid` leave the id untouched on failure, so the `< 0` checks hold.
- Round-1 fixes are correct:
  - Header now says workers write netCDF-4. USE_NCDF4 is defined as 1 except on Solaris (cube.cpp:38-45), and chunk_data::write_ncdf uses NC_NETCDF4 (cube.cpp:1818).
  - ncdf4 and jsonlite are both in DESCRIPTION Imports, so removing the guards is safe.
  - The removed `900` assertion was vacuous: none of the three kinds reaches the buffer allocation.
- Test premises:
  - Chunk assignment is `i = pid; i += nworker` (multiprocess.cpp:235), so worker 1 owns chunks 1 and 3, which are R indices 2 and 4.
  - `.broken_<id>.nc` temporaries are skipped because stoi throws on the leading dot.
  - Mapping int fill to 0 fails toward fail for the ERROR assertions, and the 800-cell value assertion covers the clean chunks.
  - Each kind proves its own branch (3/9 fail without the fix).
  - Global state: gdalcubes_options(parallel = ...) restores the processor from .pkgenv, and the env vars are unset in on.exit.
