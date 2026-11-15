#!/bin/bash
# Shared helpers, sourced by workflow steps and scripts/update-package.sh.
# "Upstream" always means SlackBuildsOrg/slackbuilds@master, fetched fresh.

set -euo pipefail

UPSTREAM_OWNER="SlackBuildsOrg"
UPSTREAM_REPO="slackbuilds"
UPSTREAM_REF="master"
SBO_FORK="perrin4869/sbo"

SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
PACKAGES_DIR="$REPO_ROOT/packages"
SBO_DIR="$REPO_ROOT/sbo"

log() { printf '%s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }

# --- package config -----------------------------------------------------

# Reset first so one package's fields don't leak into the next.
load_package_conf() {
    local conf="$1"
    # shellcheck disable=SC2034 # some fields are read by the caller (CHECK_IMAGE)
    CATEGORY='' PRGNAM='' SOURCE='' TAG_REGEX='' POLL=0 NVCHECKER_URL='' NVCHECKER_REGEX='' \
        STRATEGY=tarball DOWNLOAD_URL='' X86_64_ONLY=0 FROZEN=0 FROZEN_REASON='' \
        CHECK_IMAGE=''
    # shellcheck disable=SC1090
    source "$conf"
    [ -n "$PRGNAM" ] || die "$conf: PRGNAM not set"
    [ -n "$CATEGORY" ] || die "$conf: CATEGORY not set"
    [ -n "$SOURCE" ] || die "$conf: SOURCE not set"
}

# "owner/repo" from a github.com/codeberg.org URL; anything else unchanged.
repo_path_from_url() {
    local url="$1"
    url="${url#https://github.com/}"
    url="${url#https://codeberg.org/}"
    printf '%s' "${url%/}"
}

# PRGNAM whose SOURCE is the "owner/repo" in $1, or nothing.
find_package_by_repo() {
    local repo="$1" conf
    for conf in "$PACKAGES_DIR"/*.conf; do
        [ -e "$conf" ] || continue
        load_package_conf "$conf"
        if [ "$(repo_path_from_url "$SOURCE")" = "$repo" ]; then
            echo "$PRGNAM"
            return
        fi
    done
}

subst_version() {
    local template="$1" version="$2"
    printf '%s' "${template//%VERSION%/$version}"
}

# --- .info parsing --------------------------------------------------

# Single-line KEY="value" only; continuation lines of multi-line
# DOWNLOAD/MD5SUM end in a backslash and don't match.
info_get() {
    local file="$1" key="$2"
    sed -n "s/^${key}=\"\\(.*\\)\"\$/\\1/p" "$file" | head -1
}

version_gt() {
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]
}

# --- upstream fetch -------------------------------------------------

# Empty output if the file doesn't exist upstream.
fetch_upstream_file() {
    local path="$1" ref="${2:-$UPSTREAM_REF}"
    gh api "repos/${UPSTREAM_OWNER}/${UPSTREAM_REPO}/contents/${path}?ref=${ref}" \
        -H 'Accept: application/vnd.github.raw' 2>/dev/null || true
}

# Usage: upstream_version <category> <prgnam> [ref]
upstream_version() {
    local category="$1" prgnam="$2" ref="${3:-$UPSTREAM_REF}"
    fetch_upstream_file "${category}/${prgnam}/${prgnam}.info" "$ref" | info_get /dev/stdin VERSION
}

# --- version resolution ---------------------------------------------

# Run nvchecker on one [pkg] entry (TOML body on stdin), print the version.
nvchecker_version() {
    local workdir
    workdir="$(mktemp -d)"
    {
        printf '[__config__]\noldver = "%s/old.json"\nnewver = "%s/new.json"\n\n[pkg]\n' \
            "$workdir" "$workdir"
        cat
    } > "$workdir/config.toml"
    echo '{}' > "$workdir/old.json"
    nvchecker -l warning -c "$workdir/config.toml" >&2 || log "warn: nvchecker failed"
    jq -r '.data.pkg.version // empty' "$workdir/new.json" 2>/dev/null || true
    rm -rf "$workdir"
}

# Highest tag of a github/gitea repo matching $regex, normalized to its
# capture group. TAG_REGEX is needed because neither "latest release" nor
# "newest tag" is reliable across the repos tracked here.
resolve_scm_version() {
    local kind="$1" repo="$2" regex="$3" host="${4:-}" raw
    raw="$(
        {
            echo "source = \"$kind\""
            echo "$kind = '''$repo'''"
            echo 'use_max_tag = true'
            echo "include_regex = '''$regex'''"
            [ -z "$host" ] || echo "host = \"$host\""
            [ "$kind" != github ] || [ -z "${GH_TOKEN:-}" ] || echo "token = \"$GH_TOKEN\""
        } | nvchecker_version
    )"
    [ -z "$raw" ] || resolve_known_tag "$raw" "$regex"
}

# Version out of a known tag via TAG_REGEX; nothing if it doesn't match.
resolve_known_tag() {
    local tag="$1" regex="$2"
    printf '%s' "$tag" | grep -E "$regex" | sed -E "s/$regex/\\1/"
}

# POLL=1 uses nvchecker's regex source on NVCHECKER_URL (hosts with no
# API); otherwise SOURCE's host picks the nvchecker source.
resolve_latest() {
    if [ "$POLL" = 1 ]; then
        [ -n "$NVCHECKER_URL" ] || die "$PRGNAM: POLL=1 but NVCHECKER_URL not set"
        [ -n "$NVCHECKER_REGEX" ] || die "$PRGNAM: POLL=1 but NVCHECKER_REGEX not set"
        printf "source = \"regex\"\nurl = '''%s'''\nregex = '''%s'''\n" \
            "$NVCHECKER_URL" "$NVCHECKER_REGEX" | nvchecker_version
        return
    fi

    [ -n "$TAG_REGEX" ] || die "$PRGNAM: TAG_REGEX not set"
    case "$SOURCE" in
        https://github.com/*)
            resolve_scm_version github "$(repo_path_from_url "$SOURCE")" "$TAG_REGEX" ;;
        https://codeberg.org/*)
            resolve_scm_version gitea "$(repo_path_from_url "$SOURCE")" "$TAG_REGEX" codeberg.org ;;
        *)
            die "$PRGNAM: no resolver for SOURCE=$SOURCE (not github.com/codeberg.org, and POLL isn't set)" ;;
    esac
}

# --- detection --------------------------------------------------------

# VERSION on this package's open update PR, or nothing if there is none.
pending_version() {
    local repo branch="update/${PRGNAM}" open
    repo="${GITHUB_REPOSITORY:-$(cd "$REPO_ROOT" && gh repo view --json nameWithOwner -q .nameWithOwner)}"
    open="$(gh pr list --repo "$repo" --state open --head "$branch" --json number --jq length 2>/dev/null || echo 0)"
    [ "$open" -gt 0 ] || return 0
    { gh api "repos/${repo}/contents/sbo/${CATEGORY}/${PRGNAM}/${PRGNAM}.info?ref=${branch}" \
        -H 'Accept: application/vnd.github.raw' 2>/dev/null || true; } | info_get /dev/stdin VERSION
}

# Given a loaded conf and a candidate version (empty = unresolved), print
# one status line:
#   NEEDS_UPDATE <prgnam> <category> <version>
#   FROZEN <prgnam> <reason> [(behind: <latest>)]
#   UP_TO_DATE <prgnam> <version>
#   UNRESOLVED <prgnam>
check_result() {
    local latest="$1" tracked upstream pending
    tracked="$(info_get "$SBO_DIR/${CATEGORY}/${PRGNAM}/${PRGNAM}.info" VERSION 2>/dev/null || true)"

    if [ "$FROZEN" = 1 ]; then
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

    upstream="$(upstream_version "$CATEGORY" "$PRGNAM")"
    if [ -z "$upstream" ]; then
        log "warn: $PRGNAM: not found at ${CATEGORY}/${PRGNAM} upstream (moved/renamed?)"
        upstream="$tracked"
    fi

    if ! version_gt "$latest" "$upstream" || ! version_gt "$latest" "$tracked"; then
        echo "UP_TO_DATE $PRGNAM $upstream"
        return
    fi

    pending="$(pending_version)"
    if [ -n "$pending" ] && ! version_gt "$latest" "$pending"; then
        log "info: $PRGNAM: open PR already has $pending"
        echo "UP_TO_DATE $PRGNAM $upstream (PR open for $pending)"
        return
    fi

    echo "NEEDS_UPDATE $PRGNAM $CATEGORY $latest"
}

# poll.yml: resolve the latest version by scanning.
check_one() {
    local conf="$1" latest
    load_package_conf "$conf"
    latest="$(resolve_latest || true)"
    check_result "$latest"
}

# webhook.yml: the version comes from the webhook payload.
check_known() {
    local conf="$1" known_version="$2" latest
    load_package_conf "$conf"
    [ "$POLL" != 1 ] || die "$PRGNAM: POLL=1 has no webhook"
    [ -n "$TAG_REGEX" ] || die "$PRGNAM: TAG_REGEX not set"
    latest="$(resolve_known_tag "$known_version" "$TAG_REGEX" || true)"
    check_result "$latest"
}

# Markdown table of status lines (stdin) for $GITHUB_STEP_SUMMARY.
results_summary() {
    local title="$1" status prgnam rest
    printf '## %s\n\n| status | package | detail |\n|---|---|---|\n' "$title"
    while IFS=' ' read -r status prgnam rest; do
        [ -n "$status" ] || continue
        printf '| %s | %s | %s |\n' "$status" "$prgnam" "$rest"
    done
}

# JSON matrix of the NEEDS_UPDATE status lines (stdin).
results_matrix() {
    jq -R -s -c '[splits("\n") | split(" ") | select(.[0] == "NEEDS_UPDATE")
        | {prgnam: .[1], category: .[2], version: .[3]}]'
}

# --- package generation ---------------------------------------------------

# Write <prgnam>.info and <prgnam>.SlackBuild for <version> into <out_dir>,
# derived from <upstream_checkout_dir> (a SlackBuildsOrg/slackbuilds
# checkout), never from this repo's copy.
#
# Usage: generate_package <prgnam> <version> <upstream_checkout_dir> <out_dir>
generate_package() {
    local prgnam="${1:?prgnam required}" version="${2:?version required}" \
        upstream_dir="${3:?upstream checkout dir required}" out_dir="${4:?output dir required}"

    local conf="$PACKAGES_DIR/${prgnam}.conf"
    [ -f "$conf" ] || die "no such package config: $conf"
    load_package_conf "$conf"
    [ "$prgnam" = "$PRGNAM" ] || die "$conf declares PRGNAM=$PRGNAM"

    local src_pkg_dir="${upstream_dir}/${CATEGORY}/${PRGNAM}"
    [ -f "$src_pkg_dir/${PRGNAM}.info" ] || die "missing ${PRGNAM}.info in $src_pkg_dir"
    [ -f "$src_pkg_dir/${PRGNAM}.SlackBuild" ] || die "missing ${PRGNAM}.SlackBuild in $src_pkg_dir"

    mkdir -p "$out_dir"
    local workdir
    workdir="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$workdir'" RETURN

    # Upstream's SlackBuild verbatim apart from VERSION and BUILD.
    sed -E \
        -e "s/^(VERSION=\\\$\\{VERSION:-)[^}]*(\\})/\\1${version}\\2/" \
        -e 's/^(BUILD=\$\{BUILD:-)[^}]*(\})/\11\2/' \
        "$src_pkg_dir/${PRGNAM}.SlackBuild" > "$out_dir/${PRGNAM}.SlackBuild"

    if ! grep -qF "VERSION=\${VERSION:-${version}}" "$out_dir/${PRGNAM}.SlackBuild"; then
        die "$PRGNAM: couldn't rewrite the VERSION=\${VERSION:-...} line in ${PRGNAM}.SlackBuild"
    fi

    local url homepage requires maintainer email
    url="$(subst_version "$DOWNLOAD_URL" "$version")"
    homepage="$(info_get "$src_pkg_dir/${PRGNAM}.info" HOMEPAGE)"
    requires="$(info_get "$src_pkg_dir/${PRGNAM}.info" REQUIRES)"
    maintainer="$(info_get "$src_pkg_dir/${PRGNAM}.info" MAINTAINER)"
    email="$(info_get "$src_pkg_dir/${PRGNAM}.info" EMAIL)"

    case "$STRATEGY" in
        tarball)
            local md5 download_lines
            log "downloading $url"
            wget -q -O "$workdir/source-archive" "$url" || die "$PRGNAM: failed to download $url"
            md5="$(md5sum "$workdir/source-archive" | cut -d' ' -f1)"

            if [ "$X86_64_ONLY" = 1 ]; then
                download_lines="DOWNLOAD=\"UNSUPPORTED\"
MD5SUM=\"\"
DOWNLOAD_x86_64=\"$url\"
MD5SUM_x86_64=\"$md5\""
            else
                download_lines="DOWNLOAD=\"$url\"
MD5SUM=\"$md5\"
DOWNLOAD_x86_64=\"\"
MD5SUM_x86_64=\"\""
            fi

            cat > "$out_dir/${PRGNAM}.info" <<EOF
PRGNAM="$PRGNAM"
VERSION="$version"
HOMEPAGE="$homepage"
$download_lines
REQUIRES="$requires"
MAINTAINER="$maintainer"
EMAIL="$email"
EOF
            ;;

        rust)
            (
                cd "$workdir"
                PRGNAM="$PRGNAM" VERSION="$version" HOMEPAGE="$homepage" REQUIRES="$requires" \
                    MAINTAINER="$maintainer" EMAIL="$email" \
                    URL="$url" X86_64_ONLY="$X86_64_ONLY" \
                    bash "$SCRIPT_DIR/rust-info.sh"
            )
            [ -f "$workdir/${PRGNAM}.info" ] || die "$PRGNAM: rust-info.sh did not produce ${PRGNAM}.info"
            cp "$workdir/${PRGNAM}.info" "$out_dir/${PRGNAM}.info"
            ;;

        *)
            die "$PRGNAM: unknown STRATEGY=$STRATEGY"
            ;;
    esac

    log "generated $out_dir/${PRGNAM}.info and $out_dir/${PRGNAM}.SlackBuild"
}

# Usage: render_pr_body <prgnam> <version>
render_pr_body() {
    local prgnam="${1:?prgnam required}" version="${2:?version required}"
    load_package_conf "$PACKAGES_DIR/${prgnam}.conf"
    [ "$prgnam" = "$PRGNAM" ] || die "$PACKAGES_DIR/${prgnam}.conf declares PRGNAM=$PRGNAM"

    cat <<EOF
Detected upstream update: **${CATEGORY}/${PRGNAM} → ${version}**.

Merging submits **Files changed** to
[SlackBuildsOrg/slackbuilds](https://github.com/SlackBuildsOrg/slackbuilds)
from \`${SBO_FORK}:${PRGNAM}/${version}\`, as
\`${CATEGORY}/${PRGNAM}: Updated for version ${version}\`.
\`submit.yml\` regenerates against a fresh upstream clone at merge time,
and notes it on the upstream PR if the result differs.
EOF
}
