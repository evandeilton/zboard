# Retention order: rollup -> prune, in that order, and the prune is ABANDONED when the
# rollup of the period did not succeed in the same call.
#
# This guards the one failure that is low-probability but high-impact and
# irreversible: pruning traffic before its rollup is on disk. It is not enough
# to write the two steps in the right order and hope; the gate has to be
# forced to fail. `zb_rollup_monthly()` is replaced with a function that
# throws, and the test asserts that not a single daily row was removed.
#
# Synthetic data only; no network.

ref_date <- as.Date("2026-09-15")
old_date <- as.Date("2025-06-10") # well outside the 12-month window
in_date <- as.Date("2026-09-10") # inside it

stage_traffic <- function(dir) {
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  arrow::write_parquet(
    tibble::tibble(
      date = c(old_date, old_date + 1L, in_date),
      repo = "owner/repo",
      views = c(10L, 20L, 5L), view_uniques = c(4L, 8L, 2L),
      clones = c(1L, 2L, 3L), clone_uniques = c(1L, 1L, 2L)
    ),
    file.path(dir, "gh_traffic.parquet")
  )
  invisible(dir)
}

read_tbl <- function(dir, name) {
  path <- file.path(dir, paste0(name, ".parquet"))
  if (!file.exists(path)) {
    return(NULL)
  }
  tibble::as_tibble(arrow::read_parquet(path))
}

test_that("the rollup runs before the prune and both happen on a healthy run", {
  root <- withr::local_tempdir()
  staging <- file.path(root, "staging")
  data_dir <- file.path(root, "data")
  stage_traffic(staging)

  report <- consolidate(staging, data_dir, reference_date = ref_date)
  row <- report[report$table == "gh_traffic", ]

  expect_identical(row$rollup, "ok")
  expect_true(row$pruned)
  expect_equal(row$rows_pruned, 2L)

  daily <- read_tbl(data_dir, "gh_traffic")
  expect_equal(nrow(daily), 1L)
  expect_equal(daily$date, in_date)

  # The pruned period survives in the permanent monthly archive.
  monthly <- read_tbl(file.path(data_dir, "archive"), "gh_traffic_monthly")
  expect_equal(nrow(monthly), 2L)
  june <- monthly[monthly$month == as.Date("2025-06-01"), ]
  expect_equal(june$views, 30L)
  expect_equal(june$clones, 3L)
})

test_that("a failing rollup ABORTS the prune for that table", {
  root <- withr::local_tempdir()
  staging <- file.path(root, "staging")
  data_dir <- file.path(root, "data")
  stage_traffic(staging)

  testthat::local_mocked_bindings(
    zb_rollup_monthly = function(...) stop("forced rollup failure")
  )

  report <- suppressMessages(
    consolidate(staging, data_dir, reference_date = ref_date)
  )
  row <- report[report$table == "gh_traffic", ]

  expect_identical(row$rollup, "failed")
  expect_false(row$pruned)
  expect_equal(row$rows_pruned, 0L)

  # Nothing was removed: the daily rows are the only surviving copy.
  daily <- read_tbl(data_dir, "gh_traffic")
  expect_equal(nrow(daily), 3L)
  expect_true(old_date %in% daily$date)

  # And no archive was written.
  expect_null(read_tbl(file.path(data_dir, "archive"), "gh_traffic_monthly"))
})

test_that("the failure is confined to the table whose rollup failed", {
  root <- withr::local_tempdir()
  staging <- file.path(root, "staging")
  data_dir <- file.path(root, "data")
  stage_traffic(staging)
  arrow::write_parquet(
    tibble::tibble(
      date = c(old_date, in_date), package = "pkgA", downloads = c(7L, 9L)
    ),
    file.path(staging, "cran_downloads.parquet")
  )

  # Fail only for gh_traffic; let every other table roll up for real.
  real <- zb_rollup_monthly
  testthat::local_mocked_bindings(
    zb_rollup_monthly = function(tbl, df, archive_dir) {
      if (identical(tbl, "gh_traffic")) stop("forced rollup failure")
      real(tbl, df, archive_dir)
    }
  )

  report <- suppressMessages(
    consolidate(staging, data_dir, reference_date = ref_date)
  )

  expect_identical(report$rollup[report$table == "gh_traffic"], "failed")
  expect_false(report$pruned[report$table == "gh_traffic"])
  expect_identical(report$rollup[report$table == "cran_downloads"], "ok")
  expect_true(report$pruned[report$table == "cran_downloads"])

  expect_equal(nrow(read_tbl(data_dir, "gh_traffic")), 3L)
  expect_equal(nrow(read_tbl(data_dir, "cran_downloads")), 1L)

  # And the operator is told, in the manifest, which table was held back.
  man <- read_tbl(data_dir, "run_manifest")
  row <- man[man$source == "consolidate", ]
  expect_identical(row$status, "partial")
  expect_match(row$message, "gh_traffic")
})

test_that("permanent tables are never pruned and need no rollup", {
  root <- withr::local_tempdir()
  staging <- file.path(root, "staging")
  data_dir <- file.path(root, "data")
  dir.create(staging, recursive = TRUE)

  arrow::write_parquet(
    tibble::tibble(
      package = "pkgA", version = c("0.1", "1.0"),
      release_date = c(as.Date("2019-01-01"), as.Date("2026-08-01")),
      is_current = c(FALSE, TRUE)
    ),
    file.path(staging, "cran_versions.parquet")
  )
  arrow::write_parquet(
    tibble::tibble(
      repo = "owner/repo", tag = c("v0.1", "v1.0"), name = c("first", "latest"),
      published_at = as.POSIXct(c("2019-01-01 10:00:00", "2026-08-01 10:00:00"), tz = "UTC"),
      is_prerelease = c(FALSE, FALSE)
    ),
    file.path(staging, "gh_releases.parquet")
  )

  report <- consolidate(staging, data_dir, reference_date = ref_date)

  for (tbl in c("cran_versions", "gh_releases")) {
    row <- report[report$table == tbl, ]
    expect_identical(row$rollup, "skipped")
    expect_false(row$pruned)
    expect_equal(row$rows_pruned, 0L)
    expect_equal(nrow(read_tbl(data_dir, tbl)), 2L)
    expect_null(read_tbl(file.path(data_dir, "archive"), paste0(tbl, "_monthly")))
  }
})

test_that("the archive keeps months whose daily rows were pruned earlier", {
  root <- withr::local_tempdir()
  staging <- file.path(root, "staging")
  data_dir <- file.path(root, "data")
  stage_traffic(staging)

  # Run 1: the old month is rolled up, then its daily rows are pruned.
  consolidate(staging, data_dir, reference_date = ref_date)
  # Run 2: the old month is no longer visible in the daily table at all.
  unlink(file.path(staging, "gh_traffic.parquet"))
  consolidate(staging, data_dir, reference_date = ref_date)

  monthly <- read_tbl(file.path(data_dir, "archive"), "gh_traffic_monthly")
  expect_true(as.Date("2025-06-01") %in% monthly$month)
  expect_equal(monthly$views[monthly$month == as.Date("2025-06-01")], 30L)
})

test_that("the retention window is measured from reference_date", {
  root <- withr::local_tempdir()
  staging <- file.path(root, "staging")
  data_dir <- file.path(root, "data")
  stage_traffic(staging)

  # A 24-month window keeps everything the 12-month one would have pruned.
  report <- consolidate(
    staging, data_dir,
    reference_date = ref_date, retention_months = 24L
  )
  expect_equal(report$rows_pruned[report$table == "gh_traffic"], 0L)
  expect_equal(nrow(read_tbl(data_dir, "gh_traffic")), 3L)
})
