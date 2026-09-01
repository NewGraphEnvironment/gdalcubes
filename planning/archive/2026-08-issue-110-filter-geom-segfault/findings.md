# Findings — Segfault in filter_geom() on compute (appelmar/gdalcubes#110)

## Issue context

Filed upstream by NewGraphEnvironment: appelmar/gdalcubes#110

`filter_geom()` crashes R with a segfault when the cube is computed. The same cube writes fine without it. It happens with any geometry — even a plain rectangle — so it doesn't look shape-related.

### Environment
gdalcubes 0.7.4 (CRAN) · R 4.5.2 · macOS 15.6.1 (arm64) · GDAL 3.8.5 · PROJ 9.5.1 · GEOS 3.13.0

### Reproducible example (no network needed)
```r
library(gdalcubes); library(sf); library(terra)

# a small local raster
r <- terra::rast(nrows = 200, ncols = 200, xmin = 5e5, xmax = 502000,
                 ymin = 6e6, ymax = 6002000, crs = "EPSG:32610")
terra::values(r) <- 1L
f <- tempfile(fileext = ".tif"); terra::writeRaster(r, f, datatype = "INT1U")

col  <- create_image_collection(f, date_time = "2020-01-01", band_names = "b1")
v    <- cube_view(srs = "EPSG:32610", dx = 10, dy = 10, dt = "P1D",
                  extent = list(left = 5e5, right = 502000, bottom = 6e6, top = 6002000,
                                t0 = "2020-01-01", t1 = "2020-01-01"))

write_ncdf(raster_cube(col, v), tempfile(fileext = ".nc"))   # works

# add a plain rectangle clip -> crash
box <- st_sfc(st_polygon(list(rbind(
  c(500500, 6000500), c(501500, 6000500),
  c(501500, 6001500), c(500500, 6001500), c(500500, 6000500)))), crs = 32610)
write_ncdf(filter_geom(raster_cube(col, v), box), tempfile(fileext = ".nc"))   # *** caught segfault ***
```

### What happens
```
*** caught segfault ***
address 0x120, cause 'invalid permissions'
 1: gdalcubes:::gc_exec_worker(...)
[ERROR] worker process #0 returned 11
```

### Expected
The cube clipped to the polygon (same as without `filter_geom()`, masked to the shape).

## Repo / version facts

- Local repo `NewGraphEnvironment/gdalcubes` is at 0.7.2; upstream `v0.7.2...master` diff does NOT touch filter_geom code — the buggy code is identical here, fix can be developed on this repo.
- Crash is in the spawned worker process (`gc_exec_worker`, `src/multiprocess.cpp` / `src/gdalcubes.cpp`); workers rebuild the cube from a serialized JSON graph.
- Address 0x120 with "invalid permissions" smells like a member access through a null/garbage object pointer (offset 0x120 from null).
- Related open upstream issue: appelmar/gdalcubes#82 — `filter_geom` example produces an *empty result* on Windows. Windows also uses the separate-process worker path; plausibly the same mechanism (geometry lost/never applied in worker).

## Test conventions

- tinytest; files at `inst/tinytest/test_*.R`, driver `tests/tinytest.R`
- Pattern (see `inst/tinytest/test_crop.R`): `gdalcubes:::.raster_cube_dummy(v, nbands, fill)` |> operator |> `as_array()` to force compute; `expect_equal` on dims/values
- No `test_filter_geom.R` exists yet

## Code-path exploration (2026-08-31)

### Why "worker only" is not diagnostic
- `read_chunk()` **never runs in the parent**: `chunk_processor_multiprocess` is installed unconditionally at package load (`R/zzz.R:36` → `src/gdalcubes.cpp:1697-1719`), and `apply()` always spawns OS processes, even for 1 worker (`src/multiprocess.cpp:48-81`).
- "worker process #0 returned 11" is the **raw waitpid status** passed through by tiny-process-library (`process_unix.cpp:290-303`) → a genuine SIGSEGV, not a thrown C++ exception (those exit 1).

### filter_geom mechanics (all sound)
- State is strings only: `_wkt`, `_srs`, `/vsimem` GPKG path (`filter_geom.h:72-81`); no pointer members.
- JSON round-trip is faithful: `make_constructible_json()` writes wkt+srs (`filter_geom.h:63-70`), factory re-runs the same constructor (`cube_factory.cpp:193-197`). Worker rebuilds its own vsimem GPKG.
- Worker init is symmetric with parent (`inst/scripts/worker.R`, `gc_init` → `config::gdalcubes_init()` with `GDALAllRegister()`, `config.cpp:125-179`). Nothing left null by the rebuild.

### ⭐ Primary root-cause candidate: stack-SRS use-after-destruction
`src/gdalcubes/src/filter_geom.cpp:182-193` in `read_chunk()`:
```cpp
OGRPolygon pp;                                            // :182
OGRSpatialReference srs_cube = st_reference()->srs_ogr(); // :185  stack object
pp.addRing(&a);                                           // :192
pp.assignSpatialReference(&srs_cube);                     // :193  refcount++ (polygon + cloned ring)
```
- `assignSpatialReference` takes **refcounted ownership**; `~OGRGeometry` calls `poSRS->Release()`, and `Release()` does `delete this` at refcount 0 — so handing it a **stack** `OGRSpatialReference` is inherently wrong (mere declaration reordering is NOT a fix: `~pp` would then `delete` the stack object).
- Declaration order makes it a UAF today: `srs_cube` (declared after `pp`) is destroyed **first** at every scope exit (`:214`, `:228`, `:305`, throw at `:275`); then `pp`'s and its ring's destructors write `Private::nRefCount` through the freed pimpl.
- Matches every symptom: fires for any polygon on the first non-skipped chunk; `SEGV_ACCERR` ("invalid permissions") = write into freed/decommitted heap; fault address 0x120 ≈ `nullptr + offsetof(OGRSpatialReference::Private, nRefCount)` (~288 bytes of PJ*/CPLStrings before it); latent on GDAL 2.x (pre-pimpl), armed by GDAL 3's pimpl move.
- This is the **only** `assignSpatialReference` call in the entire codebase — which is why only `filter_geom` crashes.
- The two GEOS predicates `geom->Contains(&pp)` / `Intersects(&pp)` (`:202`, `:205`) do not use the SRS at all → dropping the assignment is a candidate minimal fix; alternative is heap SRS + `Release()` after assignment (geometry takes ownership).

### Secondary hardening sites (fault at 0x0/0x8, not the reported 0x120)
- `filter_geom.cpp:199-200` — `layer->GetNextFeature()` unchecked, immediately dereferenced ("assumption, there is only one feature"). Plausible mechanism for upstream #82's empty/odd results.
- `filter_geom.cpp:278-286` — `GDALRasterize()` NULL is logged but execution **falls through** to `gdal_rasterized->GetRasterBand(1)->RasterIO(...)`.
- `filter_geom.cpp:126-127` — `GetDriverByName("GPKG")` unchecked before `->Create()` (constructor side; would also fail in parent).
- `filter_geom.cpp:92` — `transformTo()` return unchecked (explicit TODO; skipped in the repro since SRS matches).

### Root cause CONFIRMED (2026-08-31)

- Repro on local dev build (0.7.4 source, GDAL 3.13.3): baseline `write_ncdf` OK, `filter_geom` → worker SIGSEGV at **0x138** "invalid permissions" (issue reported **0x120** on GDAL 3.8.5 — the fault offset tracks `offsetof(OGRSpatialReference::Private, nRefCount)` across GDAL versions, corroborating the mechanism).
- Removing the `assignSpatialReference(&srs_cube)` (stack SRS) at `filter_geom.cpp:185/:193` eliminates the crash; output verified correct: inside cells = 1, outside = NaN, exactly 10000 non-NA cells for a 100×100-cell polygon, and 50×50 chunking (exercising the Contains fast path) gives an identical mask.
- Fix applied: drop the SRS assignment (predicates ignore SRS) + defensive null checks: `GetDriverByName("GPKG")` (constructor), `GetNextFeature()`, `GDALRasterize()` fall-through (read_chunk).

### History / env notes
- Crash lines unchanged since the C++ codebase was integrated (`cb6f4f3`); last functional touch `b9521ab` only added chunk-status propagation. `filter_geom` marked experimental; **zero tests exercise it**.
- This machine: `gdal-config` 3.13.3 + GEOS 3.13.x via Homebrew (issue reported GDAL 3.8.5). Record parent-vs-worker `gc_gdalversion()` during reproduction.
