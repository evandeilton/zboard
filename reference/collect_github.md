# Collect GitHub activity, repository state, releases and traffic

Collects the four GitHub-side tables for the repositories curated in
`config/repos.yml`, writing each as a Parquet file in `staging_dir` for
[`consolidate()`](https://evandeilton.github.io/zboard/reference/consolidate.md):

- `gh_activity` – daily commits on the default branch, pull requests
  opened/merged/closed and issues opened/closed, from GraphQL v4.

- `gh_repo_snapshot` – stars, forks, watchers, open issues and pull
  requests, age of the oldest open issue, last push, archived flag.

- `gh_releases` – every published (non-draft) release.

- `gh_traffic` – daily views and clones with their unique counts.

Repositories are collected independently of each other and the four
tables independently of each other, so one 404 or one missing scope
degrades a single cell of the dashboard rather than the run.

## Usage

``` r
collect_github(
  from = NULL,
  to = NULL,
  config_path = "config/repos.yml",
  staging_dir = "staging",
  run_ts = Sys.time()
)
```

## Arguments

- from:

  Start of the activity window as an ISO-8601 date string or a `Date`.
  `NULL` (the default) means normal incremental mode: a rolling 30-day
  window ending today.

- to:

  End of the activity window, same forms as `from`. `NULL` defaults to
  today; the current UTC day is partial and is corrected by the next run
  under last-write-wins.

- config_path:

  Path to the curated source configuration.

- staging_dir:

  Directory the staging Parquet files are written to. Created when
  missing.

- run_ts:

  Timestamp shared by every manifest row of this run.

## Value

Invisibly, a tibble with the `run_manifest` schema: one row per source
attempted. The same rows are written to
`staging_dir/run_manifest_github.parquet`.

## Details

**Authentication.** Delegated to the `gh` package, which picks up
`GITHUB_TOKEN` (or `GITHUB_PAT`) from the environment; no token is
accepted as an argument and none is ever logged. Traffic additionally
requires the `Administration: read` scope of the fine-grained PAT;
without it the traffic table alone is recorded as failed.

**Traffic is not retroactive.** The GitHub API keeps 14 days and nothing
more, which is why the monthly rollup in
[`consolidate()`](https://evandeilton.github.io/zboard/reference/consolidate.md)
is the only long-term copy. Passing `from`/`to` therefore has no effect
on `gh_traffic`: the window is ignored for that table with a message,
and the collector continues rather than failing. Backfill is not
applicable to `gh_traffic`.

`gh_repo_snapshot` and `gh_releases` are likewise snapshots, so
`from`/`to` apply only to `gh_activity`.

Only aggregates per repository are collected. No contributor profile,
issue author or e-mail address is ever read or stored.

## See also

[`collect_cran()`](https://evandeilton.github.io/zboard/reference/collect_cran.md),
[`collect_academic()`](https://evandeilton.github.io/zboard/reference/collect_academic.md),
[`consolidate()`](https://evandeilton.github.io/zboard/reference/consolidate.md)

## Examples

``` r
if (FALSE) { # \dontrun{
Sys.setenv(GITHUB_TOKEN = "ghp_...")
collect_github()

# Backfill the activity series; gh_traffic is untouched by the window.
collect_github(from = "2025-09-01", to = "2026-08-31")
} # }
```
