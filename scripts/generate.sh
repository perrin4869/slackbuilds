#!/bin/bash
# Produce an updated .info + .SlackBuild for one package at a target version,
# derived from a *fresh* upstream checkout - never from anything already in
# this repo (staging/ included). See lib.sh header for why.
#
# Usage:
#   scripts/generate.sh <prgnam> <version> <upstream_checkout_dir> <out_dir>
#
# <upstream_checkout_dir> must be a checkout of SlackBuildsOrg/slackbuilds
# containing <category>/<prgnam>/. <out_dir> is created and populated with
# <prgnam>.info and <prgnam>.SlackBuild.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib.sh

prgnam="${1:?prgnam required}"
version="${2:?version required}"
upstream_dir="${3:?upstream checkout dir required}"
out_dir="${4:?output dir required}"

conf="packages/${prgnam}.conf"
[ -f "$conf" ] || die "no such package config: $conf"
load_package_conf "$conf"
[ "$prgnam" = "$PRGNAM" ] || die "packages/${prgnam}.conf declares PRGNAM=$PRGNAM"

src_pkg_dir="${upstream_dir}/${CATEGORY}/${PRGNAM}"
[ -d "$src_pkg_dir" ] || die "not found in upstream checkout: $src_pkg_dir"
[ -f "$src_pkg_dir/${PRGNAM}.info" ] || die "missing ${PRGNAM}.info in $src_pkg_dir"
[ -f "$src_pkg_dir/${PRGNAM}.SlackBuild" ] || die "missing ${PRGNAM}.SlackBuild in $src_pkg_dir"

mkdir -p "$out_dir"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

# --- .SlackBuild: copy upstream's verbatim, bump VERSION/BUILD only -------
# Everything else - offline crate vendoring, arch handling, whatever a mass
# upstream rewrite changed - is preserved exactly, since it's not ours to
# maintain independently of upstream.
sed -E \
    -e "s/^(VERSION=\\\$\\{VERSION:-)[^}]*(\\})/\\1${version}\\2/" \
    -e 's/^(BUILD=\$\{BUILD:-)[^}]*(\})/\11\2/' \
    "$src_pkg_dir/${PRGNAM}.SlackBuild" > "$out_dir/${PRGNAM}.SlackBuild"

if ! grep -qF "VERSION=\${VERSION:-${version}}" "$out_dir/${PRGNAM}.SlackBuild"; then
    die "$PRGNAM: couldn't find/rewrite the VERSION=\${VERSION:-...} line in ${PRGNAM}.SlackBuild - upstream format changed, needs a look"
fi

# --- .info -----------------------------------------------------------------
url="$(subst_version "$SRC_URL" "$version")"
archive="$(subst_version "$ARCHIVE" "$version")"
prgdir="$(subst_version "$PRGDIR" "$version")"

case "$GENERATOR" in
    simple)
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
