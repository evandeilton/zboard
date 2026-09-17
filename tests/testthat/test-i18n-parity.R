# CI must fail if a key exists in one language and is missing in the other.
#
# The catalogue is `config/i18n.yml`: one top-level key per user-visible
# string, each a mapping of the two supported languages. A key translated in
# one language and forgotten in the other must fail the build rather than
# publish a page with an English sentence in the middle of a Portuguese
# paragraph.
#
# Locating the catalogue
# ----------------------
# `config/` is in .Rbuildignore, so it is NOT inside the built tarball. The
# helper below therefore walks UP from the test's working directory to find
# the repository. That covers the three ways this file actually runs:
#
#   devtools::test()  wd = tests/testthat      -> found one level up
#   R CMD check       wd = <pkg>.Rcheck/tests/testthat, which in CI is nested
#                     inside the checkout      -> found further up
#   testthat::test_file() from the repo root   -> found in place
#
# When the walk finds nothing the test skips rather than fails: that means
# the package was checked outside its repository, where there is no catalogue
# to be inconsistent with. Everywhere the catalogue exists, the test runs.
#
# No network, no file written.

langs <- c("en", "pt")

repo_file <- function(...) {
  relative <- file.path(...)
  dir <- normalizePath(getwd(), mustWork = FALSE)
  for (i in seq_len(8L)) {
    candidate <- file.path(dir, relative)
    if (file.exists(candidate)) {
      return(candidate)
    }
    parent <- dirname(dir)
    if (identical(parent, dir)) break
    dir <- parent
  }
  NA_character_
}

skip_without <- function(path, what) {
  if (is.na(path)) {
    testthat::skip(paste0(
      what, " not found: the package is being checked outside its source ",
      "repository, where there is nothing to compare against."
    ))
  }
  path
}

catalogue_path <- repo_file("config", "i18n.yml")

read_catalogue <- function() {
  yaml::read_yaml(skip_without(catalogue_path, "config/i18n.yml"))
}

test_that("config/i18n.yml parses into a non-empty, flat catalogue", {
  catalogue <- read_catalogue()

  expect_type(catalogue, "list")
  expect_gt(length(catalogue), 0L)
  expect_false(anyDuplicated(names(catalogue)) > 0L)
  expect_true(all(nzchar(names(catalogue))))
  expect_true(all(vapply(catalogue, is.list, logical(1))))
})

test_that("every key is translated into every language", {
  catalogue <- read_catalogue()

  present <- lapply(langs, function(lang) {
    names(catalogue)[vapply(
      catalogue,
      function(entry) lang %in% names(entry),
      logical(1)
    )]
  })
  names(present) <- langs

  # Reported as an explicit, readable diff: a parity failure has to name the
  # keys, or the person fixing it has to bisect a 400-key file by hand.
  missing <- lapply(langs, function(lang) setdiff(names(catalogue), present[[lang]]))
  names(missing) <- langs

  expect_equal(
    missing$pt, character(),
    info = paste0(
      "key(s) translated into 'en' but missing from 'pt': ",
      paste(missing$pt, collapse = ", ")
    )
  )
  expect_equal(
    missing$en, character(),
    info = paste0(
      "key(s) translated into 'pt' but missing from 'en': ",
      paste(missing$en, collapse = ", ")
    )
  )
  expect_setequal(present$en, present$pt)
})

test_that("no key carries a language outside the supported set", {
  catalogue <- read_catalogue()

  extra <- as.character(sort(unique(unlist(lapply(catalogue, function(entry) {
    setdiff(names(entry), langs)
  }), use.names = FALSE))))

  expect_equal(
    extra, character(),
    info = paste0("unsupported language tag(s): ", paste(extra, collapse = ", "))
  )
})

test_that("every translation is a single, non-empty string", {
  catalogue <- read_catalogue()

  bad <- character()
  for (key in names(catalogue)) {
    for (lang in langs) {
      value <- catalogue[[key]][[lang]]
      ok <- is.character(value) && length(value) == 1L && nzchar(trimws(value))
      if (!ok) bad <- c(bad, paste0(key, " [", lang, "]"))
    }
  }

  expect_equal(
    bad, character(),
    info = paste0(
      "translation(s) that are not one non-empty string: ",
      paste(bad, collapse = ", ")
    )
  )
})

test_that("both languages of a key use the same {placeholder} set", {
  catalogue <- read_catalogue()

  placeholders <- function(x) {
    sort(unique(unlist(regmatches(x, gregexpr("\\{[A-Za-z_][A-Za-z0-9_]*\\}", x)))))
  }

  # A placeholder present in one language and absent from the other means the
  # translated string silently drops an interpolated value -- a date, a
  # repository name -- which is exactly the class of defect a reader of the
  # other language would never report.
  mismatched <- character()
  for (key in names(catalogue)) {
    sets <- lapply(langs, function(lang) placeholders(catalogue[[key]][[lang]]))
    if (!identical(sets[[1L]], sets[[2L]])) {
      mismatched <- c(mismatched, paste0(
        key, " (en: ", paste(sets[[1L]], collapse = " "),
        " | pt: ", paste(sets[[2L]], collapse = " "), ")"
      ))
    }
  }

  expect_equal(
    mismatched, character(),
    info = paste0(
      "key(s) whose languages interpolate different values: ",
      paste(mismatched, collapse = "; ")
    )
  )
})

test_that("every key used by the Quarto sources exists in the catalogue", {
  catalogue <- read_catalogue()
  site_dir <- repo_file("site")
  skip_without(site_dir, "site/")

  sources <- list.files(
    site_dir,
    pattern = "[.](qmd|R)$", full.names = TRUE, recursive = FALSE
  )
  skip_if(length(sources) == 0L, "no Quarto sources to scan")

  text <- unlist(lapply(sources, readLines, warn = FALSE), use.names = FALSE)
  # Literal calls only: keys assembled at run time (e.g. paste0("status.label.",
  # k)) are covered by the prefix check below instead.
  literal <- unlist(regmatches(
    text,
    gregexpr('\\btr_?f?\\(\\s*"[A-Za-z0-9_.]+"', text)
  ), use.names = FALSE)
  keys <- unique(gsub('^.*"([A-Za-z0-9_.]+)"$', "\\1", literal))
  skip_if(length(keys) == 0L, "no literal tr() calls found")

  unknown <- sort(setdiff(keys, names(catalogue)))
  expect_equal(
    unknown, character(),
    info = paste0(
      "key(s) referenced by site/ but absent from config/i18n.yml: ",
      paste(unknown, collapse = ", ")
    )
  )
})

test_that("the runtime key families the pages build dynamically are complete", {
  catalogue <- read_catalogue()

  # These keys are assembled from a data value at render time, so a missing
  # member surfaces only when that value appears in real data -- a FAIL check
  # status, say, which is precisely the day nothing else may go wrong.
  required <- c(
    paste0("status.label.", c("ok", "note", "warn", "error", "fail", "unknown")),
    paste0("status.desc.", c("ok", "note", "warn", "error", "fail", "unknown")),
    paste0("freshness.status.", c("ok", "partial", "failed", "unknown")),
    paste0("lang.name.", langs),
    paste0("github.metric.", c(
      "commits", "prs_opened", "prs_merged", "prs_closed",
      "issues_opened", "issues_closed",
      "views", "view_uniques", "clones", "clone_uniques"
    )),
    paste0("about.limit.", 1:5, ".title"),
    paste0("about.limit.", 1:5, ".body"),
    unlist(lapply(
      c("downloads", "versions", "checks", "archive", "activity", "traffic", "academic"),
      function(id) paste0("about.src.", id, c(".name", ".endpoint", ".auth", ".retro", ".limit"))
    ))
  )

  missing <- sort(setdiff(required, names(catalogue)))
  expect_equal(
    missing, character(),
    info = paste0(
      "runtime-assembled key(s) absent from config/i18n.yml: ",
      paste(missing, collapse = ", ")
    )
  )
})

test_that("the Quarto navbar labels match their i18n keys", {
  catalogue <- read_catalogue()

  # Quarto's navbar is YAML and cannot call R, so the five navigation labels
  # are duplicated into `_quarto-en.yml` / `_quarto-pt.yml`. This keeps
  # config/i18n.yml the single source of truth by failing when the copies
  # drift apart.
  nav_keys <- c("nav.overview", "nav.cran", "nav.github", "nav.academic", "nav.about")

  for (lang in langs) {
    profile_path <- repo_file("site", paste0("_quarto-", lang, ".yml"))
    skip_without(profile_path, paste0("site/_quarto-", lang, ".yml"))
    profile <- yaml::read_yaml(profile_path)

    items <- profile$website$navbar$left
    labels <- vapply(items, function(item) {
      if (is.null(item$text)) "" else as.character(item$text)[[1L]]
    }, character(1))
    expected <- vapply(nav_keys, function(key) catalogue[[key]][[lang]], character(1))

    expect_equal(
      labels, unname(expected),
      info = paste0(
        "_quarto-", lang, ".yml navbar labels have drifted from config/i18n.yml"
      )
    )
    expect_equal(as.character(profile$lang), lang)
  }
})

test_that("the Portuguese profile writes to the path the workflow publishes", {
  # By design, and per .github/workflows/collect.yml: `/` is English and
  # `/pt/` is Portuguese. The EN profile inherits `output-dir` from the base
  # project file, the PT profile overrides it, and the build job renders EN
  # first because Quarto cleans its output directory.
  base_path <- repo_file("site", "_quarto.yml")
  pt_path <- repo_file("site", "_quarto-pt.yml")
  skip_without(base_path, "site/_quarto.yml")
  skip_without(pt_path, "site/_quarto-pt.yml")

  expect_equal(yaml::read_yaml(base_path)$project$`output-dir`, "../_site")
  expect_equal(yaml::read_yaml(pt_path)$project$`output-dir`, "../_site/pt")
})
