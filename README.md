# zboard

<!-- badges: start -->
[![collect](https://github.com/evandeilton/zboard/actions/workflows/collect.yml/badge.svg)](https://github.com/evandeilton/zboard/actions/workflows/collect.yml)
[![R-CMD-check](https://github.com/evandeilton/zboard/actions/workflows/test.yml/badge.svg)](https://github.com/evandeilton/zboard/actions/workflows/test.yml)
[![Lifecycle: experimental](https://img.shields.io/badge/lifecycle-experimental-orange.svg)](https://lifecycle.r-lib.org/articles/stages.html#experimental)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE.md)
<!-- badges: end -->

**zboard** ("dashboard do Zé") is the data engine behind a public, static,
daily-updated dashboard that brings together, for a curated set of R packages
and repositories:

- the health of each package on CRAN — `R CMD check` status per flavour,
  current version, archival status;
- the download series of each package;
- development activity in the associated GitHub repositories — commits, pull
  requests, issues, releases, traffic;
- the associated academic output — publications and citations.

It runs unattended from GitHub Actions with no server and no database: Parquet
files on an orphan `data` branch are the canonical store, a bilingual Quarto
site is rebuilt from them every day and published to GitHub Pages.

- **Live dashboard:** <https://evandeilton.github.io/zboard/> (English) ·
  <https://evandeilton.github.io/zboard/pt/> (Portuguese)

## Installation

`zboard` is not on CRAN and is not intended for it — it is a self-hosted
monitoring tool rather than a general-purpose library. Install from GitHub:

```r
# install.packages("pak")
pak::pak("evandeilton/zboard")
```

Or work from a clone of the repository, which is how the pipeline is developed
and how CI runs it:

```r
renv::restore()        # pinned dependencies
devtools::load_all()   # load the package from source
```

## Quick start

Everything the pipeline does is an exported function. A full local run, from
collection to a rendered site, is:

```r
library(zboard)

# 1. Collect each source into staging/ (each collector accepts an optional
#    date window; without one it fetches the recent incremental slice).
collect_cran()
collect_github()     # needs GITHUB_TOKEN
collect_academic()   # needs OPENALEX_MAILTO

# 2. Upsert staging/ into the canonical store in data/. Monthly rollups are
#    written before the daily window is pruned, never the other way round.
consolidate()

# 3. Derive the JSON the site reads.
export_json()
```

Then, from a shell at the repository root:

```bash
quarto preview site --profile en   # or --profile pt
```

Backfilling is a date window on the collectors:

```r
collect_cran(from = "2025-09-17", to = "2026-09-17")
```

It applies to CRAN downloads, GitHub activity and academic works. GitHub
traffic cannot be backfilled: the GitHub API keeps 14 days and nothing more, so
the traffic series starts on the day collection starts — the dashboard says so
next to every traffic chart.

See `?collect_cran`, `?consolidate`, `?export_json`, `?make_badges` and
`?run_alerts` for the full reference.

## Configuration

### What is monitored

[`config/repos.yml`](config/repos.yml) is the explicit list of what the
dashboard covers. Packages and repositories that are not listed there are not
collected at all.

```yaml
cran_packages: [gkwreg, gkwdist, betaregscale, OptimalBinningWoE]
github_repos:
  - { repo: evandeilton/gkwreg, group: cran }
  - { repo: evandeilton/rnp,    group: tools }
orcid: "0009-0007-5887-4084"
```

### Environment variables

| Variable | Used by | Notes |
|---|---|---|
| `GITHUB_TOKEN` | `collect_github()`, `run_alerts()` | A fine-grained personal access token with `Metadata: read`, `Contents: read` and `Administration: read` on the monitored repositories. `Administration: read` is what the traffic endpoints require. |
| `OPENALEX_MAILTO` | `collect_academic()` | Contact e-mail for the OpenAlex polite pool, which has markedly better rate limits than anonymous access. |

Both are read from the environment only. For local work put them in a
`.Renviron` at the repository root (ignored by git) or in `~/.Renviron`. They
are never written to a versioned file or to the generated HTML.

## Deployment

One workflow, `.github/workflows/collect.yml`, runs every day at 06:15 UTC and
can also be started by hand (with optional `from`, `to` and `sources` inputs
for a backfill). Its jobs are, in order:

1. **collect** — one job per source (`cran`, `github`, `academic`). A source
   that fails does not stop the others.
2. **consolidate** — merges the staged data into the `data` branch:
   upsert, monthly rollup, then pruning of the daily series to a 12-month
   window.
3. **build** — exports the JSON, renders the site in both languages, writes
   the badges and publishes to the `gh-pages` branch.
4. **alert** — opens, updates and closes GitHub issues (label `alert`) when a
   package's CRAN check turns to `WARN`/`ERROR`/`FAIL` or the package is
   archived.

A second workflow runs `R CMD check` and a render smoke test on every pull
request.

To run it in your own fork, the repository needs:

- the secret `GH_FINE_GRAINED_PAT` — the token described above, scoped to the
  repositories in `config/repos.yml`;
- the secret `OPENALEX_MAILTO`;
- GitHub Pages enabled with *Deploy from a branch* → `gh-pages`, `/ (root)`.
  The branch is created by the first successful `build` job.

## Badges for package READMEs

The `build` job publishes shields.io *endpoint* JSON for every monitored
package under `badges/` on the site: `<pkg>-downloads`, `<pkg>-check` and
`<pkg>-version`. Use them in a package README as

```markdown
![CRAN downloads](https://img.shields.io/endpoint?url=https://evandeilton.github.io/zboard/badges/gkwreg-downloads.json)
```

## About the numbers

The dashboard is descriptive, and its sources have limits that are stated on
its [About page](https://evandeilton.github.io/zboard/about.html) in full.
In short: download counts come from a single CRAN mirror and are inflated by
CI and bots, so they are a relative trend, not a total; each release produces
a spike as binaries are rebuilt; GitHub traffic starts on the day collection
started; OpenAlex citation counts lag by weeks to months.

## License

- **Code:** MIT — see [`LICENSE.md`](LICENSE.md).
- **Published aggregated data:** CC-BY-4.0.

Upstream data remains subject to the terms of its sources: CRAN, the
`cranlogs.r-pkg.org` and `crandb.r-pkg.org` services, the GitHub API and
OpenAlex.
