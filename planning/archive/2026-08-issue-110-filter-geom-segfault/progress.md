# Progress — Segfault in filter_geom() on compute (appelmar/gdalcubes#110)

## Session 2026-08-31

- Located issue upstream (appelmar/gdalcubes#110, filed by NewGraphEnvironment); confirmed local 0.7.2 source matches upstream master for filter_geom code
- Created `newgraph` org base branch off `master`: CLAUDE.md (soul conventions, public-safe set), `.claude/visibility=public`, `planning/` structure, `.Rbuildignore` entries — commit 18dd451
- Created feature branch `110-segfault-in-filter-geom-on-compute` off `newgraph`
- PWF files kept untracked on feature branch via `.git/info/exclude` (repo convention: PWF ports to `newgraph`, never in PR diffs)
- Code-path exploration complete: primary root-cause candidate is a stack `OGRSpatialReference` handed to `assignSpatialReference()` in `filter_geom.cpp:182-193` (refcounted ownership → use-after-destruction under GDAL 3); details in findings.md
- Drafted task_plan.md phases (reproduce → confirm → fix → regression test → wrap-up); presented to user for approval
- User approved all phases through PR
- Phase 1: 0.7.2 source failed to compile against local GDAL 3.13.3 (`GetMetadata` → `CSLConstList`); upstream fixed this in the 0.7.4 line → fast-forwarded `master` to `upstream/master` (2cc0d46, v0.7.4 RC), rebased `newgraph` (now 42ab0ae), re-pointed feature branch. filter_geom code unchanged by the sync
- Deps installed into scratch Rlib: BH, tinytest, jsonlite; sf/terra/ncdf4 available in user lib
- Repro script (pure gdalcubes, no sf/terra: gdal_create raster + WKT string) at scratchpad/repro_110.R
- Reproduced segfault on dev 0.7.4 build (fault addr 0x138 on GDAL 3.13.3 vs issue's 0x120 on 3.8.5 — offset tracks GDAL's private SRS struct layout, corroborating root cause)
- Confirmed root cause: removing stack-SRS `assignSpatialReference()` eliminates crash; output verified correct (10000 masked cells, chunked fast path identical)
- Fix + 4 defensive guards (GPKG driver, GetNextFeature, GDALRasterize, RasterIO) in filter_geom.cpp; NEWS.md 0.7.5 entry
- Regression test inst/tinytest/test_filter_geom.R; full tinytest suite green (125+ results, all OK)
- /code-check: 2 rounds, both Clean (round 2 focused on the added RasterIO guard); paper trail in review-round1.md / review-round2.md
- Commits on feature branch: 67c3480 (fix + NEWS), 7c7cbf3 (regression test)
- Next: archive PWF to newgraph, then /gh-pr-push (base newgraph)
