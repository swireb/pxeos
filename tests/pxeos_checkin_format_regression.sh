#!/usr/bin/env bash
# Exercise actual JSON parser; only context lifecycle and unrelated policies mocked.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
checkin=$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/bin/pxeos.checkin
for function in rootpxe_json_get_string rootpxe_json_get_text rootpxe_json_assign rootpxe_json_assign_text rootpxe_validate_json_storage rootpxe_normalize_compression_level rootpxe_validate_pigz_compression rootpxe_apply_json_checkin; do
 eval "$(sed -n "/^${function}() *{/,/^}/p" "$checkin")"
done
rootpxe_cloud_init_cleanup_private(){ :; }
rootpxe_storage_apply_context(){ :; }
rootpxe_apply_json_deployment_identity_policy(){ :; }
rootpxe_apply_json_partition_inventory(){ :; }
rootpxe_apply_json_cloud_init(){ :; }
# Storage-only server responses intentionally omit all image codec fields.
recovery='{"taskId":42,"type":"deploy","pxeType":"down","executionToken":"11111111111111111111111111111111","progressAttempt":2,"img":"image","protocol":"nfs","storageip":"192.0.2.1","exportPath":"/images","storageOnly":true,"storageAccess":{"storageOnly":true}}'
rootpxe_apply_json_checkin "$recovery"
[[ $rootpxe_storage_only == yes && -z $img_format && -z $pigz_comp ]]
for format in 0 5; do
 for level in 0 1 9; do
  document=$(jq -c --argjson format "$format" --argjson level "$level" '.storageOnly=false | .storageAccess.storageOnly=false | .imgFormat=$format | .compressionLevel=$level | .imgType="mps" | .imgPartitionType="all" | .osid=9' <<<"$recovery")
  rootpxe_apply_json_checkin "$document"
  expected=0; [[ $level == 0 ]] || expected=-$level
  [[ $img_format == "$format" && $pigz_comp == "$expected" ]]
 done
done
for format in 1 2 3 4 6 5.5; do
 invalid=$(jq -c --argjson format "$format" '.imgFormat=$format' <<<"$document")
 if rootpxe_apply_json_checkin "$invalid"; then exit 1; fi
done
for level in -1 10 1.5; do
 invalid=$(jq -c --argjson level "$level" '.compressionLevel=$level' <<<"$document")
 if rootpxe_apply_json_checkin "$invalid"; then exit 1; fi
done
printf 'PASS: image codec parser preserves zero and rejects retired formats; storage-only recovery needs no codec\n'
