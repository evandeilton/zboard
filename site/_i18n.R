# =============================================================================
# i18n for the Quarto dashboard
# =============================================================================
#
# Files whose name starts with "_" are not project inputs, so this is sourced
# by `_setup.R`, never rendered.
#
# How the active language is decided
# ----------------------------------
# From `QUARTO_PROFILE`, the environment variable Quarto exports to the
# rendering engine for the active profile. Verified empirically against both
# profiles: `--profile en` yields "en" and `--profile pt` yields "pt".
#
# `params$lang` does NOT work here and must not be used. A profile file
# cannot inject a value into a document's `params`, so each page keeps the
# default declared in its own YAML and every page renders in the same
# language whichever profile is active. That was tested, not assumed.

# -- locating the catalogue ---------------------------------------------------

#' Find `config/i18n.yml` by walking up from a starting directory.
#'
#' Renders run with the working directory at `site/`, `devtools::test()` runs
#' from `tests/testthat/`, and `R CMD check` runs from a `.Rcheck` tree nested
#' inside the repository. One upward walk covers all three.
zb_i18n_find <- function(start = getwd(), max_up = 8L) {
  dir <- normalizePath(start, mustWork = FALSE)
  for (i in seq_len(max_up)) {
    candidate <- file.path(dir, "config", "i18n.yml")
    if (file.exists(candidate)) {
      return(normalizePath(candidate))
    }
    parent <- dirname(dir)
    if (identical(parent, dir)) break
    dir <- parent
  }
  NA_character_
}

zb_i18n_env <- new.env(parent = emptyenv())

#' Read and validate the catalogue.
#'
#' Validation is deliberately strict and happens once, at load: a key that is
#' not a two-language mapping is a broken catalogue, and failing here gives a
#' readable error instead of an `NA` printed into a published page.
zb_i18n_load <- function(path = zb_i18n_find(), langs = c("en", "pt")) {
  if (is.na(path)) {
    stop("config/i18n.yml not found: searched upwards from ", getwd(), ".", call. = FALSE)
  }
  raw <- yaml::read_yaml(path)
  if (!length(raw)) {
    stop("config/i18n.yml is empty: ", path, call. = FALSE)
  }
  bad <- names(raw)[!vapply(raw, function(v) {
    is.list(v) && all(langs %in% names(v)) &&
      all(vapply(v[langs], function(s) is.character(s) && length(s) == 1L && nzchar(s), logical(1)))
  }, logical(1))]
  if (length(bad)) {
    stop(
      "config/i18n.yml: ", length(bad), " key(s) are not a complete ",
      paste(langs, collapse = "/"), " mapping of non-empty strings: ",
      paste(utils::head(bad, 10L), collapse = ", "),
      call. = FALSE
    )
  }
  zb_i18n_env$catalogue <- raw
  zb_i18n_env$path <- path
  invisible(raw)
}

zb_i18n <- function() {
  if (is.null(zb_i18n_env$catalogue)) zb_i18n_load()
  zb_i18n_env$catalogue
}

# -- active language ----------------------------------------------------------

#' The language of the render in progress.
#'
#' Anything other than a known profile falls back to English rather than
#' failing the build: an unlocalised page is a better failure mode than no
#' page at all.
zb_lang <- function(known = c("en", "pt")) {
  profile <- trimws(unlist(strsplit(Sys.getenv("QUARTO_PROFILE", ""), ",")))
  profile <- profile[nzchar(profile) & profile %in% known]
  if (length(profile)) profile[[1L]] else known[[1L]]
}

# -- lookup -------------------------------------------------------------------

#' Translate one key.
#'
#' Fails loudly on an unknown key. A missing translation must break the build,
#' not leak a placeholder such as `{{key}}` or `NA` into a published page.
tr <- function(key, lang = zb_lang()) {
  entry <- zb_i18n()[[key]]
  if (is.null(entry)) {
    stop("i18n: unknown key '", key, "'. Add it to config/i18n.yml.", call. = FALSE)
  }
  value <- entry[[lang]]
  if (is.null(value) || !nzchar(value)) {
    stop("i18n: key '", key, "' has no '", lang, "' translation.", call. = FALSE)
  }
  value
}

#' Translate one key and fill its `{placeholder}` markers.
#'
#' Only the placeholders supplied are substituted; anything else is left
#' verbatim, which is how technical strings such as `crandb.r-pkg.org/{pkg}/all`
#' survive a pass through this function unchanged.
#'
#' Vectorised over the placeholder values, recycling to the longest, so a
#' whole table column can be labelled in one call.
tr_f <- function(key, ..., lang = zb_lang()) {
  template <- tr(key, lang)
  values <- list(...)
  if (!length(values)) {
    return(template)
  }
  n <- max(1L, max(lengths(values)))
  out <- rep(template, n)
  for (nm in names(values)) {
    replacement <- rep_len(as.character(values[[nm]]), n)
    pattern <- paste0("{", nm, "}")
    out <- vapply(
      seq_len(n),
      function(i) gsub(pattern, replacement[[i]], out[[i]], fixed = TRUE),
      character(1)
    )
  }
  out
}

#' Every key in the catalogue, sorted. Used by the parity test.
zb_i18n_keys <- function() sort(names(zb_i18n()))
