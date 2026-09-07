#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
lib=${ROOTPXE_IDENTITY_LIB:-"$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/deployment-identity.sh"}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
mkdir -p "$tmp/bin"
cat >"$tmp/plan.json" <<'JSON'
{"plan":{"topology":{"disks":[{"targetDevice":"/dev/nvme0n1","targetBinding":"wwn:disk","partitionTable":"gpt","partitions":[{"targetDevice":"/dev/nvme0n1p1","number":1},{"targetDevice":"/dev/nvme0n1p2","number":2},{"targetDevice":"/dev/nvme0n1p3","number":3},{"targetDevice":"/dev/nvme0n1p4","number":4},{"targetDevice":"/dev/nvme0n1p5","number":5},{"targetDevice":"/dev/nvme0n1p6","number":6}]}]},"disks":[{"targetDevice":"/dev/nvme0n1","partitionTable":"gpt","diskGuid":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","partitions":[{"targetDevice":"/dev/nvme0n1p1","partitionGuid":"11111111-1111-1111-1111-111111111111","filesystem":"vfat","filesystemUuid":"u1"},{"targetDevice":"/dev/nvme0n1p2","partitionGuid":"22222222-2222-2222-2222-222222222222","filesystem":"xfs","filesystemUuid":"u2"},{"targetDevice":"/dev/nvme0n1p3","partitionGuid":"33333333-3333-3333-3333-333333333333","filesystem":"xfs","filesystemUuid":"u3"},{"targetDevice":"/dev/nvme0n1p4","partitionGuid":"44444444-4444-4444-4444-444444444444","filesystem":"xfs","filesystemUuid":"u4"},{"targetDevice":"/dev/nvme0n1p5","partitionGuid":"55555555-5555-5555-5555-555555555555","filesystem":"swap","filesystemUuid":"u5"},{"targetDevice":"/dev/nvme0n1p6","partitionGuid":"66666666-6666-6666-6666-666666666666","filesystem":"xfs","filesystemUuid":"u6"}]}]}}
JSON
cat >"$tmp/bin/sfdisk" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
{"partitiontable":{"id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","partitions":[{"node":"/dev/nvme0n1p1","uuid":"11111111-1111-1111-1111-111111111111"},{"node":"/dev/nvme0n1p2","uuid":"22222222-2222-2222-2222-222222222222"},{"node":"/dev/nvme0n1p3","uuid":"33333333-3333-3333-3333-333333333333"},{"node":"/dev/nvme0n1p4","uuid":"44444444-4444-4444-4444-444444444444"},{"node":"/dev/nvme0n1p5","uuid":"55555555-5555-5555-5555-555555555555"},{"node":"/dev/nvme0n1p6","uuid":"66666666-6666-6666-6666-666666666666"}]}}
JSON
EOF
cat >"$tmp/bin/blkid" <<'EOF'
#!/usr/bin/env bash
for a; do last=$a; done
case "$last" in /dev/nvme0n1p1) echo u1;; /dev/nvme0n1p2) echo u2;; /dev/nvme0n1p3) echo u3;; /dev/nvme0n1p4) echo u4;; /dev/nvme0n1p5) echo u5;; /dev/nvme0n1p6) echo u6;; *) exit 1;; esac
EOF
chmod +x "$tmp/bin/"*; export PATH="$tmp/bin:$PATH"
. "$lib"
rootpxe_deployment_identity_plan_file="$tmp/plan.json"
rootpxe_deployment_identity_target_binding(){ printf 'wwn:disk\n'; }
rootpxe_deployment_identity_linux_storage_plan_applied /dev/nvme0n1 || fail 'matching frozen storage plan was rejected'
cp "$tmp/plan.json" "$tmp/plan.original.json"
for filter in \
  '.plan.disks[0].diskGuid="bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"' \
  '.plan.disks[0].partitions[0].partitionGuid="bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"' \
  '.plan.disks[0].partitions[0].filesystemUuid="wrong-fs"' \
  '.plan.disks[0].partitions[4].filesystemUuid="wrong-swap"'; do
  jq "$filter" "$tmp/plan.original.json" >"$tmp/plan.next.json"
  mv "$tmp/plan.next.json" "$tmp/plan.json"
  if rootpxe_deployment_identity_linux_storage_plan_applied /dev/nvme0n1; then fail "mismatched frozen identifier was accepted: $filter"; fi
done
cp "$tmp/plan.original.json" "$tmp/plan.json"
rootpxe_deployment_identity_target_binding(){ printf 'wrong\n'; }
if rootpxe_deployment_identity_linux_storage_plan_applied /dev/nvme0n1; then fail 'mismatched target binding was accepted'; fi
rootpxe_deployment_identity_target_binding(){ printf 'wwn:disk\n'; }
imgType=mpa
if rootpxe_deployment_identity_linux_storage_plan_applied /dev/nvme0n1; then fail 'MPA storage resume was accepted'; fi
printf 'PASS: PXEOS storage post-restore resume regression\n'
