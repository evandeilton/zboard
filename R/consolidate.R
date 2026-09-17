# ---------------------------------------------------------------------------
# Consolidation: upsert -> monthly rollup -> 12-month prune -> run manifest.
#
# This is the one function in the pipeline where getting the *order* wrong
# destroys data permanently: pruning traffic before its rollup is on disk is
# unlikely, but high-impact and irreversible. The rollup of a period must
# be on disk before the daily rows of that period are pruned,
# and the prune must be abandoned -- for that table -- when the rollup did
# not succeed in this very call. `zb_retention_step()` implements that as an
# explicit gate whose outcome is part of the return value, so a test can
# force the rollup to fail and assert that nothing was pruned.
#
# One archive file per table, deliberate
# --------------------------------------
# An earlier design sketch wrote the rollup to a single
# `data/archive/monthly.parquet`. That is a simplification the data model
# does not support: the nine rolled up tables have different schemas
# (cran_downloads is month/package/int, gh_repo_snapshot is month/repo/eight
# mixed columns, ...), and forcing them into one typed Parquet file would
# mean either a string blob column or a union of ~25 mostly-NULL columns --
# both of which give up the typing Parquet was chosen for in the first
# place. One file per table, `data/archive/<table>_monthly.parquet`, keeps
# every archive column typed and keeps the rollup of one table independent
# of the others' failures.
# ---------------------------------------------------------------------------

#' Aggregate a table to calendar months
#'
#' Two semantics:
#' * `"sum"` (`cran_downloads`, `gh_activity`, `gh_traffic`) -- every numeric
#'   column summed over the month.
#' * `"last"` (`gh_repo_snapshot`, `cran_checks`, `cran_status`,
#'   `academic_works`) -- the last snapshot of the month, carried over whole.
#'
#' Note on `gh_traffic`: summing `view_uniques`/`clone_uniques` over a month
#' counts a visitor once per day they appear, so the monthly figure is an
#' upper bound on distinct visitors, not a distinct count. The GitHub API
#' exposes no monthly unique figure, and the rollup is a `sum`; the
#' dashboard labels it accordingly.
#'
#' @param tbl Table name.
#' @param df The table's current contents.
#' @return A tibble keyed by `month` plus the table's grouping columns; zero
#'   rows when there is nothing to aggregate.
#' @keywords internal
#' @noRd
zb_monthly_agg <- function(tbl, df) {
  spec <- zb_schema(tbl)
  grp <- spec$group
  if (identical(spec$rollup, "none") || is.null(df) || nrow(df) == 0L) {
    return(tibble::tibble())
  }

  df <- tibble::as_tibble(df)
  df$month <- lubridate::floor_date(zb_as_date(df[[spec$date_col]]), "month")
  df <- df[!is.na(df$month), , drop = FALSE]
  if (nrow(df) == 0L) {
    return(tibble::tibble())
  }

  if (identical(spec$rollup, "sum")) {
    value_cols <- setdiff(
      names(spec$cols)[spec$cols %in% c("int", "dbl")],
      c(spec$keys, "month")
    )
    out <- dplyr::summarise(
      dplyr::group_by(df, dplyr::across(dplyr::all_of(c("month", grp)))),
      dplyr::across(dplyr::all_of(value_cols), function(x) sum(x, na.rm = TRUE)),
      .groups = "drop"
    )
  } else {
    df <- df[order(df[[spec$date_col]]), , drop = FALSE]
    out <- dplyr::ungroup(dplyr::slice_tail(
      dplyr::group_by(df, dplyr::across(dplyr::all_of(c("month", grp)))),
      n = 1L
    ))
    out <- out[, c("month", setdiff(names(out), "month")), drop = FALSE]
  }
  tibble::as_tibble(out)
}

#' Write (upsert) a table's monthly rollup into the permanent archive
#'
#' The archive is upserted rather than overwritten, which is what makes the
#' 12-month prune safe: months whose daily rows were pruned in an earlier
#' run are no longer present in `df`, so recomputing from `df` alone would
#' silently lose them. Upserting by `(month, <group>)` keeps them.
#'
#' Errors are allowed to propagate: `zb_retention_step()` turns a failure
#' here into a refusal to prune.
#'
#' @param tbl Table name.
#' @param df The table's current contents.
#' @param archive_dir Directory holding `<tbl>_monthly.parquet`.
#' @return Number of rows in the archive after the upsert, invisibly.
#' @keywords internal
#' @noRd
zb_rollup_monthly <- function(tbl, df, archive_dir) {
  spec <- zb_schema(tbl)
  if (identical(spec$rollup, "none")) {
    return(invisible(0L))
  }
  monthly <- zb_monthly_agg(tbl, df)
  if (nrow(monthly) == 0L) {
    return(invisible(0L))
  }

  if (!dir.exists(archive_dir)) {
    dir.create(archive_dir, recursive = TRUE, showWarnings = FALSE)
  }
  name <- paste0(tbl, "_monthly")
  path <- file.path(archive_dir, paste0(name, ".parquet"))
  old <- if (file.exists(path)) tibble::as_tibble(arrow::read_parquet(path)) else NULL

  merged <- zb_upsert(old, monthly, keys = c("month", spec$group), merge = "last")
  zb_write_table(merged, archive_dir, name)
  invisible(nrow(merged))
}

#' Apply the retention policy to one table
#'
#' The gate. In order:
#' 1. Roll the table up to months and write the archive -- unless the table
#'    is permanent (`cran_versions`, `gh_releases`), which need neither.
#' 2. Prune to the rolling window **only if** step 1 either succeeded or was
#'    not required. A failed rollup means the daily rows are the only copy
#'    of the period, so they stay.
#'
#' @param tbl Table name.
#' @param df The table's current contents.
#' @param archive_dir Directory holding the monthly archives.
#' @param cutoff Oldest date kept by the prune.
#' @return A list with the pruned `df`, `rollup` (`"ok"`, `"failed"` or
#'   `"skipped"`), `rollup_rows`, `pruned` (logical) and `rows_pruned`.
#' @keywords internal
#' @noRd
zb_retention_step <- function(tbl, df, archive_dir, cutoff) {
  spec <- zb_schema(tbl)
  rollup <- "skipped"
  rollup_rows <- 0L
  rollup_msg <- NA_character_

  if (!identical(spec$rollup, "none")) {
    res <- tryCatch(zb_rollup_monthly(tbl, df, archive_dir), error = function(e) e)
    if (inherits(res, "error")) {
      rollup <- "failed"
      rollup_msg <- zb_sanitize(conditionMessage(res))
      cli::cli_alert_danger(
        "{.field {tbl}}: monthly rollup FAILED ({rollup_msg}); the 12-month prune is abandoned for this table."
      )
    } else {
      rollup <- "ok"
      rollup_rows <- as.integer(res)
    }
  }

  prune_allowed <- isTRUE(spec$prune) && rollup %in% c("ok", "skipped")
  rows_pruned <- 0L
  if (prune_allowed && nrow(df) > 0L) {
    d <- zb_as_date(df[[spec$date_col]])
    keep <- is.na(d) | d >= cutoff
    rows_pruned <- as.integer(sum(!keep))
    df <- df[keep, , drop = FALSE]
  }

  list(
    df = df, rollup = rollup, rollup_rows = rollup_rows,
    rollup_message = rollup_msg, pruned = prune_allowed,
    rows_pruned = rows_pruned
  )
}

#' Collect the manifest rows written by the collectors
#'
#' @param staging_dir Staging directory.
#' @return A `run_manifest` tibble (possibly zero rows).
#' @keywords internal
#' @noRd
zb_read_staging_manifests <- function(staging_dir) {
  files <- list.files(
    staging_dir, pattern = "^run_manifest_.*\\.parquet$", full.names = TRUE
  )
  if (length(files) == 0L) {
    return(zb_empty("run_manifest"))
  }
  rows <- purrr::list_rbind(purrr::map(files, function(f) {
    tibble::as_tibble(arrow::read_parquet(f))
  }))
  zb_coerce(rows, zb_schema("run_manifest")$cols)
}

#' Consolidate staged collections into the canonical Parquet store
#'
#' @description
#' The single write path into the canonical data store (the `consolidate`
#' job). In one call, and in this order:
#'
#' 1. **Upsert** every table found in `staging_dir` into `data_dir`, by its
#'    natural key. Last-write-wins everywhere except
#'    `gh_traffic`, which merges by `max()` per key.
#' 2. **Roll up** each table to calendar months into
#'    `data_dir/archive/<table>_monthly.parquet`.
#' 3. **Prune** each table to a rolling 12-month window -- and only then,
#'    and only for tables whose rollup succeeded in this same call.
#' 4. **Record** one `run_manifest` row per source processed, with a
#'    sanitised, truncated message.
#'
#' @details
#' **Missing input is not an error.** A staging table that is absent simply
#' means its collector did not run (or failed) in this execution; the
#' corresponding canonical table is left untouched and the remaining tables
#' are still consolidated. An absent `data_dir` is created, and an
#' absent canonical table is treated as an empty table. The function is
#' therefore safe to call on a completely empty checkout.
#'
#' **Idempotence.** Running twice with the same staging input produces the
#' same canonical tables and the same row counts: the upsert is by
#' key, the rollup upserts the same monthly aggregate, and the prune is a
#' function of the data and the reference date only.
#'
#' **Retention gate.** The prune is not merely ordered after the rollup; it
#' is conditional on it. `gh_traffic` is irrecoverable -- the GitHub API
#' retains 14 days -- so if its rollup throws, its daily rows are the only
#' surviving copy of the period and are kept. The outcome per table is
#' returned, which is what `tests/testthat/test-retention-order.R` asserts
#' on.
#'
#' @param staging_dir Directory holding the collectors' output. Absent
#'   directory or absent files are tolerated.
#' @param data_dir Directory holding the canonical Parquet store; the
#'   checkout of the orphan `data` branch in CI. Created when missing.
#' @param archive_dir Directory for the permanent monthly rollups. Defaults
#'   to `archive/` inside `data_dir`.
#' @param retention_months Length of the rolling daily window, in months.
#' @param reference_date Date the rolling window is measured back from.
#'   Exposed for testing and for deterministic reruns.
#' @param run_ts Timestamp recorded on the manifest rows this call writes.
#'
#' @return Invisibly, a tibble with one row per canonical table and the
#'   columns `table`, `staging_rows`, `rows_before`, `rows_after`,
#'   `rollup` (`"ok"`/`"failed"`/`"skipped"`), `rollup_rows`, `pruned`,
#'   `rows_pruned` and `written`.
#'
#' @seealso [collect_cran()], [collect_github()], [collect_academic()],
#'   [export_json()]
#' @export
#' @examples
#' \dontrun{
#' collect_cran()
#' consolidate(staging_dir = "staging", data_dir = "data")
#' }
#'
#' # Safe on an empty tree: nothing staged, nothing stored.
#' tmp <- tempfile()
#' dir.create(tmp)
#' res <- consolidate(
#'   staging_dir = file.path(tmp, "staging"),
#'   data_dir = file.path(tmp, "data")
#' )
#' nrow(res)
consolidate <- function(staging_dir = "staging", data_dir = "data",
                        archive_dir = file.path(data_dir, "archive"),
                        retention_months = 12L,
                        reference_date = Sys.Date(),
                        run_ts = Sys.time()) {
  reference_date <- zb_as_date(reference_date)[1L]
  cutoff <- lubridate::add_with_rollback(
    reference_date, lubridate::period(months = -as.integer(retention_months))
  )
  if (!dir.exists(data_dir)) {
    dir.create(data_dir, recursive = TRUE, showWarnings = FALSE)
  }

  cli::cli_h1("consolidate()")
  cli::cli_alert_info(
    "staging {.path {staging_dir}} -> data {.path {data_dir}}; keeping daily rows from {cutoff}."
  )
  if (dir.exists(staging_dir)) {
    unknown <- setdiff(
      sub("\\.parquet$", "", list.files(staging_dir, pattern = "\\.parquet$")),
      c(names(zb_schemas()), paste0("run_manifest_", c("cran", "github", "academic")))
    )
    if (length(unknown)) {
      cli::cli_alert_warning("Ignoring unrecognised staging table{?s}: {.val {unknown}}.")
    }
  }

  tables <- setdiff(names(zb_schemas()), "run_manifest")
  report <- vector("list", length(tables))
  names(report) <- tables

  for (tbl in tables) {
    spec <- zb_schema(tbl)
    staging_path <- file.path(staging_dir, paste0(tbl, ".parquet"))
    data_path <- file.path(data_dir, paste0(tbl, ".parquet"))
    had_file <- file.exists(data_path)

    staged <- if (file.exists(staging_path)) zb_read_table(staging_dir, tbl) else NULL
    old <- zb_read_table(data_dir, tbl)

    merged <- if (is.null(staged)) {
      old
    } else {
      zb_upsert(old, staged, spec$keys, merge = spec$merge, cols = spec$cols)
    }

    ret <- zb_retention_step(tbl, merged, archive_dir, cutoff)
    merged <- zb_coerce(ret$df, spec$cols)

    written <- FALSE
    if (nrow(merged) > 0L || had_file) {
      zb_write_table(merged, data_dir, tbl)
      written <- TRUE
    }

    report[[tbl]] <- tibble::tibble(
      table = tbl,
      staging_rows = if (is.null(staged)) NA_integer_ else nrow(staged),
      rows_before = nrow(old),
      rows_after = nrow(merged),
      rollup = ret$rollup,
      rollup_rows = ret$rollup_rows,
      pruned = ret$pruned,
      rows_pruned = ret$rows_pruned,
      written = written
    )

    if (!is.null(staged)) {
      cli::cli_alert_success(
        "{.field {tbl}}: {nrow(staged)} staged, {nrow(old)} -> {nrow(merged)} row{?s} (rollup {ret$rollup}, pruned {ret$rows_pruned})."
      )
    }
  }

  report <- purrr::list_rbind(report)

  # -- run manifest --------------------------------------------------------
  # The collectors own the per-source rows: only they can distinguish "did
  # not run" from "ran and failed". They are forwarded verbatim (already
  # sanitised). A staged table with no collector row gets a synthesised one,
  # and one row summarises the consolidation itself.
  collector_rows <- zb_read_staging_manifests(staging_dir)
  staged_tables <- report$table[!is.na(report$staging_rows)]
  orphans <- setdiff(staged_tables, collector_rows$source)
  orphan_rows <- purrr::list_rbind(purrr::map(orphans, function(tbl) {
    zb_manifest_row(
      tbl, "ok",
      report$rows_after[report$table == tbl], NA_real_,
      "Staged table with no collector manifest row.", run_ts
    )
  }))

  failed_rollups <- report$table[report$rollup == "failed"]
  consolidate_row <- zb_manifest_row(
    "consolidate",
    if (length(failed_rollups)) "partial" else "ok",
    sum(report$rows_after),
    NA_real_,
    if (length(failed_rollups)) {
      paste0(
        "Monthly rollup failed; prune abandoned for: ",
        paste(failed_rollups, collapse = ", ")
      )
    } else {
      NA_character_
    },
    run_ts
  )

  new_manifest <- dplyr::bind_rows(collector_rows, orphan_rows, consolidate_row)
  if (nrow(new_manifest) > 0L) {
    man_spec <- zb_schema("run_manifest")
    man <- zb_upsert(
      zb_read_table(data_dir, "run_manifest"), new_manifest,
      man_spec$keys, merge = man_spec$merge, cols = man_spec$cols
    )
    man_ret <- zb_retention_step("run_manifest", man, archive_dir, cutoff)
    zb_write_table(zb_coerce(man_ret$df, man_spec$cols), data_dir, "run_manifest")
    cli::cli_alert_success(
      "{.field run_manifest}: +{nrow(new_manifest)} row{?s}, {nrow(man_ret$df)} kept."
    )
  }

  if (length(failed_rollups)) {
    cli::cli_alert_danger(
      "Retention gate tripped for {.val {failed_rollups}}: daily rows kept, prune skipped."
    )
  }

  invisible(report)
}
