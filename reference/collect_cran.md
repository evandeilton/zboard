# Collect CRAN health, version and download data

Collects the four CRAN-side tables for the packages curated in
`config/repos.yml`, and writes each one as a Parquet file in
`staging_dir` for
[`consolidate()`](https://evandeilton.github.io/zboard/reference/consolidate.md)
to upsert:

- `cran_downloads` – daily download counts from the Posit mirror
  (`cranlogs.r-pkg.org`). Retroactive, so `from`/`to` apply here.

- `cran_versions` – the full published version history and release dates
  from `crandb.r-pkg.org/{pkg}/all`.

- `cran_checks` – `R CMD check` status per flavour, read from CRAN's
  official `.rds` artifact via
  [`tools::CRAN_check_results()`](https://rdrr.io/r/tools/CRANtools.html).

- `cran_status` – presence on CRAN, archival state, maintainer and the
  worst check status across flavours.

Each of the four is collected independently: a failure in one is
recorded in the run manifest and does not prevent the others from being
written. Every network call retries three times with exponential backoff
on 5xx/timeout and honours `Retry-After` on 429.

## Usage

``` r
collect_cran(
  from = NULL,
  to = NULL,
  config_path = "config/repos.yml",
  staging_dir = "staging",
  run_ts = Sys.time()
)
```

## Arguments

- from:

  Start of the download window as an ISO-8601 date string or a `Date`.
  `NULL` (the default) means normal incremental mode: a rolling 35-day
  window ending yesterday. The window is deliberately wider than one day
  so that the series self-heals after an outage.

- to:

  End of the download window, same forms as `from`. `NULL` defaults to
  yesterday, because the current UTC day is still incomplete upstream.

- config_path:

  Path to the curated source configuration.

- staging_dir:

  Directory the staging Parquet files are written to. Created when
  missing.

- run_ts:

  Timestamp shared by every manifest row of this run.

## Value

Invisibly, a tibble with the `run_manifest` schema: one row per source
attempted, with `status` in `ok`/`partial`/`failed`, `rows_written`,
`duration_s` and a sanitised `message`. The same rows are written to
`staging_dir/run_manifest_cran.parquet`.

## Details

Only `cran_downloads` is retroactive. `cran_checks` and `cran_status`
are snapshots of CRAN's *current* state and `cran_versions` is a
complete history in every run, so an explicit `from`/`to` window is
applied to the download series only; the other three are unaffected (and
a message says so).

The e-mail address in `cran_status$maintainer` is collected as CRAN
publishes it;
[`export_json()`](https://evandeilton.github.io/zboard/reference/export_json.md)
strips it before the column reaches a public JSON file.

## See also

[`collect_github()`](https://evandeilton.github.io/zboard/reference/collect_github.md),
[`collect_academic()`](https://evandeilton.github.io/zboard/reference/collect_academic.md),
[`consolidate()`](https://evandeilton.github.io/zboard/reference/consolidate.md)

## Examples

``` r
if (FALSE) { # \dontrun{
# Normal daily run.
collect_cran()

# Backfill twelve months of the download series.
collect_cran(from = "2025-09-01", to = "2026-08-31")
} # }
```
