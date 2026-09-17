# zboard

“Dashboard do Zé”: a daily-updated, static dashboard of CRAN check and
download health, GitHub activity and academic output for my R packages.

- Dashboard: <https://evandeilton.github.io/zboard/dashboard/>
  ([pt](https://evandeilton.github.io/zboard/dashboard/pt/))
- Package documentation: <https://evandeilton.github.io/zboard/>

## Installation

``` r
pak::pak("evandeilton/zboard")
```

## Usage

``` r
library(zboard)
collect_cran(); collect_github(); collect_academic()   # sources -> staging/
consolidate()                                          # staging/ -> data/
export_json()                                          # data/ -> site/_data/
```

[`collect_github()`](https://evandeilton.github.io/zboard/reference/collect_github.md)
needs `GITHUB_TOKEN`;
[`collect_academic()`](https://evandeilton.github.io/zboard/reference/collect_academic.md)
needs `OPENALEX_MAILTO`. What is monitored is listed in
`config/repos.yml`.

## License

MIT for the code; the published aggregated data is CC-BY-4.0.
