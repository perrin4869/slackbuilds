#!/bin/bash

# Automatic $PRGNAM.info generator for Rust software. Set X86_64_ONLY=1
# for software that supports x86-64 only; the default (0) supports both
# x86-64 and x86.

# Copyright 2022 K. Eugene Carlson  Tsukuba, Japan
# All rights reserved.
#
# Redistribution and use of this script, with or without modification, is
# permitted provided that the following conditions are met:
#
# 1. Redistributions of this script must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
#
#  THIS SOFTWARE IS PROVIDED BY THE AUTHOR "AS IS" AND ANY EXPRESS OR IMPLIED
#  WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
#  MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO
#  EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
#  SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
#  PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS;
#  OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
#  WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
#  OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
#  ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

# Running this script in a dedicated directory for your Rust package would be
# convenient (a DEBUG directory with files from intermediate steps is
# generated).

# Information about the program goes here
PRGNAM=${PRGNAM:-}
VERSION=${VERSION:-}
HOMEPAGE=${HOMEPAGE:-}
REQUIRES=${REQUIRES:-}
MAINTAINER=${MAINTAINER:-}
EMAIL=${EMAIL:-}
X86_64_ONLY=${X86_64_ONLY:-0}

# Package tarball download
URL=${URL:-}

# Rust crates come from here
WEBADDR="https://static.crates.io/crates/"
# WEBADDR="https://crates-io.s3-us-west-1.amazonaws.com/crates/"

# X86_64_ONLY=1 writes crate info under DOWNLOAD_x86_64/MD5SUM_x86_64
# instead of DOWNLOAD/MD5SUM - chosen once here and used consistently below,
# including for the indirect ${!download_field} expansion that fetches the
# crates themselves.
if [ "$X86_64_ONLY" = 1 ]; then
  download_field=DOWNLOAD_x86_64
  md5_field=MD5SUM_x86_64
else
  download_field=DOWNLOAD
  md5_field=MD5SUM
fi

rm -rf DEBUG CRATES

wget $URL || exit
# archive/prgdir aren't caller config - both are derivable from what's
# actually there: archive is just whatever wget saved the URL under (its
# basename, since no -O was given above), and prgdir is the tarball's own
# top-level directory, read from its own manifest rather than guessed
# from $PRGNAM-$VERSION (wrong whenever the upstream repo's name doesn't
# match PRGNAM, e.g. jujutsu's repo is "jj").
archive="$(basename "$URL")"
tar xf "$archive" || exit
prgdir="$(tar tf "$archive" | head -1 | cut -d/ -f1)"

# Get name and version for Crate dependencies
grep -e ^name -e ^version "$prgdir/Cargo.lock" | grep \" | cut -d \" -f2- | tr -d \" > deps
# Get checksum as well
grep ^checksum "$prgdir/Cargo.lock" | grep \" | cut -d \" -f2- | tr -d \" > checksums

echo "$download_field"='"'$URL \\ > DOWNLOADS

# Generating depsgood; name of crate with suffix and version info
while read -r line; do
  # Even-numbered lines in the deps document are version numbers
  linemod=$((linecount % 2))
  if [ "$linemod" = 0 ]; then
    echo '          '"$WEBADDR$line/$line" | tr \\n \- >> DOWNLOADS
  else
    echo "$line".crate \\ >> DOWNLOADS
  fi

  if [ "$linemod" = 0 ]; then
    echo $line | tr \\n \- >> depsgood
  else
    echo $line.crate >> depsgood
  fi
  linecount=$((linecount + 1))
done < deps

# Don't actually use crates without checksums (not for download)
grep -v -e ^$ -e ^# "$prgdir/Cargo.lock" > ignore1
cat ignore1 | tr -d \\n > ignore2
sed -i 's|package]]|package]]\n|g' ignore2
grep -v "checksum =" ignore2 > ignore3
grep ^name ignore3 > ignore4
while read -r line; do
  echo $line | cut -d\" -f2- | cut -d\" -f-3 >> ignore
done < ignore4
sed -i 's|"version = "|-|g' ignore
sed -i 's|$|.crate|g' ignore
sed -i 's|^| -e |g' ignore
cat ignore | tr -d \\n > greparg

# Use constructed grep argument to ignore
if [ $(cat greparg | wc -c) -gt 0 ]; then
  grep -v $(cat greparg) depsgood > depsgood2
  grep -v $(cat greparg) DOWNLOADS > DOWNLOADS2
  mv depsgood2 depsgood
  mv DOWNLOADS2 DOWNLOADS
fi
sed -i '$ s| \\|"|' DOWNLOADS

# Quick cleanup
rm -f ignore*

source ./DOWNLOADS
mkdir -p CRATES
cd CRATES
wget ${!download_field} || exit
cd ..

# Using depsgood, check sha256sum
COUNT=0
while read -r crate; do
  sha256=$(sha256sum CRATES/$crate | cut -d' ' -f-1)
  COUNT=$((COUNT + 1))
  cksum=$(head -n $COUNT checksums | tac | head -n 1)
  [ $sha256 != $cksum ] && echo $crate has a bad sha256sum! && exit
done < depsgood

echo "$md5_field"='"'$(md5sum "$archive" | cut -d' ' -f-1) \\ > MD5SUMS

# Getting md5sums based on depsgood list (ensures the sums don't get mixed up)
while read -r crate; do
  md5=$(md5sum CRATES/$crate | cut -d' ' -f-1)
  echo '        '$md5 \\ >> MD5SUMS
done < depsgood
sed -i '$ s| \\|"|' MD5SUMS

# Putting $PRGNAM.info together - field order/placement matches whichever
# of DOWNLOAD/DOWNLOAD_x86_64 is the "real" one, exactly as the two
# separate scripts this was merged from did.
if [ "$X86_64_ONLY" = 1 ]; then
  cat << EOF > $PRGNAM.info
PRGNAM="$PRGNAM"
VERSION="$VERSION"
HOMEPAGE="$HOMEPAGE"
DOWNLOAD="UNSUPPORTED"
MD5SUM="UNSUPPORTED"
$(cat DOWNLOADS MD5SUMS)
REQUIRES="$REQUIRES"
MAINTAINER="$MAINTAINER"
EMAIL="$EMAIL"
EOF
else
  cat << EOF > $PRGNAM.info
PRGNAM="$PRGNAM"
VERSION="$VERSION"
HOMEPAGE="$HOMEPAGE"
$(cat DOWNLOADS MD5SUMS)
DOWNLOAD_x86_64=""
MD5SUM_x86_64=""
REQUIRES="$REQUIRES"
MAINTAINER="$MAINTAINER"
EMAIL="$EMAIL"
EOF
fi

# Cleaning up; see the DEBUG directory for intermediate documents.
mkdir DEBUG
mv DOWNLOADS MD5SUMS deps depsgood checksums greparg DEBUG/
