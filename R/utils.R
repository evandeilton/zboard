# ---------------------------------------------------------------------------
# Internal helpers for the zboard pipeline.
#
# Nothing in this file is exported. The public surface of the package is the
# seven pipeline entry points (collect_cran(), collect_github(),
# collect_academic(), consolidate(), export_json(), make_badges(),
# run_alerts()); everything here supports them.
#
# Design notes
# ------------
# * The canonical table schemas of SPEC.md S4.2 live in one place --
#   `zb_schemas()` -- together with the natural key, the merge semantics
#   (S4.2), and the retention policy (S4.3). Every read, write, upsert,
#   rollup and prune consults that registry instead of re-stating column
#   names, so a schema change is a one-line change.
# * All HTTP goes through `zb_req_perform()` (httr2) or `zb_retry()`
#   (everything else: gh, cranlogs, tools::CRAN_*). Both implement RNF-7:
#   3 attempts, exponential backoff on 5xx/timeouts, `Retry-After` honoured
#   on 429.
# * `zb_sanitize()` is the single chokepoint for anything that ends up in
#   `run_manifest$message`, which is published as public JSON (SPEC.md S11).
# ---------------------------------------------------------------------------

#' @importFrom rlang %||% .data
NULL

# -- severity ---------------------------------------------------------------

#' CRAN check status severity levels
#'
#' The five `R CMD check` outcomes of SPEC.md S4.2, in increasing severity.
#' `tools::CRAN_check_results()` spells two of them differently
#' (`WARNING`, `FAILURE`); `zb_normalize_status()` maps those onto the
#' spec's enum.
#'
#' @return Character vector of length 5, ordered from least to most severe.
#' @keywords internal
#' @noRd
zb_status_levels <- function() {
  c("OK", "NOTE", "WARN", "ERROR", "FAIL")
}

#' Normalise a CRAN check status onto the SPEC.md enum
#'
#' @param x Character or factor vector of raw statuses.
#' @return Character vector using the `OK`/`NOTE`/`WARN`/`ERROR`/`FAIL` enum;
#'   unrecognised values become `NA_character_`.
#' @keywords internal
#' @noRd
zb_normalize_status <- function(x) {
  x <- toupper(trimws(as.character(x)))
  x[x == "WARNING"] <- "WARN"
  x[x == "FAILURE"] <- "FAIL"
  x[!x %in% zb_status_levels()] <- NA_character_
  x
}

#' Worst (most severe) status in a vector
#'
#' @param x Character vector of normalised statuses.
#' @return Length-1 character vector, or `NA_character_` when `x` has no
#'   recognised status.
#' @keywords internal
#' @noRd
zb_worst_status <- function(x) {
  x <- zb_normalize_status(x)
  x <- x[!is.na(x)]
  if (length(x) == 0L) {
    return(NA_character_)
  }
  lv <- zb_status_levels()
  lv[max(match(x, lv))]
}

# -- coercion ---------------------------------------------------------------

#' Coerce to `Date`, tolerating `NULL`, `Date`, character and `POSIXt`
#'
#' @param x Value to coerce.
#' @return A `Date` vector.
#' @keywords internal
#' @noRd
zb_as_date <- function(x) {
  if (is.null(x) || length(x) == 0L) {
    return(as.Date(character()))
  }
  if (inherits(x, "Date")) {
    return(x)
  }
  if (inherits(x, "POSIXt")) {
    return(as.Date(x, tz = "UTC"))
  }
  as.Date(substr(as.character(x), 1L, 10L), format = "%Y-%m-%d")
}

#' Coerce to UTC `POSIXct`, tolerating `NULL`, ISO-8601 strings and `Date`
#'
#' @param x Value to coerce.
#' @return A `POSIXct` vector in UTC.
#' @keywords internal
#' @noRd
zb_as_ts <- function(x) {
  if (is.null(x) || length(x) == 0L) {
    return(as.POSIXct(character(), tz = "UTC"))
  }
  if (inherits(x, "POSIXt")) {
    return(as.POSIXct(x, tz = "UTC"))
  }
  if (inherits(x, "Date")) {
    return(as.POSIXct(format(x, "%Y-%m-%d 00:00:00"), tz = "UTC"))
  }
  suppressWarnings(lubridate::ymd_hms(as.character(x), tz = "UTC", quiet = TRUE))
}

#' Format a date/timestamp as an ISO-8601 string for JSON export
#'
#' Dates become `YYYY-MM-DD`; timestamps become `YYYY-MM-DDTHH:MM:SSZ`.
#' `NA` becomes `NA_character_` (which `jsonlite` renders as `null`).
#'
#' @param x A `Date` or `POSIXt` vector.
#' @return Character vector.
#' @keywords internal
#' @noRd
zb_iso <- function(x) {
  if (inherits(x, "Date")) {
    out <- format(x, "%Y-%m-%d")
  } else if (inherits(x, "POSIXt")) {
    out <- format(as.POSIXct(x, tz = "UTC"), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  } else {
    out <- as.character(x)
  }
  out[is.na(x)] <- NA_character_
  out
}

#' Typed `NA` of a given schema type
#'
#' @param type One of `"date"`, `"ts"`, `"chr"`, `"int"`, `"dbl"`, `"lgl"`.
#' @param n Length of the returned vector.
#' @return A length-`n` vector of `NA` of the requested type.
#' @keywords internal
#' @noRd
zb_na_of <- function(type, n = 0L) {
  switch(type,
    date = rep(as.Date(NA), n),
    ts   = rep(as.POSIXct(NA, tz = "UTC"), n),
    chr  = rep(NA_character_, n),
    int  = rep(NA_integer_, n),
    dbl  = rep(NA_real_, n),
    lgl  = rep(NA, n),
    cli::cli_abort("Unknown schema type {.val {type}}.")
  )
}

#' Coerce a data frame onto a column specification
#'
#' Missing columns are added as typed `NA`; extra columns are dropped;
#' column order follows `cols`. This is the single point where Arrow-facing
#' types are pinned down, which keeps Parquet schemas stable across runs
#' (an inconsistent schema would make `arrow::open_dataset()` and every
#' downstream `bind_rows()` fail unpredictably).
#'
#' @param df A data frame (or `NULL`).
#' @param cols Named character vector: names are column names, values are
#'   schema types accepted by `zb_na_of()`.
#' @return A tibble with exactly the columns of `cols`, in that order.
#' @keywords internal
#' @noRd
zb_coerce <- function(df, cols) {
  n <- if (is.null(df)) 0L else nrow(df)
  out <- vector("list", length(cols))
  names(out) <- names(cols)
  for (nm in names(cols)) {
    type <- cols[[nm]]
    v <- if (!is.null(df) && nm %in% names(df)) df[[nm]] else zb_na_of(type, n)
    if (length(v) == 0L && n > 0L) v <- zb_na_of(type, n)
    out[[nm]] <- switch(type,
      date = zb_as_date(v),
      ts   = zb_as_ts(v),
      chr  = as.character(v),
      int  = suppressWarnings(as.integer(v)),
      dbl  = suppressWarnings(as.numeric(v)),
      lgl  = as.logical(v)
    )
    if (length(out[[nm]]) != n) {
      out[[nm]] <- rep(out[[nm]], length.out = n)
    }
  }
  tibble::as_tibble(out)
}

# -- schema registry --------------------------------------------------------

#' Canonical table registry
#'
#' One entry per table of SPEC.md S4.2. Each entry records:
#' \describe{
#'   \item{cols}{named character vector `column = type` (see `zb_na_of()`)}
#'   \item{keys}{natural key used for the idempotent upsert (S4.1)}
#'   \item{merge}{`"last"` (last-write-wins) or `"max"` -- only `gh_traffic`
#'     uses `"max"`, because a mid-day read returns a partial count and
#'     overwriting with a smaller value destroys consolidated data (S4.2)}
#'   \item{date_col}{column that carries the retention window's date}
#'   \item{rollup}{`"sum"`, `"last"` (last snapshot of the month) or `"none"`
#'     (S4.3)}
#'   \item{prune}{whether the 12-month rolling window applies (S4.3);
#'     `cran_versions` and `gh_releases` are permanent}
#'   \item{group}{extra grouping columns for the monthly rollup, i.e. the
#'     natural key minus the date column}
#' }
#'
#' @return A named list of table specifications.
#' @keywords internal
#' @noRd
zb_schemas <- function() {
  list(
    cran_downloads = list(
      cols = c(date = "date", package = "chr", downloads = "int"),
      keys = c("date", "package"), merge = "last",
      date_col = "date", group = "package", rollup = "sum", prune = TRUE
    ),
    cran_versions = list(
      cols = c(
        package = "chr", version = "chr", release_date = "date",
        is_current = "lgl"
      ),
      keys = c("package", "version"), merge = "last",
      date_col = "release_date", group = c("package", "version"),
      rollup = "none", prune = FALSE
    ),
    cran_checks = list(
      cols = c(
        snapshot_date = "date", package = "chr", version = "chr",
        flavor = "chr", status = "chr", check_time = "dbl"
      ),
      keys = c("snapshot_date", "package", "flavor"), merge = "last",
      date_col = "snapshot_date", group = c("package", "flavor"),
      rollup = "last", prune = TRUE
    ),
    cran_status = list(
      cols = c(
        snapshot_date = "date", package = "chr", on_cran = "lgl",
        archived = "lgl", maintainer = "chr", worst_status = "chr"
      ),
      keys = c("snapshot_date", "package"), merge = "last",
      date_col = "snapshot_date", group = "package",
      rollup = "last", prune = TRUE
    ),
    gh_activity = list(
      cols = c(
        date = "date", repo = "chr", commits = "int", prs_opened = "int",
        prs_merged = "int", prs_closed = "int", issues_opened = "int",
        issues_closed = "int"
      ),
      keys = c("date", "repo"), merge = "last",
      date_col = "date", group = "repo", rollup = "sum", prune = TRUE
    ),
    gh_repo_snapshot = list(
      cols = c(
        snapshot_date = "date", repo = "chr", stars = "int", forks = "int",
        watchers = "int", open_issues = "int", open_prs = "int",
        oldest_open_issue_days = "int", last_push_at = "ts", archived = "lgl"
      ),
      keys = c("snapshot_date", "repo"), merge = "last",
      date_col = "snapshot_date", group = "repo", rollup = "last", prune = TRUE
    ),
    gh_traffic = list(
      cols = c(
        date = "date", repo = "chr", views = "int", view_uniques = "int",
        clones = "int", clone_uniques = "int"
      ),
      keys = c("date", "repo"), merge = "max",
      date_col = "date", group = "repo", rollup = "sum", prune = TRUE
    ),
    gh_releases = list(
      cols = c(
        repo = "chr", tag = "chr", name = "chr", published_at = "ts",
        is_prerelease = "lgl"
      ),
      keys = c("repo", "tag"), merge = "last",
      date_col = "published_at", group = c("repo", "tag"),
      rollup = "none", prune = FALSE
    ),
    academic_works = list(
      cols = c(
        snapshot_date = "date", work_id = "chr", doi = "chr", title = "chr",
        venue = "chr", year = "int", type = "chr", cited_by_count = "int"
      ),
      keys = c("snapshot_date", "work_id"), merge = "last",
      date_col = "snapshot_date", group = "work_id", rollup = "last",
      prune = TRUE
    ),
    run_manifest = list(
      cols = c(
        run_ts = "ts", source = "chr", status = "chr", rows_written = "int",
        duration_s = "dbl", message = "chr"
      ),
      keys = c("run_ts", "source"), merge = "last",
      date_col = "run_ts", group = "source",
      # Pipeline telemetry, not published data: pruned to the same rolling
      # window so the `data` branch stays small (RNF-9), but never rolled up
      # -- a monthly aggregate of run statuses would be meaningless.
      rollup = "none", prune = TRUE
    )
  )
}

#' Look up one table specification
#'
#' @param tbl Table name.
#' @return The specification list for `tbl`.
#' @keywords internal
#' @noRd
zb_schema <- function(tbl) {
  s <- zb_schemas()
  if (!tbl %in% names(s)) {
    cli::cli_abort("Unknown table {.val {tbl}}.")
  }
  s[[tbl]]
}

#' Empty, fully typed tibble for a table
#'
#' An absent Parquet file is not an error anywhere in this pipeline
#' (SPEC.md RNF-3): a missing table is an empty table.
#'
#' @param tbl Table name.
#' @return A zero-row tibble with the canonical schema.
#' @keywords internal
#' @noRd
zb_empty <- function(tbl) {
  zb_coerce(NULL, zb_schema(tbl)$cols)
}

# -- parquet I/O ------------------------------------------------------------

#' Read a pipeline table from Parquet
#'
#' @param dir Directory holding `<tbl>.parquet`.
#' @param tbl Table name (also the file stem).
#' @param coerce Whether to coerce onto the canonical schema. Set `FALSE`
#'   for archive tables, which carry a derived schema.
#' @return A tibble; zero rows (typed) when the file does not exist.
#' @keywords internal
#' @noRd
zb_read_table <- function(dir, tbl, coerce = TRUE) {
  path <- file.path(dir, paste0(tbl, ".parquet"))
  if (!file.exists(path)) {
    return(if (coerce) zb_empty(tbl) else tibble::tibble())
  }
  df <- tibble::as_tibble(arrow::read_parquet(path))
  if (coerce) zb_coerce(df, zb_schema(tbl)$cols) else df
}

#' Write a pipeline table to Parquet
#'
#' Uses zstd compression (SPEC.md S4.1) when the Arrow build supports it,
#' falling back to Arrow's default otherwise.
#'
#' @param df Data frame to write.
#' @param dir Destination directory; created when missing.
#' @param tbl Table name (also the file stem).
#' @return The path written, invisibly.
#' @keywords internal
#' @noRd
zb_write_table <- function(df, dir, tbl) {
  if (!dir.exists(dir)) {
    dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  }
  path <- file.path(dir, paste0(tbl, ".parquet"))
  compression <- if (isTRUE(arrow::codec_is_available("zstd"))) "zstd" else "uncompressed"
  arrow::write_parquet(tibble::as_tibble(df), path, compression = compression)
  invisible(path)
}

# -- upsert -----------------------------------------------------------------

#' `max()` ignoring `NA`, preserving the input type
#'
#' @param x A numeric vector.
#' @return Length-1 vector of the same type as `x`.
#' @keywords internal
#' @noRd
zb_max_na <- function(x) {
  ok <- !is.na(x)
  if (!any(ok)) {
    return(x[NA_integer_][1L])
  }
  max(x[ok])
}

#' Collapse duplicate keys inside a single batch, keeping the last row
#'
#' @param df A data frame.
#' @param keys Character vector of key columns.
#' @return `df` with at most one row per key.
#' @keywords internal
#' @noRd
zb_dedupe_last <- function(df, keys) {
  if (nrow(df) == 0L) {
    return(df)
  }
  dup <- duplicated(df[, keys, drop = FALSE], fromLast = TRUE)
  df[!dup, , drop = FALSE]
}

#' Idempotent upsert by natural key
#'
#' Implements the two merge semantics of SPEC.md S4.2:
#' * `"last"` -- last-write-wins. Incoming rows replace existing rows with
#'   the same key; keys absent from `new` are untouched.
#' * `"max"` -- element-wise `max()` per key over every numeric column. Used
#'   only by `gh_traffic`: the GitHub traffic API returns a partial count
#'   for the current day, and last-write-wins would overwrite a full day
#'   with a smaller, partial value. The source is irrecoverable (14-day
#'   retention), so the loss would be permanent.
#'
#' Re-running with identical input is a no-op in both modes, which is what
#' RNF-5 requires.
#'
#' @param old Existing table (possibly zero rows).
#' @param new Incoming rows (possibly zero rows).
#' @param keys Character vector of key columns.
#' @param merge `"last"` or `"max"`.
#' @param cols Optional column specification to coerce the result onto.
#' @return A tibble.
#' @keywords internal
#' @noRd
zb_upsert <- function(old, new, keys, merge = c("last", "max"), cols = NULL) {
  merge <- match.arg(merge)
  if (!is.null(cols)) {
    old <- zb_coerce(old, cols)
    new <- zb_coerce(new, cols)
  }
  # Row order is part of the output, not an accident: two runs that agree on
  # content must also agree byte-for-byte on the Parquet they write, or
  # RNF-5 ("same state") is only true up to a permutation and the `data`
  # branch churns a full rewrite every day. The sort is radix (C locale) so
  # it does not depend on the runner's collation.
  sort_by_keys <- function(df) {
    df <- tibble::as_tibble(df)
    if (nrow(df) <= 1L) {
      return(df)
    }
    idx <- do.call(
      order, c(as.list(df[, keys, drop = FALSE]), list(method = "radix"))
    )
    df[idx, , drop = FALSE]
  }

  if (is.null(new) || nrow(new) == 0L) {
    return(sort_by_keys(old %||% tibble::tibble()))
  }
  new <- zb_dedupe_last(tibble::as_tibble(new), keys)
  if (is.null(old) || nrow(old) == 0L) {
    return(sort_by_keys(new))
  }
  old <- tibble::as_tibble(old)

  final_names <- union(names(old), names(new))

  if (merge == "last") {
    keep <- dplyr::anti_join(old, new, by = keys)
    out <- dplyr::bind_rows(keep, new)
  } else {
    combined <- dplyr::bind_rows(old, new)
    num_cols <- setdiff(
      names(combined)[vapply(combined, is.numeric, logical(1))], keys
    )
    oth_cols <- setdiff(names(combined), c(keys, num_cols))
    out <- dplyr::summarise(
      dplyr::group_by(combined, dplyr::across(dplyr::all_of(keys))),
      dplyr::across(dplyr::all_of(num_cols), zb_max_na),
      dplyr::across(dplyr::all_of(oth_cols), dplyr::last),
      .groups = "drop"
    )
  }
  out <- out[, final_names, drop = FALSE]
  if (!is.null(cols)) out <- zb_coerce(out, cols)
  sort_by_keys(out)
}

# -- retry / HTTP -----------------------------------------------------------

#' HTTP status carried by an error condition
#'
#' Works for both `httr2` (`httr2_http_429`) and `gh` (`http_error_502`)
#' conditions, whose classes both end in the three-digit status.
#'
#' @param e A condition object.
#' @return Integer status, or `NA_integer_`.
#' @keywords internal
#' @noRd
zb_http_status <- function(e) {
  cls <- class(e)
  m <- regmatches(cls, regexpr("[0-9]{3}$", cls))
  m <- suppressWarnings(as.integer(m))
  m <- m[!is.na(m)]
  if (length(m)) {
    return(m[1L])
  }
  for (f in c("status", "response_status", "http_status")) {
    v <- suppressWarnings(tryCatch(e[[f]], error = function(...) NULL))
    if (!is.null(v) && length(v) == 1L && !is.na(suppressWarnings(as.integer(v)))) {
      return(as.integer(v))
    }
  }
  NA_integer_
}

#' Is an error condition worth retrying? (RNF-7)
#'
#' @param e A condition object.
#' @return `TRUE` for 429/5xx and for transport-level timeouts.
#' @keywords internal
#' @noRd
zb_is_transient <- function(e) {
  st <- zb_http_status(e)
  if (!is.na(st)) {
    return(st == 429L || st >= 500L)
  }
  msg <- tolower(paste(conditionMessage(e), collapse = " "))
  any(vapply(
    c(
      "timeout", "timed out", "connection", "could not resolve",
      "temporarily unavailable", "recv failure", "ssl", "curl"
    ),
    function(p) grepl(p, msg, fixed = TRUE),
    logical(1)
  ))
}

#' `Retry-After` value carried by an error condition, in seconds
#'
#' @param e A condition object.
#' @return Numeric seconds, or `NULL` when the header is absent.
#' @keywords internal
#' @noRd
zb_retry_after <- function(e) {
  hdrs <- NULL
  resp <- suppressWarnings(tryCatch(e$resp, error = function(...) NULL))
  if (!is.null(resp)) {
    hdrs <- suppressWarnings(tryCatch(
      httr2::resp_headers(resp),
      error = function(...) NULL
    ))
  }
  if (is.null(hdrs)) {
    hdrs <- suppressWarnings(tryCatch(
      e$response_headers,
      error = function(...) NULL
    ))
  }
  if (is.null(hdrs)) {
    return(NULL)
  }
  names(hdrs) <- tolower(names(hdrs))
  v <- hdrs[["retry-after"]]
  if (is.null(v)) {
    return(NULL)
  }
  v <- suppressWarnings(as.numeric(v))
  if (is.na(v)) NULL else v
}

#' Retry a call with exponential backoff (RNF-7)
#'
#' Three attempts by default; the delay doubles on each retry and a
#' `Retry-After` header, when present, overrides it. Non-transient errors
#' (4xx other than 429, parse errors, ...) are re-raised immediately -- a
#' 401 from an expired PAT must fail loudly, not after 3 sleeps.
#'
#' Used for every network call that is not an `httr2` request:
#' `gh::gh()`, `gh::gh_gql()`, `cranlogs::cran_downloads()` and the
#' `tools::CRAN_*()` readers. `httr2` requests use `zb_req_perform()`.
#'
#' @param f A zero-argument function performing the call.
#' @param max_tries Maximum number of attempts.
#' @param base_delay Seconds before the first retry.
#' @param label Short label used in the retry message.
#' @param quiet Suppress the retry message.
#' @return The value of `f()`.
#' @keywords internal
#' @noRd
zb_retry <- function(f, max_tries = 3L, base_delay = 1, label = "request",
                     quiet = FALSE) {
  stopifnot(is.function(f))
  max_tries <- max(1L, as.integer(max_tries))
  for (i in seq_len(max_tries)) {
    res <- tryCatch(f(), error = function(e) e)
    if (!inherits(res, "error")) {
      return(res)
    }
    if (i == max_tries || !zb_is_transient(res)) {
      stop(res)
    }
    delay <- zb_retry_after(res) %||% (base_delay * 2^(i - 1L))
    delay <- min(delay, 120)
    if (!quiet) {
      cli::cli_alert_warning(
        "{label}: transient failure (attempt {i}/{max_tries}), retrying in {round(delay, 1)}s."
      )
    }
    Sys.sleep(delay)
  }
  invisible(NULL)
}

#' Perform an httr2 request with the pipeline's retry policy (RNF-7)
#'
#' @param req An `httr2_request`.
#' @param max_tries Maximum number of attempts.
#' @param timeout Per-attempt timeout in seconds.
#' @return An `httr2_response`.
#' @keywords internal
#' @noRd
zb_req_perform <- function(req, max_tries = 3L, timeout = 60) {
  req <- httr2::req_user_agent(
    req,
    "zboard (https://github.com/evandeilton/zboard)"
  )
  req <- httr2::req_timeout(req, timeout)
  req <- httr2::req_retry(
    req,
    max_tries = max_tries,
    backoff = function(i) min(2^i, 60),
    is_transient = function(resp) httr2::resp_status(resp) %in% c(429L, 500L, 502L, 503L, 504L)
  )
  httr2::req_perform(req)
}

# -- sanitisation -----------------------------------------------------------

#' Sanitise and truncate a message destined for `run_manifest`
#'
#' `run_manifest$message` is exported verbatim to public JSON
#' (SPEC.md S11), so it must never carry a token, a PAT, a URL credential
#' or a third-party e-mail address (NG-5). This redacts, in order:
#' the literal values of the pipeline's own secret environment variables,
#' GitHub token shapes, `key: value` pairs whose key looks like a
#' credential, e-mail addresses, and `user:pass@host` URL credentials.
#' The result is squished and truncated to `max_chars` (SPEC.md S4.2).
#'
#' @param x Message (any length; collapsed to one string).
#' @param max_chars Maximum length of the result.
#' @return A length-1 character vector, or `NA_character_` for empty input.
#' @keywords internal
#' @noRd
zb_sanitize <- function(x, max_chars = 500L) {
  x <- as.character(x)
  x <- x[!is.na(x)]
  if (length(x) == 0L) {
    return(NA_character_)
  }
  x <- paste(x, collapse = " ")
  if (!nzchar(trimws(x))) {
    return(NA_character_)
  }

  secret_vars <- c(
    "GITHUB_TOKEN", "GITHUB_PAT", "GH_TOKEN", "GH_PAT",
    "GH_FINE_GRAINED_PAT", "OPENALEX_MAILTO"
  )
  secrets <- unlist(lapply(secret_vars, Sys.getenv), use.names = FALSE)
  secrets <- unique(secrets[nzchar(secrets) & nchar(secrets) >= 6L])
  for (s in secrets) {
    x <- gsub(s, "<redacted>", x, fixed = TRUE)
  }

  x <- stringr::str_replace_all(x, "gh[pousr]_[A-Za-z0-9]{16,}", "<redacted>")
  x <- stringr::str_replace_all(x, "github_pat_[A-Za-z0-9_]{20,}", "<redacted>")
  x <- stringr::str_replace_all(
    x,
    "(?i)(authorization|token|bearer|api[-_ ]?key|password|secret)([\"' ]*[:=][\"' ]*|\\s+)\\S+",
    "\\1=<redacted>"
  )
  # URL credentials first: "https://user:pw@host" would otherwise be eaten by
  # the e-mail pattern and reported as a redacted address, which is true but
  # misleading about what was found.
  x <- stringr::str_replace_all(x, "://[^/@[:space:]]+@", "://<redacted>@")
  x <- stringr::str_replace_all(
    x, "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", "<redacted-email>"
  )

  x <- stringr::str_squish(x)
  if (nchar(x) > max_chars) {
    x <- paste0(substr(x, 1L, max_chars - 3L), "...")
  }
  x
}

#' Strip the e-mail address from a `Maintainer` field
#'
#' `cran_status$maintainer` is collected verbatim from CRAN, which includes
#' an address. `export_json()` publishes that column, so the address is
#' removed by default before it reaches a public JSON file (SPEC.md S11).
#'
#' @param x Character vector of `Name <mail@@example.com>` strings.
#' @return Character vector with the bracketed address removed.
#' @keywords internal
#' @noRd
zb_strip_email <- function(x) {
  out <- stringr::str_replace_all(
    as.character(x), "\\s*<[^>]*@[^>]*>", ""
  )
  out <- stringr::str_replace_all(
    out, "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", ""
  )
  stringr::str_squish(out)
}

# -- manifest ---------------------------------------------------------------

#' Build one `run_manifest` row
#'
#' @param source Source name (a table name, or `"consolidate"`).
#' @param status One of `"ok"`, `"partial"`, `"failed"`.
#' @param rows_written Number of rows produced.
#' @param duration_s Elapsed seconds.
#' @param message Free text; sanitised and truncated by `zb_sanitize()`.
#' @param run_ts Run timestamp shared by every row of one execution.
#' @return A one-row tibble with the `run_manifest` schema.
#' @keywords internal
#' @noRd
zb_manifest_row <- function(source, status = "ok", rows_written = 0L,
                            duration_s = NA_real_, message = NA_character_,
                            run_ts = Sys.time()) {
  status <- match.arg(status, c("ok", "partial", "failed"))
  zb_coerce(
    tibble::tibble(
      run_ts = zb_as_ts(run_ts),
      source = as.character(source),
      status = status,
      rows_written = as.integer(rows_written),
      duration_s = as.numeric(duration_s),
      message = zb_sanitize(message)
    ),
    zb_schema("run_manifest")$cols
  )
}

#' Write the collector-side manifest into the staging directory
#'
#' Collectors own the status of their own sources: a source that failed
#' outright leaves no data file behind, so without this sidecar
#' `consolidate()` could not tell "did not run" from "ran and failed".
#' One file per collector avoids a name collision when the three collector
#' jobs' artifacts are merged into a single staging directory.
#'
#' @param rows A tibble of `zb_manifest_row()` rows.
#' @param staging_dir Staging directory.
#' @param collector Collector name (`"cran"`, `"github"`, `"academic"`).
#' @return The path written, invisibly, or `NULL` when `rows` is empty.
#' @keywords internal
#' @noRd
zb_write_staging_manifest <- function(rows, staging_dir, collector) {
  if (is.null(rows) || nrow(rows) == 0L) {
    return(invisible(NULL))
  }
  rows <- zb_coerce(rows, zb_schema("run_manifest")$cols)
  zb_write_table(rows, staging_dir, paste0("run_manifest_", collector))
}

#' Wrap a sub-collector's return value
#'
#' Lets a sub-collector report a degraded-but-usable outcome (`"partial"`)
#' without throwing -- e.g. 3 of 4 packages fetched from crandb.
#'
#' @param data A data frame.
#' @param status One of `"ok"`, `"partial"`, `"failed"`.
#' @param message Free text explaining a non-`"ok"` status.
#' @return A list with `data`, `status` and `message`.
#' @keywords internal
#' @noRd
zb_result <- function(data, status = "ok", message = NA_character_) {
  list(data = data, status = status, message = message)
}

#' Run one sub-collector, write its staging table, return its manifest row
#'
#' The isolation boundary required by RNF-3: an error inside `fn` is caught,
#' logged (sanitised) and turned into a `failed` manifest row, so the
#' remaining sources of the same collector still run and still publish.
#'
#' @param source Source name; also the staging table name unless `tbl` is given.
#' @param fn Zero-argument function returning a data frame or a `zb_result()`.
#' @param staging_dir Directory to write the staging Parquet into.
#' @param run_ts Run timestamp shared by every row of one execution.
#' @param tbl Staging table name.
#' @return A one-row `run_manifest` tibble.
#' @keywords internal
#' @noRd
zb_run_source <- function(source, fn, staging_dir, run_ts, tbl = source) {
  t0 <- proc.time()[["elapsed"]]
  res <- tryCatch(fn(), error = function(e) e)
  dur <- round(proc.time()[["elapsed"]] - t0, 3)
  if (inherits(res, "error")) {
    msg <- zb_sanitize(conditionMessage(res))
    cli::cli_alert_danger("{.field {source}}: failed after {dur}s -- {msg}")
    return(zb_manifest_row(source, "failed", 0L, dur, msg, run_ts))
  }
  if (!is.list(res) || !"data" %in% names(res)) {
    res <- zb_result(res)
  }
  df <- tibble::as_tibble(res$data)
  zb_write_table(df, staging_dir, tbl)
  status <- res$status %||% "ok"
  cli::cli_alert_success(
    "{.field {source}}: {nrow(df)} row{?s} in {dur}s ({status})."
  )
  zb_manifest_row(source, status, nrow(df), dur, res$message, run_ts)
}

# -- misc -------------------------------------------------------------------

#' Split `owner/name` into its two parts
#'
#' @param repo A single `"owner/name"` string.
#' @return A list with `owner` and `name`.
#' @keywords internal
#' @noRd
zb_split_repo <- function(repo) {
  parts <- strsplit(as.character(repo)[1L], "/", fixed = TRUE)[[1L]]
  if (length(parts) != 2L || !all(nzchar(parts))) {
    cli::cli_abort("Repository {.val {repo}} is not in {.code owner/name} form.")
  }
  list(owner = parts[1L], name = parts[2L])
}

#' Resolve a `from`/`to` collection window
#'
#' `NULL` means "normal incremental mode": a rolling window ending
#' `end_offset` days before today and `default_days` long. Re-collecting a
#' rolling window (rather than only yesterday) is deliberate: the upstream
#' sources restate recent days, and last-write-wins makes the repeated
#' write free, so the series self-heals after an outage (RNF-3).
#'
#' @param from Start date (`Date`, ISO string, `NULL` or `NA`).
#' @param to End date (`Date`, ISO string, `NULL` or `NA`).
#' @param default_days Window length used when `from` is not supplied.
#' @param end_offset Days between today and the default `to`.
#' @param today Reference date.
#' @return A list with `Date` elements `from` and `to`.
#' @keywords internal
#' @noRd
zb_window <- function(from = NULL, to = NULL, default_days = 35L,
                      end_offset = 0L, today = Sys.Date()) {
  blank <- function(x) {
    is.null(x) || length(x) == 0L || all(is.na(x)) ||
      (is.character(x) && !nzchar(trimws(x[1L])))
  }
  to2 <- if (blank(to)) today - end_offset else zb_as_date(to)[1L]
  from2 <- if (blank(from)) to2 - (default_days - 1L) else zb_as_date(from)[1L]
  if (is.na(to2) || is.na(from2)) {
    cli::cli_abort("Could not parse the {.arg from}/{.arg to} window.")
  }
  if (from2 > to2) {
    cli::cli_abort(
      "{.arg from} ({from2}) must not be after {.arg to} ({to2})."
    )
  }
  list(from = from2, to = to2)
}

#' Was an explicit backfill window requested?
#'
#' @param from Value of the `from` argument.
#' @param to Value of the `to` argument.
#' @return `TRUE` when either is a usable, non-`NA` value.
#' @keywords internal
#' @noRd
zb_is_backfill <- function(from, to) {
  usable <- function(x) {
    !(is.null(x) || length(x) == 0L || all(is.na(x)) ||
      (is.character(x) && !nzchar(trimws(x[1L]))))
  }
  usable(from) || usable(to)
}

#' Turn `options(warn = 2)` on under CI (RNF-8)
#'
#' Not called from anywhere inside the package: changing a global option as
#' a side effect of loading or of running a pipeline step would be wrong
#' (and `R CMD check`-unfriendly). The workflow call site is expected to
#' invoke it explicitly before the pipeline step, e.g.
#' `Rscript -e 'zboard:::zb_ci_strict_warnings(); zboard::collect_cran()'`.
#'
#' @return The previous value of `warn`, invisibly.
#' @keywords internal
#' @noRd
zb_ci_strict_warnings <- function() {
  old <- getOption("warn")
  if (identical(Sys.getenv("CI"), "true")) {
    options(warn = 2)
  }
  invisible(old)
}

# -- configuration ----------------------------------------------------------

#' Read the curated source configuration
#'
#' Reads `config/repos.yml` (SPEC.md S5): the explicit, editorial list of
#' CRAN packages, GitHub repositories and the ORCID iD to collect.
#' Anything not listed here is not collected, not aggregated and not
#' displayed.
#'
#' Validates shapes early so that a typo fails at the top of a collector
#' rather than as an opaque 404 halfway through it.
#'
#' @param path Path to the YAML configuration file.
#' @return A list with elements `cran_packages` (character vector),
#'   `github_repos` (tibble with `repo` and `group`) and `orcid`
#'   (length-1 character, possibly `NA`).
#' @keywords internal
#' @noRd
read_repos_config <- function(path = "config/repos.yml") {
  if (!file.exists(path)) {
    cli::cli_abort("Configuration file not found: {.path {path}}.")
  }
  cfg <- yaml::read_yaml(path)

  cran_packages <- as.character(unlist(cfg$cran_packages %||% character(), use.names = FALSE))
  cran_packages <- unique(cran_packages[nzchar(cran_packages)])
  bad_pkg <- !grepl("^[A-Za-z][A-Za-z0-9.]*$", cran_packages)
  if (any(bad_pkg)) {
    cli::cli_abort(
      "Invalid CRAN package name(s) in {.path {path}}: {.val {cran_packages[bad_pkg]}}."
    )
  }

  raw_repos <- cfg$github_repos %||% list()
  github_repos <- tibble::tibble(
    repo = vapply(
      raw_repos, function(x) as.character(x$repo %||% NA_character_)[1L],
      character(1)
    ),
    group = vapply(
      raw_repos, function(x) as.character(x$group %||% NA_character_)[1L],
      character(1)
    )
  )
  github_repos <- github_repos[!is.na(github_repos$repo), , drop = FALSE]
  bad_repo <- !grepl("^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$", github_repos$repo)
  if (any(bad_repo)) {
    cli::cli_abort(
      "Invalid repository name(s) in {.path {path}}: {.val {github_repos$repo[bad_repo]}}. Expected {.code owner/name}."
    )
  }

  orcid <- as.character(cfg$orcid %||% NA_character_)[1L]
  if (!is.na(orcid) && nzchar(orcid) &&
    !grepl("^[0-9]{4}-[0-9]{4}-[0-9]{4}-[0-9]{3}[0-9X]$", orcid)) {
    cli::cli_abort("Invalid ORCID iD in {.path {path}}: {.val {orcid}}.")
  }

  list(
    cran_packages = cran_packages,
    github_repos = github_repos,
    orcid = if (is.na(orcid) || !nzchar(orcid)) NA_character_ else orcid
  )
}
