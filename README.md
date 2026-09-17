# zboard

<!-- badges: start -->
[![collect](https://github.com/evandeilton/prod-monitor/actions/workflows/collect.yml/badge.svg)](https://github.com/evandeilton/prod-monitor/actions/workflows/collect.yml)
[![test](https://github.com/evandeilton/prod-monitor/actions/workflows/test.yml/badge.svg)](https://github.com/evandeilton/prod-monitor/actions/workflows/test.yml)
[![Lifecycle: experimental](https://img.shields.io/badge/lifecycle-experimental-orange.svg)](https://lifecycle.r-lib.org/articles/stages.html#experimental)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE.md)
<!-- badges: end -->

**zboard** — "dashboard do Zé" — is the data engine behind a public, static,
daily-updated dashboard that consolidates, in one place:

1. the health of R packages published on CRAN (`R CMD check` status per flavor,
   current version, archival risk);
2. the historical download series for those packages;
3. development activity in a curated set of GitHub repositories (commits, PRs,
   issues, releases, traffic);
4. the associated academic output (publications and citations).

The dashboard serves two purposes at once: **operational** — catching CRAN
regressions before the official notification arrives — and **showcase** — a
public portfolio artifact, linkable from a CV, LinkedIn or a package README.

- **Live dashboard:** <https://evandeilton.github.io/prod-monitor/> (EN) ·
  <https://evandeilton.github.io/prod-monitor/pt/> (PT-BR)
- **Full, normative specification:** [`SPEC.md`](SPEC.md)

> **Package name vs. repository name.** The R package is `zboard`; the GitHub
> repository is `evandeilton/prod-monitor`. Use `prod-monitor` only in
> repository and Pages URLs, and `zboard` in everything that is code —
> `library(zboard)`, `zboard::collect_cran()`, installation instructions.

Status: `0.0.0.9000`, pre-release. Not on CRAN and not intended for it — this is
a self-hosted monitoring tool, not a general-purpose library.

---

## What it is not

`SPEC.md` §2 is normative; the items below are excluded by design, not by
omission, and should not be implemented without revising the spec first.

| # | Non-goal | Why |
|---|---|---|
| NG-1 | Statistical modelling, forecasting or model-based anomaly detection | The dashboard is descriptive. CRAN download series are a convenience sample from a single mirror, contaminated by CI and bots; modelling them would produce inference with no external validity. |
| NG-2 | Raw commit counts as a headline KPI | Subject to Goodhart's law; measures typing volume, not output. |
| NG-3 | Backend, managed database or dynamic runtime | Zero cost, minimal maintenance. |
| NG-4 | HTML scraping of CRAN or GitHub | Brittle. Official APIs and artifacts (`.rds`, JSON) only. |
| NG-5 | Collection of identifiable third-party data (contributor profiles, issue authors' e-mails) | Privacy. Per-repository aggregates only. |
| NG-6 | Server-side reactivity (hosted Shiny) or heavy WASM (Shinylive) | Boot and maintenance cost out of proportion to the gain. |

## Declared limitations

Methodological transparency is a requirement, not a courtesy. The **normative,
full text lives on the dashboard's *About* page**, in both languages
(`SPEC.md` §10). In short:

1. **Downloads are not a census.** The series reflects only the
   `cloud.r-project.org` (Posit) mirror. There is no known inclusion probability
   for the other mirrors, so no unbiased estimator of total downloads exists.
   Use the series for relative trend, never as an absolute level.
2. **Automation contamination.** CRAN check farms, Docker images and third-party
   CI inflate the counts. For niche packages the non-human fraction may be the
   majority.
3. **Release artifact.** Each new version produces a spike of several times the
   baseline as Windows/macOS binaries are rebuilt. The release markers on the
   charts exist to make that artifact visible, not to correct it.
4. **Truncated traffic series.** Traffic starts on the date of first collection;
   everything before it is inaccessible by API design (14-day retention).
5. **Citation lag.** OpenAlex counts have weeks-to-months indexing latency and
   incomplete coverage for software.

---

## Architecture

Three branches (`SPEC.md` §14):

| Branch | Contents |
|---|---|
| `main` | Code: the `zboard` package, the Quarto sources, the workflows. |
| `data` | Orphan branch. Canonical Parquet store, `data/*.parquet` (ADR-2). |
| `gh-pages` | The rendered site, deployed by CI. |

One daily workflow (`.github/workflows/collect.yml`, cron `15 6 * * *`):

```
collect (matrix: cran | github | academic)   <- isolated failure per source (RNF-3)
     |
consolidate (needs: collect, if: always())   <- upsert -> rollup -> prune -> push `data`
     |
     +-- build   export JSON -> render EN -> render PT -> badges -> deploy gh-pages
     +-- alert   open / update / close issues per SPEC.md §8
```

Every CI step is a call to an exported, documented, tested function of the
installed package — the package is installed once per job and the steps read
`zboard::collect_cran()`, `zboard::consolidate()`, and so on. There are no
standalone scripts.

---

## Running it locally

```r
# 1. Dependencies (once renv.lock exists; see "Setup" below)
renv::restore()

# 2. Load the package from source
devtools::load_all()

# 3. Collect into staging/ (each collector takes an optional date window)
zboard::collect_cran()
zboard::collect_github()     # needs GITHUB_TOKEN
zboard::collect_academic()   # needs OPENALEX_MAILTO

# 4. Upsert staging/ into data/ (rollup, then prune - never the other way round)
zboard::consolidate()

# 5. Derive the JSON the front-end reads
zboard::export_json()

# 6. Preview the dashboard
# (from a shell, at the repository root)
# quarto preview site --profile en
# quarto preview site --profile pt
```

Backfill is a date window on the collectors, and applies to `cran_downloads`,
`gh_activity` and `academic_works` only:

```r
zboard::collect_cran(from = "2025-09-17", to = "2026-09-17")
```

It is **not** applicable to `gh_traffic`: the GitHub traffic API retains 14 days
and nothing more. This is a permanent limitation, and the reason the collector
should be running before anything else is polished — every day without
collection is data lost for good (`SPEC.md` §12, Phase 0).

In CI the same window is passed through the `from` / `to` inputs of the
`collect` workflow's `workflow_dispatch`, with `sources` narrowing the run to a
comma-separated subset of `cran,github,academic`.

### Development cycle

```r
devtools::load_all()       # iterate
devtools::document()       # regenerate NAMESPACE + man/ from roxygen
devtools::test()           # testthat (edition 3)
devtools::check()          # what CI runs, via r-lib/actions/check-r-package
```

CI fails on a warning (`error-on: '"warning"'`), and the pipeline steps run
under `options(warn = 2)` (RNF-8), so treat a warning as a failure locally too.

### Environment variables

| Variable | Used by | Notes |
|---|---|---|
| `GITHUB_TOKEN` | `collect_github()`, `run_alerts()` | Locally, a fine-grained PAT (see Setup). In CI, the collector receives `secrets.GH_FINE_GRAINED_PAT` and the alert job receives the automatic Actions token. |
| `OPENALEX_MAILTO` | `collect_academic()` | Contact e-mail for the OpenAlex polite pool. |

Both are read from the environment; never commit them, and never write them into
generated HTML (`SPEC.md` §11). For local work, put them in a `.Renviron` that is
outside the repository, or in the project's `.Renviron` — which is **not** in
`.gitignore` today, so prefer `~/.Renviron` unless you add it first.

---

## Setup

These steps require decisions and credentials that only the repository owner can
provide. **No automated agent can create tokens, secrets or credentials** — do
these by hand, in your own GitHub session, before the first production run.
They close pendencies P-1 to P-4 of `SPEC.md` §15.

**1. Create the fine-grained PAT and register it as `GH_FINE_GRAINED_PAT`.**

GitHub → Settings → Developer settings → Personal access tokens → Fine-grained
tokens. Minimum scope (`SPEC.md` §11):

- `Metadata: read`
- `Contents: read`
- `Administration: read` — required for the traffic endpoints, and the reason
  the automatic Actions token is not sufficient here

Restrict the token to the repositories listed in
[`config/repos.yml`](config/repos.yml) — not "all repositories". Register it as
a repository secret named `GH_FINE_GRAINED_PAT` (Settings → Secrets and
variables → Actions).

**Rotate every six months.** Set a calendar reminder when you create it; an
expired PAT surfaces as a 401 from the GitHub collector (`SPEC.md` §13).

**2. Register `OPENALEX_MAILTO`.** A real contact e-mail address, as a
repository secret. OpenAlex uses it for the polite pool, which gives markedly
better rate limits. It is never written to a versioned file or to the generated
HTML.

**3. Enable GitHub Pages.** Settings → Pages → Build and deployment →
Source: **Deploy from a branch** → Branch: `gh-pages`, folder `/ (root)`.
The branch is created by the first successful `build` job, so run the workflow
once before configuring this.

**4. Confirm `config/repos.yml` (P-1).** The file is already populated with the
list proposed in `SPEC.md` §5, marked *"a confirmar pelo autor"*. Repositories
and packages that are not listed are **not collected and not aggregated** —
curation is an editorial decision, not a display filter. Edit and confirm before
the first production run.

**5. Decide on third-party PRs and reviews (P-3).** Whether contributions you
make to repositories you do not own should be counted is still open. It is not
modelled in the current schema: `gh_activity` is keyed on `(date, repo)` and
`repos.yml` lists only owned repositories. Including it would mean a new table
and a new collection path, so treat it as a schema change, not a config toggle.

**6. Decide on `evandeilton.github.io` (P-4).** Not included by default. It is a
personal site rather than a package, so its commit activity measures publishing
cadence rather than software output — which is exactly the kind of volume metric
NG-2 keeps off the dashboard. Add it to `config/repos.yml` under a distinct
`group` if you want it tracked anyway.

---

## Consuming the badges

The `build` job writes shields.io *endpoint* JSON to `badges/` on the published
site. Drop this into the README of any package (`SPEC.md` §7.4):

```markdown
![CRAN downloads](https://img.shields.io/endpoint?url=https://evandeilton.github.io/prod-monitor/badges/gkwreg-downloads.json)
```

Available in v1, for each curated package: `<pkg>-downloads`, `<pkg>-check`
(green / yellow / red according to the worst flavor) and `<pkg>-version`.

---

## License

- **Code:** MIT. See [`LICENSE.md`](LICENSE.md) for the full text
  (`LICENSE` is the year/holder stub that `License: MIT + file LICENSE` in
  `DESCRIPTION` requires).
- **Published aggregated data:** CC-BY-4.0.

Upstream data remains subject to the terms of its sources: CRAN, the
`cranlogs.r-pkg.org` and `crandb.r-pkg.org` services, the GitHub API and
OpenAlex.
