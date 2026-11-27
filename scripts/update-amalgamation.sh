#!/bin/bash

# update-amalgamation.sh replaces the libvsql C in Sources/CVSQL with the C from
# a vsql amalgamation (vsql-VERSION-amalgamation.zip from a vsql release, or
# the folder it unzips to). With no arguments, or a version, the zip is
# downloaded from the latest (or that) vsql release:
#
#   scripts/update-amalgamation.sh
#   scripts/update-amalgamation.sh v1.2.3
#   scripts/update-amalgamation.sh vsql-v1.2.3-amalgamation.zip
#
# Only what's needed to compile libvsql is copied: libvsql.c (one file with the
# C for every OS and architecture), libvsql.h and the licenses. The libraries
# that V used to link libvsql on each OS (LIBVSQL_FLAGS in vsql.mk) are checked
# against the ones that Package.swift links, since they have to be changed by
# hand.

set -euo pipefail

source="${1:-latest}"
root="$(cd "$(dirname "$0")/.." && pwd)"
target="$root/Sources/CVSQL"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

if [ ! -e "$source" ]; then
  version="$source"
  if [ "$version" = latest ]; then
    version="$(curl -fsSL https://api.github.com/repos/elliotchance/vsql/releases/latest |
      sed -n 's/^ *"tag_name": *"\(.*\)",$/\1/p')"
  fi
  zip="vsql-$version-amalgamation.zip"
  echo "Downloading $zip"
  curl -fsSL -o "$tmp/$zip" \
    "https://github.com/elliotchance/vsql/releases/download/$version/$zip"
  source="$tmp/$zip"
fi

if [ -f "$source" ]; then
  unzip -q "$source" -d "$tmp/unzipped"
  source="$(dirname "$(find "$tmp/unzipped" -name libvsql.h | head -1)")"
fi

if [ ! -f "$source/libvsql.h" ] || [ ! -f "$source/libvsql.c" ]; then
  echo "$1 isn't a vsql amalgamation (there's no libvsql.h or libvsql.c)" >&2
  exit 1
fi

# The libraries in LIBVSQL_FLAGS for each OS (the architectures are the same).
libraries() {
  local os="$1"
  sed -n "/^ifeq (\$(VSQL_OS)_\$(VSQL_ARCH),${os}_amd64)/,/^endif/p" "$source/vsql.mk" |
    sed -n 's/^ *LIBVSQL_FLAGS *[:+]*= *//p' | tr ' ' '\n' | sed -n 's/^-l//p' | sort | tr '\n' ' '
}
expected() {
  echo "$1" | tr ' ' '\n' | sed '/^$/d' | sort | tr '\n' ' '
}
check() {
  local os="$1" want got
  want="$(expected "$2")"
  got="$(libraries "$os")"
  if [ "$got" != "$want" ]; then
    echo "libvsql links different libraries on $os: $got(Package.swift links $want)." >&2
    echo "Update the linkerSettings in Package.swift." >&2
    exit 1
  fi
}
check linux "dl pthread m"
check macos "dl pthread m"
check windows "dbghelp user32 winmm ws2_32 advapi32 bcrypt"

mkdir -p "$target/include" "$target/amalgamation"
cp "$source/libvsql.h" "$target/include/"
for name in libvsql.c LICENSE LICENSE-V; do
  cp "$source/$name" "$target/amalgamation/"
done

echo "Updated $target from ${1:-the latest release}"
