# ---------------------------------------------------------------------------
# CRAN collector (SPEC.md S5, first four rows of the source table).
#
# Writes four staging tables:
#   staging/cran_downloads.parquet  <- cranlogs.r-pkg.org        (retroactive)
#   staging/cran_versions.parquet   <- crandb.r-pkg.org/{pkg}/all(retroactive)
#   staging/cran_checks.parquet     <- tools::CRAN_check_results (snapshot)
#   staging/cran_status.parquet     <- tools::CRAN_package_db    (snapshot)
#                                      + CRAN_archive_db + crandb
#
# All four are attempted independently: a crandb outage does not stop the
# download series from being collected (RNF-3).
# ---------------------------------------------------------------------------

#' Fetch daily CRAN download counts
#'
#' Uses `cranlogs::cran_downloads()` when the (suggested) package is
#' installed, and falls back to a direct `httr2` call against the same
#' service otherwise, so the collector still works in a minimal CI image.
#' Either way this is a single HTTP request for the whole package set, which
#' respects the "1 request per package per day" courtesy limit of SPEC.md S5.
#'
#' @param pkgs Character vector of package names.
#' @param from,to `Date` bounds, inclusive.
#' @return A `zb_result()` carrying a `cran_downloads` tibble.
#' @keywords internal
#' @noRd
zb_fetch_cran_downloads <- function(pkgs, from, to) {
  cols <- zb_schema("cran_downloads")$cols
  if (length(pkgs) == 0L) {
    return(zb_result(zb_empty("cran_downloads"), "partial", "No CRAN packages configured."))
  }

  if (requireNamespace("cranlogs", quietly = TRUE)) {
    raw <- zb_retry(
      function() {
        cranlogs::cran_downloads(
          packages = pkgs, from = format(from), to = format(to)
        )
      },
      label = "cranlogs::cran_downloads"
    )
    df <- tibble::tibble(
      date = zb_as_date(raw$date),
      package = as.character(raw$package),
      downloads = suppressWarnings(as.integer(raw$count))
    )
  } else {
    url <- sprintf(
      "https://cranlogs.r-pkg.org/downloads/daily/%s:%s/%s",
      format(from), format(to), paste(pkgs, collapse = ",")
    )
    body <- httr2::resp_body_json(zb_req_perform(httr2::request(url)))
    df <- purrr::list_rbind(purrr::map(body, function(entry) {
      dl <- entry$downloads %||% list()
      if (length(dl) == 0L) {
        return(tibble::tibble(
          date = as.Date(character()), package = character(),
          downloads = integer()
        ))
      }
      tibble::tibble(
        date = zb_as_date(vapply(dl, function(d) d$day %||% NA_character_, character(1))),
        package = as.character(entry$package %||% NA_character_),
        downloads = vapply(
          dl, function(d) as.integer(d$downloads %||% NA_integer_), integer(1)
        )
      )
    }))
  }

  df <- df[!is.na(df$date) & !is.na(df$package), , drop = FALSE]
  df$downloads[is.na(df$downloads)] <- 0L
  zb_result(zb_coerce(df, cols))
}

#' Fetch the crandb `/{pkg}/all` document for each package
#'
#' One request per package. Failures are tolerated per package; the caller
#' decides whether the outcome is `ok` or `partial`.
#'
#' @param pkgs Character vector of package names.
#' @return A named list; each element is either the parsed JSON document or
#'   `NULL` when the fetch failed (or the package is unknown to crandb).
#' @keywords internal
#' @noRd
zb_fetch_crandb <- function(pkgs) {
  out <- vector("list", length(pkgs))
  names(out) <- pkgs
  for (p in pkgs) {
    doc <- tryCatch(
      zb_retry(
        function() {
          url <- paste0("https://crandb.r-pkg.org/", p, "/all")
          httr2::resp_body_json(zb_req_perform(httr2::request(url)))
        },
        label = paste0("crandb/", p)
      ),
      error = function(e) NULL
    )
    out[[p]] <- doc
  }
  out
}

#' Build the `cran_versions` table from crandb documents
#'
#' crandb's `timeline` element maps every published version to its CRAN
#' publication timestamp, which is exactly the retroactive release history
#' the download chart needs for its release markers (SPEC.md S7.1).
#'
#' @param docs Named list from `zb_fetch_crandb()`.
#' @return A `zb_result()` carrying a `cran_versions` tibble.
#' @keywords internal
#' @noRd
zb_build_cran_versions <- function(docs) {
  cols <- zb_schema("cran_versions")$cols
  ok <- !vapply(docs, is.null, logical(1))
  rows <- purrr::list_rbind(purrr::imap(docs[ok], function(doc, pkg) {
    tl <- doc$timeline %||% list()
    if (length(tl) == 0L) {
      return(NULL)
    }
    latest <- as.character(doc$latest %||% NA_character_)[1L]
    tibble::tibble(
      package = pkg,
      version = names(tl),
      release_date = zb_as_date(vapply(tl, function(x) as.character(x)[1L], character(1))),
      is_current = names(tl) == latest
    )
  }))
  status <- if (all(ok)) "ok" else "partial"
  msg <- if (all(ok)) {
    NA_character_
  } else {
    paste0("crandb unavailable for: ", paste(names(docs)[!ok], collapse = ", "))
  }
  zb_result(zb_coerce(rows, cols), status, msg)
}

#' Build the `cran_checks` table from the official check-results table
#'
#' `tools::CRAN_check_results()` reads CRAN's own `.rds` artifact (no HTML
#' scraping, NG-4). Its `Status` column is an ordered factor whose labels
#' are `OK < NOTE < WARNING < ERROR < FAILURE`; SPEC.md S4.2 spells the last
#' two `WARN` and `FAIL`, so `zb_normalize_status()` maps them. An
#' unexpected label becomes `NA` rather than being silently accepted, which
#' is the explicit-failure-on-schema-drift mitigation of SPEC.md S13.
#'
#' @param pkgs Character vector of package names.
#' @param snapshot_date Snapshot date for the rows.
#' @return A `zb_result()` carrying a `cran_checks` tibble.
#' @keywords internal
#' @noRd
zb_build_cran_checks <- function(pkgs, snapshot_date) {
  cols <- zb_schema("cran_checks")$cols
  cr <- zb_retry(function() tools::CRAN_check_results(), label = "CRAN_check_results")
  required <- c("Flavor", "Package", "Version", "Status")
  missing <- setdiff(required, names(cr))
  if (length(missing)) {
    cli::cli_abort(
      "Unexpected schema from {.fn tools::CRAN_check_results}: missing {.val {missing}}."
    )
  }
  sub <- cr[cr$Package %in% pkgs, , drop = FALSE]
  status <- zb_normalize_status(sub$Status)
  df <- tibble::tibble(
    snapshot_date = rep(zb_as_date(snapshot_date)[1L], nrow(sub)),
    package = as.character(sub$Package),
    version = as.character(sub$Version),
    flavor = as.character(sub$Flavor),
    status = status,
    check_time = if ("T_check" %in% names(sub)) {
      suppressWarnings(as.numeric(sub$T_check))
    } else {
      rep(NA_real_, nrow(sub))
    }
  )
  n_unknown <- sum(is.na(status))
  missing_pkgs <- setdiff(pkgs, unique(df$package))
  parts <- c(
    if (n_unknown > 0L) paste0(n_unknown, " row(s) with an unrecognised check status"),
    if (length(missing_pkgs)) paste0("no check results for: ", paste(missing_pkgs, collapse = ", "))
  )
  zb_result(
    zb_coerce(df, cols),
    if (length(parts)) "partial" else "ok",
    if (length(parts)) paste(parts, collapse = "; ") else NA_character_
  )
}

#' Build the `cran_status` table
#'
#' `on_cran` comes from the active package index; `maintainer` from the same
#' source (falling back to crandb). `archived` is deliberately **not**
#' "present in `Archive/`": CRAN keeps every superseded tarball there, so an
#' active, healthy package appears in the archive index too. A package is
#' archived when crandb says so, or when it is absent from the active index
#' *and* present in `Archive/`.
#'
#' @param pkgs Character vector of package names.
#' @param docs Named list from `zb_fetch_crandb()`.
#' @param checks `cran_checks` tibble for the same snapshot.
#' @param snapshot_date Snapshot date for the rows.
#' @return A `zb_result()` carrying a `cran_status` tibble.
#' @keywords internal
#' @noRd
zb_build_cran_status <- function(pkgs, docs, checks, snapshot_date) {
  cols <- zb_schema("cran_status")$cols
  if (length(pkgs) == 0L) {
    return(zb_result(zb_empty("cran_status"), "partial", "No CRAN packages configured."))
  }

  db <- zb_retry(function() tools::CRAN_package_db(), label = "CRAN_package_db")
  idx <- match(pkgs, db$Package)
  on_cran <- !is.na(idx)
  maintainer <- as.character(db$Maintainer[idx])

  archive <- tryCatch(
    zb_retry(function() tools::CRAN_archive_db(), label = "CRAN_archive_db"),
    error = function(e) NULL
  )
  in_archive <- if (is.null(archive)) rep(NA, length(pkgs)) else pkgs %in% names(archive)

  crandb_archived <- vapply(pkgs, function(p) {
    doc <- docs[[p]]
    if (is.null(doc) || is.null(doc$archived)) NA else isTRUE(as.logical(doc$archived)[1L])
  }, logical(1), USE.NAMES = FALSE)

  archived <- ifelse(
    !is.na(crandb_archived), crandb_archived, !on_cran & in_archive %in% TRUE
  )

  crandb_maint <- vapply(pkgs, function(p) {
    doc <- docs[[p]]
    latest <- as.character(doc$latest %||% NA_character_)[1L]
    v <- if (!is.null(doc) && !is.na(latest)) doc$versions[[latest]]$Maintainer else NULL
    as.character(v %||% NA_character_)[1L]
  }, character(1), USE.NAMES = FALSE)
  maintainer[is.na(maintainer)] <- crandb_maint[is.na(maintainer)]

  worst <- vapply(pkgs, function(p) {
    zb_worst_status(checks$status[checks$package == p])
  }, character(1), USE.NAMES = FALSE)

  df <- tibble::tibble(
    snapshot_date = rep(zb_as_date(snapshot_date)[1L], length(pkgs)),
    package = pkgs,
    on_cran = on_cran,
    archived = archived,
    maintainer = maintainer,
    worst_status = worst
  )
  missing_pkgs <- pkgs[!on_cran & !(archived %in% TRUE)]
  zb_result(
    zb_coerce(df, cols),
    if (length(missing_pkgs)) "partial" else "ok",
    if (length(missing_pkgs)) {
      paste0("not found on CRAN: ", paste(missing_pkgs, collapse = ", "))
    } else {
      NA_character_
    }
  )
}

#' Collect CRAN health, version and download data
#'
#' @description
#' Collects the four CRAN-side tables of SPEC.md S4.2 for the packages
#' curated in `config/repos.yml`, and writes each one as a Parquet file in
#' `staging_dir` for [consolidate()] to upsert:
#'
#' * `cran_downloads` -- daily download counts from the Posit mirror
#'   (`cranlogs.r-pkg.org`). Retroactive, so `from`/`to` apply here.
#' * `cran_versions` -- the full published version history and release
#'   dates from `crandb.r-pkg.org/{pkg}/all`.
#' * `cran_checks` -- `R CMD check` status per flavour, read from CRAN's
#'   official `.rds` artifact via `tools::CRAN_check_results()`.
#' * `cran_status` -- presence on CRAN, archival state, maintainer and the
#'   worst check status across flavours.
#'
#' Each of the four is collected independently: a failure in one is
#' recorded in the run manifest and does not prevent the others from being
#' written (RNF-3). Every network call retries three times with exponential
#' backoff on 5xx/timeout and honours `Retry-After` on 429 (RNF-7).
#'
#' @details
#' Only `cran_downloads` is retroactive. `cran_checks` and `cran_status` are
#' snapshots of CRAN's *current* state and `cran_versions` is a complete
#' history in every run, so an explicit `from`/`to` window is applied to the
#' download series only; the other three are unaffected (and a message says
#' so).
#'
#' The e-mail address in `cran_status$maintainer` is collected as CRAN
#' publishes it; [export_json()] strips it before the column reaches a
#' public JSON file.
#'
#' @param from Start of the download window as an ISO-8601 date string or a
#'   `Date`. `NULL` (the default) means normal incremental mode: a rolling
#'   35-day window ending yesterday. The window is deliberately wider than
#'   one day so that the series self-heals after an outage.
#' @param to End of the download window, same forms as `from`. `NULL`
#'   defaults to yesterday, because the current UTC day is still incomplete
#'   upstream.
#' @param config_path Path to the curated source configuration
#'   (SPEC.md S5).
#' @param staging_dir Directory the staging Parquet files are written to.
#'   Created when missing.
#' @param run_ts Timestamp shared by every manifest row of this run.
#'
#' @return Invisibly, a tibble with the `run_manifest` schema: one row per
#'   source attempted, with `status` in `ok`/`partial`/`failed`,
#'   `rows_written`, `duration_s` and a sanitised `message`. The same rows
#'   are written to `staging_dir/run_manifest_cran.parquet`.
#'
#' @seealso [collect_github()], [collect_academic()], [consolidate()]
#' @export
#' @examples
#' \dontrun{
#' # Normal daily run.
#' collect_cran()
#'
#' # Backfill twelve months of the download series.
#' collect_cran(from = "2025-09-01", to = "2026-08-31")
#' }
collect_cran <- function(from = NULL, to = NULL,
                         config_path = "config/repos.yml",
                         staging_dir = "staging",
                         run_ts = Sys.time()) {
  cfg <- read_repos_config(config_path)
  pkgs <- cfg$cran_packages
  win <- zb_window(from, to, default_days = 35L, end_offset = 1L)
  snapshot_date <- Sys.Date()

  cli::cli_h1("collect_cran()")
  cli::cli_alert_info(
    "{length(pkgs)} package{?s}; download window {win$from} .. {win$to}."
  )
  if (zb_is_backfill(from, to)) {
    cli::cli_alert_info(
      "Backfill window applies to {.field cran_downloads} only; checks, status and versions are snapshots."
    )
  }

  docs <- NULL
  manifest <- dplyr::bind_rows(
    zb_run_source(
      "cran_downloads",
      function() zb_fetch_cran_downloads(pkgs, win$from, win$to),
      staging_dir, run_ts
    ),
    zb_run_source(
      "cran_versions",
      function() {
        docs <<- zb_fetch_crandb(pkgs)
        zb_build_cran_versions(docs)
      },
      staging_dir, run_ts
    )
  )

  checks_res <- NULL
  manifest <- dplyr::bind_rows(
    manifest,
    zb_run_source(
      "cran_checks",
      function() {
        checks_res <<- zb_build_cran_checks(pkgs, snapshot_date)
        checks_res
      },
      staging_dir, run_ts
    ),
    zb_run_source(
      "cran_status",
      function() {
        checks <- if (is.null(checks_res)) zb_empty("cran_checks") else checks_res$data
        if (is.null(docs)) {
          docs <- vector("list", length(pkgs))
          names(docs) <- pkgs
        }
        zb_build_cran_status(pkgs, docs, checks, snapshot_date)
      },
      staging_dir, run_ts
    )
  )

  zb_write_staging_manifest(manifest, staging_dir, "cran")
  invisible(manifest)
}
