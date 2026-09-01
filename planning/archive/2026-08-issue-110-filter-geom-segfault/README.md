# Archive: filter_geom() compute segfault (appelmar/gdalcubes#110)

## Outcome

Root-caused and fixed the segfault that crashed every computed `filter_geom()`
cube: `read_chunk()` handed a stack-allocated `OGRSpatialReference` to
`OGRPolygon::assignSpatialReference()`, which takes refcounted ownership and
`Release()`s it in `~OGRGeometry()` — a use-after-destruction under GDAL 3's
pimpl'd SRS (the fault address tracked `offsetof(Private, nRefCount)` across
GDAL versions: 0x120 on 3.8.5, 0x138 on 3.13.3, which clinched the diagnosis).
Fix drops the assignment (the OGR predicates ignore SRS) and closes out four
log-and-continue error paths in the same file. Added the first-ever test
coverage for `filter_geom()`. Key learnings: gdalcubes workers ALWAYS run in
separate processes (even 1 worker), so "crashes in worker only" is not
diagnostic — `read_chunk()` never runs in the parent; and `master` had to be
fast-forwarded to upstream v0.7.4 first because 0.7.2 no longer compiled
against GDAL 3.13. Likely also explains upstream #82 (Windows empty results).

Closed by: commits 67c3480 + 7c7cbf3 / PR NewGraphEnvironment/gdalcubes#1
(base `newgraph`) / upstream issue https://github.com/appelmar/gdalcubes/issues/110
