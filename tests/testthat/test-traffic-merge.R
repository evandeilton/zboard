# gh_traffic merges by max() per (date, repo), never by
# last-write-wins.
#
# Why it matters: the GitHub traffic API returns a *partial* count for the
# current UTC day. A run at 06:15 that reports 3 views must not overwrite a
# previous value of 40 recorded later the same day, because the source is
# irrecoverable -- GitHub keeps 14 days and nothing more (S4.3, S10.4).
#
# Synthetic data only; no network.

ref_date <- as.Date("2026-09-15")

traffic <- function(dates, repo, views, view_uniques, clones, clone_uniques) {
  tibble::tibble(
    date = dates, repo = repo, views = as.integer(views),
    view_uniques = as.integer(view_uniques), clones = as.integer(clones),
    clone_uniques = as.integer(clone_uniques)
  )
}

test_that("zb_upsert() with merge = 'max' never lowers a numeric column", {
  d <- as.Date(c("2026-09-14", "2026-09-15"))
  old <- traffic(d, "owner/repo", c(40L, 12L), c(20L, 6L), c(9L, 4L), c(5L, 2L))
  new <- traffic(d, "owner/repo", c(3L, 30L), c(1L, 15L), c(1L, 11L), c(1L, 7L))

  out <- zb_upsert(old, new, keys = c("date", "repo"), merge = "max")

  expect_equal(nrow(out), 2L)
  expect_equal(out$views, c(40L, 30L))
  expect_equal(out$view_uniques, c(20L, 15L))
  expect_equal(out$clones, c(9L, 11L))
  expect_equal(out$clone_uniques, c(5L, 7L))
  expect_type(out$views, "integer")
})

test_that("merge = 'max' still inserts keys that are new", {
  old <- traffic(as.Date("2026-09-14"), "owner/repo", 40L, 20L, 9L, 5L)
  new <- traffic(as.Date("2026-09-15"), "owner/repo", 1L, 1L, 1L, 1L)

  out <- zb_upsert(old, new, keys = c("date", "repo"), merge = "max")

  expect_equal(nrow(out), 2L)
  expect_equal(out$views[out$date == as.Date("2026-09-14")], 40L)
  expect_equal(out$views[out$date == as.Date("2026-09-15")], 1L)
})

test_that("merge = 'max' is per (date, repo), not across repositories", {
  d <- as.Date("2026-09-15")
  old <- dplyr::bind_rows(
    traffic(d, "owner/a", 40L, 20L, 9L, 5L),
    traffic(d, "owner/b", 2L, 1L, 1L, 1L)
  )
  new <- dplyr::bind_rows(
    traffic(d, "owner/a", 5L, 3L, 2L, 1L),
    traffic(d, "owner/b", 7L, 4L, 3L, 2L)
  )

  out <- zb_upsert(old, new, keys = c("date", "repo"), merge = "max")

  expect_equal(out$views[out$repo == "owner/a"], 40L)
  expect_equal(out$views[out$repo == "owner/b"], 7L)
})

test_that("last-write-wins does lower a value, which is why traffic differs", {
  d <- as.Date("2026-09-15")
  old <- tibble::tibble(date = d, package = "pkgA", downloads = 40L)
  new <- tibble::tibble(date = d, package = "pkgA", downloads = 3L)

  out <- zb_upsert(old, new, keys = c("date", "package"), merge = "last")

  expect_equal(out$downloads, 3L)
})

test_that("consolidate() applies max() to gh_traffic and last-write-wins elsewhere", {
  root <- withr::local_tempdir()
  staging <- file.path(root, "staging")
  data_dir <- file.path(root, "data")
  dir.create(staging, recursive = TRUE)

  d <- as.Date(c("2026-09-14", "2026-09-15"))

  # Full counts recorded by an earlier run.
  arrow::write_parquet(
    traffic(d, "owner/repo", c(40L, 30L), c(20L, 15L), c(9L, 11L), c(5L, 7L)),
    file.path(staging, "gh_traffic.parquet")
  )
  arrow::write_parquet(
    tibble::tibble(date = d, package = "pkgA", downloads = c(40L, 30L)),
    file.path(staging, "cran_downloads.parquet")
  )
  consolidate(staging, data_dir, reference_date = ref_date)

  # A mid-day re-read: every count is smaller.
  arrow::write_parquet(
    traffic(d, "owner/repo", c(3L, 4L), c(1L, 2L), c(1L, 1L), c(1L, 1L)),
    file.path(staging, "gh_traffic.parquet")
  )
  arrow::write_parquet(
    tibble::tibble(date = d, package = "pkgA", downloads = c(3L, 4L)),
    file.path(staging, "cran_downloads.parquet")
  )
  consolidate(staging, data_dir, reference_date = ref_date)

  traf <- tibble::as_tibble(arrow::read_parquet(file.path(data_dir, "gh_traffic.parquet")))
  traf <- traf[order(traf$date), ]
  expect_equal(nrow(traf), 2L)
  expect_equal(traf$views, c(40L, 30L))
  expect_equal(traf$clones, c(9L, 11L))

  # The retroactive, reconstitutable source is allowed to go down.
  dl <- tibble::as_tibble(arrow::read_parquet(file.path(data_dir, "cran_downloads.parquet")))
  expect_equal(sort(dl$downloads), c(3L, 4L))
})

test_that("the monthly traffic rollup sums the merged (maximum) values", {
  root <- withr::local_tempdir()
  staging <- file.path(root, "staging")
  data_dir <- file.path(root, "data")
  dir.create(staging, recursive = TRUE)

  d <- as.Date(c("2026-09-14", "2026-09-15"))
  arrow::write_parquet(
    traffic(d, "owner/repo", c(40L, 30L), c(20L, 15L), c(9L, 11L), c(5L, 7L)),
    file.path(staging, "gh_traffic.parquet")
  )
  consolidate(staging, data_dir, reference_date = ref_date)

  arrow::write_parquet(
    traffic(d, "owner/repo", c(3L, 4L), c(1L, 2L), c(1L, 1L), c(1L, 1L)),
    file.path(staging, "gh_traffic.parquet")
  )
  consolidate(staging, data_dir, reference_date = ref_date)

  monthly <- tibble::as_tibble(arrow::read_parquet(
    file.path(data_dir, "archive", "gh_traffic_monthly.parquet")
  ))
  expect_equal(nrow(monthly), 1L)
  expect_equal(monthly$views, 70L)
  expect_equal(monthly$clones, 20L)
})
