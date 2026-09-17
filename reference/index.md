# Package index

## Collect

One collector per source. Each writes staged Parquet tables and a run
manifest.

- [`collect_cran()`](https://evandeilton.github.io/zboard/reference/collect_cran.md)
  : Collect CRAN health, version and download data
- [`collect_github()`](https://evandeilton.github.io/zboard/reference/collect_github.md)
  : Collect GitHub activity, repository state, releases and traffic
- [`collect_academic()`](https://evandeilton.github.io/zboard/reference/collect_academic.md)
  : Collect academic output from OpenAlex

## Consolidate and publish

Merge the staged tables into the canonical store, then derive what the
dashboard reads.

- [`consolidate()`](https://evandeilton.github.io/zboard/reference/consolidate.md)
  : Consolidate staged collections into the canonical Parquet store
- [`export_json()`](https://evandeilton.github.io/zboard/reference/export_json.md)
  : Export the canonical Parquet store as JSON for the static dashboard
- [`make_badges()`](https://evandeilton.github.io/zboard/reference/make_badges.md)
  : Generate shields.io endpoint badges from the canonical store

## Alerts

- [`run_alerts()`](https://evandeilton.github.io/zboard/reference/run_alerts.md)
  : Open, update and close CRAN alert issues
