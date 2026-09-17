# Export the canonical Parquet store as JSON for the static dashboard

Reads `data_dir/*.parquet` (and the monthly archives under
`archive_dir`) and writes the ten JSON files the Quarto dashboard
consumes into `output_dir`: `overview.json`, `cran_status.json`,
`cran_downloads.json`, `gh_activity.json`, `gh_traffic.json`,
`gh_issues.json`, `gh_releases.json`, `academic.json`, `freshness.json`
and `meta.json`.

**The complete field-by-field schema of all ten files is documented as a
comment block at the top of `R/export_json.R`.** That block is the
contract between this package and the front-end; read it there.

## Usage

``` r
export_json(
  data_dir = "data",
  output_dir = "site/_data",
  archive_dir = file.path(data_dir, "archive"),
  downloads_window_days = 365L,
  redact_emails = TRUE,
  pretty = FALSE,
  generated_at = Sys.time()
)
```

## Arguments

- data_dir:

  Directory holding the canonical Parquet store.

- output_dir:

  Directory the JSON files are written to. Created when missing.

- archive_dir:

  Directory holding the monthly rollups. Defaults to `archive/` inside
  `data_dir`.

- downloads_window_days:

  Length, in days, of the daily download and activity series exported
  (the rolling daily window).

- redact_emails:

  Strip e-mail addresses from `maintainer` before publishing. Leave
  `TRUE` unless you have a specific reason not to.

- pretty:

  Pretty-print the JSON. `FALSE` produces smaller files.

- generated_at:

  Build timestamp recorded in every file.

## Value

Invisibly, a tibble with one row per file written and the columns
`file`, `path` and `bytes`.

## Details

An absent Parquet file is an empty table, not an error, and every array
in the output is emitted even when empty. Calling this on a directory
with no data at all produces ten valid, empty-but-well-formed JSON
files, which is what lets the site build before the first collection has
run.

Dates and timestamps are serialised as ISO-8601 strings; no Arrow or R
date type reaches the JSON. Numbers are written at full precision
(`digits = NA`).

`cran_status$maintainer` is collected from CRAN with an e-mail address
attached. Because these files are published on a public site, the
address is removed by default, leaving the display name.

## See also

[`consolidate()`](https://evandeilton.github.io/zboard/reference/consolidate.md),
[`make_badges()`](https://evandeilton.github.io/zboard/reference/make_badges.md)

## Examples

``` r
# Works on an empty store: every file is written, every array is empty.
tmp <- tempfile()
dir.create(tmp)
out <- export_json(
  data_dir = file.path(tmp, "data"),
  output_dir = file.path(tmp, "json")
)
#> 
#> ── export_json() ───────────────────────────────────────────────────────────────
#> ℹ data /tmp/Rtmp6evWpe/file43bb57c520bc/data -> json /tmp/Rtmp6evWpe/file43bb57c520bc/json.
#> ✔ 10 JSON files written (1603 bytes).
out$file
#>  [1] "overview.json"       "cran_status.json"    "cran_downloads.json"
#>  [4] "gh_activity.json"    "gh_traffic.json"     "gh_issues.json"     
#>  [7] "gh_releases.json"    "academic.json"       "freshness.json"     
#> [10] "meta.json"          
jsonlite::fromJSON(file.path(tmp, "json", "meta.json"))$schema_version
#> [1] 1

if (FALSE) { # \dontrun{
# In the pipeline, against the checked-out `data` branch.
export_json(data_dir = "data", output_dir = "site/_data")
} # }
```
