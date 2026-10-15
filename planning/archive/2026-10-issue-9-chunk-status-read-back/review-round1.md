# Code review, round 1: chunk-status-read-back

## Clean

I found no issues that would cause failures, security problems or data loss.

## What was checked

- `src/gdalcubes/src/cube.cpp` `chunk_data::read_ncdf()`:
  - Every early return now sets ERROR and closes the file handle. The empty-chunk return used to leak the handle; it now closes it.
  - In the `nc_get_var_double()` failure branch, `buf(nullptr)` frees the malloc'd buffer, because `_size` is still non-zero at that point. `size({0,0,0,0})` then makes `empty()` true, so the write callback (cube.cpp:974) skips the merge. There is no double free: the destructor sees a null `_buf`.
  - The `||` chain over `nc_inq_dimlen()` short-circuits, so a dimension length is never read after an earlier failure.
- Caller (`src/multiprocess.cpp:121-140`): `read_ncdf()` does not throw (`GCBS_ERROR` only logs), so the chunk still reaches `f()`. The callback writes status 1 and increments `chunk_error_count`. The file is still removed.
- Status consumers: the write callback casts `dat->status()` to an int and counts any non-OK status. With the change, ERROR reaches the output instead of OK. No consumer raises on ERROR.
- Real worker files: `exec()` writes `.<id>.nc` and then renames it, so the main process never reads a half-written file. A real empty chunk with a non-OK status is written with zero-length dimensions plus the `value` variable. On netCDF-4 (every platform except Solaris) it reads back through the "chunk is empty" path, which keeps the worker's INCOMPLETE status, so the new ERROR overrides do not change it.
- Test `inst/tinytest/test_chunk_readback.R`:
  - Chunk ids 1 and 3 match worker 1's stride in `exec()` (pid, then += nworker).
  - The stand-in's `.broken_<id>.nc` temp names are rejected by `std::stoi`, so the main process never picks them up early.
  - The `on.exit` restores the default worker. `gdalcubes_options(parallel = ...)` calls `gc_set_process_execution()` again with `.pkgenv$worker.cmd`, and the env vars are unset.
  - The status fill mapping (`-2147483647` -> 0) only applies to the clean-chunk positions. Mapping fill to 0 cannot make the ERROR assertions pass. The values assertion (800 cells of 500) independently covers the case where a clean chunk is lost.
- `test_chunk_status.R` ncdf4 guard: harmless.

## Non-blocking notes (not defects)

1. **The ncdf4 guard can never fire.** ncdf4 is in DESCRIPTION `Imports:` (line 53), not missing from Suggests as the brief stated. The `requireNamespace("ncdf4")` guards in both test files are redundant but harmless; they do not silently skip.
2. **The comment in the test header misstates the worker file format.** It says workers write "classic-format" files at compression level 0. But `chunk_data::write_ncdf()` (cube.cpp:1811-1815) always calls `nc_create(..., NC_NETCDF4)` when `USE_NCDF4 == 1`, which is every platform except Solaris. The compression level does not affect the format. The conclusion still holds, since a damaged netCDF-4 file fails at `nc_open()`, so the `nc_get_var_double` branch stays unreachable from here. Only the stated reason is off.
3. **The "never merged as data" assertion cannot fail.** The `expect_false(any(values == 900))` assertion is vacuous for all three kinds, because none reaches the data read. This is consistent with the accepted, documented gap.
4. **Solaris only (`USE_NCDF4 == 0`).** An empty chunk with a non-OK status is written in the classic model with four zero-length (unlimited) dimensions. Classic format allows only one unlimited dimension, so the file lacks `t`/`y`/`x`. `read_ncdf()` now reports such a chunk as ERROR where it used to keep the worker's INCOMPLETE. Both are non-OK and counted the same way, so nothing is lost; only the INCOMPLETE/ERROR distinction blurs on that platform.
