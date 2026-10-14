library(gdalcubes)

# write_ncdf() records a per-chunk status in the output's `chunk_status` variable.
# A read that fails after its image has opened, and a mask image that fails to
# open or to read, must not be recorded as OK: the chunk is otherwise computed
# from the remaining images (or, for a failed mask, from unmasked pixels) with
# nothing to tell the caller.

chunk_status_fixture = function(break_what = "none") {
  v = cube_view(srs = "EPSG:32609",
                extent = list(left = 0, right = 400, bottom = 0, top = 400,
                              t0 = "2021-07-05", t1 = "2021-07-24"),
                dx = 10, dy = 10, dt = "P10D")
  d = tempfile(pattern = "chunk_status_")
  dir.create(d)
  # COG layout puts the IFD before the tile data, so overwriting the end of the
  # file corrupts pixels while the file still opens
  co = list(COMPRESS = "DEFLATE")
  b = suppressMessages(write_tif(gdalcubes:::.raster_cube_dummy(v, 1, 500), d,
                                 prefix = "B04_", COG = TRUE, creation_options = co))
  m = suppressMessages(write_tif(gdalcubes:::.raster_cube_dummy(v, 1, 4), d,
                                 prefix = "SCL_", COG = TRUE, creation_options = co))
  fmt = file.path(d, "format.json")
  writeLines(c(
    '{"description": "chunk_status test", "tags": ["test"], "pattern": ".*\\\\.tif",',
    ' "images": {"pattern": ".*_([0-9-]{10})\\\\.tif"},',
    ' "datetime": {"pattern": ".*_([0-9-]{10})\\\\.tif", "format": "%Y-%m-%d"},',
    ' "bands": {"B04": {"pattern": ".*/B04_.*"}, "SCL": {"pattern": ".*/SCL_.*"}}}'), fmt)
  col = create_image_collection(c(b, m), format = fmt, out_file = file.path(d, "col.db"))

  # overwrite the start of the first tile's compressed stream, located from the
  # TileOffsets tag (324) of the first IFD of this little-endian classic TIFF
  corrupt = function(f) {
    con = file(f, "r+b")
    on.exit(close(con))
    stopifnot(identical(readBin(con, "raw", 2), charToRaw("II")))
    seek(con, 4)
    ifd = readBin(con, "integer", size = 4, endian = "little")
    seek(con, ifd)
    n = readBin(con, "integer", size = 2, signed = FALSE, endian = "little")
    tile = NA
    for (i in seq_len(n)) {
      tag = readBin(con, "integer", size = 2, signed = FALSE, endian = "little")
      seek(con, 6, origin = "current")
      val = readBin(con, "integer", size = 4, endian = "little")
      if (tag == 324) tile = val
    }
    stopifnot(!is.na(tile))
    seek(con, tile, rw = "write")
    writeBin(as.raw(rep(0xAB, 64)), con)
  }
  switch(break_what,
         band_read = corrupt(b[2]),
         mask_open = unlink(m[2]),
         mask_read = corrupt(m[2]),
         none = NULL)
  list(col = col, v = v, files = c(b, m))
}

chunk_status_of = function(fx, parallel) {
  old = gdalcubes_options()$parallel
  gdalcubes_options(parallel = parallel)
  on.exit(gdalcubes_options(parallel = old))
  out = tempfile(fileext = ".nc")
  raster_cube(fx$col, fx$v, mask = image_mask("SCL", values = c(8, 9)),
              chunking = c(1, 16, 16)) |>
    select_bands("B04") |>
    write_ncdf(out)
  nc = ncdf4::nc_open(out)
  on.exit(ncdf4::nc_close(nc), add = TRUE)
  st = as.vector(ncdf4::ncvar_get(nc, "chunk_status", raw_datavals = TRUE))
  st[st == -2147483647L] = 0L  # netCDF fill: no status written, i.e. OK
  st
}

for (p in c(1, 2)) {
  expect_true(all(chunk_status_of(chunk_status_fixture("none"), p) == 0),
              info = paste("clean read is OK, parallel", p))
  for (b in c("band_read", "mask_open", "mask_read")) {
    fx = chunk_status_fixture(b)
    if (b != "mask_open" && requireNamespace("sf", quietly = TRUE)) {
      # the corrupted file must still open, or this tests an open failure
      info = suppressWarnings(sf::gdal_utils("info", fx$files[if (b == "band_read") 2 else 4],
                                             quiet = TRUE))
      expect_true(length(info) == 1 && !is.na(info) && nzchar(info),
                  info = paste(b, "file still opens"))
    }
    expect_true(any(suppressWarnings(chunk_status_of(fx, p)) != 0),
                info = paste(b, "is not recorded as OK, parallel", p))
  }
}
