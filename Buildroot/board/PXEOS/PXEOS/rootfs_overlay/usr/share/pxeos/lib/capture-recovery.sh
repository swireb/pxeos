#!/bin/bash
# Capture publication recovery.  This file is intentionally source-only: the
# caller supplies the storage/path/finalize primitives from funcs.sh.

rootpxe_capture_recovery_fail() {
    rootpxe_capture_resume_error_code="$1"
    rootpxe_capture_resume_error_reason="$2"
    return 1
}

rootpxe_capture_recovery_json_file() {
    local file="$1"
    [[ -f $file && ! -L $file && -s $file ]] || return 1
    jq -e 'type == "object"' "$file" >/dev/null 2>&1
}

rootpxe_capture_recovery_inventory_file() {
    local file="$1"
    rootpxe_capture_recovery_json_file "$file" || return 1
    jq -e '.version == 1 and (.disks|type == "array" and length > 0) and all(.disks[]; (.number|type == "number" and . > 0) and (.sourceDevice|type == "string" and length > 0) and (.partitionTable|IN("gpt","mbr","none")) and (.originalDiskBytes|type == "number" and . > 0) and (.logicalSectorBytes|type == "number" and . > 0) and (.physicalSectorBytes|type == "number" and . > 0) and (.partitions|type == "array"))' "$file" >/dev/null 2>&1
}

rootpxe_capture_recovery_schema_file() {
    local file="$1"
    rootpxe_capture_recovery_json_file "$file" || return 1
    jq -e '(.version == 1 or .version == 2) and (.partitionTable|IN("gpt","mbr")) and (.originalDiskBytes|type == "number" and . > 0) and (.logicalSectorBytes|type == "number" and . > 0) and (.physicalSectorBytes|type == "number" and . > 0) and (.minDeployBytes|type == "number" and . > 0) and (.partitions|type == "array" and length > 0) and all(.partitions[]; (.number|type == "number" and . > 0) and (.startSectors|type == "number" and . >= 0) and (.originalSectors|type == "number" and . > 0) and (.minSectors|type == "number" and . > 0))' "$file" >/dev/null 2>&1
}

rootpxe_capture_recovery_copy_private() {
    local source="$1" variable="$2" temporary
    temporary=$(mktemp "${TMPDIR:-/tmp}/rootpxe-capture-metadata.XXXXXX") || return 1
    chmod 600 "$temporary" || { rm -f -- "$temporary"; return 1; }
    cp -- "$source" "$temporary" || { rm -f -- "$temporary"; return 1; }
    chmod 600 "$temporary" || { rm -f -- "$temporary"; return 1; }
    printf -v "$variable" '%s' "$temporary"
    export "$variable"
}

rootpxe_capture_resume_cleanup() {
    local file
    for file in "${rootpxe_partition_inventory_file:-}" "${rootpxe_original_schema_file:-}"; do
        [[ $file == "${TMPDIR:-/tmp}"/rootpxe-capture-metadata.* && -f $file && ! -L $file ]] && rm -f -- "$file"
    done
    unset -v rootpxe_partition_inventory_file rootpxe_original_schema_file rootpxe_capture_resume_published
}

rootpxe_capture_artifact_scope() {
    local image_type="$1" scope="${imgPartitionType:-all}"
    case "$image_type" in
        [Nn]|dd) printf '%s\n' all ;;
        mps|mpa)
            case "$scope" in
                all|mbr|[1-9]|[1-9][0-9]*) printf '%s\n' "$scope" ;;
                *) return 1 ;;
            esac
            ;;
        *) return 1 ;;
    esac
}

rootpxe_capture_publish_metadata() {
    local image_path="$1" image_type="$2" inventory schema payload scope
    [[ -d $image_path && ! -L $image_path ]] || return 1
    inventory="$image_path/.rootpxe-partition-inventory.json"
    rootpxe_capture_recovery_inventory_file "$inventory" || return 1
    if [[ $image_type == [Nn] ]]; then
        schema="$image_path/.rootpxe-original-schema.json"
        rootpxe_capture_recovery_schema_file "$schema" || return 1
    fi
    case "$image_type" in [Nn]|mps|mpa|dd) ;; *) return 1;; esac
    scope=$(rootpxe_capture_artifact_scope "$image_type") || return 1
    payload=$(find "$image_path" -xdev -type f ! -name '.rootpxe-capture-taskid' ! -name '.rootpxe-partition-inventory.json' ! -name '.rootpxe-original-schema.json' -size +0c -print -quit 2>/dev/null) || return 1
    [[ -n $payload ]] || return 1
    ! find "$image_path" -xdev -type l -print -quit 2>/dev/null | grep -q . || return 1
    rootpxe_validate_restore_artifacts "$image_path" "$image_type" "$scope" "${schema:-}"
}

rootpxe_capture_resume_published() {
    local relative target parent marker inventory schema
    unset -v rootpxe_capture_resume_published rootpxe_capture_resume_error_code rootpxe_capture_resume_error_reason
    [[ ${type:-} == up ]] || return 1
    relative=$(rootpxe_safe_relative_path "${img:-}") || { rootpxe_capture_recovery_fail CAPTURE_PUBLISHED_PATH_INVALID unsafe_target_path; return 2; }
    target=$(rootpxe_storage_path "$relative") || { rootpxe_capture_recovery_fail CAPTURE_PUBLISHED_PATH_INVALID unsafe_target_path; return 2; }
    parent=$(dirname "$target") || { rootpxe_capture_recovery_fail CAPTURE_PUBLISHED_PATH_INVALID unsafe_target_path; return 2; }
    [[ -d $target && ! -L $target && -d $parent && ! -L $parent ]] || return 1
    marker="$target/.rootpxe-capture-taskid"
    [[ -e $marker || -L $marker ]] || return 1
    rootpxe_capture_marker_matches_task "$marker" "${taskid:-}" || { rootpxe_capture_recovery_fail CAPTURE_PUBLISHED_MARKER_FOREIGN marker_not_owned; return 3; }
    inventory="$target/.rootpxe-partition-inventory.json"
    rootpxe_capture_recovery_inventory_file "$inventory" || { rootpxe_capture_recovery_fail CAPTURE_PUBLISHED_METADATA_MISSING partition_inventory_missing_or_invalid; return 2; }
    rootpxe_capture_recovery_copy_private "$inventory" rootpxe_partition_inventory_file || { rootpxe_capture_recovery_fail CAPTURE_PUBLISHED_METADATA_MISSING partition_inventory_temp_copy_failed; return 2; }
    if [[ ${imgType:-} == [Nn] ]]; then
        schema="$target/.rootpxe-original-schema.json"
        rootpxe_capture_recovery_schema_file "$schema" || { rootpxe_capture_resume_cleanup; rootpxe_capture_recovery_fail CAPTURE_PUBLISHED_METADATA_MISSING original_schema_missing_or_invalid; return 2; }
        rootpxe_capture_recovery_copy_private "$schema" rootpxe_original_schema_file || { rootpxe_capture_resume_cleanup; rootpxe_capture_recovery_fail CAPTURE_PUBLISHED_METADATA_MISSING original_schema_temp_copy_failed; return 2; }
    fi
    rootpxe_capture_publish_metadata "$target" "${imgType:-}" || { rootpxe_capture_resume_cleanup; rootpxe_capture_recovery_fail CAPTURE_PUBLISHED_METADATA_MISSING published_payload_or_metadata_invalid; return 2; }
    rootpxe_capture_set_final_path "$target" || { rootpxe_capture_resume_cleanup; rootpxe_capture_recovery_fail CAPTURE_PUBLISHED_METADATA_MISSING published_size_invalid; return 2; }
    rootpxe_capture_resume_published=1
    export rootpxe_capture_resume_published
    return 0
}
