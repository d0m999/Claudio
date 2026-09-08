#!/usr/bin/env bash
# Validate and copy the explicitly approved first-party sound packs. Candidate directories may live
# beside the approved set for listening, but their presence alone never authorizes distribution.
# The destination must be new or empty so an older assembly cannot retain an unapproved pack.
set -euo pipefail

SOURCE_ROOT="${1:-packs}"
DESTINATION_ROOT="${2:-}"

if [[ -z "$DESTINATION_ROOT" ]]; then
    echo "usage: $0 <source-packs-directory> <destination-packs-directory>" >&2
    exit 2
fi
while [[ "$DESTINATION_ROOT" != "/" && "$DESTINATION_ROOT" == */ ]]; do
    DESTINATION_ROOT="${DESTINATION_ROOT%/}"
done
if [[ ! -d "$SOURCE_ROOT" || -L "$SOURCE_ROOT" ]]; then
    echo "❌ bundled packs source must be a real directory: $SOURCE_ROOT" >&2
    exit 1
fi
if [[ ! -f "$SOURCE_ROOT/LICENSES.md" || -L "$SOURCE_ROOT/LICENSES.md" || ! -s "$SOURCE_ROOT/LICENSES.md" ]]; then
    echo "❌ bundled packs license ledger is missing, empty, or a symlink: $SOURCE_ROOT/LICENSES.md" >&2
    exit 1
fi
SELECTION_FILE="$SOURCE_ROOT/bundled-pack-selection.json"
if [[ ! -f "$SELECTION_FILE" || -L "$SELECTION_FILE" || ! -s "$SELECTION_FILE" ]]; then
    echo "❌ bundled pack selection is missing, empty, or a symlink: $SELECTION_FILE" >&2
    exit 1
fi
if ! jq -e '
    type == "object"
    and .schema == 1
    and .purpose == "claudi0 default bundled sound pack selection"
    and (.selected_pack_ids | type == "array" and length > 0)
    and ([.selected_pack_ids[] |
        (type == "string" and test("^[a-z0-9][a-z0-9-]*$"))
    ] | all)
    and ((.selected_pack_ids | unique | length) == (.selected_pack_ids | length))
' "$SELECTION_FILE" >/dev/null; then
    echo "❌ invalid bundled pack selection: $SELECTION_FILE" >&2
    exit 1
fi

if [[ -e "$DESTINATION_ROOT" || -L "$DESTINATION_ROOT" ]]; then
    if [[ ! -d "$DESTINATION_ROOT" || -L "$DESTINATION_ROOT" ]]; then
        echo "❌ bundled packs destination must be a real directory: $DESTINATION_ROOT" >&2
        exit 1
    fi
    shopt -s nullglob dotglob
    destination_entries=("$DESTINATION_ROOT"/*)
    shopt -u nullglob dotglob
    if [[ "${#destination_entries[@]}" -ne 0 ]]; then
        echo "❌ bundled packs destination must be empty: $DESTINATION_ROOT" >&2
        exit 1
    fi
else
    mkdir -p "$DESTINATION_ROOT"
fi
pack_count=0

while IFS= read -r entry_name; do
    entry="$SOURCE_ROOT/$entry_name"
    if [[ -L "$entry" || ! -d "$entry" ]]; then
        echo "❌ approved bundled pack must be a real directory: $entry" >&2
        exit 1
    fi

    manifest="$entry/manifest.json"
    if [[ -L "$manifest" || ! -f "$manifest" || ! -s "$manifest" ]]; then
        echo "❌ pack manifest is missing, empty, or a symlink: $manifest" >&2
        exit 1
    fi
    if ! jq -e '
        type == "object"
        and .schema == 1
        and (.id | type == "string" and test("^[a-z0-9][a-z0-9-]*$"))
        and (.name | type == "string" and length > 0)
        and (.author | type == "string" and length > 0)
        and (.license == "CC0-1.0")
        and (.version | type == "string" and length > 0)
        and (.events | type == "object" and length > 0)
        and ([
            .events | to_entries[] |
            ((.key == "task_start"
                or .key == "stop"
                or .key == "stop_failure"
                or .key == "notification"
                or .key == "subagent_stop")
              and (.value | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$")))
        ] | all)
    ' "$manifest" >/dev/null; then
        echo "❌ invalid bundled pack manifest: $manifest" >&2
        exit 1
    fi

    pack_id="$(jq -er '.id' "$manifest")"
    if [[ "$pack_id" != "$entry_name" ]]; then
        echo "❌ pack directory/id mismatch: directory=$entry_name id=$pack_id" >&2
        exit 1
    fi

    audio_count=0
    while IFS= read -r audio_name; do
        case "${audio_name##*.}" in
            wav|mp3|aiff|m4a) ;;
            *)
                echo "❌ unsupported bundled audio extension in $manifest: $audio_name" >&2
                exit 1
                ;;
        esac
        audio_path="$entry/$audio_name"
        if [[ -L "$audio_path" || ! -f "$audio_path" || ! -s "$audio_path" ]]; then
            echo "❌ declared bundled audio is missing, empty, or a symlink: $audio_path" >&2
            exit 1
        fi
        audio_count=$((audio_count + 1))
    done < <(jq -r '.events[]' "$manifest")
    if [[ "$audio_count" -eq 0 ]]; then
        echo "❌ bundled pack declares no audio files: $manifest" >&2
        exit 1
    fi

    cp -R "$entry" "$DESTINATION_ROOT/$entry_name"
    pack_count=$((pack_count + 1))
done < <(jq -r '.selected_pack_ids[]' "$SELECTION_FILE")

if [[ "$pack_count" -eq 0 ]]; then
    echo "❌ no bundled sound packs found in $SOURCE_ROOT" >&2
    exit 1
fi

cp "$SOURCE_ROOT/LICENSES.md" "$DESTINATION_ROOT/LICENSES.md"
cp "$SELECTION_FILE" "$DESTINATION_ROOT/bundled-pack-selection.json"
echo "✅ validated and copied $pack_count bundled sound pack(s)"
