# =============================================================================
# Presentation layer for the Quarto dashboard.
# =============================================================================
#
# Sourced at the top of every page. Files starting with "_" are not project
# inputs, so this is never rendered on its own.
#
# What lives here, and why
# ------------------------
# * JSON access, against the contract documented at the top of
#   R/export_json.R. Every array is present but may be empty, so every reader
#   below degrades to an empty table rather than an error (RNF-3).
# * Formatting. Numbers and dates are localised from `config/i18n.yml`, never
#   from the system locale: a CI runner has no guarantee of a pt_BR locale,
#   and a silently English month name in the Portuguese build is exactly the
#   kind of defect nobody notices.
# * HTML components. Hand-written, so that tables carry `<th scope>` and a
#   `<caption>`, and figures carry a real `alt` (RNF-10).
# * Figures. ggplot2 rendered to a PNG and embedded as a data URI. The page
#   then has no JavaScript and no external asset at all, which keeps the
#   deliverable a pile of static HTML (NG-3, NG-6) and puts the `alt` text
#   under direct control instead of a chunk option.
#
# Status is NEVER encoded by colour alone: every status carries a symbol, a
# text label and a screen-reader description (SPEC.md S7.2, RNF-10).

suppressPackageStartupMessages({
  library(ggplot2)
})

source("_i18n.R", local = FALSE)

# -- JSON ---------------------------------------------------------------------

#' Locate `site/_data`, wherever the render was started from.
zb_data_dir <- function() {
  for (candidate in c("_data", file.path("site", "_data"))) {
    if (dir.exists(candidate)) {
      return(candidate)
    }
  }
  "_data"
}

zb_json_cache <- new.env(parent = emptyenv())

#' Read one of the ten exported JSON files.
#'
#' A missing file yields an empty list. That is the documented first-build
#' state: the site must render before any collection has run.
zb_json <- function(name) {
  if (!is.null(zb_json_cache[[name]])) {
    return(zb_json_cache[[name]])
  }
  path <- file.path(zb_data_dir(), paste0(name, ".json"))
  value <- if (file.exists(path)) {
    jsonlite::fromJSON(path, simplifyVector = TRUE, simplifyDataFrame = TRUE)
  } else {
    list()
  }
  zb_json_cache[[name]] <- value
  value
}

#' Coerce a JSON array to a data frame, empty array included.
zb_df <- function(x) {
  if (is.null(x) || length(x) == 0L) {
    return(data.frame())
  }
  if (is.data.frame(x)) {
    return(x)
  }
  tryCatch(as.data.frame(x, stringsAsFactors = FALSE), error = function(e) data.frame())
}

zb_empty <- function(x) nrow(zb_df(x)) == 0L

#' Flatten a `series` array (one object per entity, each with `points`) into a
#' single long data frame with the entity column attached.
zb_points <- function(series, by) {
  d <- zb_df(series)
  if (nrow(d) == 0L || !"points" %in% names(d) || !by %in% names(d)) {
    return(data.frame())
  }
  parts <- lapply(seq_len(nrow(d)), function(i) {
    pts <- d$points[[i]]
    if (!is.data.frame(pts) || nrow(pts) == 0L) {
      return(NULL)
    }
    pts[[by]] <- d[[by]][[i]]
    pts
  })
  parts <- parts[!vapply(parts, is.null, logical(1))]
  if (!length(parts)) {
    return(data.frame())
  }
  out <- do.call(rbind, parts)
  out$date <- as.Date(out$date)
  out
}

#' Scalar field of a JSON object, with a typed fallback.
zb_get <- function(x, field, default = NA) {
  value <- x[[field]]
  if (is.null(value) || length(value) == 0L) default else value[[1L]]
}

# -- formatting ---------------------------------------------------------------

zb_months <- function() trimws(strsplit(tr("format.month_short"), ",")[[1L]])

#' Integer with the locale's thousands separator.
zb_int <- function(x, na = tr("common.unknown")) {
  vapply(x, function(v) {
    if (is.null(v) || length(v) == 0L || is.na(v)) {
      return(na)
    }
    formatC(as.integer(round(v)),
      format = "d", big.mark = tr("format.thousands_sep")
    )
  }, character(1), USE.NAMES = FALSE)
}

#' Real number with the locale's separators.
zb_dbl <- function(x, digits = 1L, na = tr("common.unknown")) {
  vapply(x, function(v) {
    if (is.null(v) || length(v) == 0L || is.na(v)) {
      return(na)
    }
    formatC(as.numeric(v),
      format = "f", digits = digits,
      big.mark = tr("format.thousands_sep"),
      decimal.mark = tr("format.decimal_sep")
    )
  }, character(1), USE.NAMES = FALSE)
}

#' Signed percentage, for a trend against a baseline.
zb_pct <- function(x, na = tr("downloads.trend_unavailable")) {
  vapply(x, function(v) {
    if (is.null(v) || length(v) == 0L || is.na(v)) {
      return(na)
    }
    sign <- if (v > 0) "+" else ""
    tr_f("format.percent", value = paste0(sign, zb_dbl(v, digits = 1L)))
  }, character(1), USE.NAMES = FALSE)
}

zb_bool <- function(x, na = tr("common.unknown")) {
  vapply(x, function(v) {
    if (is.null(v) || length(v) == 0L || is.na(v)) {
      return(na)
    }
    if (isTRUE(as.logical(v))) tr("format.yes") else tr("format.no")
  }, character(1), USE.NAMES = FALSE)
}

#' "YYYY-MM-DD" in the reader's locale, without touching the system locale.
zb_date <- function(x, na = tr("common.unknown")) {
  months <- zb_months()
  vapply(x, function(v) {
    d <- suppressWarnings(as.Date(v))
    if (length(d) == 0L || is.na(d)) {
      return(na)
    }
    parts <- as.integer(format(d, c("%d", "%m", "%Y")))
    tr_f("format.date_pattern",
      day = parts[[1L]], mon = months[[parts[[2L]]]], year = parts[[3L]]
    )
  }, character(1), USE.NAMES = FALSE)
}

#' Short date, for a chart axis.
zb_date_short <- function(x) {
  months <- zb_months()
  vapply(x, function(v) {
    d <- suppressWarnings(as.Date(v))
    if (length(d) == 0L || is.na(d)) {
      return("")
    }
    parts <- as.integer(format(d, c("%d", "%m")))
    tr_f("format.date_short_pattern", day = parts[[1L]], mon = months[[parts[[2L]]]])
  }, character(1), USE.NAMES = FALSE)
}

#' "YYYY-MM" in the reader's locale.
zb_month <- function(x, na = tr("common.unknown")) {
  months <- zb_months()
  vapply(x, function(v) {
    if (is.null(v) || length(v) == 0L || is.na(v)) {
      return(na)
    }
    parts <- strsplit(as.character(v), "-", fixed = TRUE)[[1L]]
    if (length(parts) < 2L) {
      return(na)
    }
    tr_f("format.month_year_pattern",
      mon = months[[as.integer(parts[[2L]])]], year = parts[[1L]]
    )
  }, character(1), USE.NAMES = FALSE)
}

#' ISO-8601 UTC timestamp in the reader's locale. The zone stays UTC on
#' purpose: the pipeline is documented in UTC and a browser-local rendering
#' would need JavaScript.
zb_datetime <- function(x, na = tr("common.unknown")) {
  months <- zb_months()
  vapply(x, function(v) {
    ts <- suppressWarnings(as.POSIXct(v, format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"))
    if (length(ts) == 0L || is.na(ts)) {
      return(na)
    }
    parts <- format(ts, c("%d", "%m", "%Y", "%H:%M"), tz = "UTC")
    tr_f("format.datetime_pattern",
      day = as.integer(parts[[1L]]), mon = months[[as.integer(parts[[2L]])]],
      year = parts[[3L]], time = parts[[4L]]
    )
  }, character(1), USE.NAMES = FALSE)
}

# -- HTML ---------------------------------------------------------------------

zb_esc <- function(x) htmltools::htmlEscape(ifelse(is.na(x), "", as.character(x)))
zb_esc_attr <- function(x) htmltools::htmlEscape(as.character(x), attribute = TRUE)

#' The small subset of Markdown used inside hand-built HTML components.
#'
#' Pandoc does not process Markdown inside a raw HTML block, so a string from
#' `i18n.yml` that carries `**bold**` or a backtick has to be converted here.
#' Escaping happens first, so the catalogue can never inject markup.
zb_md_inline <- function(x) {
  out <- zb_esc(x)
  out <- gsub("\\[([^]]+)\\]\\(([^)]+)\\)", '<a href="\\2">\\1</a>', out)
  out <- gsub("\\*\\*([^*]+)\\*\\*", "<strong>\\1</strong>", out)
  out <- gsub("(^|[^*])\\*([^*]+)\\*", "\\1<em>\\2</em>", out)
  out <- gsub("`([^`]+)`", "<code>\\1</code>", out)
  out
}

#' Emit a block, always fenced by blank lines so Pandoc keeps raw HTML raw and
#' Markdown Markdown.
zb_out <- function(...) cat("\n", paste0(..., collapse = ""), "\n\n", sep = "")

#' The language switch of SPEC.md S7.3: a static link between `/` and `/pt/`
#' that preserves the page path. Quarto's navbar is a fixed YAML href and
#' cannot do this, so the switch lives in the page body.
zb_lang_bar <- function(page) {
  lang <- zb_lang()
  other <- if (identical(lang, "en")) "pt" else "en"
  href <- if (identical(lang, "en")) paste0("pt/", page) else paste0("../", page)
  paste0(
    '<nav class="zb-langbar" aria-label="', zb_esc_attr(tr("lang.bar_aria")), '">',
    '<span class="zb-langbar-current">', zb_esc(tr("lang.reading")), " ",
    "<strong>", zb_esc(tr(paste0("lang.name.", lang))), "</strong></span>",
    # The link is deliberately written in the language it leads to: a reader
    # who cannot read the current page can still read its exit.
    '<a class="zb-langbar-link" href="', zb_esc_attr(href), '" hreflang="', other, '" lang="', other, '">',
    zb_esc(tr_f("lang.switch_to",
      language = tr(paste0("lang.name.", other), lang = other), lang = other
    )),
    "</a></nav>"
  )
}

#' Page header: the language switch, the date of the most recent datum (never
#' the build date, SPEC.md S7.2) and, separately labelled, the build time.
zb_page_header <- function(page, latest_date = NULL) {
  latest <- if (is.null(latest_date) || is.na(latest_date)) {
    tr("common.latest_datum_unknown")
  } else {
    tr_f("common.latest_datum", date = zb_date(latest_date))
  }
  paste0(
    zb_lang_bar(page),
    '<p class="zb-dateline">',
    '<span class="zb-dateline-data">', zb_md_inline(latest), "</span>",
    '<span class="zb-dateline-build">',
    zb_md_inline(tr_f("common.build_time",
      datetime = zb_datetime(zb_get(zb_json("meta"), "generated_at"))
    )),
    "</span></p>"
  )
}

zb_status_levels <- c("ok", "note", "warn", "error", "fail", "unknown")

zb_status_key <- function(status) {
  key <- tolower(ifelse(is.na(status) | !nzchar(as.character(status)), "unknown", as.character(status)))
  ifelse(key %in% zb_status_levels, key, "unknown")
}

#' A CRAN check status: symbol + text label + screen-reader description.
#' Colour is decoration here, never the information channel (RNF-10).
zb_status <- function(status) {
  key <- zb_status_key(status)
  symbols <- c(
    ok = "✓", note = "•", warn = "▲",
    error = "✕", fail = "✕", unknown = "?"
  )
  vapply(key, function(k) {
    paste0(
      '<span class="zb-status zb-status-', k, '">',
      '<span class="zb-status-sym" aria-hidden="true">', symbols[[k]], "</span>",
      '<span class="zb-status-text">', zb_esc(tr(paste0("status.label.", k))), "</span>",
      '<span class="zb-sr-only">, ', zb_esc(tr("common.aria_status_prefix")), ": ",
      zb_esc(tr(paste0("status.desc.", k))), "</span>",
      "</span>"
    )
  }, character(1), USE.NAMES = FALSE)
}

#' A pipeline run status, same rules.
zb_run_status <- function(status) {
  key <- tolower(ifelse(is.na(status) | !nzchar(as.character(status)), "unknown", as.character(status)))
  key <- ifelse(key %in% c("ok", "partial", "failed"), key, "unknown")
  symbols <- c(ok = "✓", partial = "▲", failed = "✕", unknown = "?")
  vapply(key, function(k) {
    paste0(
      '<span class="zb-status zb-run-', k, '">',
      '<span class="zb-status-sym" aria-hidden="true">', symbols[[k]], "</span>",
      '<span class="zb-status-text">', zb_esc(tr(paste0("freshness.status.", k))), "</span>",
      "</span>"
    )
  }, character(1), USE.NAMES = FALSE)
}

#' A semantic HTML table: `<caption>`, `<th scope="col">` and, optionally, a
#' row header per row (RNF-10). Hand-written rather than `knitr::kable()`,
#' which emits neither `scope` nor a per-column escaping policy.
#'
#' @param raw Names of columns already containing trusted HTML (a status
#'   badge, a link). Every other cell is escaped.
#' @param caption Visible `<caption>`. Left `NULL` where the heading directly
#'   above the table already says the same thing.
#' @param label Accessible name for the horizontally scrollable wrapper.
#'   Defaults to the caption; pass it explicitly when the caption is dropped,
#'   so the scroll region is never an unnamed `role="region"`.
zb_table <- function(df, labels = names(df), caption = NULL,
                     align = rep("l", ncol(df)), raw = character(),
                     row_header = FALSE, label = caption) {
  df <- zb_df(df)
  if (nrow(df) == 0L) {
    return("")
  }
  cells <- lapply(names(df), function(nm) {
    if (nm %in% raw) as.character(df[[nm]]) else zb_esc(df[[nm]])
  })
  names(cells) <- names(df)

  head_cells <- vapply(seq_along(labels), function(j) {
    paste0(
      '<th scope="col" class="zb-', align[[j]], '">', zb_esc(labels[[j]]), "</th>"
    )
  }, character(1))

  body_rows <- vapply(seq_len(nrow(df)), function(i) {
    tds <- vapply(seq_along(cells), function(j) {
      tag <- if (row_header && j == 1L) "th" else "td"
      scope <- if (row_header && j == 1L) ' scope="row"' else ""
      paste0(
        "<", tag, scope, ' class="zb-', align[[j]], '">',
        cells[[j]][[i]], "</", tag, ">"
      )
    }, character(1))
    paste0("<tr>", paste0(tds, collapse = ""), "</tr>")
  }, character(1))

  paste0(
    '<div class="zb-table-wrap" tabindex="0"',
    if (is.null(label)) "" else paste0(' role="region" aria-label="', zb_esc_attr(label), '"'),
    ">",
    '<table class="zb-table">',
    if (is.null(caption)) "" else paste0("<caption>", zb_esc(caption), "</caption>"),
    "<thead><tr>", paste0(head_cells, collapse = ""), "</tr></thead>",
    "<tbody>", paste0(body_rows, collapse = ""), "</tbody>",
    "</table></div>"
  )
}

#' A grid of headline figures. `note` is rendered under the value and is where
#' the mandatory download label lives on the Overview page.
zb_kpis <- function(items) {
  cards <- vapply(items, function(it) {
    paste0(
      '<div class="zb-kpi">',
      '<p class="zb-kpi-value">', zb_esc(it$value), "</p>",
      '<p class="zb-kpi-label">', zb_esc(it$label), "</p>",
      if (is.null(it$note)) "" else paste0('<p class="zb-kpi-note">', zb_md_inline(it$note), "</p>"),
      "</div>"
    )
  }, character(1))
  paste0('<div class="zb-kpi-grid">', paste0(cards, collapse = ""), "</div>")
}

#' One package status card (SPEC.md S7.1).
zb_pkg_card <- function(row) {
  fact <- function(label, value, extra = NULL) {
    paste0(
      '<div class="zb-fact"><dt>', zb_esc(label), "</dt>",
      "<dd>", value,
      if (is.null(extra)) "" else paste0('<span class="zb-fact-extra">', zb_esc(extra), "</span>"),
      "</dd></div>"
    )
  }
  flavours <- if (isTRUE(zb_get(row, "n_flavors", 0L) > 0L)) {
    tr_f("overview.card.flavors",
      not_ok = zb_get(row, "n_flavors_not_ok", 0L), n = zb_get(row, "n_flavors", 0L)
    )
  } else {
    tr("overview.card.flavors_none")
  }
  version <- zb_get(row, "version")
  release_date <- zb_get(row, "release_date")
  repo <- zb_get(row, "repo")
  release_tag <- zb_get(row, "last_release_tag")

  flags <- character()
  if (isTRUE(zb_get(row, "archived", FALSE))) flags <- c(flags, tr("overview.card.archived"))
  if (isFALSE(zb_get(row, "on_cran", TRUE))) flags <- c(flags, tr("overview.card.off_index"))

  paste0(
    '<article class="zb-card zb-card-', zb_status_key(zb_get(row, "worst_status")), '">',
    '<header class="zb-card-head">',
    '<h3 class="zb-card-title">', zb_esc(zb_get(row, "package")), "</h3>",
    zb_status(zb_get(row, "worst_status")),
    "</header>",
    if (length(flags)) {
      paste0('<p class="zb-card-flag">', paste0(zb_esc(flags), collapse = " · "), "</p>")
    } else {
      ""
    },
    '<p class="zb-card-sub">', zb_esc(flavours), "</p>",
    "<dl class=\"zb-facts\">",
    fact(
      tr("overview.card.version"),
      if (is.na(version)) tr("common.unknown") else zb_esc(version),
      if (is.na(release_date)) NULL else tr_f("overview.card.released_on", date = zb_date(release_date))
    ),
    fact(
      tr("downloads.last_30d"), zb_int(zb_get(row, "downloads_30d", 0L)),
      paste0(tr("downloads.trend"), ": ", zb_pct(zb_get(row, "downloads_trend_pct")))
    ),
    fact(tr("overview.card.issues"), zb_int(zb_get(row, "open_issues"))),
    fact(tr("overview.card.prs"), zb_int(zb_get(row, "open_prs"))),
    fact(tr("overview.card.stars"), zb_int(zb_get(row, "stars"))),
    fact(
      tr("overview.card.last_release"),
      if (is.na(release_tag)) zb_esc(tr("overview.card.no_release")) else zb_esc(release_tag),
      if (is.na(zb_get(row, "last_release_at"))) NULL else zb_datetime(zb_get(row, "last_release_at"))
    ),
    "</dl>",
    '<p class="zb-card-repo">',
    if (is.na(repo)) {
      zb_esc(tr("overview.card.no_repo"))
    } else {
      paste0(
        '<a href="https://github.com/', zb_esc_attr(repo), '">', zb_esc(repo), "</a>"
      )
    },
    "</p></article>"
  )
}

#' The mandatory download wording of SPEC.md S7.2, plus the one-click path to
#' the S10 limitation it refers to. Called beside every download figure and
#' beside every headline download figure.
#'
#' `downloads.label` is reproduced verbatim, lower case included: it is the
#' exact wording the spec mandates, and it is never to be paraphrased into
#' anything resembling "total downloads".
zb_downloads_note <- function(anchor = "lim-1") {
  paste0(
    '<p class="zb-note zb-note-sample">',
    '<span class="zb-note-mark" aria-hidden="true">ⓘ</span> ',
    "<strong>", zb_esc(tr("downloads.label")), "</strong>. ",
    '<a href="about.html#', zb_esc_attr(anchor), '">',
    zb_esc(tr("downloads.limitation_link")), "</a>.</p>"
  )
}

#' A short aside, e.g. a per-repository start-of-series notice.
zb_note <- function(text, class = "") {
  paste0(
    '<p class="zb-note ', class, '">',
    '<span class="zb-note-mark" aria-hidden="true">ⓘ</span> ',
    zb_md_inline(text), "</p>"
  )
}

#' The empty state. An empty section means "not collected yet", not "zero",
#' and saying so is part of the degraded-publication contract (RNF-3).
zb_no_data <- function(text = tr("common.no_data")) {
  paste0('<p class="zb-empty">', zb_md_inline(text), "</p>")
}

# -- figures ------------------------------------------------------------------

# Okabe-Ito: distinguishable under the common colour-vision deficiencies.
# Every chart pairs it with a second channel (line type, or a facet) so that
# colour is never the only carrier (RNF-10).
zb_palette <- c(
  "#0072B2", "#D55E00", "#009E73", "#CC79A7",
  "#E69F00", "#56B4E9", "#7A4E9E", "#333333"
)

zb_theme <- function(base_size = 12) {
  theme_minimal(base_size = base_size) +
    theme(
      text = element_text(colour = "#1f2328"),
      axis.text = element_text(colour = "#3f4650"),
      axis.title = element_text(colour = "#1f2328"),
      panel.grid.minor = element_blank(),
      panel.grid.major = element_line(colour = "#e3e6ea"),
      strip.text = element_text(colour = "#1f2328", face = "bold", hjust = 0),
      strip.background = element_rect(fill = "#f2f4f7", colour = NA),
      legend.position = "top",
      legend.title = element_blank(),
      legend.key.width = unit(1.6, "lines"),
      plot.margin = margin(4, 8, 4, 4)
    )
}

#' Render a ggplot and return it as a self-contained `<figure>`.
#'
#' The PNG is inlined as a data URI: no external asset to copy, nothing to
#' break when the site is served from a subdirectory, and the `alt` text is
#' written here rather than guessed by a chunk option.
zb_fig <- function(plot, alt, caption = NULL, width = 9.2, height = 5, dpi = 132) {
  file <- tempfile(fileext = ".png")
  on.exit(unlink(file), add = TRUE)
  device <- if (requireNamespace("ragg", quietly = TRUE)) ragg::agg_png else NULL
  args <- list(
    filename = file, plot = plot, width = width, height = height,
    dpi = dpi, units = "in", bg = "white"
  )
  if (!is.null(device)) args$device <- device
  suppressMessages(do.call(ggplot2::ggsave, args))
  paste0(
    '<figure class="zb-figure">',
    '<img src="', knitr::image_uri(file), '" alt="', zb_esc_attr(alt), '" ',
    'width="', round(width * dpi), '" height="', round(height * dpi), '" />',
    if (is.null(caption)) "" else paste0("<figcaption>", zb_md_inline(caption), "</figcaption>"),
    "</figure>"
  )
}

#' The dateline every chart must carry: the date of its most recent datum,
#' not the date of the build (SPEC.md S7.2).
zb_chart_dateline <- function(date) {
  if (is.null(date) || length(date) == 0L || is.na(date)) {
    tr("common.chart_undated")
  } else {
    tr_f("common.chart_dated", date = zb_date(date))
  }
}

#' Shared x axis for a daily series.
zb_scale_x_day <- function() {
  scale_x_date(labels = function(d) zb_date_short(d), expand = expansion(mult = c(0.01, 0.03)))
}

#' Height that grows with the number of facets, so a five-repository panel
#' does not squash into illegibility.
zb_facet_height <- function(n, per = 1.5, base = 1.5, max_height = 12) {
  min(base + per * max(n, 1L), max_height)
}

#' Human labels for the activity/traffic metrics, in catalogue order.
zb_metric_labels <- function(metrics) {
  vapply(metrics, function(m) tr(paste0("github.metric.", m)), character(1), USE.NAMES = FALSE)
}

zb_i18n_load()
