#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
funcs="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/funcs.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"; rm -f -- "${rootpxe_resolved_layout_file:-}"' EXIT
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
for name in rootpxe_validate_deployment_layout rootpxe_canonical_json_hash; do
    eval "$(awk -v name="$name" '$0 ~ "^" name "\\(\\)" { found=1 } found {print} found && /^}/ {exit}' "$funcs")"
done
# This fixture isolates the real jq physical resolver, not LVM or disk IO.
rootpxe_validate_lvm_deployment_layout(){ return 0; }
blockdev(){ [[ $1 == --getsize64 ]] && printf '%s\n' "$((800 * 4096))"; }
cat >"$tmp/schema" <<'EOF'
{"version":2,"partitionTable":"mbr","originalDiskBytes":1638400,"logicalSectorBytes":4096,"partitions":[
 {"number":1,"kind":"primary","startSectors":0,"originalSectors":64,"minSectors":64,"role":"boot","resizable":false},
 {"number":3,"kind":"extended","startSectors":64,"originalSectors":256,"minSectors":256,"role":"extended_container","resizable":false,"logicalNumbers":[5,6],"ebrReservedSectors":2},
 {"number":4,"kind":"primary","startSectors":320,"originalSectors":64,"minSectors":64,"role":"recovery","fs":"ntfs","resizable":true},
 {"number":5,"kind":"logical","parentNumber":3,"startSectors":66,"originalSectors":64,"minSectors":64,"role":"data","fs":"ntfs","resizable":true},
 {"number":6,"kind":"logical","parentNumber":3,"startSectors":132,"originalSectors":64,"minSectors":64,"role":"data","fs":"ntfs","resizable":true}]}
EOF
schemaRevision=1; schemaHash=$(rootpxe_canonical_json_hash "$tmp/schema")
jq -n --arg hash "$schemaHash" '{schemaHash:$hash,partitions:[{number:1,mode:"original"},{number:3,mode:"derived"},{number:4,mode:"original"},{number:5,mode:"fixed",fixedBytes:524288},{number:6,mode:"remaining"}]}' >"$tmp/layout"
rootpxe_validate_deployment_layout /dev/fake "$tmp/schema" "$tmp/layout" || fail resolution
jq -e '([.[]|select(.number==6)][0].resolvedSectors == 384) and ([.[]|select(.number==3)][0].resolvedSectors == 578) and all(.[]|select(.kind!="extended"); .startSectors % 64 == 0)' "$rootpxe_resolved_layout_file" >/dev/null || fail frontend-runtime-geometry-parity
printf 'PASS: MBR logical alignment and remaining-space parity\n'
