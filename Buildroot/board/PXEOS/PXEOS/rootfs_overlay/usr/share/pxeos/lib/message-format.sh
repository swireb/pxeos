#!/usr/bin/env bash
# Display-only vocabulary. Never use this output for task or disk decisions.
rootpxe_message_catalog=/usr/share/pxeos/pxe_messages.json
[[ -r $rootpxe_message_catalog ]] || rootpxe_message_catalog="${BASH_SOURCE[0]%/*}/../pxe_messages.json"

rootpxe_message_text() {
    local original="$1" translated
    if [[ -r ${rootpxe_message_catalog:-} ]] && command -v jq >/dev/null 2>&1; then
        translated=$(jq -er --arg original "$original" 'select(.version == 1) | .messages[$original] | select(type == "string" and length > 0)' "$rootpxe_message_catalog" 2>/dev/null) && { printf '%s' "$translated"; return 0; }
    fi
    printf '%s' "$original"
}

rootpxe_display_message() {
    rootpxe_format_message "$1" "${2:-}" "${3:-}" zh
}

rootpxe_console_summary() {
    rootpxe_format_message "$1" "${2:-}" "${3:-}" console
}

rootpxe_format_message() {
    local raw="$1" stage="${2:-}" code="${3:-}" locale="${4:-zh}" display
    local fallback_zh='执行异常'
    if [[ -r ${rootpxe_message_catalog:-} ]] && command -v jq >/dev/null 2>&1; then
        display=$(printf '%s' "$raw" | jq -Rrs --arg stage "$stage" --arg code "$code" --arg locale "$locale" --slurpfile catalogs "$rootpxe_message_catalog" '
          . as $raw | ($raw|ascii_downcase) as $displayRaw | $catalogs[0] as $root | (if $locale == "console" then $root.console else $root end) as $c |
          (if $locale == "console" then ": " else "：" end) as $separator |
          if ($root.version != 1 or ($c.stages|type) != "object" or ($c.codes|type) != "object" or ($c.reasons|type) != "object" or ($c.messages|type) != "object" or ($root.contextReasons|type) != "array" or ($root.legacyPrefixes|type) != "object") then error("catalog") else . end |
          [$displayRaw | match("(^|\\s)(pxeos_stage|code|reason)=([^\\s]*)"; "g") | {key:(.captures[1].string|ascii_upcase), value:.captures[2].string}] as $markers |
          [$displayRaw | match("(^|\\s)(pxeos_stage|code|reason)(?=$|[^A-Za-z0-9_])"; "g")] as $markerKeys |
          [$markers[] | select(.key == "PXEOS_STAGE") | .value|ascii_downcase] as $stages |
          [$markers[] | select(.key == "CODE") | .value|ascii_upcase] as $codes |
          [$markers[] | select(.key == "REASON") | .value|ascii_downcase] as $reasons |
          (if ($stage|gsub("^\\s+|\\s+$"; "")) == "" and ($stages|length) == 1 then $stages[0] else ($stage|ascii_downcase|gsub("^\\s+|\\s+$"; "")) end) as $effectiveStage |
          ($c.stages[$effectiveStage] // "") as $stageText |
          ($code|ascii_upcase|gsub("^\\s+|\\s+$"; "")) as $outerCode |
          (if ($codes|length) == 1 then $codes[0] else $outerCode end) as $effectiveCode |
          ($c.messages["PXEOS 执行异常"] // "Operation failed; check task log") as $generic |
          (if $stageText == "" then $generic else $stageText + $separator + $generic end) as $fallback |
          (if ($markers|length) == 0 then
            [$root.legacyPrefixes|to_entries[] | . as $prefix |
              select(($raw|ascii_downcase|startswith($prefix.key|ascii_downcase)) and
                (($raw|length) == ($prefix.key|length) or
                  (($raw[($prefix.key|length):(($prefix.key|length)+1)]|test("^[A-Za-z0-9_]$"))|not)))] |
              sort_by([-(.key|length),.key]) | .[0].value // ""
            else "" end) as $legacyCode |
          if ($markerKeys|length) != ($markers|length) or ($outerCode != "" and ($outerCode|test("^[A-Za-z][A-Za-z0-9_]{0,127}$")|not)) or any($markers[]; (if .key == "REASON" then (.value|test("^[A-Za-z0-9][A-Za-z0-9_.:+-]{0,255}$")) else (.value|test("^[A-Za-z][A-Za-z0-9_]{0,127}$")) end)|not) or ($stages|length) > 1 or ($codes|length) > 1 or ($reasons|length) > 1 then $fallback
          elif ($codes|length) == 1 and $outerCode != "" and $outerCode != "PXEOS_ERROR" and $outerCode != "PXEOS_FAILED" and $outerCode != $codes[0] then $fallback
          elif ($c.codes[$effectiveCode] // "") != "" then
            if ($reasons|length) == 1 and ($c.reasons[$reasons[0]] // "") != "" and (any($root.contextReasons[]; . == $reasons[0])|not) then $c.reasons[$reasons[0]] else $c.codes[$effectiveCode] end
          elif ($codes|length) != 0 or ($reasons|length) != 0 or ($outerCode != "" and $outerCode != "PXEOS_ERROR" and $outerCode != "PXEOS_FAILED") then $fallback
          elif ($c.codes[$legacyCode] // "") != "" then $c.codes[$legacyCode]
          elif ($c.messages[$raw] // "") != "" then $c.messages[$raw]
          elif any($c.messages[]; . == $raw) then $raw
          elif ($raw | test("^inventory fields=[0-9]+$")) then $c.messages["inventory fields="]
          elif ($raw | test("^progress=[0-9]+$")) then (if $stageText == "" then $c.messages["stage="] else $stageText end) + $separator + $c.messages["progress="]
          elif $raw == ("stage=" + $effectiveStage) then (if $stageText == "" then $c.messages["stage="] else $stageText end)
          else $fallback end |
          select(type == "string" and length > 0)
        ' 2>/dev/null) && { printf '%s' "$display"; return 0; }
    fi
    if [[ $locale == console ]]; then
        printf '%s' 'Operation failed; check task log'
    else
        # Return display data; physical consoles always use the ASCII branch.
        printf '%s' "$fallback_zh"
    fi
}
