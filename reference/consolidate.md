# Consolidate staged collections into the canonical Parquet store

The single write path into the canonical data store (the `consolidate`
job). In one call, and in this order:

1.  **Upsert** every table found in `staging_dir` into `data_dir`, by
    its natural key. Last-write-wins everywhere except `gh_traffic`,
    which merges by [`max()`](https://rdrr.io/r/base/Extremes.html) per
    key.

2.  **Roll up** each table to calendar months into
    `data_dir/archive/<table>_monthly.parquet`.

3.  **Prune** each table to a rolling 12-month window – and only then,
    and only for tables whose rollup succeeded in this same call.

4.  **Record** one `run_manifest` row per source processed, with a
    sanitised, truncated message.

## Usage

``` r
consolidate(
  staging_dir = "staging",
  data_dir = "data",
  archive_dir = file.path(data_dir, "archive"),
  retention_months = 12L,
  reference_date = Sys.Date(),
  run_ts = Sys.time()
)
```

## Arguments

- staging_dir:

  Directory holding the collectors' output. Absent directory or absent
  files are tolerated.

- data_dir:

  Directory holding the canonical Parquet store; the checkout of the
  orphan `data` branch in CI. Created when missing.

- archive_dir:

  Directory for the permanent monthly rollups. Defaults to `archive/`
  inside `data_dir`.

- retention_months:

  Length of the rolling daily window, in months.

- reference_date:

  Date the rolling window is measured back from. Exposed for testing and
  for deterministic reruns.

- run_ts:

  Timestamp recorded on the manifest rows this call writes.

## Value

Invisibly, a tibble with one row per canonical table and the columns
`table`, `staging_rows`, `rows_before`, `rows_after`, `rollup`
(`"ok"`/`"failed"`/`"skipped"`), `rollup_rows`, `pruned`, `rows_pruned`
and `written`.

## Details

**Missing input is not an error.** A staging table that is absent simply
means its collector did not run (or failed) in this execution; the
corresponding canonical table is left untouched and the remaining tables
are still consolidated. An absent `data_dir` is created, and an absent
canonical table is treated as an empty table. The function is therefore
safe to call on a completely empty checkout.

**Idempotence.** Running twice with the same staging input produces the
same canonical tables and the same row counts: the upsert is by key, the
rollup upserts the same monthly aggregate, and the prune is a function
of the data and the reference date only.

**Retention gate.** The prune is not merely ordered after the rollup; it
is conditional on it. `gh_traffic` is irrecoverable – the GitHub API
retains 14 days – so if its rollup throws, its daily rows are the only
surviving copy of the period and are kept. The outcome per table is
returned, which is what `tests/testthat/test-retention-order.R` asserts
on.

## See also

[`collect_cran()`](https://evandeilton.github.io/zboard/reference/collect_cran.md),
[`collect_github()`](https://evandeilton.github.io/zboard/reference/collect_github.md),
[`collect_academic()`](https://evandeilton.github.io/zboard/reference/collect_academic.md),
[`export_json()`](https://evandeilton.github.io/zboard/reference/export_json.md)

## Examples

``` r
if (FALSE) { # \dontrun{
collect_cran()
consolidate(staging_dir = "staging", data_dir = "data")
} # }

# Safe on an empty tree: nothing staged, nothing stored.
tmp <- tempfile()
dir.create(tmp)
res <- consolidate(
  staging_dir = file.path(tmp, "staging"),
  data_dir = file.path(tmp, "data")
)
#> 
#> ── consolidate() ───────────────────────────────────────────────────────────────
#> ℹ staging /tmp/RtmpTuom5d/file449b70e728d5/staging -> data /tmp/RtmpTuom5d/file449b70e728d5/data; keeping daily rows from 2025-09-17.
#> ✔ run_manifest: +1 row, 1 kept.
nrow(res)
#> [1] 9
```
