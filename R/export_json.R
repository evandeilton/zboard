# ===========================================================================
# JSON EXPORT CONTRACT  --  read this before writing any front-end code.
# ===========================================================================
#
# export_json() reads data/*.parquet (+ data/archive/*_monthly.parquet) and
# writes exactly the ten files below into `output_dir` (default
# "site/_data"). This comment block IS the contract: field names, types and
# an example for every file. It is the only thing the Quarto dashboard needs
# to know about the data layer.
#
# UNIVERSAL RULES
# ---------------
# * Every file is a JSON **object** at the top level, never a bare array.
# * Every file carries `generated_at` : string, ISO-8601 UTC with a `Z`
#   suffix ("2026-09-17T06:21:33Z"). That is the BUILD time. For the
#   "date of the most recent datum" required by SPEC.md S7.2, use
#   `meta.json -> latest_data_date` (or the per-table variant), never
#   `generated_at`.
# * Dates are strings, "YYYY-MM-DD". Timestamps are strings,
#   "YYYY-MM-DDTHH:MM:SSZ". Months are strings, "YYYY-MM". No numeric epoch
#   values, no Arrow types leak out.
# * Missing values are JSON `null`, never "NA", never "".
# * Every array field is present even when empty (`[]`). A table with no
#   data yields an empty array, NOT a missing key and NOT an error: the site
#   must render before any real data exists.
# * Counts are integers; `check_time` and `duration_s` are floats.
# * `status` (CRAN check) is one of "OK", "NOTE", "WARN", "ERROR", "FAIL",
#   in increasing severity, or null when unknown.
# * `status` (pipeline run) is one of "ok", "partial", "failed".
# * Maintainer e-mail addresses are stripped by default (see the
#   `redact_emails` argument). `maintainer` is a display name only.
#
# ---------------------------------------------------------------------------
# 1. overview.json  --  the Overview page (SPEC.md S7.1)
# ---------------------------------------------------------------------------
# {
#   "generated_at": "2026-09-17T06:21:33Z",
#   "snapshot_date": "2026-09-17",            // date of the newest snapshot
#   "packages": [                              // one object per CRAN package
#     {
#       "package": "gkwreg",
#       "worst_status": "OK",                  // worst flavour, or null
#       "n_flavors": 13,                       // flavours checked
#       "n_flavors_not_ok": 0,                 // flavours worse than OK
#       "version": "2.1.18",                   // current CRAN version
#       "release_date": "2026-08-24",
#       "on_cran": true,
#       "archived": false,
#       "maintainer": "José Evandeilton Lopes",
#       "downloads_30d": 412,                  // last 30 days of the series
#       "downloads_prev_30d": 380,             // the 30 days before those
#       "downloads_trend_pct": 8.4,            // null when prev is 0
#       "repo": "evandeilton/gkwreg",          // null when no repo matches
#       "open_issues": 1,
#       "open_prs": 0,
#       "stars": 2,
#       "last_release_tag": "v2.1.18",
#       "last_release_at": "2026-08-23T18:23:53Z"
#     }
#   ],
#   "freshness": [ ... ],                      // same objects as freshness.json
#   "totals": {
#     "n_packages": 4, "n_repos": 6, "downloads_30d": 1234,
#     "open_issues": 3, "open_prs": 0, "n_works": 9, "citations": 12
#   }
# }
# NOTE ON `repo`: the package<->repository link is inferred by matching the
# package name against the repository's name part ("owner/<package>"), which
# is how the curated set in config/repos.yml is laid out. No such repo => null.
#
# ---------------------------------------------------------------------------
# 2. cran_status.json  --  the CRAN page, status and history
# ---------------------------------------------------------------------------
# {
#   "generated_at": "...",
#   "snapshot_date": "2026-09-17",
#   "flavors": ["r-devel-linux-x86_64-debian-clang", ...],  // sorted, distinct
#   "checks": [   // latest snapshot only, package x flavour
#     { "snapshot_date": "2026-09-17", "package": "gkwreg", "version": "2.1.18",
#       "flavor": "r-devel-linux-x86_64-debian-gcc", "status": "OK",
#       "check_time": 151.61 }
#   ],
#   "status": [
#     { "snapshot_date": "2026-09-17", "package": "gkwreg", "on_cran": true,
#       "archived": false, "maintainer": "José Evandeilton Lopes",
#       "worst_status": "OK", "n_flavors": 13, "n_flavors_not_ok": 0 }
#   ],
#   "versions": [  // complete history, permanent table, newest first
#     { "package": "gkwreg", "version": "2.1.18",
#       "release_date": "2026-08-24", "is_current": true }
#   ]
# }
#
# ---------------------------------------------------------------------------
# 3. cran_downloads.json  --  the CRAN download chart
# ---------------------------------------------------------------------------
# {
#   "generated_at": "...",
#   "window_start": "2025-09-18", "window_end": "2026-09-16",
#   "latest_data_date": "2026-09-16",
#   "series": [
#     { "package": "gkwreg",
#       "total": 4821,                         // over the exported window
#       "points": [ { "date": "2026-09-01", "downloads": 23 } ] }
#   ],
#   "releases": [   // vertical markers; SPEC.md S7.1 and S10.3
#     { "package": "gkwreg", "version": "2.1.18", "date": "2026-08-24" }
#   ],
#   "monthly": [    // permanent rollup, outlives the 12-month daily window
#     { "package": "gkwreg", "month": "2026-08", "downloads": 900 }
#   ]
# }
# The series is a partial sample of one mirror. SPEC.md S7.2 requires the
# label "downloads from the Posit mirror (partial sample)" on every chart
# built from this file, and a one-click path to the S10 limitations.
#
# ---------------------------------------------------------------------------
# 4. gh_activity.json  --  the GitHub activity chart
# ---------------------------------------------------------------------------
# {
#   "generated_at": "...", "latest_data_date": "2026-09-16",
#   "series": [
#     { "repo": "evandeilton/gkwreg",
#       "points": [ { "date": "2026-09-01", "commits": 3, "prs_opened": 0,
#                     "prs_merged": 0, "prs_closed": 0,
#                     "issues_opened": 1, "issues_closed": 0 } ] }
#   ],
#   "monthly": [
#     { "repo": "evandeilton/gkwreg", "month": "2026-08", "commits": 10,
#       "prs_opened": 0, "prs_merged": 0, "prs_closed": 0,
#       "issues_opened": 2, "issues_closed": 2 }
#   ]
# }
# `prs_merged` and `prs_closed` are DISJOINT: a merged PR counts only in
# `prs_merged`. Commits must not be shown as a headline KPI (NG-2): they are
# a secondary series on the GitHub page only.
#
# ---------------------------------------------------------------------------
# 5. gh_traffic.json  --  the GitHub traffic chart
# ---------------------------------------------------------------------------
# {
#   "generated_at": "...", "latest_data_date": "2026-09-16",
#   "series": [
#     { "repo": "evandeilton/gkwreg",
#       "series_start_date": "2026-09-03",     // FIRST EVER collected day
#       "points": [ { "date": "2026-09-03", "views": 1, "view_uniques": 1,
#                     "clones": 3, "clone_uniques": 2 } ] }
#   ],
#   "monthly": [
#     { "repo": "...", "month": "2026-09", "views": 40, "view_uniques": 12,
#       "clones": 90, "clone_uniques": 30 }
#   ]
# }
# `series_start_date` is the earliest day known for that repo, daily rows and
# monthly archive combined. SPEC.md S10.4 requires the chart to say
# "collection started on <series_start_date>": everything before it is
# unrecoverable by design of the GitHub API (14-day retention).
# In `monthly`, the `*_uniques` columns are SUMS of daily uniques, i.e. an
# upper bound on distinct visitors, not a distinct count. Label them as such.
#
# ---------------------------------------------------------------------------
# 6. gh_issues.json  --  open issues / PRs and repository state
# ---------------------------------------------------------------------------
# {
#   "generated_at": "...", "snapshot_date": "2026-09-17",
#   "repos": [
#     { "repo": "evandeilton/gkwreg", "open_issues": 1, "open_prs": 0,
#       "oldest_open_issue_days": 312,         // null when nothing is open
#       "stars": 2, "forks": 0, "watchers": 1,
#       "last_push_at": "2026-08-23T18:37:21Z", "archived": false }
#   ],
#   "history": [   // 12 months of daily snapshots, for a trend sparkline
#     { "snapshot_date": "2026-09-16", "repo": "...", "open_issues": 1,
#       "open_prs": 0, "oldest_open_issue_days": 311, "stars": 2 }
#   ]
# }
# Aggregates per repository only. No issue title, author or e-mail (NG-5).
#
# ---------------------------------------------------------------------------
# 7. gh_releases.json  --  release markers and the release table
# ---------------------------------------------------------------------------
# {
#   "generated_at": "...",
#   "releases": [   // permanent table, newest first
#     { "repo": "evandeilton/gkwreg", "tag": "v2.1.18", "name": "gkwreg 2.1.18",
#       "published_at": "2026-08-23T18:23:53Z", "is_prerelease": false }
#   ],
#   "latest_by_repo": [
#     { "repo": "evandeilton/gkwreg", "tag": "v2.1.18",
#       "published_at": "2026-08-23T18:23:53Z" }
#   ]
# }
#
# ---------------------------------------------------------------------------
# 8. academic.json  --  the Academic page
# ---------------------------------------------------------------------------
# {
#   "generated_at": "...", "snapshot_date": "2026-09-17",
#   "works": [   // most recent snapshot only, newest publication first
#     { "work_id": "https://openalex.org/W4409453217",
#       "doi": "https://doi.org/10.32614/cran.package.gkwreg",
#       "title": "gkwreg: Generalized Kumaraswamy Regression Models",
#       "venue": null, "year": 2025, "type": "dataset", "cited_by_count": 0 }
#   ],
#   "by_year": [ { "year": 2025, "n_works": 4, "citations": 3 } ],
#   "by_type": [ { "type": "dataset", "n_works": 4, "citations": 3 } ],
#   "totals": { "n_works": 9, "citations": 12 }
# }
# `type` is OpenAlex's own vocabulary, passed through unchanged.
# Citation counts lag indexing by weeks to months (SPEC.md S10.5).
#
# ---------------------------------------------------------------------------
# 9. freshness.json  --  the per-source traffic light (SPEC.md S7.1)
# ---------------------------------------------------------------------------
# {
#   "generated_at": "...",
#   "sources": [   // ONE object per source: its most recent run
#     { "source": "cran_downloads", "run_ts": "2026-09-17T06:15:02Z",
#       "status": "ok", "rows_written": 140, "duration_s": 1.21,
#       "age_hours": 0.1, "message": null }
#   ],
#   "worst_status": "ok"                       // worst over all sources
# }
# `source` takes a table name ("cran_downloads", "gh_traffic", ...) or the
# literal "consolidate". `message` is sanitised and capped at 500 chars; it
# never contains a token or an e-mail address (SPEC.md S11).
#
# ---------------------------------------------------------------------------
# 10. meta.json  --  build metadata
# ---------------------------------------------------------------------------
# {
#   "generated_at": "2026-09-17T06:21:33Z",
#   "schema_version": 1,
#   "package_version": "0.0.0.9000",
#   "latest_data_date": "2026-09-16",          // newest datum anywhere; null if none
#   "latest_data_date_by_table": { "cran_downloads": "2026-09-16", ... },
#   "row_counts": { "cran_downloads": 1400, ... },  // every table, 0 when absent
#   "retention_months": 12,
#   "n_packages": 4,
#   "n_repos": 6,
#   "tables_present": ["cran_downloads", "cran_versions"]
# }
# `schema_version` changes only on a breaking change to this contract.
# ===========================================================================

#' Render every `Date`/`POSIXct` column as an ISO-8601 string
#'
#' @param df A data frame.
#' @return The same data frame with date/time columns as character.
#' @keywords internal
#' @noRd
zb_iso_cols <- function(df) {
  for (nm in names(df)) {
    if (inherits(df[[nm]], "Date") || inherits(df[[nm]], "POSIXt")) {
      df[[nm]] <- zb_iso(df[[nm]])
    }
  }
  df
}

#' Write one JSON file with the pipeline's serialisation settings
#'
#' @param x Object to serialise.
#' @param dir Output directory.
#' @param name File name without the extension.
#' @param pretty Pretty-print the output.
#' @return The path written.
#' @keywords internal
#' @noRd
zb_write_json <- function(x, dir, name, pretty = FALSE) {
  path <- file.path(dir, paste0(name, ".json"))
  jsonlite::write_json(
    x, path,
    auto_unbox = TRUE, null = "null", na = "null",
    pretty = pretty, digits = NA
  )
  path
}

#' Keep only the rows of the most recent snapshot
#'
#' @param df A snapshot table.
#' @param col Name of the snapshot date column.
#' @return The subset of `df` whose `col` equals its maximum.
#' @keywords internal
#' @noRd
zb_latest_snapshot <- function(df, col = "snapshot_date") {
  if (nrow(df) == 0L) {
    return(df)
  }
  mx <- suppressWarnings(max(df[[col]], na.rm = TRUE))
  if (is.na(mx) || is.infinite(as.numeric(mx))) {
    return(df[0L, , drop = FALSE])
  }
  df[!is.na(df[[col]]) & df[[col]] == mx, , drop = FALSE]
}

#' Group a daily table into per-entity series objects
#'
#' @param df A daily table.
#' @param by Grouping column (`"package"` or `"repo"`).
#' @param value_cols Columns to include in each point.
#' @param date_col Date column.
#' @param extra Optional named list of functions of the group's rows, each
#'   adding one scalar field beside `points`.
#' @return A list of objects ready for JSON serialisation.
#' @keywords internal
#' @noRd
zb_series_list <- function(df, by, value_cols, date_col = "date", extra = NULL) {
  if (nrow(df) == 0L) {
    return(list())
  }
  df <- df[order(df[[by]], df[[date_col]]), , drop = FALSE]
  groups <- split(df, df[[by]])
  unname(lapply(names(groups), function(key) {
    g <- groups[[key]]
    points <- zb_iso_cols(g[, c(date_col, value_cols), drop = FALSE])
    out <- list()
    out[[by]] <- key
    for (nm in names(extra)) out[[nm]] <- extra[[nm]](g)
    out$points <- points
    out
  }))
}

#' Read a monthly archive table
#'
#' @param archive_dir Directory holding the monthly archives.
#' @param tbl Base table name.
#' @return A tibble with a `month` column formatted `"YYYY-MM"`; zero rows
#'   when the archive does not exist.
#' @keywords internal
#' @noRd
zb_read_monthly <- function(archive_dir, tbl) {
  path <- file.path(archive_dir, paste0(tbl, "_monthly.parquet"))
  if (!file.exists(path)) {
    return(tibble::tibble())
  }
  df <- tibble::as_tibble(arrow::read_parquet(path))
  if ("month" %in% names(df)) {
    df$month <- format(zb_as_date(df$month), "%Y-%m")
    df <- df[order(df$month), , drop = FALSE]
  }
  df
}

#' Export the canonical Parquet store as JSON for the static dashboard
#'
#' @description
#' Reads `data_dir/*.parquet` (and the monthly archives under
#' `archive_dir`) and writes the ten JSON files the Quarto dashboard
#' consumes into `output_dir`: `overview.json`, `cran_status.json`,
#' `cran_downloads.json`, `gh_activity.json`, `gh_traffic.json`,
#' `gh_issues.json`, `gh_releases.json`, `academic.json`,
#' `freshness.json` and `meta.json`.
#'
#' **The complete field-by-field schema of all ten files is documented as a
#' comment block at the top of `R/export_json.R`.** That block is the
#' contract between this package and the front-end; read it there.
#'
#' @details
#' An absent Parquet file is an empty table, not an error, and every array
#' in the output is emitted even when empty. Calling this on a directory
#' with no data at all produces ten valid, empty-but-well-formed JSON files,
#' which is what lets the site build before the first collection has run
#' (RNF-3).
#'
#' Dates and timestamps are serialised as ISO-8601 strings; no Arrow or R
#' date type reaches the JSON. Numbers are written at full precision
#' (`digits = NA`).
#'
#' `cran_status$maintainer` is collected from CRAN with an e-mail address
#' attached. Because these files are published on a public site, the address
#' is removed by default, leaving the display name (SPEC.md S11, NG-5).
#'
#' @param data_dir Directory holding the canonical Parquet store.
#' @param output_dir Directory the JSON files are written to. Created when
#'   missing.
#' @param archive_dir Directory holding the monthly rollups. Defaults to
#'   `archive/` inside `data_dir`.
#' @param downloads_window_days Length, in days, of the daily download and
#'   activity series exported (the rolling window of SPEC.md S4.3).
#' @param redact_emails Strip e-mail addresses from `maintainer` before
#'   publishing. Leave `TRUE` unless you have a specific reason not to.
#' @param pretty Pretty-print the JSON. `FALSE` produces smaller files.
#' @param generated_at Build timestamp recorded in every file.
#'
#' @return Invisibly, a tibble with one row per file written and the columns
#'   `file`, `path` and `bytes`.
#'
#' @seealso [consolidate()], [make_badges()]
#' @export
#' @examples
#' # Works on an empty store: every file is written, every array is empty.
#' tmp <- tempfile()
#' dir.create(tmp)
#' out <- export_json(
#'   data_dir = file.path(tmp, "data"),
#'   output_dir = file.path(tmp, "json")
#' )
#' out$file
#' jsonlite::fromJSON(file.path(tmp, "json", "meta.json"))$schema_version
#'
#' \dontrun{
#' # In the pipeline, against the checked-out `data` branch.
#' export_json(data_dir = "data", output_dir = "site/_data")
#' }
export_json <- function(data_dir = "data", output_dir = "site/_data",
                        archive_dir = file.path(data_dir, "archive"),
                        downloads_window_days = 365L,
                        redact_emails = TRUE,
                        pretty = FALSE,
                        generated_at = Sys.time()) {
  if (!dir.exists(output_dir)) {
    dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
  }
  gen <- zb_iso(zb_as_ts(generated_at)[1L])

  tbls <- lapply(names(zb_schemas()), function(t) zb_read_table(data_dir, t))
  names(tbls) <- names(zb_schemas())

  cli::cli_h1("export_json()")
  cli::cli_alert_info("data {.path {data_dir}} -> json {.path {output_dir}}.")

  # -- shared derived values ----------------------------------------------
  checks_latest <- zb_latest_snapshot(tbls$cran_checks)
  status_latest <- zb_latest_snapshot(tbls$cran_status)
  repo_latest <- zb_latest_snapshot(tbls$gh_repo_snapshot)
  works_latest <- zb_latest_snapshot(tbls$academic_works)

  if (redact_emails && nrow(status_latest) > 0L) {
    status_latest$maintainer <- zb_strip_email(status_latest$maintainer)
  }

  flavor_counts <- dplyr::summarise(
    dplyr::group_by(checks_latest, .data$package),
    n_flavors = dplyr::n(),
    n_flavors_not_ok = sum(!is.na(.data$status) & .data$status != "OK"),
    .groups = "drop"
  )

  dl <- tbls$cran_downloads
  dl_end <- if (nrow(dl)) suppressWarnings(max(dl$date, na.rm = TRUE)) else as.Date(NA)
  dl_start <- if (is.na(dl_end)) as.Date(NA) else dl_end - (downloads_window_days - 1L)
  dl_win <- if (is.na(dl_end)) dl[0L, , drop = FALSE] else dl[dl$date >= dl_start, , drop = FALSE]

  dl_sum <- function(lo, hi) {
    if (nrow(dl) == 0L || is.na(dl_end)) {
      return(tibble::tibble(package = character(), downloads = integer()))
    }
    sub <- dl[dl$date > dl_end - hi & dl$date <= dl_end - lo, , drop = FALSE]
    dplyr::summarise(
      dplyr::group_by(sub, .data$package),
      downloads = sum(.data$downloads, na.rm = TRUE), .groups = "drop"
    )
  }
  dl30 <- dl_sum(0L, 30L)
  dl60 <- dl_sum(30L, 60L)

  releases <- tbls$gh_releases
  releases <- releases[order(releases$published_at, decreasing = TRUE), , drop = FALSE]
  latest_release <- releases[!duplicated(releases$repo), , drop = FALSE]

  manifest <- tbls$run_manifest
  manifest <- manifest[order(manifest$run_ts, decreasing = TRUE), , drop = FALSE]
  fresh <- manifest[!duplicated(manifest$source), , drop = FALSE]
  fresh_out <- if (nrow(fresh) == 0L) {
    list()
  } else {
    f <- fresh[, c("source", "run_ts", "status", "rows_written", "duration_s", "message"), drop = FALSE]
    f$age_hours <- round(
      as.numeric(difftime(zb_as_ts(generated_at)[1L], f$run_ts, units = "hours")), 3
    )
    zb_iso_cols(f)
  }

  # -- 1. overview ---------------------------------------------------------
  pkg_names <- sort(unique(c(
    status_latest$package, tbls$cran_versions$package, dl$package
  )))
  pkg_names <- pkg_names[!is.na(pkg_names)]

  current_version <- tbls$cran_versions[
    !is.na(tbls$cran_versions$is_current) & tbls$cran_versions$is_current, ,
    drop = FALSE
  ]
  repo_basename <- sub("^.*/", "", repo_latest$repo)

  overview_pkgs <- lapply(pkg_names, function(p) {
    st <- status_latest[status_latest$package == p, , drop = FALSE]
    fc <- flavor_counts[flavor_counts$package == p, , drop = FALSE]
    cv <- current_version[current_version$package == p, , drop = FALSE]
    d30 <- dl30$downloads[dl30$package == p]
    d60 <- dl60$downloads[dl60$package == p]
    d30 <- if (length(d30)) as.integer(d30[1L]) else 0L
    d60 <- if (length(d60)) as.integer(d60[1L]) else 0L
    rs <- repo_latest[repo_basename == p, , drop = FALSE]
    repo_id <- if (nrow(rs)) rs$repo[1L] else NA_character_
    lr <- if (!is.na(repo_id)) {
      latest_release[latest_release$repo == repo_id, , drop = FALSE]
    } else {
      latest_release[0L, , drop = FALSE]
    }
    list(
      package = p,
      worst_status = if (nrow(st)) st$worst_status[1L] else NA_character_,
      n_flavors = if (nrow(fc)) as.integer(fc$n_flavors[1L]) else 0L,
      n_flavors_not_ok = if (nrow(fc)) as.integer(fc$n_flavors_not_ok[1L]) else 0L,
      version = if (nrow(cv)) cv$version[1L] else NA_character_,
      release_date = if (nrow(cv)) zb_iso(cv$release_date[1L]) else NA_character_,
      on_cran = if (nrow(st)) st$on_cran[1L] else NA,
      archived = if (nrow(st)) st$archived[1L] else NA,
      maintainer = if (nrow(st)) st$maintainer[1L] else NA_character_,
      downloads_30d = d30,
      downloads_prev_30d = d60,
      downloads_trend_pct = if (d60 > 0L) round(100 * (d30 - d60) / d60, 2) else NA_real_,
      repo = repo_id,
      open_issues = if (nrow(rs)) as.integer(rs$open_issues[1L]) else NA_integer_,
      open_prs = if (nrow(rs)) as.integer(rs$open_prs[1L]) else NA_integer_,
      stars = if (nrow(rs)) as.integer(rs$stars[1L]) else NA_integer_,
      last_release_tag = if (nrow(lr)) lr$tag[1L] else NA_character_,
      last_release_at = if (nrow(lr)) zb_iso(lr$published_at[1L]) else NA_character_
    )
  })

  snapshot_date <- suppressWarnings(max(c(
    status_latest$snapshot_date, repo_latest$snapshot_date,
    works_latest$snapshot_date
  ), na.rm = TRUE))
  snapshot_date <- if (is.infinite(as.numeric(snapshot_date))) NA_character_ else zb_iso(snapshot_date)

  files <- character()
  files["overview"] <- zb_write_json(list(
    generated_at = gen,
    snapshot_date = snapshot_date,
    packages = overview_pkgs,
    freshness = fresh_out,
    totals = list(
      n_packages = length(pkg_names),
      n_repos = length(unique(repo_latest$repo)),
      downloads_30d = as.integer(sum(dl30$downloads)),
      open_issues = as.integer(sum(repo_latest$open_issues, na.rm = TRUE)),
      open_prs = as.integer(sum(repo_latest$open_prs, na.rm = TRUE)),
      n_works = nrow(works_latest),
      citations = as.integer(sum(works_latest$cited_by_count, na.rm = TRUE))
    )
  ), output_dir, "overview", pretty)

  # -- 2. cran_status ------------------------------------------------------
  versions <- tbls$cran_versions
  versions <- versions[order(versions$package, versions$release_date, decreasing = c(FALSE, TRUE), method = "radix"), , drop = FALSE]
  status_out <- if (nrow(status_latest)) {
    dplyr::left_join(status_latest, flavor_counts, by = "package")
  } else {
    status_latest
  }
  files["cran_status"] <- zb_write_json(list(
    generated_at = gen,
    snapshot_date = if (nrow(status_latest)) zb_iso(status_latest$snapshot_date[1L]) else NA_character_,
    flavors = sort(unique(checks_latest$flavor)),
    checks = zb_iso_cols(checks_latest),
    status = zb_iso_cols(status_out),
    versions = zb_iso_cols(versions)
  ), output_dir, "cran_status", pretty)

  # -- 3. cran_downloads ---------------------------------------------------
  release_markers <- tbls$cran_versions[
    , c("package", "version", "release_date"), drop = FALSE
  ]
  names(release_markers)[3L] <- "date"
  files["cran_downloads"] <- zb_write_json(list(
    generated_at = gen,
    window_start = zb_iso(dl_start),
    window_end = zb_iso(dl_end),
    latest_data_date = zb_iso(dl_end),
    series = zb_series_list(
      dl_win, "package", "downloads",
      extra = list(total = function(g) as.integer(sum(g$downloads, na.rm = TRUE)))
    ),
    releases = zb_iso_cols(release_markers),
    monthly = zb_read_monthly(archive_dir, "cran_downloads")
  ), output_dir, "cran_downloads", pretty)

  # -- 4. gh_activity ------------------------------------------------------
  act <- tbls$gh_activity
  act_end <- if (nrow(act)) suppressWarnings(max(act$date, na.rm = TRUE)) else as.Date(NA)
  act_win <- if (is.na(act_end)) {
    act[0L, , drop = FALSE]
  } else {
    act[act$date >= act_end - (downloads_window_days - 1L), , drop = FALSE]
  }
  files["gh_activity"] <- zb_write_json(list(
    generated_at = gen,
    latest_data_date = zb_iso(act_end),
    series = zb_series_list(
      act_win, "repo",
      c("commits", "prs_opened", "prs_merged", "prs_closed", "issues_opened", "issues_closed")
    ),
    monthly = zb_read_monthly(archive_dir, "gh_activity")
  ), output_dir, "gh_activity", pretty)

  # -- 5. gh_traffic -------------------------------------------------------
  traf <- tbls$gh_traffic
  traf_monthly <- zb_read_monthly(archive_dir, "gh_traffic")
  traf_end <- if (nrow(traf)) suppressWarnings(max(traf$date, na.rm = TRUE)) else as.Date(NA)
  series_start <- function(g) {
    repo_id <- g$repo[1L]
    daily_min <- suppressWarnings(min(g$date, na.rm = TRUE))
    arch_min <- if (nrow(traf_monthly) && "repo" %in% names(traf_monthly)) {
      m <- traf_monthly$month[traf_monthly$repo == repo_id]
      if (length(m)) zb_as_date(paste0(min(m), "-01")) else as.Date(NA)
    } else {
      as.Date(NA)
    }
    zb_iso(suppressWarnings(min(c(daily_min, arch_min), na.rm = TRUE)))
  }
  files["gh_traffic"] <- zb_write_json(list(
    generated_at = gen,
    latest_data_date = zb_iso(traf_end),
    series = zb_series_list(
      traf, "repo", c("views", "view_uniques", "clones", "clone_uniques"),
      extra = list(series_start_date = series_start)
    ),
    monthly = traf_monthly
  ), output_dir, "gh_traffic", pretty)

  # -- 6. gh_issues --------------------------------------------------------
  hist_cols <- c(
    "snapshot_date", "repo", "open_issues", "open_prs",
    "oldest_open_issue_days", "stars"
  )
  files["gh_issues"] <- zb_write_json(list(
    generated_at = gen,
    snapshot_date = if (nrow(repo_latest)) zb_iso(repo_latest$snapshot_date[1L]) else NA_character_,
    repos = zb_iso_cols(repo_latest[, c(
      "repo", "open_issues", "open_prs", "oldest_open_issue_days",
      "stars", "forks", "watchers", "last_push_at", "archived"
    ), drop = FALSE]),
    history = zb_iso_cols(tbls$gh_repo_snapshot[, hist_cols, drop = FALSE])
  ), output_dir, "gh_issues", pretty)

  # -- 7. gh_releases ------------------------------------------------------
  files["gh_releases"] <- zb_write_json(list(
    generated_at = gen,
    releases = zb_iso_cols(releases),
    latest_by_repo = zb_iso_cols(
      latest_release[, c("repo", "tag", "published_at"), drop = FALSE]
    )
  ), output_dir, "gh_releases", pretty)

  # -- 8. academic ---------------------------------------------------------
  works <- works_latest[order(works_latest$year, decreasing = TRUE), , drop = FALSE]
  by_year <- dplyr::summarise(
    dplyr::group_by(works, .data$year),
    n_works = dplyr::n(),
    citations = as.integer(sum(.data$cited_by_count, na.rm = TRUE)),
    .groups = "drop"
  )
  by_type <- dplyr::summarise(
    dplyr::group_by(works, .data$type),
    n_works = dplyr::n(),
    citations = as.integer(sum(.data$cited_by_count, na.rm = TRUE)),
    .groups = "drop"
  )
  files["academic"] <- zb_write_json(list(
    generated_at = gen,
    snapshot_date = if (nrow(works)) zb_iso(works$snapshot_date[1L]) else NA_character_,
    works = zb_iso_cols(works[, c(
      "work_id", "doi", "title", "venue", "year", "type", "cited_by_count"
    ), drop = FALSE]),
    by_year = by_year,
    by_type = by_type,
    totals = list(
      n_works = nrow(works),
      citations = as.integer(sum(works$cited_by_count, na.rm = TRUE))
    )
  ), output_dir, "academic", pretty)

  # -- 9. freshness --------------------------------------------------------
  sev <- c("ok", "partial", "failed")
  worst <- if (nrow(fresh)) sev[max(match(fresh$status, sev), na.rm = TRUE)] else NA_character_
  files["freshness"] <- zb_write_json(list(
    generated_at = gen,
    sources = fresh_out,
    worst_status = worst
  ), output_dir, "freshness", pretty)

  # -- 10. meta ------------------------------------------------------------
  latest_by_table <- lapply(names(tbls), function(t) {
    df <- tbls[[t]]
    dc <- zb_schema(t)$date_col
    if (nrow(df) == 0L) {
      return(NA_character_)
    }
    zb_iso(suppressWarnings(max(zb_as_date(df[[dc]]), na.rm = TRUE)))
  })
  names(latest_by_table) <- names(tbls)
  row_counts <- as.list(vapply(tbls, nrow, integer(1)))
  data_dates <- unlist(latest_by_table[setdiff(names(tbls), "run_manifest")])
  data_dates <- data_dates[!is.na(data_dates)]

  files["meta"] <- zb_write_json(list(
    generated_at = gen,
    schema_version = 1L,
    package_version = as.character(utils::packageVersion("zboard")),
    latest_data_date = if (length(data_dates)) max(data_dates) else NA_character_,
    latest_data_date_by_table = latest_by_table,
    row_counts = row_counts,
    retention_months = 12L,
    n_packages = length(pkg_names),
    n_repos = length(unique(repo_latest$repo)),
    tables_present = names(tbls)[vapply(
      names(tbls),
      function(t) file.exists(file.path(data_dir, paste0(t, ".parquet"))),
      logical(1)
    )]
  ), output_dir, "meta", pretty)

  out <- tibble::tibble(
    file = paste0(names(files), ".json"),
    path = unname(files),
    bytes = as.integer(file.size(unname(files)))
  )
  cli::cli_alert_success(
    "{nrow(out)} JSON file{?s} written ({sum(out$bytes)} bytes)."
  )
  invisible(out)
}
