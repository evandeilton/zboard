# ---------------------------------------------------------------------------
# GitHub collector (SPEC.md S5, rows 5 and 6 of the source table).
#
# Writes four staging tables:
#   staging/gh_activity.parquet      <- GraphQL v4 (retroactive)
#   staging/gh_repo_snapshot.parquet <- GraphQL v4 (snapshot)
#   staging/gh_releases.parquet      <- GraphQL v4 (retroactive)
#   staging/gh_traffic.parquet       <- REST /traffic/{views,clones}
#                                       NOT retroactive: 14 days, then gone
#
# Authentication is delegated to the `gh` package, which reads GITHUB_TOKEN /
# GITHUB_PAT from the environment. No token is ever passed through an
# argument here, and none is ever printed (SPEC.md S11).
#
# Design note on `gh_activity.commits`
# ------------------------------------
# SPEC.md S5 names `contributionsCollection` as the GraphQL area for GitHub
# activity, but that connection is scoped to a *user* and gives no clean
# per-repository daily granularity. The column it has to fill is documented
# in S4.2 as "commits no branch default", which is exactly
# `defaultBranchRef.target.history`. We page that connection's `nodes` and
# group `committedDate` by UTC day in R, rather than asking for `totalCount`
# once per day, because a single paged query serves both the incremental run
# and a twelve-month backfill with the same code path and a bounded number
# of requests.
# ---------------------------------------------------------------------------

#' Run a GraphQL query against the GitHub v4 API
#'
#' Wraps `gh::gh_gql()` with the pipeline retry policy (RNF-7) and turns a
#' GraphQL-level `errors` payload -- which arrives with HTTP 200 and would
#' otherwise be silently treated as an empty result -- into an R error.
#'
#' `gh::gh_gql()` requires variables to be passed inside a `variables` list;
#' a `NULL` element in that list is serialised in a way the API rejects, so
#' `NULL`s are dropped (an omitted nullable variable is what "first page"
#' means).
#'
#' @param query GraphQL query string.
#' @param variables Named list of query variables.
#' @return The `data` element of the response.
#' @keywords internal
#' @noRd
zb_gql <- function(query, variables = list()) {
  variables <- variables[!vapply(variables, is.null, logical(1))]
  res <- zb_retry(
    function() gh::gh_gql(query, variables = variables),
    label = "GitHub GraphQL"
  )
  if (!is.null(res$errors) && length(res$errors)) {
    msgs <- vapply(
      res$errors, function(e) as.character(e$message %||% "unknown")[1L], character(1)
    )
    cli::cli_abort("GitHub GraphQL error: {paste(msgs, collapse = '; ')}")
  }
  res$data
}

#' Count occurrences per UTC date over a fixed window
#'
#' @param x Character vector of ISO-8601 timestamps (`NULL` entries allowed).
#' @param dates `Date` vector spanning the window.
#' @return Integer vector aligned with `dates`.
#' @keywords internal
#' @noRd
zb_count_by_day <- function(x, dates) {
  d <- zb_as_date(x)
  d <- d[!is.na(d)]
  as.integer(tabulate(match(d, dates), nbins = length(dates)))
}

#' Page a GitHub GraphQL connection until a cutoff is passed
#'
#' Both the pull-request and the issue connections are ordered by
#' `UPDATED_AT DESC`. Any item created, closed or merged inside the window
#' necessarily has `updatedAt` at or after the window start, so paging can
#' stop as soon as a whole page falls before it.
#'
#' @param owner,name Repository coordinates.
#' @param connection `"pullRequests"` or `"issues"`.
#' @param fields Extra node fields to request.
#' @param since `Date` cutoff.
#' @param page_size Nodes per request.
#' @param max_pages Hard cap on requests per repository.
#' @return A list of node lists.
#' @keywords internal
#' @noRd
zb_gql_page <- function(owner, name, connection, fields, since,
                        page_size = 100L, max_pages = 30L) {
  query <- glue::glue(
    "query($owner:String!, $name:String!, $cursor:String) {{
       repository(owner:$owner, name:$name) {{
         {connection}(first:{page_size}, orderBy:{{field:UPDATED_AT, direction:DESC}}, after:$cursor) {{
           pageInfo {{ hasNextPage endCursor }}
           nodes {{ updatedAt {fields} }}
         }}
       }}
     }}"
  )
  nodes <- list()
  cursor <- NULL
  for (i in seq_len(max_pages)) {
    data <- zb_gql(
      as.character(query),
      list(owner = owner, name = name, cursor = cursor)
    )
    conn <- data$repository[[connection]]
    page <- conn$nodes %||% list()
    nodes <- c(nodes, page)
    if (length(page) == 0L) break
    oldest <- suppressWarnings(min(
      zb_as_date(vapply(page, function(n) n$updatedAt %||% NA_character_, character(1))),
      na.rm = TRUE
    ))
    if (!is.na(oldest) && oldest < since) break
    if (!isTRUE(conn$pageInfo$hasNextPage)) break
    cursor <- conn$pageInfo$endCursor
  }
  nodes
}

#' Page the default branch's commit history over a window
#'
#' @param owner,name Repository coordinates.
#' @param from,to `Date` bounds, inclusive.
#' @param page_size Commits per request.
#' @param max_pages Hard cap on requests per repository.
#' @return Character vector of `committedDate` timestamps.
#' @keywords internal
#' @noRd
zb_gql_commits <- function(owner, name, from, to, page_size = 100L,
                           max_pages = 50L) {
  query <- glue::glue(
    "query($owner:String!, $name:String!, $since:GitTimestamp!, $until:GitTimestamp!, $cursor:String) {{
       repository(owner:$owner, name:$name) {{
         defaultBranchRef {{
           target {{
             ... on Commit {{
               history(since:$since, until:$until, first:{page_size}, after:$cursor) {{
                 totalCount
                 pageInfo {{ hasNextPage endCursor }}
                 nodes {{ committedDate }}
               }}
             }}
           }}
         }}
       }}
     }}"
  )
  out <- character()
  cursor <- NULL
  for (i in seq_len(max_pages)) {
    data <- zb_gql(as.character(query), list(
      owner = owner, name = name,
      since = paste0(format(from), "T00:00:00Z"),
      until = paste0(format(to + 1L), "T00:00:00Z"),
      cursor = cursor
    ))
    hist <- data$repository$defaultBranchRef$target$history
    if (is.null(hist)) break
    nodes <- hist$nodes %||% list()
    out <- c(out, vapply(
      nodes, function(n) as.character(n$committedDate %||% NA_character_)[1L], character(1)
    ))
    if (!isTRUE(hist$pageInfo$hasNextPage)) break
    cursor <- hist$pageInfo$endCursor
  }
  out
}

#' Build the daily `gh_activity` series for one repository
#'
#' Emits one row per day in the window even when nothing happened, so the
#' series is gap-free for charting and for the monthly `sum()` rollup.
#'
#' `prs_merged` and `prs_closed` are disjoint: GitHub sets `closedAt` on a
#' merged pull request too, so counting both would double-count every merge.
#' A merged PR is counted in `prs_merged` on its merge date; a PR closed
#' without merging is counted in `prs_closed` on its close date.
#'
#' @param repo `"owner/name"`.
#' @param from,to `Date` bounds, inclusive.
#' @return A `gh_activity` tibble.
#' @keywords internal
#' @noRd
zb_build_gh_activity_one <- function(repo, from, to) {
  rn <- zb_split_repo(repo)
  dates <- seq(from, to, by = "day")

  commits <- zb_gql_commits(rn$owner, rn$name, from, to)

  prs <- zb_gql_page(
    rn$owner, rn$name, "pullRequests", "createdAt closedAt mergedAt state", from
  )
  pull <- function(nodes, field) {
    vapply(nodes, function(n) as.character(n[[field]] %||% NA_character_)[1L], character(1))
  }
  pr_state <- if (length(prs)) pull(prs, "state") else character()
  pr_created <- if (length(prs)) pull(prs, "createdAt") else character()
  pr_merged <- if (length(prs)) pull(prs, "mergedAt") else character()
  pr_closed <- if (length(prs)) pull(prs, "closedAt") else character()
  pr_closed_unmerged <- pr_closed[is.na(pr_merged) & pr_state != "MERGED"]

  iss <- zb_gql_page(rn$owner, rn$name, "issues", "createdAt closedAt state", from)
  iss_created <- if (length(iss)) pull(iss, "createdAt") else character()
  iss_closed <- if (length(iss)) pull(iss, "closedAt") else character()

  zb_coerce(
    tibble::tibble(
      date = dates,
      repo = repo,
      commits = zb_count_by_day(commits, dates),
      prs_opened = zb_count_by_day(pr_created, dates),
      prs_merged = zb_count_by_day(pr_merged, dates),
      prs_closed = zb_count_by_day(pr_closed_unmerged, dates),
      issues_opened = zb_count_by_day(iss_created, dates),
      issues_closed = zb_count_by_day(iss_closed, dates)
    ),
    zb_schema("gh_activity")$cols
  )
}

#' Build `gh_repo_snapshot` and `gh_releases` for one repository
#'
#' Both come out of one GraphQL request, so they are collected together and
#' then split by the caller.
#'
#' @param repo `"owner/name"`.
#' @param snapshot_date Snapshot date for the snapshot row.
#' @param max_release_pages Hard cap on release pages per repository.
#' @return A list with elements `snapshot` and `releases`.
#' @keywords internal
#' @noRd
zb_build_gh_repo_one <- function(repo, snapshot_date, max_release_pages = 10L) {
  rn <- zb_split_repo(repo)
  query <- "query($owner:String!, $name:String!, $cursor:String) {
     repository(owner:$owner, name:$name) {
       nameWithOwner stargazerCount forkCount isArchived pushedAt
       watchers { totalCount }
       issues(states:OPEN) { totalCount }
       pullRequests(states:OPEN) { totalCount }
       oldestIssue: issues(states:OPEN, first:1, orderBy:{field:CREATED_AT, direction:ASC}) {
         nodes { createdAt }
       }
       releases(first:100, orderBy:{field:CREATED_AT, direction:DESC}, after:$cursor) {
         pageInfo { hasNextPage endCursor }
         nodes { tagName name publishedAt isPrerelease isDraft }
       }
     }
   }"

  releases <- list()
  cursor <- NULL
  repo_node <- NULL
  for (i in seq_len(max_release_pages)) {
    data <- zb_gql(query, list(owner = rn$owner, name = rn$name, cursor = cursor))
    repo_node <- repo_node %||% data$repository
    conn <- data$repository$releases
    releases <- c(releases, conn$nodes %||% list())
    if (!isTRUE(conn$pageInfo$hasNextPage)) break
    cursor <- conn$pageInfo$endCursor
  }

  oldest <- repo_node$oldestIssue$nodes
  oldest_days <- if (length(oldest)) {
    as.integer(zb_as_date(snapshot_date)[1L] - zb_as_date(oldest[[1L]]$createdAt))
  } else {
    NA_integer_
  }

  snapshot <- zb_coerce(
    tibble::tibble(
      snapshot_date = zb_as_date(snapshot_date)[1L],
      repo = as.character(repo_node$nameWithOwner %||% repo),
      stars = repo_node$stargazerCount %||% NA_integer_,
      forks = repo_node$forkCount %||% NA_integer_,
      watchers = repo_node$watchers$totalCount %||% NA_integer_,
      open_issues = repo_node$issues$totalCount %||% NA_integer_,
      open_prs = repo_node$pullRequests$totalCount %||% NA_integer_,
      oldest_open_issue_days = oldest_days,
      last_push_at = zb_as_ts(repo_node$pushedAt %||% NA_character_),
      archived = isTRUE(repo_node$isArchived)
    ),
    zb_schema("gh_repo_snapshot")$cols
  )

  published <- Filter(function(n) !isTRUE(n$isDraft), releases)
  rel <- if (length(published)) {
    tibble::tibble(
      repo = repo,
      tag = vapply(published, function(n) as.character(n$tagName %||% NA_character_)[1L], character(1)),
      name = vapply(published, function(n) as.character(n$name %||% NA_character_)[1L], character(1)),
      published_at = zb_as_ts(vapply(
        published, function(n) as.character(n$publishedAt %||% NA_character_)[1L], character(1)
      )),
      is_prerelease = vapply(published, function(n) isTRUE(n$isPrerelease), logical(1))
    )
  } else {
    NULL
  }

  list(
    snapshot = snapshot,
    releases = zb_coerce(rel, zb_schema("gh_releases")$cols)
  )
}

#' Fetch the 14-day traffic window for one repository
#'
#' @param repo `"owner/name"`.
#' @return A `gh_traffic` tibble.
#' @keywords internal
#' @noRd
zb_build_gh_traffic_one <- function(repo) {
  rn <- zb_split_repo(repo)
  grab <- function(endpoint, key) {
    res <- zb_retry(
      function() {
        gh::gh(
          paste0("GET /repos/{owner}/{repo}/traffic/", endpoint),
          owner = rn$owner, repo = rn$name
        )
      },
      label = paste0("GitHub traffic/", endpoint)
    )
    items <- res[[key]] %||% list()
    if (length(items) == 0L) {
      return(tibble::tibble(date = as.Date(character()), count = integer(), uniques = integer()))
    }
    tibble::tibble(
      date = zb_as_date(vapply(
        items, function(x) as.character(x$timestamp %||% NA_character_)[1L], character(1)
      )),
      count = vapply(items, function(x) as.integer(x$count %||% NA_integer_), integer(1)),
      uniques = vapply(items, function(x) as.integer(x$uniques %||% NA_integer_), integer(1))
    )
  }
  views <- grab("views", "views")
  clones <- grab("clones", "clones")

  df <- dplyr::full_join(
    dplyr::rename(views, views = "count", view_uniques = "uniques"),
    dplyr::rename(clones, clones = "count", clone_uniques = "uniques"),
    by = "date"
  )
  # The two endpoints can report different sets of days; a day present on
  # one side only means zero on the other, not unknown. Leaving NA there
  # would poison the `max()` merge and the monthly sum.
  df <- tidyr::replace_na(
    df,
    list(views = 0L, view_uniques = 0L, clones = 0L, clone_uniques = 0L)
  )
  df$repo <- rep(repo, length.out = nrow(df))
  zb_coerce(df, zb_schema("gh_traffic")$cols)
}

#' Map over repositories, tolerating per-repository failure
#'
#' @param repos Character vector of `"owner/name"`.
#' @param fn Function of one repository.
#' @param label Label used in the failure message.
#' @param combine Row-bind the per-repository results into one tibble. Set
#'   `FALSE` when `fn` returns something other than a data frame.
#' @return A `zb_result()` whose status is `"partial"` when any repository
#'   failed and `"failed"` when every one of them did.
#' @keywords internal
#' @noRd
zb_map_repos <- function(repos, fn, label, combine = TRUE) {
  out <- list()
  failed <- character()
  for (r in repos) {
    res <- tryCatch(fn(r), error = function(e) e)
    if (inherits(res, "error")) {
      failed <- c(failed, paste0(r, ": ", zb_sanitize(conditionMessage(res), 120L)))
      cli::cli_alert_warning("{label} failed for {.val {r}}.")
    } else {
      out[[r]] <- res
    }
  }
  df <- if (isTRUE(combine)) purrr::list_rbind(out) else out
  status <- if (length(failed) == 0L) {
    "ok"
  } else if (length(failed) == length(repos) && length(repos) > 0L) {
    "failed"
  } else {
    "partial"
  }
  msg <- if (length(failed)) paste(failed, collapse = "; ") else NA_character_
  zb_result(df, status, msg)
}

#' Collect GitHub activity, repository state, releases and traffic
#'
#' @description
#' Collects the four GitHub-side tables of SPEC.md S4.2 for the
#' repositories curated in `config/repos.yml`, writing each as a Parquet
#' file in `staging_dir` for [consolidate()]:
#'
#' * `gh_activity` -- daily commits on the default branch, pull requests
#'   opened/merged/closed and issues opened/closed, from GraphQL v4.
#' * `gh_repo_snapshot` -- stars, forks, watchers, open issues and pull
#'   requests, age of the oldest open issue, last push, archived flag.
#' * `gh_releases` -- every published (non-draft) release.
#' * `gh_traffic` -- daily views and clones with their unique counts.
#'
#' Repositories are collected independently of each other and the four
#' tables independently of each other, so one 404 or one missing scope
#' degrades a single cell of the dashboard rather than the run (RNF-3).
#'
#' @details
#' **Authentication.** Delegated to the `gh` package, which picks up
#' `GITHUB_TOKEN` (or `GITHUB_PAT`) from the environment; no token is
#' accepted as an argument and none is ever logged. Traffic additionally
#' requires the `Administration: read` scope of the fine-grained PAT
#' (SPEC.md S11); without it the traffic table alone is recorded as failed.
#'
#' **Traffic is not retroactive.** The GitHub API keeps 14 days and nothing
#' more, which is why the monthly rollup in [consolidate()] is the only
#' long-term copy (SPEC.md S4.3). Passing `from`/`to` therefore has no
#' effect on `gh_traffic`: the window is ignored for that table with a
#' message, and the collector continues rather than failing (SPEC.md S6,
#' "Backfill ... Não aplicável a `gh_traffic`").
#'
#' `gh_repo_snapshot` and `gh_releases` are likewise snapshots, so
#' `from`/`to` apply only to `gh_activity`.
#'
#' Only aggregates per repository are collected. No contributor profile,
#' issue author or e-mail address is ever read or stored (NG-5).
#'
#' @param from Start of the activity window as an ISO-8601 date string or a
#'   `Date`. `NULL` (the default) means normal incremental mode: a rolling
#'   30-day window ending today.
#' @param to End of the activity window, same forms as `from`. `NULL`
#'   defaults to today; the current UTC day is partial and is corrected by
#'   the next run under last-write-wins.
#' @param config_path Path to the curated source configuration
#'   (SPEC.md S5).
#' @param staging_dir Directory the staging Parquet files are written to.
#'   Created when missing.
#' @param run_ts Timestamp shared by every manifest row of this run.
#'
#' @return Invisibly, a tibble with the `run_manifest` schema: one row per
#'   source attempted. The same rows are written to
#'   `staging_dir/run_manifest_github.parquet`.
#'
#' @seealso [collect_cran()], [collect_academic()], [consolidate()]
#' @export
#' @examples
#' \dontrun{
#' Sys.setenv(GITHUB_TOKEN = "ghp_...")
#' collect_github()
#'
#' # Backfill the activity series; gh_traffic is untouched by the window.
#' collect_github(from = "2025-09-01", to = "2026-08-31")
#' }
collect_github <- function(from = NULL, to = NULL,
                           config_path = "config/repos.yml",
                           staging_dir = "staging",
                           run_ts = Sys.time()) {
  cfg <- read_repos_config(config_path)
  repos <- cfg$github_repos$repo
  win <- zb_window(from, to, default_days = 30L, end_offset = 0L)
  snapshot_date <- Sys.Date()

  cli::cli_h1("collect_github()")
  cli::cli_alert_info(
    "{length(repos)} repositor{?y/ies}; activity window {win$from} .. {win$to}."
  )
  if (!nzchar(Sys.getenv("GITHUB_TOKEN")) && !nzchar(Sys.getenv("GITHUB_PAT"))) {
    cli::cli_alert_warning(
      "No {.envvar GITHUB_TOKEN}/{.envvar GITHUB_PAT} found; unauthenticated requests will be rate limited."
    )
  }
  if (zb_is_backfill(from, to)) {
    cli::cli_alert_info(
      "Backfill window applies to {.field gh_activity} only. {.field gh_traffic} is not retroactive (GitHub keeps 14 days); the window is ignored for it."
    )
  }

  repo_parts <- NULL
  manifest <- dplyr::bind_rows(
    zb_run_source(
      "gh_activity",
      function() {
        zb_map_repos(
          repos,
          function(r) zb_build_gh_activity_one(r, win$from, win$to),
          "gh_activity"
        )
      },
      staging_dir, run_ts
    ),
    zb_run_source(
      "gh_repo_snapshot",
      function() {
        repo_parts <<- zb_map_repos(
          repos,
          function(r) zb_build_gh_repo_one(r, snapshot_date),
          "gh_repo_snapshot",
          combine = FALSE
        )
        zb_result(
          purrr::list_rbind(purrr::map(repo_parts$data, "snapshot")),
          repo_parts$status, repo_parts$message
        )
      },
      staging_dir, run_ts
    )
  )

  manifest <- dplyr::bind_rows(
    manifest,
    zb_run_source(
      "gh_releases",
      function() {
        if (is.null(repo_parts)) {
          cli::cli_abort("The repository snapshot query did not run; releases come from the same request.")
        }
        zb_result(
          purrr::list_rbind(purrr::map(repo_parts$data, "releases")),
          repo_parts$status, repo_parts$message
        )
      },
      staging_dir, run_ts
    ),
    zb_run_source(
      "gh_traffic",
      function() zb_map_repos(repos, zb_build_gh_traffic_one, "gh_traffic"),
      staging_dir, run_ts
    )
  )

  zb_write_staging_manifest(manifest, staging_dir, "github")
  invisible(manifest)
}
