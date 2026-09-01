# Code review — round 1 (staged diff, segfault fix for appelmar/gdalcubes#110)

Reviewed: `git diff --cached` (NEWS.md, inst/tinytest/test_filter_geom.R,
src/gdalcubes/src/filter_geom.cpp), full files read, plus filter_geom.h,
R/dummy.R, R/cube.R, R/coerce.R, R/filter_geom.R, R/config.R, tests/tinytest.R,
DESCRIPTION, and cube.h (chunk_data ownership). Checklist classes applied:
silent failures, error-path resource handling, guards failing toward "skip",
test determinism.

## Clean

No issues found. No findings that meet the bar (real failure, security problem,
or data loss).

## Verification notes (what was checked and why it passes)

### Core fix (filter_geom.cpp:186-198)

- Removing `pp.assignSpatialReference(&srs_cube)` is correct. In the old code
  `srs_cube` was declared after `pp`, so it was destroyed first and
  `~OGRGeometry` then called `Release()` on a destroyed stack object
  (use-after-destruction). OGR's `Contains()`/`Intersects()` never consult the
  assigned SRS (no implicit reprojection in OGR), and both geometries are
  already in the cube SRS (the GPKG feature is transformed to `srs_in` in the
  constructor; `pp` is built from chunk bounds in cube coordinates), so
  dropping the assignment changes no behavior.

### New throw paths — resource cleanup

- `read_chunk`, `cur_feature == NULL` (filter_geom.cpp:205-209): calls
  `GDALClose(in_ogr_dataset)` before throwing. `pp`/`a` are stack objects with
  no SRS refcount attached anymore; `layer` is owned by the dataset. No leak.
- `read_chunk`, `gdal_rasterized == NULL` (filter_geom.cpp:288-294):
  `GDALRasterizeOptionsFree(rasterize_opts)` was correctly moved to before the
  NULL check (options are dead after the `GDALRasterize` call either way), and
  the throw path closes `in_ogr_dataset`. The calloc'd output buffer is owned
  by the `out` shared_ptr; `chunk_data::~chunk_data` (cube.h:278-280) frees it
  because `out->size(...)` is set before `out->buf(...)`, so its size product
  is nonzero. No leak.
- This throw also fixes a second latent segfault: the old code only logged
  `GCBS_ERROR("gdal_rasterize failed ")` and then dereferenced the NULL
  `gdal_rasterized->GetRasterBand(1)` unconditionally.
- Constructor, `gpkg_driver == NULL` (filter_geom.cpp:127-130): this throw
  leaks the heap geometry `p` (destroyed only at line 151). Not reported as a
  finding: every pre-existing throw in the same constructor (lines 111-114,
  132-135, 137-140, 145-148) has the identical behavior (several also leak
  `gpkg_out`/`geom_feature_out`), it is a one-shot fatal path that propagates
  to R and aborts the operation, and a GDAL build without the GPKG driver is
  effectively unusable for this package anyway. Consistent with codebase idiom.
- `_ogr_dataset` is assigned before the driver check, but the destructor
  (filter_geom.h:53-59) guards on `filesystem::exists()`, so a throw before the
  /vsimem file is created is harmless.

### Test determinism (inst/tinytest/test_filter_geom.R)

- API usage verified against sources: `.raster_cube_dummy(view, nbands, fill,
  chunking)` (R/dummy.R:23) accepts the `chunking` argument used;
  `dim.cube` returns `size(x)` = (t, y, x) (R/cube.R:424), matching
  `c(1, 200, 200)`; `as_array` returns (band, t, y, x) (R/coerce.R:100);
  `filter_geom(cube, geom, srs)` matches the piped call. ncdf4 is in Imports;
  tests/tinytest.R runs all inst/tinytest files and already guards the native
  pipe on R >= 4.1.0.
- Geometry is chunking- and orientation-invariant: polygon edges
  (500500/501500, 6000500/6001500) lie exactly on cell boundaries of the
  10 m grid anchored at 500000/6000000 (all coordinates exactly representable
  in doubles), so every cell center (…5 coordinates) is strictly inside or
  strictly outside — gdal_rasterize's center-inside burn rule is unambiguous
  and yields exactly 100x100 = 10000 cells regardless of chunk layout.
- The indexed assertions are robust to y-axis orientation: [10,10] and
  [190,190] are outside in the x dimension alone (x = 500095 / 501895), and
  [100,100] is inside for either y direction (y center 6001005 or 6000995,
  both within 6000500-6001500).
- The first cube is not actually a single chunk under defaults
  (`.default_chunk_size(1, 200, 200)` with parallel = 1 gives 192x192, i.e.
  4 chunks — the "single-chunk" comment is only prose), but no assertion
  depends on that: the mask is computed per chunk and is identical under any
  chunking, which is exactly what the final `expect_equal(is.na(x), is.na(y))`
  asserts. In the c(1,50,50) case the four interior chunks coincide exactly
  with the polygon; whether `Contains()` treats the shared boundary as
  contained (it does — closed-set containment with interiors intersecting) or
  not, the copy fast path and the rasterize path produce the same mask, so the
  comparison is deterministic either way, including on GDAL builds without
  GEOS (Contains -> false just forces the rasterize path).

### Out of scope (pre-existing, untouched by this diff)

- filter_geom.cpp:296-299: if `RasterIO` fails, the code only logs and then
  reads `geom_mask` — uninitialized `malloc` memory — as the mask, silently
  producing a nondeterministic mask (same "log-and-continue" class the diff
  fixes for `GDALRasterize`). Pre-existing behavior, not introduced or
  worsened here; noted for a possible follow-up, not a finding on this diff.
