# ---------------------------------------------------------------------------
# shields.io endpoint badges (SPEC.md S7.4, ADR-5).
#
# Each file is a tiny JSON document in the shields.io *endpoint* schema:
#   { "schemaVersion": 1, "label": "...", "message": "...", "color": "..." }
# consumed as
#   https://img.shields.io/endpoint?url=<public URL of the file>
# shields.io renders, caches and themes the badge; we only publish the data
# (ADR-5: ~15 lines of code instead of an SVG generator).
#
# The default output directory is inside the Quarto output (`_site/badges/`)
# because the badge has to be reachable at the published GitHub Pages URL.
# That means this function runs AFTER `quarto render`, not before it.
# ---------------------------------------------------------------------------

#' shields.io colour for a CRAN check status
#'
#' Follows the severity order `OK < NOTE < WARN < ERROR < FAIL`. `WARN` gets
#' orange rather than yellow so that "needs attention" and "will be archived
#' if unfixed" are not the same colour; severity is also carried by the
#' badge text, so colour is never the only channel (SPEC.md S7.2).
#'
#' @param status A normalised status, or `NA`.
#' @return A shields.io colour name.
#' @keywords internal
#' @noRd
zb_status_color <- function(status) {
  switch(as.character(status)[1L],
    OK = "brightgreen",
    NOTE = "yellow",
    WARN = "orange",
    ERROR = "red",
    FAIL = "red",
    "lightgrey"
  )
}

#' Compact download count for a badge message
#'
#' @param n A count.
#' @return A short string such as `"842"`, `"1.2k"` or `"3.4M"`.
#' @keywords internal
#' @noRd
zb_compact_number <- function(n) {
  n <- suppressWarnings(as.numeric(n)[1L])
  if (is.na(n)) {
    return("n/a")
  }
  if (abs(n) >= 1e6) {
    return(paste0(format(round(n / 1e6, 1), trim = TRUE), "M"))
  }
  if (abs(n) >= 1e3) {
    return(paste0(format(round(n / 1e3, 1), trim = TRUE), "k"))
  }
  format(round(n), trim = TRUE, scientific = FALSE)
}

#' Generate shields.io endpoint badges from the canonical store
#'
#' @description
#' Writes three JSON badge endpoints per curated CRAN package into
#' `output_dir` (SPEC.md S7.4):
#'
#' * `<pkg>-downloads.json` -- downloads over the last 30 days of the
#'   series, e.g. `1.2k/month`, blue.
#' * `<pkg>-check.json` -- the worst `R CMD check` status across flavours,
#'   coloured by severity (`OK` green, `NOTE` yellow, `WARN` orange,
#'   `ERROR`/`FAIL` red, unknown grey) with the flavour count in the text.
#' * `<pkg>-version.json` -- the current CRAN version, blue; red and reading
#'   `archived` when the package has been archived.
#'
#' @details
#' The default `output_dir` sits inside the rendered site because shields.io
#' fetches the endpoint over HTTP from the published GitHub Pages URL. Run
#' this **after** `quarto render`, so the files survive into the deployed
#' `_site/`.
#'
#' A package with no data still gets its three badges, reading `n/a` in
#' grey, so a README badge never 404s while the pipeline is warming up.
#'
#' @param data_dir Directory holding the canonical Parquet store.
#' @param output_dir Directory the badge JSON files are written to. Created
#'   when missing.
#' @param packages Character vector of package names to generate badges for.
#'   Defaults to every package present in the store.
#' @param window_days Length of the download window summarised by the
#'   downloads badge.
#'
#' @return Invisibly, a tibble with one row per badge and the columns
#'   `slug`, `path`, `label`, `message` and `color`.
#'
#' @seealso [export_json()], [consolidate()]
#' @export
#' @examples
#' tmp <- tempfile()
#' dir.create(tmp)
#' # No data yet: placeholder badges are still written.
#' b <- make_badges(
#'   data_dir = file.path(tmp, "data"),
#'   output_dir = file.path(tmp, "badges"),
#'   packages = "gkwreg"
#' )
#' b$slug
#'
#' \dontrun{
#' # In the pipeline, after `quarto render`.
#' make_badges(data_dir = "data", output_dir = "_site/badges")
#' }
make_badges <- function(data_dir = "data", output_dir = "_site/badges",
                        packages = NULL, window_days = 30L) {
  if (!dir.exists(output_dir)) {
    dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
  }

  status <- zb_latest_snapshot(zb_read_table(data_dir, "cran_status"))
  checks <- zb_latest_snapshot(zb_read_table(data_dir, "cran_checks"))
  versions <- zb_read_table(data_dir, "cran_versions")
  downloads <- zb_read_table(data_dir, "cran_downloads")

  if (is.null(packages)) {
    packages <- sort(unique(c(status$package, versions$package, downloads$package)))
    packages <- packages[!is.na(packages)]
  }

  cli::cli_h1("make_badges()")
  cli::cli_alert_info("{length(packages)} package{?s} -> {.path {output_dir}}.")

  dl_end <- if (nrow(downloads)) suppressWarnings(max(downloads$date, na.rm = TRUE)) else as.Date(NA)

  rows <- list()
  emit <- function(slug, label, message, color) {
    path <- file.path(output_dir, paste0(slug, ".json"))
    jsonlite::write_json(
      list(
        schemaVersion = 1L, label = label, message = message, color = color
      ),
      path,
      auto_unbox = TRUE, null = "null", na = "null"
    )
    tibble::tibble(
      slug = slug, path = path, label = label, message = message, color = color
    )
  }

  for (p in packages) {
    # downloads ------------------------------------------------------------
    n_dl <- if (nrow(downloads) && !is.na(dl_end)) {
      sub <- downloads[
        downloads$package == p & downloads$date > dl_end - window_days, ,
        drop = FALSE
      ]
      if (nrow(sub)) sum(sub$downloads, na.rm = TRUE) else NA_real_
    } else {
      NA_real_
    }
    rows[[length(rows) + 1L]] <- emit(
      paste0(p, "-downloads"), "CRAN downloads",
      if (is.na(n_dl)) "n/a" else paste0(zb_compact_number(n_dl), "/month"),
      if (is.na(n_dl)) "lightgrey" else "blue"
    )

    # checks ---------------------------------------------------------------
    st <- status$worst_status[status$package == p]
    st <- if (length(st)) st[1L] else NA_character_
    n_flavors <- sum(checks$package == p, na.rm = TRUE)
    rows[[length(rows) + 1L]] <- emit(
      paste0(p, "-check"), "CRAN checks",
      if (is.na(st)) {
        "unknown"
      } else if (n_flavors > 0L) {
        paste0(st, " (", n_flavors, " flavors)")
      } else {
        st
      },
      zb_status_color(st)
    )

    # version --------------------------------------------------------------
    cv <- versions[
      versions$package == p & !is.na(versions$is_current) & versions$is_current, ,
      drop = FALSE
    ]
    archived <- status$archived[status$package == p]
    archived <- length(archived) > 0L && isTRUE(archived[1L])
    rows[[length(rows) + 1L]] <- emit(
      paste0(p, "-version"), "CRAN",
      if (archived) {
        "archived"
      } else if (nrow(cv)) {
        paste0("v", cv$version[1L])
      } else {
        "n/a"
      },
      if (archived) "red" else if (nrow(cv)) "blue" else "lightgrey"
    )
  }

  out <- purrr::list_rbind(rows)
  cli::cli_alert_success("{nrow(out)} badge{?s} written.")
  invisible(out)
}
