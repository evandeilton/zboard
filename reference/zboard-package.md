# zboard: Public production monitoring for curated R packages and repositories

"Dashboard do Zé" – collects, consolidates and publishes a static,
daily-updated dashboard of CRAN check and download health, GitHub
development activity and academic output for a curated set of R packages
and repositories.

## Details

The pipeline is a sequence of exported functions: the collectors
[`collect_cran()`](https://evandeilton.github.io/zboard/reference/collect_cran.md),
[`collect_github()`](https://evandeilton.github.io/zboard/reference/collect_github.md)
and
[`collect_academic()`](https://evandeilton.github.io/zboard/reference/collect_academic.md)
write staged Parquet tables;
[`consolidate()`](https://evandeilton.github.io/zboard/reference/consolidate.md)
merges them into the canonical store;
[`export_json()`](https://evandeilton.github.io/zboard/reference/export_json.md)
and
[`make_badges()`](https://evandeilton.github.io/zboard/reference/make_badges.md)
derive what the dashboard and the shields.io badges read;
[`run_alerts()`](https://evandeilton.github.io/zboard/reference/run_alerts.md)
turns CRAN check failures into GitHub issues.

## See also

Useful links:

- <https://github.com/evandeilton/zboard>

- <https://evandeilton.github.io/zboard/>

- Report bugs at <https://github.com/evandeilton/zboard/issues>

## Author

**Maintainer**: José Evandeilton Lopes <evandeilton@gmail.com>
([ORCID](https://orcid.org/0009-0007-5887-4084))

Authors:

- José Evandeilton Lopes <evandeilton@gmail.com>
  ([ORCID](https://orcid.org/0009-0007-5887-4084))
