#!/usr/bin/env bash
# Run one operation from a repository-owned output directory whose inode stays pinned as cwd.

claudio_output_directory_identity() {
    /usr/bin/stat -f '%d:%i' -- "$1"
}

claudio_assert_pinned_output_binding() {
    local candidate="$1"
    local expected_identity="$2"
    local current_identity

    if [[ -L "$candidate" || ! -d "$candidate" ]]; then
        echo "❌ output directory changed after validation: $candidate" >&2
        return 1
    fi
    current_identity="$(claudio_output_directory_identity "$candidate")" || {
        echo "❌ cannot re-read output directory identity after validation: $candidate" >&2
        return 1
    }
    if [[ "$current_identity" != "$expected_identity" ]]; then
        echo "❌ output directory changed after validation: $candidate" >&2
        return 1
    fi
}

claudio_with_pinned_output_directory() {
    local repository_root="$1"
    local relative_output="$2"
    shift 2

    local candidate
    local command_status
    local expected_identity="${CLAUDIO_PINNED_OUTPUT_DIRECTORY_IDENTITY:-}"
    local pinned_identity
    local pinned_physical
    local repository_root_physical

    repository_root_physical="$(cd -P -- "$repository_root" && pwd -P)" || {
        echo "❌ cannot resolve repository root for local output" >&2
        return 1
    }
    candidate="$repository_root_physical/$relative_output"

    if [[ -L "$candidate" ]]; then
        echo "❌ output directory must not be a symbolic link: $relative_output" >&2
        return 1
    fi
    if [[ -e "$candidate" && ! -d "$candidate" ]]; then
        echo "❌ output path must be a directory: $relative_output" >&2
        return 1
    fi
    mkdir -p -- "$candidate"

    (
        cd -P -- "$candidate" || {
            echo "❌ cannot enter output directory: $relative_output" >&2
            return 1
        }
        pinned_physical="$(pwd -P)"
        if [[ "$pinned_physical" != "$candidate" ]]; then
            echo "❌ output directory escapes the repository: $relative_output" >&2
            return 1
        fi
        pinned_identity="$(claudio_output_directory_identity ".")" || {
            echo "❌ cannot read pinned output directory identity: $relative_output" >&2
            return 1
        }
        if [[ -n "$expected_identity" && "$pinned_identity" != "$expected_identity" ]]; then
            echo "❌ output directory changed after validation: $candidate" >&2
            return 1
        fi

        "$@"
        command_status=$?
        if [[ $command_status -ne 0 ]]; then
            return "$command_status"
        fi
        claudio_assert_pinned_output_binding "$candidate" "$pinned_identity"
    )
}
