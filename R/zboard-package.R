#' zboard: Public production monitoring for curated R packages and repositories
#'
#' "Dashboard do Zé" -- collects, consolidates and publishes a static,
#' daily-updated dashboard of CRAN check and download health, GitHub
#' development activity and academic output for a curated set of R packages
#' and repositories.
#'
#' The pipeline is a sequence of exported functions: the collectors
#' [collect_cran()], [collect_github()] and [collect_academic()] write staged
#' Parquet tables; [consolidate()] merges them into the canonical store;
#' [export_json()] and [make_badges()] derive what the dashboard and the
#' shields.io badges read; [run_alerts()] turns CRAN check failures into
#' GitHub issues.
#'
#' @keywords internal
"_PACKAGE"

## usethis namespace: start
## usethis namespace: end
NULL
