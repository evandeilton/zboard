# ---------------------------------------------------------------------------
# Alerts (SPEC.md S8).
#
# One channel: an issue in the monitoring repository itself, labelled
# `alert`. Two triggers and nothing else -- S8's anti-fatigue clause is a
# requirement, not a suggestion: "an alert that fires every week stops being
# read, and the day CRAN actually breaks, it goes unnoticed."
#
#   worst_status in {WARN, ERROR, FAIL}  -> high     -> auto-open, comment
#                                                       while it persists,
#                                                       auto-close on OK/NOTE
#   archived = TRUE                      -> critical -> auto-open, NEVER
#                                                       auto-close
#
# Deduplication is by a hidden HTML marker in the issue body, one per
# (kind, package). The plan is built by a pure function, `zb_alert_plan()`,
# and executed separately, so the decision logic is inspectable without a
# network call and a token-less run can print exactly what it would do.
# ---------------------------------------------------------------------------

#' Hidden HTML deduplication marker for an alert
#'
#' @param kind `"cran-check"` or `"archived"`.
#' @param package Package name.
#' @param prefix Marker namespace; the repository slug of SPEC.md S8.
#' @return A length-1 character vector, e.g.
#'   `"<!-- zboard:cran-check:gkwreg -->"`.
#' @keywords internal
#' @noRd
zb_alert_marker <- function(kind, package, prefix = "zboard") {
  paste0("<!-- ", prefix, ":", kind, ":", package, " -->")
}

#' Decide which alerts should be open, from the latest CRAN snapshot
#'
#' Pure: no network, no side effect. Returns the desired state, which
#' [run_alerts()] then reconciles against the repository's open issues.
#'
#' @param status Latest `cran_status` snapshot.
#' @param checks Latest `cran_checks` snapshot.
#' @param prefix Marker namespace.
#' @return A tibble with the columns `kind`, `package`, `marker`,
#'   `severity`, `status`, `n_flavors`, `title` and `body`; zero rows when
#'   nothing should be open.
#' @keywords internal
#' @noRd
zb_alert_plan <- function(status, checks, prefix = "zboard") {
  empty <- tibble::tibble(
    kind = character(), package = character(), marker = character(),
    severity = character(), status = character(), n_flavors = integer(),
    title = character(), body = character()
  )
  if (nrow(status) == 0L) {
    return(empty)
  }

  snapshot <- zb_iso(status$snapshot_date[1L])
  rows <- list()

  # -- trigger 1: worst check status in {WARN, ERROR, FAIL} ----------------
  bad <- status[
    !is.na(status$worst_status) & status$worst_status %in% c("WARN", "ERROR", "FAIL"), ,
    drop = FALSE
  ]
  for (i in seq_len(nrow(bad))) {
    pkg <- bad$package[i]
    st <- bad$worst_status[i]
    pkg_checks <- checks[checks$package == pkg, , drop = FALSE]
    # "{n} flavor(s)" is the count of flavours sitting at the worst status.
    n <- sum(!is.na(pkg_checks$status) & pkg_checks$status == st)
    detail <- if (nrow(pkg_checks)) {
      offending <- pkg_checks[
        !is.na(pkg_checks$status) & pkg_checks$status != "OK", ,
        drop = FALSE
      ]
      offending <- offending[order(offending$flavor), , drop = FALSE]
      paste0(
        "\n| flavor | status | version |\n|---|---|---|\n",
        paste0(
          "| `", offending$flavor, "` | **", offending$status, "** | ",
          offending$version, " |",
          collapse = "\n"
        ),
        "\n"
      )
    } else {
      "\n"
    }
    rows[[length(rows) + 1L]] <- tibble::tibble(
      kind = "cran-check",
      package = pkg,
      marker = zb_alert_marker("cran-check", pkg, prefix),
      severity = "high",
      status = st,
      n_flavors = as.integer(n),
      title = glue::glue("[CRAN] {pkg}: {st} em {n} flavor(s)"),
      body = paste0(
        zb_alert_marker("cran-check", pkg, prefix), "\n\n",
        glue::glue(
          "`{pkg}` is at **{st}** on {n} CRAN check flavor(s) ",
          "(snapshot {snapshot}, UTC)."
        ), "\n",
        detail,
        "\nSource: `tools::CRAN_check_results()`.\n",
        "\n---\n",
        "Opened, updated and closed automatically by `zboard::run_alerts()`. ",
        "It closes by itself as soon as the worst status returns to `OK` or `NOTE`.\n"
      )
    )
  }

  # -- trigger 2: archived (critical, never auto-closed) -------------------
  gone <- status[!is.na(status$archived) & status$archived, , drop = FALSE]
  for (i in seq_len(nrow(gone))) {
    pkg <- gone$package[i]
    rows[[length(rows) + 1L]] <- tibble::tibble(
      kind = "archived",
      package = pkg,
      marker = zb_alert_marker("archived", pkg, prefix),
      severity = "critical",
      status = "ARCHIVED",
      n_flavors = NA_integer_,
      title = glue::glue("[CRAN] {pkg}: archived"),
      body = paste0(
        zb_alert_marker("archived", pkg, prefix), "\n\n",
        glue::glue(
          "`{pkg}` is no longer in the CRAN active index and is present in ",
          "the archive (snapshot {snapshot}, UTC)."
        ), "\n",
        "\n---\n",
        "**Critical.** This issue is never closed automatically; close it by ",
        "hand once the situation is resolved.\n"
      )
    )
  }

  if (length(rows) == 0L) {
    return(empty)
  }
  out <- purrr::list_rbind(rows)
  out$title <- as.character(out$title)
  out
}

#' List the repository's open alert issues, keyed by marker
#'
#' The issues endpoint also returns pull requests; those are filtered out.
#'
#' @param repo `"owner/name"`.
#' @param token GitHub token.
#' @param label Issue label used by the alert channel.
#' @param prefix Marker namespace.
#' @return A tibble with the columns `number`, `title` and `marker` (`NA`
#'   for an alert-labelled issue with no recognisable marker).
#' @keywords internal
#' @noRd
zb_open_alert_issues <- function(repo, token, label = "alert",
                                 prefix = "zboard") {
  rn <- zb_split_repo(repo)
  issues <- zb_retry(
    function() {
      gh::gh(
        "GET /repos/{owner}/{repo}/issues",
        owner = rn$owner, repo = rn$name,
        state = "open", labels = label, per_page = 100L,
        .limit = 1000L, .token = token
      )
    },
    label = "GitHub issues"
  )
  issues <- Filter(function(x) is.null(x$pull_request), issues)
  if (length(issues) == 0L) {
    return(tibble::tibble(
      number = integer(), title = character(), marker = character()
    ))
  }
  bodies <- vapply(
    issues, function(x) as.character(x$body %||% "")[1L], character(1)
  )
  pattern <- paste0("<!--\\s*", prefix, ":[a-z-]+:[^ ]+\\s*-->")
  found <- stringr::str_extract(bodies, pattern)
  tibble::tibble(
    number = vapply(issues, function(x) as.integer(x$number), integer(1)),
    title = vapply(issues, function(x) as.character(x$title %||% "")[1L], character(1)),
    marker = stringr::str_squish(found)
  )
}

#' Make sure the alert label exists in the repository
#'
#' Creating an issue with a label that does not exist fails with 422, and
#' the label will not exist in a freshly created monitoring repository.
#' An "already exists" response is the expected outcome and is ignored.
#'
#' @param repo `"owner/name"`.
#' @param token GitHub token.
#' @param label Label name.
#' @return `NULL`, invisibly.
#' @keywords internal
#' @noRd
zb_ensure_label <- function(repo, token, label = "alert") {
  rn <- zb_split_repo(repo)
  try(
    suppressWarnings(gh::gh(
      "POST /repos/{owner}/{repo}/labels",
      owner = rn$owner, repo = rn$name,
      name = label, color = "d73a4a",
      description = "Automated monitoring alert (zboard)",
      .token = token
    )),
    silent = TRUE
  )
  invisible(NULL)
}

#' Open, update and close CRAN alert issues
#'
#' @description
#' Reconciles the repository's open `alert` issues against the latest CRAN
#' snapshot in `data_dir`, following SPEC.md S8 exactly:
#'
#' * `worst_status` in `WARN`/`ERROR`/`FAIL` opens
#'   `[CRAN] {pkg}: {status} em {n} flavor(s)`, high severity. While the
#'   condition persists the issue is updated by a comment, never reopened
#'   and never duplicated. It is closed automatically as soon as the worst
#'   status returns to `OK` or `NOTE`.
#' * `archived = TRUE` opens a critical issue that is **never** closed
#'   automatically; it waits for a human.
#'
#' Deduplication is by a hidden HTML marker in the issue body, one per
#' `(kind, package)` -- `<!-- zboard:cran-check:{pkg} -->` or
#' `<!-- zboard:archived:{pkg} -->`. Open issues are listed and
#' matched on that marker before anything is created, so a second issue is
#' never opened for a condition that is already tracked.
#'
#' @details
#' **Dry run.** When `token` is `""` -- no PAT in the environment, a fork,
#' a local run -- nothing is sent to the API. The plan is printed and the
#' function returns invisibly without error, so a workflow without
#' `issues: write` does not fail (SPEC.md S11 restricts that permission to
#' the `alert` job).
#'
#' The token is never printed and never written anywhere.
#'
#' @param repo Target repository as `"owner/name"`. Defaults to the
#'   `GITHUB_REPOSITORY` environment variable that GitHub Actions sets.
#' @param token GitHub token with `issues: write`. Defaults to
#'   `GITHUB_TOKEN`. `""` triggers the dry run described above.
#' @param data_dir Directory holding the canonical Parquet store.
#' @param label Issue label used by the alert channel.
#' @param marker_prefix Namespace of the hidden deduplication marker.
#'
#' @return Invisibly, a tibble with one row per action and the columns
#'   `kind`, `package`, `action` (`"created"`, `"commented"`, `"closed"` or
#'   `"dry-run"`), `issue` (issue number, `NA` for a dry run) and `title`.
#'
#' @seealso [consolidate()]
#' @export
#' @examples
#' \dontrun{
#' # In the `alert` job of the workflow.
#' run_alerts(
#'   repo = Sys.getenv("GITHUB_REPOSITORY"),
#'   token = Sys.getenv("GITHUB_TOKEN")
#' )
#' }
#'
#' # Without a token: prints the plan, touches no API.
#' run_alerts(repo = "evandeilton/zboard", token = "", data_dir = tempfile())
run_alerts <- function(repo = Sys.getenv("GITHUB_REPOSITORY"),
                       token = Sys.getenv("GITHUB_TOKEN"),
                       data_dir = "data",
                       label = "alert",
                       marker_prefix = "zboard") {
  repo <- as.character(repo)[1L]
  token <- as.character(token)[1L]
  if (is.na(token)) token <- ""

  status <- zb_latest_snapshot(zb_read_table(data_dir, "cran_status"))
  checks <- zb_latest_snapshot(zb_read_table(data_dir, "cran_checks"))
  plan <- zb_alert_plan(status, checks, marker_prefix)

  cli::cli_h1("run_alerts()")
  no_action <- tibble::tibble(
    kind = character(), package = character(), action = character(),
    issue = integer(), title = character()
  )

  if (!nzchar(token)) {
    cli::cli_alert_warning(
      "No token supplied: dry run. Nothing is sent to the GitHub API."
    )
    if (nrow(plan) == 0L) {
      cli::cli_alert_success("No alert condition in the latest snapshot; no issue would be opened.")
      return(invisible(no_action))
    }
    for (i in seq_len(nrow(plan))) {
      cli::cli_alert_info(
        "Would ensure open ({plan$severity[i]}): {.strong {plan$title[i]}} [{plan$marker[i]}]"
      )
    }
    cli::cli_alert_info(
      "Would close any open {.val cran-check} alert whose package is not listed above."
    )
    return(invisible(tibble::tibble(
      kind = plan$kind, package = plan$package, action = "dry-run",
      issue = NA_integer_, title = plan$title
    )))
  }

  if (!nzchar(repo) || !grepl("^[^/]+/[^/]+$", repo)) {
    cli::cli_abort("{.arg repo} must be {.code owner/name}; got {.val {repo}}.")
  }
  rn <- zb_split_repo(repo)
  open <- zb_open_alert_issues(repo, token, label, marker_prefix)
  actions <- list()

  if (nrow(plan) > 0L) {
    zb_ensure_label(repo, token, label)
  }

  # -- open or update ------------------------------------------------------
  for (i in seq_len(nrow(plan))) {
    marker <- plan$marker[i]
    hit <- open$number[!is.na(open$marker) & open$marker == marker]
    if (length(hit)) {
      number <- hit[1L]
      zb_retry(
        function() {
          gh::gh(
            "POST /repos/{owner}/{repo}/issues/{number}/comments",
            owner = rn$owner, repo = rn$name, number = number,
            body = paste0(
              "Still present as of the latest snapshot.\n\n", plan$body[i]
            ),
            .token = token
          )
        },
        label = "GitHub comment"
      )
      cli::cli_alert_info("Commented on #{number}: {plan$title[i]}")
      actions[[length(actions) + 1L]] <- tibble::tibble(
        kind = plan$kind[i], package = plan$package[i], action = "commented",
        issue = as.integer(number), title = plan$title[i]
      )
    } else {
      created <- zb_retry(
        function() {
          gh::gh(
            "POST /repos/{owner}/{repo}/issues",
            owner = rn$owner, repo = rn$name,
            title = plan$title[i], body = plan$body[i],
            labels = list(label),
            .token = token
          )
        },
        label = "GitHub issue"
      )
      number <- as.integer(created$number)
      cli::cli_alert_warning("Opened #{number}: {plan$title[i]}")
      actions[[length(actions) + 1L]] <- tibble::tibble(
        kind = plan$kind[i], package = plan$package[i], action = "created",
        issue = number, title = plan$title[i]
      )
    }
  }

  # -- close resolved check alerts ----------------------------------------
  # Only `cran-check` markers are eligible. An `archived` alert stays open
  # until a human closes it (SPEC.md S8, critical severity).
  check_prefix <- paste0("<!-- ", marker_prefix, ":cran-check:")
  stale <- open[
    !is.na(open$marker) &
      startsWith(open$marker, check_prefix) &
      !open$marker %in% plan$marker[plan$kind == "cran-check"], ,
    drop = FALSE
  ]
  for (i in seq_len(nrow(stale))) {
    number <- stale$number[i]
    pkg <- sub("^.*:cran-check:(.*) -->$", "\\1", stale$marker[i])
    zb_retry(
      function() {
        gh::gh(
          "POST /repos/{owner}/{repo}/issues/{number}/comments",
          owner = rn$owner, repo = rn$name, number = number,
          body = paste0(
            "Resolved: the worst CRAN check status is back to `OK`/`NOTE`. ",
            "Closing automatically."
          ),
          .token = token
        )
      },
      label = "GitHub comment"
    )
    zb_retry(
      function() {
        gh::gh(
          "PATCH /repos/{owner}/{repo}/issues/{number}",
          owner = rn$owner, repo = rn$name, number = number,
          state = "closed", .token = token
        )
      },
      label = "GitHub close"
    )
    cli::cli_alert_success("Closed #{number}: {stale$title[i]}")
    actions[[length(actions) + 1L]] <- tibble::tibble(
      kind = "cran-check", package = pkg, action = "closed",
      issue = as.integer(number), title = stale$title[i]
    )
  }

  out <- if (length(actions)) purrr::list_rbind(actions) else no_action
  if (nrow(out) == 0L) {
    cli::cli_alert_success("Nothing to do: no alert condition, no stale alert.")
  }
  invisible(out)
}
