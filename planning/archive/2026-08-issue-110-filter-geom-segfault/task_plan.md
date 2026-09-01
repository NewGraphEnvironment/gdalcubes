# Task: Fix segfault in filter_geom() on compute (appelmar/gdalcubes#110)

`filter_geom()` crashes R with a segfault when the cube is computed (worker process SIGSEGV, "address 0x120, cause 'invalid permissions'"). Any geometry triggers it, even a plain rectangle in the cube's own SRS. Root-cause candidate from code exploration: `read_chunk()` hands a **stack** `OGRSpatialReference` to `OGRPolygon::assignSpatialReference()` (refcounted ownership) at `src/gdalcubes/src/filter_geom.cpp:182-193` — a use-after-destruction on every scope exit under GDAL 3.

Branch: `110-segfault-in-filter-geom-on-compute` off `newgraph`; PR targets `newgraph`. PWF files stay untracked here (`.git/info/exclude`) and are ported to `newgraph`.

## Phase 1 — Reproduce

- [x] Build and install the dev package into an isolated library (scratch `R_LIBS`) so the user's installed gdalcubes is untouched
- [x] Run the issue #110 repro script; confirm the segfault (worker exit 11) on 0.7.4 source (after syncing master to upstream)
- [x] Record parent vs worker GDAL/GEOS/PROJ versions (`gdalcubes:::gc_gdalversion()`) in findings.md

## Phase 2 — Confirm root cause

- [x] Minimal-patch experiment: drop/neutralize the `assignSpatialReference(&srs_cube)` at `filter_geom.cpp:193`, rebuild, rerun repro — crash gone confirms the UAF
- [x] ~~lldb backtrace~~ skipped — behavioral confirmation + version-dependent fault-offset shift (0x120 on GDAL 3.8.5 vs 0x138 on 3.13.3) is sufficient evidence
- [x] Document confirmed mechanism in findings.md

## Phase 3 — Fix

- [x] Real fix in `read_chunk()`: remove the SRS assignment on `pp` (the `Contains`/`Intersects` predicates at `:202`/`:205` ignore SRS) — or, if SRS must be kept, heap-allocate the SRS and `Release()` after assignment so the geometry owns it. NOT a declaration reorder (that makes `~pp` `delete` a stack object)
- [x] Defensive null checks with proper error throws at the secondary sites: `GetNextFeature()` (`:199`), `GDALRasterize()` fall-through (`:278-286`), `GetDriverByName("GPKG")` (`:126`)
- [x] Rebuild, rerun repro: output netCDF written and masked to the polygon (compare against unfiltered write)

## Phase 4 — Regression test

- [x] Add `inst/tinytest/test_filter_geom.R` following `test_crop.R` pattern: `.raster_cube_dummy()` |> `filter_geom()` (WKT rectangle + sfc input) |> `as_array()`; assert dims, inside-polygon values, outside-polygon NA
- [x] Run full tinytest suite locally — all green

## Phase 5 — Wrap-up

- [x] NEWS.md entry for the fix
- [x] `/code-check` clean on the staged diff; atomic commits (code only — no CLAUDE.md, no planning/)
- [ ] Port PWF artifacts to `newgraph`, then `/planning-archive`
- [ ] `/gh-pr-push` — PR base `newgraph`
- [ ] Optional (user decision): comment on upstream appelmar/gdalcubes#110 with root cause + patch reference

## Validation

- [x] Repro script passes (no segfault, correct masked output)
- [x] Tests pass
- [x] `/code-check` clean on each commit
- [x] PWF checkboxes match landed work
- [ ] `/planning-archive` on completion
