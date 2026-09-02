#!/bin/bash
# Shared helpers for detect.sh / generate.sh / submit.sh.
#
# Conventions used throughout this pipeline:
#  - "upstream" always means SlackBuildsOrg/slackbuilds@master, fetched fresh.
#    Nothing in this repo (staging/, packages/*.conf VERSION) is ever treated
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
    CATEGORY= PRGNAM= SOURCE= GITHUB_REPO= TAG_REGEX= GENERATOR= \
        SRC_URL= ARCHIVE= PRGDIR= VERSION= FROZEN=0 FROZEN_REASON=
    # shellcheck disable=SC1090
    source "$conf"
    [ -n "$PRGNAM" ] || die "$conf: PRGNAM not set"
    [ -n "$CATEGORY" ] || die "$conf: CATEGORY not set"
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

# --- misc -------------------------------------------------------------

# md5sum of a local file, first field only.
md5_of() { md5sum "$1" | cut -d' ' -f1; }
