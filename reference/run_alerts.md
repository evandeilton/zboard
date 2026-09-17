# Open, update and close CRAN alert issues

Reconciles the repository's open `alert` issues against the latest CRAN
snapshot in `data_dir`:

- `worst_status` in `WARN`/`ERROR`/`FAIL` opens
  `[CRAN] {pkg}: {status} em {n} flavor(s)`, high severity. While the
  condition persists the issue is updated by a comment, never reopened
  and never duplicated. It is closed automatically as soon as the worst
  status returns to `OK` or `NOTE`.

- `archived = TRUE` opens a critical issue that is **never** closed
  automatically; it waits for a human.

Deduplication is by a hidden HTML marker in the issue body, one per
`(kind, package)` – `<!-- zboard:cran-check:{pkg} -->` or
`<!-- zboard:archived:{pkg} -->`. Open issues are listed and matched on
that marker before anything is created, so a second issue is never
opened for a condition that is already tracked.

## Usage

``` r
run_alerts(
  repo = Sys.getenv("GITHUB_REPOSITORY"),
  token = Sys.getenv("GITHUB_TOKEN"),
  data_dir = "data",
  label = "alert",
  marker_prefix = "zboard"
)
```

## Arguments

- repo:

  Target repository as `"owner/name"`. Defaults to the
  `GITHUB_REPOSITORY` environment variable that GitHub Actions sets.

- token:

  GitHub token with `issues: write`. Defaults to `GITHUB_TOKEN`. `""`
  triggers the dry run described above.

- data_dir:

  Directory holding the canonical Parquet store.

- label:

  Issue label used by the alert channel.

- marker_prefix:

  Namespace of the hidden deduplication marker.

## Value

Invisibly, a tibble with one row per action and the columns `kind`,
`package`, `action` (`"created"`, `"commented"`, `"closed"` or
`"dry-run"`), `issue` (issue number, `NA` for a dry run) and `title`.

## Details

**Dry run.** When `token` is `""` – no PAT in the environment, a fork, a
local run – nothing is sent to the API. The plan is printed and the
function returns invisibly without error, so a workflow without
`issues: write` does not fail (that permission is restricted to the
`alert` job).

The token is never printed and never written anywhere.

## See also

[`consolidate()`](https://evandeilton.github.io/zboard/reference/consolidate.md)

## Examples

``` r
if (FALSE) { # \dontrun{
# In the `alert` job of the workflow.
run_alerts(
  repo = Sys.getenv("GITHUB_REPOSITORY"),
  token = Sys.getenv("GITHUB_TOKEN")
)
} # }

# Without a token: prints the plan, touches no API.
run_alerts(repo = "evandeilton/zboard", token = "", data_dir = tempfile())
#> 
#> ── run_alerts() ────────────────────────────────────────────────────────────────
#> ! No token supplied: dry run. Nothing is sent to the GitHub API.
#> ✔ No alert condition in the latest snapshot; no issue would be opened.
```
