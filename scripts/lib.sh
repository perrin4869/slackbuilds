#!/bin/bash
# Shared helpers, sourced directly by workflow run: steps (there are no
# detect.sh/generate.sh/submit.sh scripts - everything here is a function).
#
# Conventions used throughout this pipeline:
#  - "upstream" always means SlackBuildsOrg/slackbuilds@master, fetched fresh.
#    Nothing in this repo (per-package dirs under sbo/) is ever treated as a
#    base to diff or build against - see the plan's "Hard constraint".
#  - Package configs live in packages/<prgnam>.conf and are sourced, not parsed.

set -euo pipefail

UPSTREAM_OWNER="SlackBuildsOrg"
UPSTREAM_REPO="slackbuilds"
UPSTREAM_REF="master"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKAGES_DIR="$REPO_ROOT/packages"

log() { printf '%s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }

# --- package config -----------------------------------------------------

# Source a packages/<prgnam>.conf file into the current shell, after
# resetting the fields it's allowed to set. Keeps one package's leftover
# vars from bleeding into the next when looping over all configs.
load_package_conf() {
    local conf="$1"
    CATEGORY= PRGNAM= SOURCE= TAG_REGEX= POLL=0 NVCHECKER_URL= NVCHECKER_REGEX= \
        STRATEGY= SRC_URL= ARCHIVE= PRGDIR= FROZEN=0 FROZEN_REASON= \
        IMAGE_VARIANT=
    # shellcheck disable=SC1090
    source "$conf"
    [ -n "$PRGNAM" ] || die "$conf: PRGNAM not set"
    [ -n "$CATEGORY" ] || die "$conf: CATEGORY not set"
    [ -n "$SOURCE" ] || die "$conf: SOURCE not set"
    # Most packages are a single source tarball with no special vendoring -
    # STRATEGY is only worth naming explicitly for the rust/rust64 case.
    STRATEGY="${STRATEGY:-tarball}"
    # IMAGE_VARIANT names a derived image (ghcr.io/perrin4869/slackbuilds-
    # <variant>:15.0) with an expensive toolchain dependency pre-baked in,
    # for check.yml to build against instead of the base image - empty
    # means the base image is enough. See check.yml for how this is used.
}

# Strip a known host prefix off a github.com/codeberg.org SOURCE URL,
# leaving "owner/repo". A no-op (returns $1 unchanged) for anything else -
# safe to call unconditionally, since the result is only ever compared
# against a github/codeberg "owner/repo" string, never used standalone.
repo_path_from_url() {
    local url="$1"
    url="${url#https://github.com/}"
    url="${url#https://codeberg.org/}"
    printf '%s' "${url%/}"
}

# Print the PRGNAM whose packages/*.conf's SOURCE (a github.com/codeberg.org
# URL) resolves to $1 (an "owner/repo" string), or nothing if none matches.
# Lets a repository_dispatch payload that names the upstream project which
# changed scope detection to that one package, instead of re-checking every
# package on every webhook firing.
find_package_by_repo() {
    local repo="$1" conf
    for conf in packages/*.conf; do
        [ -e "$conf" ] || continue
        load_package_conf "$conf"
        if [ "$(repo_path_from_url "$SOURCE")" = "$repo" ]; then
            echo "$PRGNAM"
            return
        fi
    done
}

# %VERSION% substitution used in SRC_URL / ARCHIVE / PRGDIR templates.
subst_version() {
    local template="$1" version="$2"
    printf '%s' "${template//%VERSION%/$version}"
}

# --- .info parsing --------------------------------------------------

# Read a single-line KEY="value" field out of an .info file. Only matches
# lines that open AND close their quote on the same line, so it correctly
# ignores the interior lines of a multi-line DOWNLOAD/MD5SUM block (those
# lines end in a trailing backslash, not a quote) without picking up a
# partial value.
info_get() {
    local file="$1" key="$2"
    sed -n "s/^${key}=\"\\(.*\\)\"\$/\\1/p" "$file" | head -1
}

# --- version comparison --------------------------------------------------

# True if $1 > $2 as Slackware/SBo-style dotted versions.
version_gt() {
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]
}

# --- upstream fetch -------------------------------------------------

# Print the raw contents of a file from SlackBuildsOrg/slackbuilds@master.
# Empty output if the file doesn't exist - callers treat that as "package
# not in upstream yet".
fetch_upstream_file() {
    local path="$1"
    gh api "repos/${UPSTREAM_OWNER}/${UPSTREAM_REPO}/contents/${path}?ref=${UPSTREAM_REF}" \
        -H 'Accept: application/vnd.github.raw' 2>/dev/null || true
}

# Print VERSION as currently shipped in SlackBuildsOrg/slackbuilds for a
# given category/prgnam, or nothing if the package isn't there.
upstream_version() {
    local category="$1" prgnam="$2" tmp
    tmp="$(mktemp)"
    fetch_upstream_file "${category}/${prgnam}/${prgnam}.info" > "$tmp"
    [ -s "$tmp" ] && info_get "$tmp" VERSION
    rm -f "$tmp"
}

# --- GitHub-hosted version resolution --------------------------------

# Print every tag and release tag_name for a GitHub repo, deduped, one per
# line. Both are queried because some projects (e.g. pinentry-dmenu) never
# cut a formal Release, only tags.
github_candidate_tags() {
    local repo="$1"
    {
        gh api "repos/${repo}/tags" --paginate --jq '.[].name' 2>/dev/null || true
        gh api "repos/${repo}/releases" --paginate --jq '.[].tag_name' 2>/dev/null || true
    } | sort -u
}

# Resolve the highest version for a GitHub-sourced package whose tag names
# match TAG_REGEX (a POSIX ERE anchored with ^...$, capture group 1 = the
# version). Prints nothing if no tag matches.
#
# TAG_REGEX exists because, measured against the repos this pipeline
# actually tracks, "latest release" and "newest tag" are both unreliable:
# scala3's releases/latest is an LTS backport older than what's shipped,
# and newest-by-date tags include things like i3-gaps' "tree-pr4" or yq's
# "vTestB". A per-package anchored regex is the only reliable filter.
resolve_github_version() {
    local repo="$1" regex="$2"
    github_candidate_tags "$repo" \
        | grep -E "$regex" \
        | sed -E "s/$regex/\\1/" \
        | sort -V | tail -1
}

# --- Codeberg-hosted version resolution -------------------------------

# Codeberg's API (Gitea) is shaped like GitHub's: same tags/releases split,
# same reason for querying both (a project may only ever cut tags). Not
# paginated beyond one page of 50 - every package this pipeline tracks on
# Codeberg is small enough that its full tag history fits in one page; if
# that stops being true, page through the same way resolve_github_version
# lets `gh --paginate` do it for GitHub.
codeberg_candidate_tags() {
    local repo="$1"
    {
        curl -sf "https://codeberg.org/api/v1/repos/${repo}/tags?limit=50" \
            | jq -r '.[].name' 2>/dev/null || true
        curl -sf "https://codeberg.org/api/v1/repos/${repo}/releases?limit=50" \
            | jq -r '.[].tag_name' 2>/dev/null || true
    } | sort -u
}

resolve_codeberg_version() {
    local repo="$1" regex="$2"
    codeberg_candidate_tags "$repo" \
        | grep -E "$regex" \
        | sed -E "s/$regex/\\1/" \
        | sort -V | tail -1
}

# Extract the version out of a single already-known tag (a webhook
# payload's own version field) using TAG_REGEX, instead of scanning every
# tag for candidates - the tag is trusted as-is (see check_one: still
# subject to the normal version_gt-against-upstream check, and a human
# reviewing the resulting PR before merge), TAG_REGEX just normalizes its
# format the same way it would if found via a full scan. Prints nothing
# if it doesn't match, so the caller can fall back to that full scan.
resolve_known_tag() {
    local tag="$1" regex="$2"
    printf '%s' "$tag" | grep -E "$regex" | sed -E "s/$regex/\\1/"
}

# --- kernel.org cgit version resolution --------------------------------

# cgit has no JSON API; scrape the /refs/ page's "Tag" column, which links
# to each tag as `.../tag/?h=<tagname>`. Works for any cgit instance, not
# just kernel.org, in case another package ever needs it.
cgit_candidate_tags() {
    local cgit_url="$1"
    curl -sf "${cgit_url%/}/refs/" \
        | grep -oE "tag/\?h=[^'\"]+" | sed -E "s#tag/\?h=##" | sort -u
}

resolve_kernel_cgit_version() {
    local cgit_url="$1" regex="$2"
    cgit_candidate_tags "$cgit_url" \
        | grep -E "$regex" \
        | sed -E "s/$regex/\\1/" \
        | sort -V | tail -1
}

# --- nvchecker version resolution (POLL=1 packages) ---------------------

# nvchecker's `regex` source: fetch $url, apply $regex directly against the
# page, take the max (by nvchecker's own version sort) of every match's
# capture group. Used for POLL=1 packages, tracked by poll.yml - a
# maintained tool instead of another bespoke scraper like
# resolve_kernel_cgit_version above (kept as-is only because it's already
# in use elsewhere - see image-deps.yml).
#
# $regex is written into the TOML as a triple-single-quoted literal
# string (no escaping of any kind, including embedded quote characters)
# rather than interpolated into a shell command - avoids the same class of
# quoting problems as CGIT_URL-style scraping without needing $regex
# itself to avoid quote characters (though in practice ours do, since they
# match version characters directly rather than "everything until a
# quote").
resolve_nvchecker_version() {
    local url="$1" regex="$2" workdir
    workdir="$(mktemp -d)"
    cat > "$workdir/config.toml" <<TOML
[__config__]
oldver = "$workdir/old.json"
newver = "$workdir/new.json"

[pkg]
source = "regex"
url = '''$url'''
regex = '''$regex'''
TOML
    echo '{}' > "$workdir/old.json"
    nvchecker -c "$workdir/config.toml" >/dev/null 2>&1 || true
    jq -r '.data.pkg.version // empty' "$workdir/new.json" 2>/dev/null
    rm -rf "$workdir"
}

# --- detection orchestration --------------------------------------------

# An update is only "needed" if it beats what upstream currently ships AND
# there's no open PR for it already here (an update PR bumps this repo's
# own tracked sbo/.info in the same commit, but that only lands on master
# once the PR merges - until then, this branch-name check is what stops a
# second PR for the same version from being opened while the first is
# still in review).
already_pending() {
    local prgnam="$1" version="$2"
    gh pr list --repo "$(git config --get remote.origin.url | sed -E 's#.*[:/]([^/]+/[^/.]+)(\.git)?$#\1#')" \
        --state open --head "update/${prgnam}-${version}" --json number --jq 'length > 0' 2>/dev/null || echo false
}

# SOURCE is just the repo's endpoint URL - it says where the code lives,
# not how to check it for updates. Resolution is: POLL=1 always means
# nvchecker (SOURCE, in that case, is whatever page nvchecker isn't
# already told to scrape via NVCHECKER_URL - typically the repo's
# homepage, not consulted here); otherwise it's inferred from SOURCE's
# host, since that's the only thing that actually determines which API is
# available (github.com and codeberg.org have one; an arbitrary
# self-hosted cgit/hg server doesn't, hence POLL=1 for those).
resolve_latest() {
    if [ "${POLL:-0}" = "1" ]; then
        [ -n "${NVCHECKER_URL:-}" ] || die "$PRGNAM: POLL=1 but NVCHECKER_URL not set"
        [ -n "${NVCHECKER_REGEX:-}" ] || die "$PRGNAM: POLL=1 but NVCHECKER_REGEX not set"
        resolve_nvchecker_version "$NVCHECKER_URL" "$NVCHECKER_REGEX"
        return
    fi

    [ -n "${TAG_REGEX:-}" ] || die "$PRGNAM: TAG_REGEX not set"
    case "$SOURCE" in
        https://github.com/*)
            resolve_github_version "$(repo_path_from_url "$SOURCE")" "$TAG_REGEX"
            ;;
        https://codeberg.org/*)
            resolve_codeberg_version "$(repo_path_from_url "$SOURCE")" "$TAG_REGEX"
            ;;
        *)
            die "$PRGNAM: no resolver for SOURCE=$SOURCE (not github.com/codeberg.org, and POLL isn't set)"
            ;;
    esac
}

# Given a package conf already loaded (CATEGORY/PRGNAM/etc in scope) and a
# resolved candidate version (possibly empty - "couldn't resolve one"),
# decide what to do about it and print one status line:
#   NEEDS_UPDATE <prgnam> <category> <new_version>   an update PR should be opened
#   FROZEN <prgnam> <reason> (N behind: <latest>)     skipped, reported for the summary
#   UP_TO_DATE <prgnam> <version>                     nothing to do
#   UNRESOLVED <prgnam>                               couldn't determine a latest version
#
# Shared by check_one (resolves $latest by scanning - poll.yml's job) and
# check_known (webhook.yml's job: $latest is already known, from the
# webhook payload) - what to do with a candidate version is identical
# either way, only how it was obtained differs.
check_result() {
    local latest="$1"

    # Our own last-known version, straight from this repo's own tracked
    # copy - not packages/*.conf (no VERSION field there; it duplicated
    # this without ever being a separate source of truth).
    local tracked
    tracked="$(info_get "sbo/${CATEGORY}/${PRGNAM}/${PRGNAM}.info" VERSION 2>/dev/null || true)"

    if [ "${FROZEN:-0}" = "1" ]; then
        if [ -n "$latest" ] && version_gt "$latest" "$tracked"; then
            echo "FROZEN $PRGNAM ${FROZEN_REASON:-frozen} (behind: $latest)"
        else
            echo "FROZEN $PRGNAM ${FROZEN_REASON:-frozen}"
        fi
        return
    fi

    if [ -z "$latest" ]; then
        echo "UNRESOLVED $PRGNAM"
        return
    fi

    local upstream
    upstream="$(upstream_version "$CATEGORY" "$PRGNAM")"
    if [ -z "$upstream" ]; then
        log "warn: $PRGNAM: not found at ${CATEGORY}/${PRGNAM} upstream (moved/renamed?)"
        upstream="$tracked"
    fi

    if ! version_gt "$latest" "$upstream" || ! version_gt "$latest" "$tracked"; then
        echo "UP_TO_DATE $PRGNAM $upstream"
        return
    fi

    if [ "$(already_pending "$PRGNAM" "$latest")" = "true" ]; then
        log "info: $PRGNAM: PR for $latest already open, skipping"
        echo "UP_TO_DATE $PRGNAM $upstream"
        return
    fi

    echo "NEEDS_UPDATE $PRGNAM $CATEGORY $latest"
}

# Resolve $conf's latest version by scanning (resolve_latest) and print
# its status line. Used only by poll.yml; webhook.yml already has a
# version from the webhook payload and uses check_known instead, since
# re-scanning to confirm what newreleases.io just told us would defeat
# the point of it telling us.
check_one() {
    local conf="$1"
    load_package_conf "$conf"
    local latest
    latest="$(resolve_latest || true)"
    check_result "$latest"
}

# Like check_one, but $known_version is already known for this package (a
# webhook payload's own version field) rather than something to resolve
# by scanning. Extracts/normalizes it via TAG_REGEX the same way a scan
# would (see resolve_known_tag); if it doesn't match, reports UNRESOLVED
# rather than falling back to a scan here - that's poll.yml's job, on its
# own schedule, not something webhook.yml also does on every firing.
check_known() {
    local conf="$1" known_version="$2"
    load_package_conf "$conf"
    [ "${POLL:-0}" != "1" ] || die "$PRGNAM: POLL=1, has no webhook option - shouldn't reach check_known"
    [ -n "${TAG_REGEX:-}" ] || die "$PRGNAM: TAG_REGEX not set"
    local latest
    latest="$(resolve_known_tag "$known_version" "$TAG_REGEX" || true)"
    check_result "$latest"
}

# --- package generation ---------------------------------------------------
# Used once per job by two different workflow files -
# open-update-prs.yml's own step and submit.yml's - so it stays a plain
# function here rather than one workflow owning it.
#
# Produces an updated .info + .SlackBuild for one package at a target
# version, derived from a *fresh* upstream checkout - never from anything
# already in this repo. See this file's header for why.
#
# Usage: generate_package <prgnam> <version> <upstream_checkout_dir> <out_dir>
#
# <upstream_checkout_dir> must be a checkout of SlackBuildsOrg/slackbuilds
# containing <category>/<prgnam>/. <out_dir> is created and populated with
# <prgnam>.info and <prgnam>.SlackBuild.
generate_package() {
    local prgnam="${1:?prgnam required}" version="${2:?version required}" \
        upstream_dir="${3:?upstream checkout dir required}" out_dir="${4:?output dir required}"

    local conf="packages/${prgnam}.conf"
    [ -f "$conf" ] || die "no such package config: $conf"
    load_package_conf "$conf"
    [ "$prgnam" = "$PRGNAM" ] || die "packages/${prgnam}.conf declares PRGNAM=$PRGNAM"

    local src_pkg_dir="${upstream_dir}/${CATEGORY}/${PRGNAM}"
    [ -d "$src_pkg_dir" ] || die "not found in upstream checkout: $src_pkg_dir"
    [ -f "$src_pkg_dir/${PRGNAM}.info" ] || die "missing ${PRGNAM}.info in $src_pkg_dir"
    [ -f "$src_pkg_dir/${PRGNAM}.SlackBuild" ] || die "missing ${PRGNAM}.SlackBuild in $src_pkg_dir"

    mkdir -p "$out_dir"
    local workdir
    workdir="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$workdir'" RETURN

    # --- .SlackBuild: copy upstream's verbatim, bump VERSION/BUILD only ---
    # Everything else - offline crate vendoring, arch handling, whatever a
    # mass upstream rewrite changed - is preserved exactly, since it's not
    # ours to maintain independently of upstream.
    sed -E \
        -e "s/^(VERSION=\\\$\\{VERSION:-)[^}]*(\\})/\\1${version}\\2/" \
        -e 's/^(BUILD=\$\{BUILD:-)[^}]*(\})/\11\2/' \
        "$src_pkg_dir/${PRGNAM}.SlackBuild" > "$out_dir/${PRGNAM}.SlackBuild"

    if ! grep -qF "VERSION=\${VERSION:-${version}}" "$out_dir/${PRGNAM}.SlackBuild"; then
        die "$PRGNAM: couldn't find/rewrite the VERSION=\${VERSION:-...} line in ${PRGNAM}.SlackBuild - upstream format changed, needs a look"
    fi

    # --- .info -------------------------------------------------------------
    local url archive prgdir
    url="$(subst_version "$SRC_URL" "$version")"
    archive="$(subst_version "$ARCHIVE" "$version")"
    prgdir="$(subst_version "$PRGDIR" "$version")"

    case "$STRATEGY" in
        tarball)
            local homepage requires maintainer email archive_path md5
            homepage="$(info_get "$src_pkg_dir/${PRGNAM}.info" HOMEPAGE)"
            requires="$(info_get "$src_pkg_dir/${PRGNAM}.info" REQUIRES)"
            maintainer="$(info_get "$src_pkg_dir/${PRGNAM}.info" MAINTAINER)"
            email="$(info_get "$src_pkg_dir/${PRGNAM}.info" EMAIL)"

            archive_path="$workdir/$archive"
            log "downloading $url"
            wget -q -O "$archive_path" "$url" || die "$PRGNAM: failed to download $url"
            md5="$(md5_of "$archive_path")"

            cat > "$out_dir/${PRGNAM}.info" <<EOF
PRGNAM="$PRGNAM"
VERSION="$version"
HOMEPAGE="$homepage"
DOWNLOAD="$url"
MD5SUM="$md5"
DOWNLOAD_x86_64=""
MD5SUM_x86_64=""
REQUIRES="$requires"
MAINTAINER="$maintainer"
EMAIL="$email"
EOF
            ;;

        rust|rust64)
            local homepage requires maintainer email rust_script
            homepage="$(info_get "$src_pkg_dir/${PRGNAM}.info" HOMEPAGE)"
            requires="$(info_get "$src_pkg_dir/${PRGNAM}.info" REQUIRES)"
            maintainer="$(info_get "$src_pkg_dir/${PRGNAM}.info" MAINTAINER)"
            email="$(info_get "$src_pkg_dir/${PRGNAM}.info" EMAIL)"

            rust_script="scripts/rust-info.sh"
            [ "$STRATEGY" = rust64 ] && rust_script="scripts/rust64-info.sh"

            (
                cd "$workdir"
                PRGNAM="$PRGNAM" VERSION="$version" HOMEPAGE="$homepage" REQUIRES="$requires" \
                    MAINTAINER="$maintainer" EMAIL="$email" \
                    URL="$url" ARCHIVE="$archive" PRGDIR="$prgdir" \
                    bash "$REPO_ROOT/$rust_script"
            )
            [ -f "$workdir/${PRGNAM}.info" ] || die "$PRGNAM: rust-info generator did not produce ${PRGNAM}.info"
            cp "$workdir/${PRGNAM}.info" "$out_dir/${PRGNAM}.info"
            ;;

        *)
            die "$PRGNAM: unknown STRATEGY=$STRATEGY"
            ;;
    esac

    log "generated $out_dir/${PRGNAM}.info and $out_dir/${PRGNAM}.SlackBuild"
}

# --- PR body rendering -----------------------------------------------------
# Used by open-update-prs.yml, once per package - same reasoning as
# generate_package for why it's a plain function.
#
# Packages live at <category>/<prgnam>/ in this repo - the exact same path
# they occupy in SlackBuildsOrg/slackbuilds - so the PR's own "Files
# changed" tab already *is* the real diff (full GitHub review UI: inline
# comments, viewed checkboxes, etc.), not something that needs restating
# here. This just states what merging it will do.
#
# Usage: render_pr_body <prgnam> <version>
render_pr_body() {
    local prgnam="${1:?prgnam required}" version="${2:?version required}"

    local conf="packages/${prgnam}.conf"
    load_package_conf "$conf"
    [ "$prgnam" = "$PRGNAM" ] || die "packages/${prgnam}.conf declares PRGNAM=$PRGNAM"

    local commit_msg="${CATEGORY}/${PRGNAM}: Updated for version ${version}"

    cat <<EOF
Detected upstream update: **${CATEGORY}/${PRGNAM} → ${version}**.

The diff below (**Files changed** tab) is exactly what merging this PR
submits to
[SlackBuildsOrg/slackbuilds](https://github.com/SlackBuildsOrg/slackbuilds)
as \`${SBO_FORK:-perrin4869/sbo}:${PRGNAM}/${version}\` - modulo one thing:
\`submit.yml\` re-derives it against a fresh upstream clone at merge time
rather than trusting what's reviewed here, in case upstream moved since
this PR was opened. If that happens it'll say so on the resulting upstream
PR.

> **${commit_msg}**
EOF
}

# --- misc -------------------------------------------------------------

# md5sum of a local file, first field only.
md5_of() { md5sum "$1" | cut -d' ' -f1; }
