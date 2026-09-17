# Collect academic output from OpenAlex

Collects the `academic_works` snapshot – publications, preprints,
datasets and software attributed to the ORCID iD configured in
`config/repos.yml`, with their venue, year, type and accumulated
citation count – and writes it as `staging_dir/academic_works.parquet`
for
[`consolidate()`](https://evandeilton.github.io/zboard/reference/consolidate.md).

## Usage

``` r
collect_academic(
  from = NULL,
  to = NULL,
  config_path = "config/repos.yml",
  staging_dir = "staging",
  mailto = Sys.getenv("OPENALEX_MAILTO", ""),
  run_ts = Sys.time()
)
```

## Arguments

- from:

  Optional lower bound on publication date, as an ISO-8601 date string
  or a `Date`. `NULL` (the default) applies no lower bound.

- to:

  Optional upper bound on publication date, same forms as `from`.

- config_path:

  Path to the curated source configuration.

- staging_dir:

  Directory the staging Parquet file is written to. Created when
  missing.

- mailto:

  Contact address for the OpenAlex polite pool. Defaults to the
  `OPENALEX_MAILTO` environment variable, and to `""` (anonymous pool)
  when that is unset.

- run_ts:

  Timestamp shared by every manifest row of this run.

## Value

Invisibly, a tibble with the `run_manifest` schema: one row for the
`academic_works` source. The same row is written to
`staging_dir/run_manifest_academic.parquet`.

## Details

**Polite pool.** OpenAlex serves anonymous callers from a slower, shared
pool. Supplying a contact address moves the caller to the polite pool.
The address is a repository secret: it is read from `OPENALEX_MAILTO` as
the default of the `mailto` argument, is never hard-coded, and is never
written to any output file. When the variable is unset the collector
still runs, unauthenticated, and says so.

**What `from`/`to` mean here.** `academic_works` is a snapshot keyed by
`(snapshot_date, work_id)`, so there is no past state to rebuild. An
explicit window is therefore interpreted as a filter on the *publication
date* of the works to collect (OpenAlex's `from_publication_date` /
`to_publication_date`), not as a range of snapshots. The default,
`NULL`, collects the whole body of work in every run.

**Type values.** `type` is stored exactly as OpenAlex reports it
(`article`, `preprint`, `dataset`, `book-chapter`, ...). The column is
deliberately not normalised onto a closed set of values; doing so would
discard information the dashboard can display verbatim.

Only the author's own works are collected. No co-author name, identifier
or affiliation is stored.

## See also

[`collect_cran()`](https://evandeilton.github.io/zboard/reference/collect_cran.md),
[`collect_github()`](https://evandeilton.github.io/zboard/reference/collect_github.md),
[`consolidate()`](https://evandeilton.github.io/zboard/reference/consolidate.md)

## Examples

``` r
if (FALSE) { # \dontrun{
Sys.setenv(OPENALEX_MAILTO = "you@example.com")
collect_academic()

# Only works published from 2024 onwards.
collect_academic(from = "2024-01-01")
} # }
```
