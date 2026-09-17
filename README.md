# zboard

<!-- badges: start -->
[![collect](https://github.com/evandeilton/zboard/actions/workflows/collect.yml/badge.svg)](https://github.com/evandeilton/zboard/actions/workflows/collect.yml)
[![R-CMD-check](https://github.com/evandeilton/zboard/actions/workflows/test.yml/badge.svg)](https://github.com/evandeilton/zboard/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE.md)
<!-- badges: end -->

"Dashboard do Zé": a daily-updated, static dashboard of CRAN check and
download health, GitHub activity and academic output for my R packages.

- Dashboard: <https://evandeilton.github.io/zboard/dashboard/> ([pt](https://evandeilton.github.io/zboard/dashboard/pt/))
- Package documentation: <https://evandeilton.github.io/zboard/>

## Installation

```r
pak::pak("evandeilton/zboard")
```

## Usage

```r
library(zboard)
collect_cran(); collect_github(); collect_academic()   # sources -> staging/
consolidate()                                          # staging/ -> data/
export_json()                                          # data/ -> site/_data/
```

`collect_github()` needs `GITHUB_TOKEN`; `collect_academic()` needs
`OPENALEX_MAILTO`. What is monitored is listed in `config/repos.yml`.

## License

MIT for the code; the published aggregated data is CC-BY-4.0.
