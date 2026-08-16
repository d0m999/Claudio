#!/usr/bin/env bash
# Validate and copy every distributable first-party sound pack. Any new top-level pack directory is
# therefore either included or fails loudly; release assembly cannot silently keep shipping a
# hard-coded subset.
set -euo pipefail

SOURCE_ROOT="${1:-packs}"
DESTINATION_ROOT="${2:-}"

if [[ -z "$DESTINATION_ROOT" ]]; then
    echo "usage: $0 <source-packs-directory> <destination-packs-directory>" >&2
    exit 2
fi
if [[ ! -d "$SOURCE_ROOT" || -L "$SOURCE_ROOT" ]]; then
    echo "❌ bundled packs source must be a real directory: $SOURCE_ROOT" >&2
    exit 1
fi
if [[ ! -f "$SOURCE_ROOT/LICENSES.md" || -L "$SOURCE_ROOT/LICENSES.md" || ! -s "$SOURCE_ROOT/LICENSES.md" ]]; then
    echo "❌ bundled packs license ledger is missing, empty, or a symlink: $SOURCE_ROOT/LICENSES.md" >&2
    exit 1
fi

mkdir -p "$DESTINATION_ROOT"
pack_count=0
shopt -s nullglob dotglob
entries=("$SOURCE_ROOT"/*)
shopt -u nullglob dotglob

for entry in "${entries[@]}"; do
    entry_name="$(basename "$entry")"
    case "$entry_name" in
        LICENSES.md|license-snapshots)
            continue
            ;;
    esac

    if [[ -L "$entry" || ! -d "$entry" ]]; then
        echo "❌ unexpected bundled packs entry (expected a real pack directory): $entry" >&2
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
done

if [[ "$pack_count" -eq 0 ]]; then
    echo "❌ no bundled sound packs found in $SOURCE_ROOT" >&2
    exit 1
fi

cp "$SOURCE_ROOT/LICENSES.md" "$DESTINATION_ROOT/LICENSES.md"
echo "✅ validated and copied $pack_count bundled sound pack(s)"
