# Code Review — Round 2 (staged diff, filter_geom segfault fix)

Date: 2026-08-31
Scope: staged diff (`git diff --cached`) — NEWS.md, inst/tinytest/test_filter_geom.R (new),
src/gdalcubes/src/filter_geom.cpp. Focus per instructions: the RasterIO != CE_None guard
added since round 1; C++ error-path resource handling; R test determinism.

## Verdict: Clean

No real issues found. Details of what was verified, so the conclusion is auditable:

### RasterIO guard (filter_geom.cpp:297-303) — cleanup set is exactly right

Live resources at the point of the throw, and their disposition:

- `geom_mask` (malloc, line 296) — freed by the guard. Not double-freed: the later
  `std::free(geom_mask)` at line 316 is unreachable after the throw.
- `gdal_rasterized` (GDALRasterize result, line 288) — closed by the guard. The later
  `GDALClose(gdal_rasterized)` at line 317 is unreachable after the throw.
- `in_ogr_dataset` (GDALOpenEx, line 172) — closed by the guard. The trailing
  `GDALClose(in_ogr_dataset)` at line 319 is unreachable after the throw.
- `rasterize_opts` — already freed unconditionally at line 289, before this guard;
  the guard correctly does not touch it. No leak, no double-free.
- `out`'s calloc'd buffer — intact on the throw path: `out->size(...)` (line 246) is set
  before `out->buf(...)` (line 247), and `chunk_data::~chunk_data()` (cube.h:278-280)
  frees `_buf` when the size product is > 0. The `std::shared_ptr<chunk_data> out`
  destructor runs during stack unwinding and reclaims the buffer. `chunk_data::buf()`
  documents ownership transfer (cube.h:333), so no double ownership exists.
- `in` (shared_ptr from `_in_cube->read_chunk`) — reclaimed by shared_ptr unwinding.
- `pp` / `a` (stack OGR objects) — safe now that no SRS is assigned to `pp` (the very
  use-after-destruction the diff removes).
- `cur_feature` — already destroyed at line 219, well before this point.

The guard also converts a previously *silent* failure into a loud one: before the diff,
a RasterIO error was only logged and execution continued into the mask loop reading an
uninitialized malloc'd `geom_mask` — a nondeterministic mask. Correct fix direction
(fails loud, not toward "skip").

### Other three guards

- `GetDriverByName("GPKG")` null (constructor, lines 127-130): correct; leak of heap
  geometry `p` is the accepted pre-existing constructor idiom.
- `GetNextFeature()` null (lines 205-209): closes `in_ogr_dataset`, throws. Nothing else
  heap-allocated at that point. Correct.
- `GDALRasterize()` null (lines 290-294): `GDALRasterizeOptionsFree` was correctly moved
  to run unconditionally before the check; guard closes `in_ogr_dataset` and throws.
  Previously a NULL result was only logged and then dereferenced at `GetRasterBand(1)`
  — this fixes a second latent segfault. `out`'s buffer is again reclaimed by the
  shared_ptr destructor.

### Core fix (removal of `assignSpatialReference`)

Verified semantics-preserving: `Contains()`/`Intersects()` dispatch to GEOS, which
ignores SRS entirely, and both geometries are already in the same CRS (the constructor
writes the GPKG layer in the cube's CRS, `srs_in`, line 136; the chunk rectangle `pp`
is built from cube coordinates). Removing the assignment eliminates the
`~OGRGeometry()` → `Release()` on a stack SRS destroyed earlier (declaration order:
`pp` before `srs_cube`, so `srs_cube` was destroyed first).

### R test (inst/tinytest/test_filter_geom.R)

- Discovery: matches tinytest's `test_*.R` pattern in `inst/tinytest/`;
  `tests/tinytest.R` runs `test_package("gdalcubes")` gated on R >= 4.1.0, consistent
  with the test's use of the native pipe.
- `.raster_cube_dummy(view, nbands, fill, chunking)` signature matches both calls
  (R/dummy.R:23), including `chunking = c(1, 50, 50)`.
- Determinism: dummy cube, no I/O beyond /vsimem and a tempfile ncdf; fill 1.0 is exact
  in double; polygon edges fall exactly on cell boundaries so no cell center is ever on
  an edge — the 100x100 = 10000 burned-cell count is stable under GDAL's center-in-poly
  rasterization rule. The polygon is centered in the cube, so every index assertion is
  invariant to y-axis orientation of `as_array` output. `dim.cube` returns (t, y, x) =
  (1, 200, 200) and `as_array` returns (band, t, y, x) — both match the expectations.
- Minor note, not a defect: the comment "single-chunk result" for the first cube is
  inaccurate — the default chunk size for a 200x200 cube at `parallel = 1` computes to
  192x192 (R/config.R:224-240), i.e. the first cube has 4 spatial chunks (polygon cells
  50-149 all fall in chunk (0,0)). Every assertion is chunk-layout-independent, and the
  x-vs-y comparison still meaningfully compares two different chunkings (192 vs 50),
  including the `Contains()` fast-copy path (chunks at 50-cell boundaries lie fully
  inside the polygon). No behavior or reliability impact.

### Accepted tradeoffs re-confirmed, not re-flagged

std::string throws + GCBS_ERROR idiom; constructor leaks of `p`/`gpkg_out` on throw;
unchecked malloc/calloc returns.
