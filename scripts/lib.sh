#!/bin/bash
# Shared helpers for detect.sh / generate.sh / submit.sh.
#
# Conventions used throughout this pipeline:
#  - "upstream" always means SlackBuildsOrg/slackbuilds@master, fetched fresh.
#    Nothing in this repo (per-package dirs, packages/*.conf VERSION) is ever treated
#    as a base to diff or build against - see the plan's "Hard constraint".
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
    CATEGORY= PRGNAM= SOURCE= GITHUB_REPO= CODEBERG_REPO= CGIT_URL= SRHT_REPO= \
        NVCHECKER_URL= NVCHECKER_REGEX= \
        TAG_REGEX= GENERATOR= SRC_URL= ARCHIVE= PRGDIR= VERSION= FROZEN=0 FROZEN_REASON=
    # shellcheck disable=SC1090
    source "$conf"
    [ -n "$PRGNAM" ] || die "$conf: PRGNAM not set"
    [ -n "$CATEGORY" ] || die "$conf: CATEGORY not set"
    # Most packages are a single source tarball with no special vendoring -
    # GENERATOR is only worth naming explicitly for the rust/rust64 case.
    GENERATOR="${GENERATOR:-tarball}"
}

# Print the PRGNAM whose packages/*.conf declares GITHUB_REPO or
# CODEBERG_REPO equal to $1 (an "owner/repo" string), or nothing if none
# matches. Lets a repository_dispatch payload that names the upstream
# project which changed scope detection to that one package, instead of
# re-checking every package on every webhook firing.
find_package_by_repo() {
    local repo="$1" conf
    for conf in packages/*.conf; do
        [ -e "$conf" ] || continue
        load_package_conf "$conf"
        if [ "${GITHUB_REPO:-}" = "$repo" ] || [ "${CODEBERG_REPO:-}" = "$repo" ]; then
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

# Print the raw contents of a file from SlackBuildsOrg/slackbuilds, at
# $UPSTREAM_REF unless a third arg overrides it (submit.sh re-fetches at
# a specific SHA to compare against what a PR was reviewed at). Empty
# output if the file doesn't exist - callers treat that as "package not
# in upstream yet".
fetch_upstream_file() {
    local path="$1" ref="${2:-$UPSTREAM_REF}"
    gh api "repos/${UPSTREAM_OWNER}/${UPSTREAM_REPO}/contents/${path}?ref=${ref}" \
        -H 'Accept: application/vnd.github.raw' 2>/dev/null || true
}

# Print VERSION as currently shipped in SlackBuildsOrg/slackbuilds for a
# given category/prgnam, or nothing if the package isn't there.
upstream_version() {
    local category="$1" prgnam="$2" ref="${3:-$UPSTREAM_REF}" tmp
    tmp="$(mktemp)"
    fetch_upstream_file "${category}/${prgnam}/${prgnam}.info" "$ref" > "$tmp"
    [ -s "$tmp" ] && info_get "$tmp" VERSION
    rm -f "$tmp"
}

# HEAD sha of SlackBuildsOrg/slackbuilds@master, for UPDATE.json provenance.
upstream_head_sha() {
    gh api "repos/${UPSTREAM_OWNER}/${UPSTREAM_REPO}/commits/${UPSTREAM_REF}" --jq '.sha'
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

# --- sourcehut Mercurial version resolution ----------------------------

# hg.sr.ht has no API either; scrape the /tags page's archive links
# (`archive/<tag>.tar.gz`), which is also the exact source-download URL
# shape SBo uses for these packages. "tip" is Mercurial's alias for the
# working head, not a real tag - always excluded.
srht_hg_candidate_tags() {
    local repo="$1"
    curl -sf "https://hg.sr.ht/${repo}/tags" \
        | grep -oE "archive/[^'\"]+\.tar\.gz" \
        | sed -E 's#archive/(.+)\.tar\.gz#\1#' \
        | grep -v '^tip$' | sort -u
}

resolve_sourcehut_hg_version() {
    local repo="$1" regex="$2"
    srht_hg_candidate_tags "$repo" \
        | grep -E "$regex" \
        | sed -E "s/$regex/\\1/" \
        | sort -V | tail -1
}

# --- nvchecker version resolution (pull-based packages) ----------------

# nvchecker's `regex` source: fetch $url, apply $regex directly against the
# page, take the max (by nvchecker's own version sort) of every match's
# capture group. Used for SOURCE=nvchecker packages tracked by
# poll.yml - a maintained tool instead of another bespoke scraper,
# for packages where we're not already committed to one (see
# resolve_kernel_cgit_version / resolve_sourcehut_hg_version above, which
# stay as-is where already in use).
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
# Used by the detect composite action (.github/actions/detect). A function,
# not a script: called once per package inside that action's own loop, from
# webhook.yml and poll.yml alike.

# An update is only "needed" if it beats both what upstream currently ships
# AND the last version this repo already opened a PR for (which may still
# be sitting in review upstream) - the .conf VERSION exists purely to avoid
# filing the same PR twice.
already_pending() {
    local prgnam="$1" version="$2"
    gh pr list --repo "$(git config --get remote.origin.url | sed -E 's#.*[:/]([^/]+/[^/.]+)(\.git)?$#\1#')" \
        --state open --head "update/${prgnam}-${version}" --json number --jq 'length > 0' 2>/dev/null || echo false
}

resolve_latest() {
    local conf_source="$1"
    case "$conf_source" in
        github)
            [ -n "${GITHUB_REPO:-}" ] || die "$PRGNAM: SOURCE=github but GITHUB_REPO not set"
            [ -n "${TAG_REGEX:-}" ] || die "$PRGNAM: SOURCE=github but TAG_REGEX not set"
            resolve_github_version "$GITHUB_REPO" "$TAG_REGEX"
            ;;
        codeberg)
            [ -n "${CODEBERG_REPO:-}" ] || die "$PRGNAM: SOURCE=codeberg but CODEBERG_REPO not set"
            [ -n "${TAG_REGEX:-}" ] || die "$PRGNAM: SOURCE=codeberg but TAG_REGEX not set"
            resolve_codeberg_version "$CODEBERG_REPO" "$TAG_REGEX"
            ;;
        kernel-cgit)
            [ -n "${CGIT_URL:-}" ] || die "$PRGNAM: SOURCE=kernel-cgit but CGIT_URL not set"
            [ -n "${TAG_REGEX:-}" ] || die "$PRGNAM: SOURCE=kernel-cgit but TAG_REGEX not set"
            resolve_kernel_cgit_version "$CGIT_URL" "$TAG_REGEX"
            ;;
        sourcehut-hg)
            [ -n "${SRHT_REPO:-}" ] || die "$PRGNAM: SOURCE=sourcehut-hg but SRHT_REPO not set"
            [ -n "${TAG_REGEX:-}" ] || die "$PRGNAM: SOURCE=sourcehut-hg but TAG_REGEX not set"
            resolve_sourcehut_hg_version "$SRHT_REPO" "$TAG_REGEX"
            ;;
        nvchecker)
            [ -n "${NVCHECKER_URL:-}" ] || die "$PRGNAM: SOURCE=nvchecker but NVCHECKER_URL not set"
            [ -n "${NVCHECKER_REGEX:-}" ] || die "$PRGNAM: SOURCE=nvchecker but NVCHECKER_REGEX not set"
            resolve_nvchecker_version "$NVCHECKER_URL" "$NVCHECKER_REGEX"
            ;;
        *)
            log "warn: $PRGNAM: no version resolver implemented for SOURCE=$conf_source"
            ;;
    esac
}

# Prints one status line to stdout:
#   NEEDS_UPDATE <prgnam> <category> <new_version>   an update PR should be opened
#   FROZEN <prgnam> <reason> (N behind: <latest>)     skipped, reported for the summary
#   UP_TO_DATE <prgnam> <version>                     nothing to do
#   UNRESOLVED <prgnam>                               couldn't determine a latest version
check_one() {
    local conf="$1"
    load_package_conf "$conf"

    local latest
    latest="$(resolve_latest "$SOURCE" || true)"

    if [ "${FROZEN:-0}" = "1" ]; then
        if [ -n "$latest" ] && version_gt "$latest" "$VERSION"; then
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
        upstream="$VERSION"
    fi

    if ! version_gt "$latest" "$upstream" || ! version_gt "$latest" "$VERSION"; then
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

# --- package generation ---------------------------------------------------
# Used by the open-update-prs composite action and submit.yml. A function,
# not a script: open-update-prs calls this once per NEEDS_UPDATE line inside
# its own loop, which a composite/reusable action can't be invoked from (a
# `uses:` step is static, not callable dynamically per loop iteration) - so
# this has to be something plain bash can call directly, in any context.
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

    case "$GENERATOR" in
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
            [ "$GENERATOR" = rust64 ] && rust_script="scripts/rust64-info.sh"

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
            die "$PRGNAM: unknown GENERATOR=$GENERATOR"
            ;;
    esac

    log "generated $out_dir/${PRGNAM}.info and $out_dir/${PRGNAM}.SlackBuild"
}

# --- PR body rendering -----------------------------------------------------
# Used by the open-update-prs composite action, once per NEEDS_UPDATE line -
# same "must be callable from inside a loop" reasoning as generate_package.
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
