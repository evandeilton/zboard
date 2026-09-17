# Generate shields.io endpoint badges from the canonical store

Writes three JSON badge endpoints per curated CRAN package into
`output_dir`:

- `<pkg>-downloads.json` – downloads over the last `window_days` days of
  the series, e.g. `1.2k/month`, blue.

- `<pkg>-check.json` – the worst `R CMD check` status across flavours,
  coloured by severity (`OK` green, `NOTE` yellow, `WARN` orange,
  `ERROR`/`FAIL` red, unknown grey) with the flavour count in the text.

- `<pkg>-version.json` – the current CRAN version, blue; red and reading
  `archived` when the package has been archived.

## Usage

``` r
make_badges(
  data_dir = "data",
  output_dir = "_site/badges",
  packages = NULL,
  window_days = 30L
)
```

## Arguments

- data_dir:

  Directory holding the canonical Parquet store.

- output_dir:

  Directory the badge JSON files are written to. Created when missing.

- packages:

  Character vector of package names to generate badges for. Defaults to
  every package present in the store.

- window_days:

  Length of the download window summarised by the downloads badge.

## Value

Invisibly, a tibble with one row per badge and the columns `slug`,
`path`, `label`, `message` and `color`.

## Details

The default `output_dir` sits inside the rendered site because
shields.io fetches the endpoint over HTTP from the published GitHub
Pages URL. Run this **after** `quarto render`, so the files survive into
the deployed `_site/`.

A package with no data still gets its three badges, reading `n/a` in
grey, so a README badge never 404s while the pipeline is warming up.

## See also

[`export_json()`](https://evandeilton.github.io/zboard/reference/export_json.md),
[`consolidate()`](https://evandeilton.github.io/zboard/reference/consolidate.md)

## Examples

``` r
tmp <- tempfile()
dir.create(tmp)
# No data yet: placeholder badges are still written.
b <- make_badges(
  data_dir = file.path(tmp, "data"),
  output_dir = file.path(tmp, "badges"),
  packages = "gkwreg"
)
#> 
#> ── make_badges() ───────────────────────────────────────────────────────────────
#> ℹ 1 package -> /tmp/Rtmp6evWpe/file43bb4705de1a/badges.
#> ✔ 3 badges written.
b$slug
#> [1] "gkwreg-downloads" "gkwreg-check"     "gkwreg-version"  

if (FALSE) { # \dontrun{
# In the pipeline, after `quarto render`.
make_badges(data_dir = "data", output_dir = "_site/badges")
} # }
```
