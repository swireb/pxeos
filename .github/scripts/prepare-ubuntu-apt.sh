#!/usr/bin/env bash
set -euo pipefail

sources_file=${1:-/etc/apt/sources.list.d/ubuntu.sources}
archive='https://archive.ubuntu.com/ubuntu/'
[[ -e $sources_file ]] || exit 0

updated_sources=$(mktemp)
trap 'rm -f -- "$updated_sources"' EXIT
# Replace only the runner's complete mirror-list URI on a deb822 URIs field.
uri_field='[Uu][Rr][Ii][Ss]:'
sed -E "/^$uri_field/ {
    :replace
    s#(^$uri_field[[:blank:]]*|[[:blank:]])mirror\+file:/etc/apt/apt-mirrors\.txt([[:space:]]|$)#\1$archive\2#
    t replace
}" "$sources_file" > "$updated_sources"

if cmp -s "$sources_file" "$updated_sources"; then
    exit 0
else
    cmp_status=$?
    [[ $cmp_status == 1 ]] || exit "$cmp_status"
fi

sudo tee "$sources_file" < "$updated_sources" > /dev/null
printf 'Switched Ubuntu APT mirror to %s\n' "$archive"
sudo apt-get --error-on=any update
