# ---------------------------------------------------------------------------
# Academic collector: publications, preprints, datasets and software.
#
# Writes staging/academic_works.parquet from OpenAlex:
#   api.openalex.org/works?filter=author.orcid:{orcid}
#
# No authentication. OpenAlex asks for a contact address to place the caller
# in its "polite pool"; that address is a repository secret
# (OPENALEX_MAILTO) read from the environment as a default argument value
# and never written to a file or logged.
# ---------------------------------------------------------------------------

#' Extract the publication venue from an OpenAlex work
#'
#' `primary_location$source$display_name` is the canonical venue but is
#' `NULL` for a fair share of records (software and datasets in particular),
#' in which case the raw source name is the best available fallback.
#'
#' @param work One parsed OpenAlex work object.
#' @return Length-1 character vector, possibly `NA`.
#' @keywords internal
#' @noRd
zb_openalex_venue <- function(work) {
  loc <- work$primary_location %||% list()
  v <- loc$source$display_name %||% loc$raw_source_name %||% NA_character_
  as.character(v)[1L]
}

#' Page the OpenAlex `/works` endpoint with a cursor
#'
#' @param orcid ORCID iD.
#' @param mailto Contact address for the polite pool, or `""`.
#' @param from,to Optional `Date` bounds on the publication date.
#' @param per_page Records per request (OpenAlex caps this at 200).
#' @param max_pages Hard cap on requests.
#' @return A list of parsed work objects.
#' @keywords internal
#' @noRd
zb_fetch_openalex_works <- function(orcid, mailto = "", from = NULL, to = NULL,
                                    per_page = 200L, max_pages = 25L) {
  filters <- c(paste0("author.orcid:", orcid))
  if (!is.null(from)) filters <- c(filters, paste0("from_publication_date:", format(from)))
  if (!is.null(to)) filters <- c(filters, paste0("to_publication_date:", format(to)))

  works <- list()
  cursor <- "*"
  for (i in seq_len(max_pages)) {
    req <- httr2::request("https://api.openalex.org/works")
    query <- list(
      filter = paste(filters, collapse = ","),
      select = paste(
        c(
          "id", "doi", "title", "display_name", "publication_year",
          "publication_date", "type", "cited_by_count", "primary_location"
        ),
        collapse = ","
      ),
      cursor = cursor
    )
    query[["per-page"]] <- per_page
    if (nzchar(mailto)) query$mailto <- mailto
    req <- httr2::req_url_query(req, !!!query)

    body <- httr2::resp_body_json(zb_req_perform(req))
    page <- body$results %||% list()
    works <- c(works, page)
    cursor <- body$meta$next_cursor %||% NULL
    if (length(page) == 0L || is.null(cursor)) break
  }
  works
}

#' Build the `academic_works` snapshot from OpenAlex work objects
#'
#' @param works List of parsed OpenAlex work objects.
#' @param snapshot_date Snapshot date for the rows.
#' @return An `academic_works` tibble.
#' @keywords internal
#' @noRd
zb_build_academic_works <- function(works, snapshot_date) {
  cols <- zb_schema("academic_works")$cols
  if (length(works) == 0L) {
    return(zb_empty("academic_works"))
  }
  chr1 <- function(x) as.character(x %||% NA_character_)[1L]
  df <- tibble::tibble(
    snapshot_date = zb_as_date(snapshot_date)[1L],
    work_id = vapply(works, function(w) chr1(w$id), character(1)),
    doi = vapply(works, function(w) chr1(w$doi), character(1)),
    title = vapply(works, function(w) chr1(w$title %||% w$display_name), character(1)),
    venue = vapply(works, zb_openalex_venue, character(1)),
    year = vapply(works, function(w) as.integer(w$publication_year %||% NA_integer_)[1L], integer(1)),
    type = vapply(works, function(w) chr1(w$type), character(1)),
    cited_by_count = vapply(
      works, function(w) as.integer(w$cited_by_count %||% NA_integer_)[1L], integer(1)
    )
  )
  df <- df[!is.na(df$work_id), , drop = FALSE]
  df <- zb_dedupe_last(df, c("snapshot_date", "work_id"))
  zb_coerce(df, cols)
}

#' Collect academic output from OpenAlex
#'
#' @description
#' Collects the `academic_works` snapshot -- publications,
#' preprints, datasets and software attributed to the ORCID iD configured in
#' `config/repos.yml`, with their venue, year, type and accumulated citation
#' count -- and writes it as `staging_dir/academic_works.parquet` for
#' [consolidate()].
#'
#' @details
#' **Polite pool.** OpenAlex serves anonymous callers from a slower, shared
#' pool. Supplying a contact address moves the caller to the polite pool.
#' The address is a repository secret: it is read from
#' `OPENALEX_MAILTO` as the default of the `mailto` argument, is never
#' hard-coded, and is never written to any output file. When the variable is
#' unset the collector still runs, unauthenticated, and says so.
#'
#' **What `from`/`to` mean here.** `academic_works` is a snapshot keyed by
#' `(snapshot_date, work_id)`, so there is no past state to rebuild. An
#' explicit window is therefore interpreted as a filter on the *publication
#' date* of the works to collect (OpenAlex's `from_publication_date` /
#' `to_publication_date`), not as a range of snapshots. The default, `NULL`,
#' collects the whole body of work in every run.
#'
#' **Type values.** `type` is stored exactly as OpenAlex reports it
#' (`article`, `preprint`, `dataset`, `book-chapter`, ...). The column is
#' deliberately not normalised onto a closed set of values; doing so would
#' discard information the dashboard can display verbatim.
#'
#' Only the author's own works are collected. No co-author name, identifier
#' or affiliation is stored.
#'
#' @param from Optional lower bound on publication date, as an ISO-8601 date
#'   string or a `Date`. `NULL` (the default) applies no lower bound.
#' @param to Optional upper bound on publication date, same forms as `from`.
#' @param config_path Path to the curated source configuration.
#' @param staging_dir Directory the staging Parquet file is written to.
#'   Created when missing.
#' @param mailto Contact address for the OpenAlex polite pool. Defaults to
#'   the `OPENALEX_MAILTO` environment variable, and to `""` (anonymous
#'   pool) when that is unset.
#' @param run_ts Timestamp shared by every manifest row of this run.
#'
#' @return Invisibly, a tibble with the `run_manifest` schema: one row for
#'   the `academic_works` source. The same row is written to
#'   `staging_dir/run_manifest_academic.parquet`.
#'
#' @seealso [collect_cran()], [collect_github()], [consolidate()]
#' @export
#' @examples
#' \dontrun{
#' Sys.setenv(OPENALEX_MAILTO = "you@example.com")
#' collect_academic()
#'
#' # Only works published from 2024 onwards.
#' collect_academic(from = "2024-01-01")
#' }
collect_academic <- function(from = NULL, to = NULL,
                             config_path = "config/repos.yml",
                             staging_dir = "staging",
                             mailto = Sys.getenv("OPENALEX_MAILTO", ""),
                             run_ts = Sys.time()) {
  cfg <- read_repos_config(config_path)
  orcid <- cfg$orcid
  snapshot_date <- Sys.Date()
  mailto <- as.character(mailto)[1L]
  if (is.na(mailto)) mailto <- ""

  cli::cli_h1("collect_academic()")
  if (is.na(orcid)) {
    cli::cli_alert_warning("No {.field orcid} configured in {.path {config_path}}; nothing to collect.")
  } else {
    cli::cli_alert_info("ORCID {.val {orcid}}.")
  }
  if (!nzchar(mailto)) {
    cli::cli_alert_warning(
      "No {.envvar OPENALEX_MAILTO} set; using the anonymous OpenAlex pool (slower, no guarantees)."
    )
  }

  bounds <- list(
    from = if (zb_is_backfill(from, NULL)) zb_as_date(from)[1L] else NULL,
    to = if (zb_is_backfill(to, NULL)) zb_as_date(to)[1L] else NULL
  )
  if (!is.null(bounds$from) || !is.null(bounds$to)) {
    cli::cli_alert_info(
      "Window applied as an OpenAlex publication-date filter, not as a snapshot range."
    )
  }

  manifest <- zb_run_source(
    "academic_works",
    function() {
      if (is.na(orcid)) {
        return(zb_result(
          zb_empty("academic_works"), "partial",
          "No ORCID configured; academic collection skipped."
        ))
      }
      works <- zb_fetch_openalex_works(orcid, mailto, bounds$from, bounds$to)
      zb_result(zb_build_academic_works(works, snapshot_date))
    },
    staging_dir, run_ts
  )

  zb_write_staging_manifest(manifest, staging_dir, "academic")
  invisible(manifest)
}
