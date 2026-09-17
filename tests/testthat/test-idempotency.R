# Idempotence: two runs on the same day produce the same data state.
#
# Synthetic data only: nothing here touches the network. Staging Parquet
# files are written by hand into a temporary directory, so the test
# exercises exactly the code path consolidate() takes in CI.

ref_date <- as.Date("2026-09-15")

make_staging <- function(dir, ref = ref_date, bump = 0L) {
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  dates <- seq(ref - 9L, ref, by = "day")
  pkgs <- c("pkgA", "pkgB")
  repos <- c("owner/pkgA", "owner/pkgB")

  arrow::write_parquet(
    tibble::tibble(
      date = rep(dates, times = length(pkgs)),
      package = rep(pkgs, each = length(dates)),
      downloads = as.integer(seq_len(length(dates) * length(pkgs))) + bump
    ),
    file.path(dir, "cran_downloads.parquet")
  )

  arrow::write_parquet(
    tibble::tibble(
      package = c("pkgA", "pkgA", "pkgB"),
      version = c("1.0", "1.1", "0.9"),
      release_date = as.Date(c("2026-01-10", "2026-08-01", "2025-12-25")),
      is_current = c(FALSE, TRUE, TRUE)
    ),
    file.path(dir, "cran_versions.parquet")
  )

  arrow::write_parquet(
    tibble::tibble(
      snapshot_date = rep(ref, 4L),
      package = rep(pkgs, each = 2L),
      version = c("1.1", "1.1", "0.9", "0.9"),
      flavor = rep(c("r-devel-linux", "r-release-macos"), 2L),
      status = c("OK", "NOTE", "OK", "OK"),
      check_time = c(10.5, 11.5, 9, 8)
    ),
    file.path(dir, "cran_checks.parquet")
  )

  arrow::write_parquet(
    tibble::tibble(
      snapshot_date = rep(ref, 2L),
      package = pkgs,
      on_cran = c(TRUE, TRUE),
      archived = c(FALSE, FALSE),
      maintainer = c("A <a@example.com>", "B <b@example.com>"),
      worst_status = c("NOTE", "OK")
    ),
    file.path(dir, "cran_status.parquet")
  )

  arrow::write_parquet(
    tibble::tibble(
      date = rep(dates, times = length(repos)),
      repo = rep(repos, each = length(dates)),
      commits = 1L, prs_opened = 0L, prs_merged = 0L, prs_closed = 0L,
      issues_opened = 0L, issues_closed = 0L
    ),
    file.path(dir, "gh_activity.parquet")
  )

  arrow::write_parquet(
    tibble::tibble(
      date = rep(dates, times = length(repos)),
      repo = rep(repos, each = length(dates)),
      views = 5L, view_uniques = 2L, clones = 3L, clone_uniques = 1L
    ),
    file.path(dir, "gh_traffic.parquet")
  )

  invisible(dir)
}

read_all <- function(data_dir) {
  files <- sort(list.files(data_dir, pattern = "\\.parquet$"))
  out <- lapply(files, function(f) {
    tibble::as_tibble(arrow::read_parquet(file.path(data_dir, f)))
  })
  names(out) <- files
  out
}

test_that("consolidate() writes the expected tables from staging", {
  root <- withr::local_tempdir()
  staging <- file.path(root, "staging")
  data_dir <- file.path(root, "data")
  make_staging(staging)

  report <- consolidate(staging, data_dir, reference_date = ref_date)

  expect_s3_class(report, "tbl_df")
  expect_true(all(
    c("table", "rows_before", "rows_after", "rollup", "pruned") %in% names(report)
  ))
  expect_equal(report$rows_before[report$table == "cran_downloads"], 0L)
  expect_equal(report$rows_after[report$table == "cran_downloads"], 20L)
  expect_true(file.exists(file.path(data_dir, "cran_downloads.parquet")))
  expect_true(file.exists(file.path(data_dir, "run_manifest.parquet")))

  # Tables nothing was staged for are neither created nor reported as staged.
  expect_true(is.na(report$staging_rows[report$table == "academic_works"]))
  expect_false(file.exists(file.path(data_dir, "academic_works.parquet")))
})

test_that("two runs on the same day do not duplicate or change any row", {
  root <- withr::local_tempdir()
  staging <- file.path(root, "staging")
  data_dir <- file.path(root, "data")
  make_staging(staging)

  run_ts <- as.POSIXct("2026-09-15 06:15:00", tz = "UTC")
  first <- consolidate(staging, data_dir, reference_date = ref_date, run_ts = run_ts)
  snap1 <- read_all(data_dir)

  second <- consolidate(staging, data_dir, reference_date = ref_date, run_ts = run_ts)
  snap2 <- read_all(data_dir)

  expect_identical(second$rows_after, first$rows_after)
  expect_identical(names(snap2), names(snap1))
  expect_equal(snap2, snap1)

  # The monthly archives are upserted, not appended, so they are stable too.
  arch1 <- read_all(file.path(data_dir, "archive"))
  consolidate(staging, data_dir, reference_date = ref_date, run_ts = run_ts)
  expect_equal(read_all(file.path(data_dir, "archive")), arch1)
})

test_that("run_manifest is keyed by (run_ts, source), so a later run appends", {
  root <- withr::local_tempdir()
  staging <- file.path(root, "staging")
  data_dir <- file.path(root, "data")
  make_staging(staging)

  consolidate(staging, data_dir,
    reference_date = ref_date,
    run_ts = as.POSIXct("2026-09-15 06:15:00", tz = "UTC")
  )
  n1 <- nrow(arrow::read_parquet(file.path(data_dir, "run_manifest.parquet")))

  consolidate(staging, data_dir,
    reference_date = ref_date,
    run_ts = as.POSIXct("2026-09-16 06:15:00", tz = "UTC")
  )
  n2 <- nrow(arrow::read_parquet(file.path(data_dir, "run_manifest.parquet")))

  expect_gt(n2, n1)
})

test_that("changed values replace rather than duplicate (last-write-wins)", {
  root <- withr::local_tempdir()
  staging <- file.path(root, "staging")
  data_dir <- file.path(root, "data")

  make_staging(staging)
  consolidate(staging, data_dir, reference_date = ref_date)
  before <- arrow::read_parquet(file.path(data_dir, "cran_downloads.parquet"))

  make_staging(staging, bump = 100L)
  consolidate(staging, data_dir, reference_date = ref_date)
  after <- arrow::read_parquet(file.path(data_dir, "cran_downloads.parquet"))

  expect_equal(nrow(after), nrow(before))
  expect_equal(sum(after$downloads), sum(before$downloads) + 100L * nrow(before))
})

test_that("consolidate() and export_json() survive a completely empty tree", {
  root <- withr::local_tempdir()

  report <- consolidate(
    file.path(root, "staging"), file.path(root, "data")
  )
  expect_s3_class(report, "tbl_df")
  expect_true(all(is.na(report$staging_rows)))
  expect_true(all(report$rows_after == 0L))

  out <- export_json(
    data_dir = file.path(root, "data"), output_dir = file.path(root, "json")
  )
  expect_equal(nrow(out), 10L)
  for (p in out$path) {
    expect_no_error(jsonlite::fromJSON(p))
  }
  meta <- jsonlite::fromJSON(file.path(root, "json", "meta.json"))
  expect_identical(meta$schema_version, 1L)
  expect_true(is.null(meta$latest_data_date) || is.na(meta$latest_data_date))

  overview <- jsonlite::fromJSON(file.path(root, "json", "overview.json"))
  expect_length(overview$packages, 0L)
})

test_that("export_json() emits valid JSON with ISO dates and no maintainer e-mail", {
  root <- withr::local_tempdir()
  staging <- file.path(root, "staging")
  data_dir <- file.path(root, "data")
  make_staging(staging)
  consolidate(staging, data_dir, reference_date = ref_date)

  out <- export_json(data_dir = data_dir, output_dir = file.path(root, "json"))
  expect_equal(nrow(out), 10L)
  expect_true(all(out$bytes > 0L))

  dl <- jsonlite::fromJSON(file.path(root, "json", "cran_downloads.json"))
  expect_match(dl$window_end, "^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
  expect_match(dl$generated_at, "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")
  expect_equal(sort(dl$series$package), c("pkgA", "pkgB"))
  expect_match(dl$series$points[[1]]$date[1], "^[0-9]{4}-[0-9]{2}-[0-9]{2}$")

  st <- jsonlite::fromJSON(file.path(root, "json", "cran_status.json"))
  expect_false(any(grepl("@", st$status$maintainer)))

  fresh <- jsonlite::fromJSON(file.path(root, "json", "freshness.json"))
  expect_true(all(fresh$sources$status %in% c("ok", "partial", "failed")))
  expect_false(anyDuplicated(fresh$sources$source) > 0L)
})

test_that("make_badges() writes the shields.io endpoint schema", {
  root <- withr::local_tempdir()
  staging <- file.path(root, "staging")
  data_dir <- file.path(root, "data")
  make_staging(staging)
  consolidate(staging, data_dir, reference_date = ref_date)

  badges <- make_badges(data_dir = data_dir, output_dir = file.path(root, "badges"))
  expect_setequal(
    badges$slug,
    c(
      "pkgA-downloads", "pkgA-check", "pkgA-version",
      "pkgB-downloads", "pkgB-check", "pkgB-version"
    )
  )
  one <- jsonlite::fromJSON(badges$path[badges$slug == "pkgA-check"])
  expect_identical(one$schemaVersion, 1L)
  expect_identical(one$color, "yellow") # worst_status NOTE
  expect_match(one$message, "^NOTE")

  ver <- jsonlite::fromJSON(badges$path[badges$slug == "pkgA-version"])
  expect_identical(ver$message, "v1.1")
})
