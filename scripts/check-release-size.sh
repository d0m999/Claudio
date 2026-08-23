#!/usr/bin/env bash
# Release bundle executable-size contract. Budgets are per Mach-O architecture so the same gate
# applies to local arm64 bundles and CI's arm64+x86_64 universal bundle.
set -euo pipefail

APP="${1:-dist/claudi0.app}"
GUI_BINARY="$APP/Contents/MacOS/claudi0-app"
HELPER_BINARY="$APP/Contents/Resources/bin/claudi0"
LEGACY_HELPER_ALIAS="$APP/Contents/Resources/bin/claudio"

GUI_BYTES_PER_ARCH="${CLAUDIO_GUI_BYTES_PER_ARCH:-5500000}"
HELPER_BYTES_PER_ARCH="${CLAUDIO_HELPER_BYTES_PER_ARCH:-3250000}"
NON_EXECUTABLE_BUNDLE_BYTES="${CLAUDIO_NON_EXECUTABLE_BUNDLE_BYTES:-1000000}"
LIPO_BIN="${CLAUDIO_LIPO_BIN:-lipo}"

for path in "$GUI_BINARY" "$HELPER_BINARY"; do
  if [ ! -f "$path" ]; then
    echo "❌ 缺少 Release 可执行文件：$path" >&2
    exit 1
  fi
done

if [ ! -L "$LEGACY_HELPER_ALIAS" ]; then
  echo "❌ legacy helper 必须是相对符号链接，不能再复制一份 Mach-O：$LEGACY_HELPER_ALIAS" >&2
  exit 1
fi
if [ "$(readlink "$LEGACY_HELPER_ALIAS")" != "claudi0" ]; then
  echo "❌ legacy helper 链接必须精确指向同目录的 claudi0" >&2
  exit 1
fi

GUI_ARCHS="$("$LIPO_BIN" -archs "$GUI_BINARY")"
HELPER_ARCHS="$("$LIPO_BIN" -archs "$HELPER_BINARY")"
if [ "$GUI_ARCHS" != "$HELPER_ARCHS" ]; then
  echo "❌ GUI/helper 架构不一致：GUI=[$GUI_ARCHS] helper=[$HELPER_ARCHS]" >&2
  exit 1
fi

ARCH_COUNT="$(printf '%s\n' "$GUI_ARCHS" | awk '{print NF}')"
if [ "$ARCH_COUNT" -lt 1 ]; then
  echo "❌ 无法识别 Mach-O 架构：$GUI_BINARY" >&2
  exit 1
fi

check_binary_budget() {
  local label="$1"
  local path="$2"
  local per_arch_budget="$3"
  local arch slice actual
  for arch in $GUI_ARCHS; do
    if [ "$ARCH_COUNT" -eq 1 ]; then
      slice="$path"
    else
      slice="$SLICE_DIR/$(basename "$path").$arch"
      "$LIPO_BIN" "$path" -thin "$arch" -output "$slice"
    fi
    actual="$(stat -f '%z' "$slice")"
    if [ "$actual" -gt "$per_arch_budget" ]; then
      echo "❌ $label [$arch] 超出体积预算：${actual} B > ${per_arch_budget} B" >&2
      exit 1
    fi
    echo "✅ ${label} [$arch]：${actual} B / ${per_arch_budget} B"
  done
}

SLICE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/claudio-release-slices.XXXXXX")"
trap 'rm -rf "$SLICE_DIR"' EXIT

check_binary_budget "claudi0-app" "$GUI_BINARY" "$GUI_BYTES_PER_ARCH"
check_binary_budget "claudi0 helper" "$HELPER_BINARY" "$HELPER_BYTES_PER_ARCH"

BUNDLE_BYTES="$(find "$APP" -type f -exec stat -f '%z' {} + | awk '{sum += $1} END {print sum + 0}')"
GUI_FILE_BYTES="$(stat -f '%z' "$GUI_BINARY")"
HELPER_FILE_BYTES="$(stat -f '%z' "$HELPER_BINARY")"
NON_EXECUTABLE_BYTES=$((BUNDLE_BYTES - GUI_FILE_BYTES - HELPER_FILE_BYTES))
if [ "$NON_EXECUTABLE_BYTES" -gt "$NON_EXECUTABLE_BUNDLE_BYTES" ]; then
  echo "❌ 非可执行资源超出体积预算：${NON_EXECUTABLE_BYTES} B > ${NON_EXECUTABLE_BUNDLE_BYTES} B" >&2
  exit 1
fi
echo "✅ 非可执行资源：${NON_EXECUTABLE_BYTES} B / ${NON_EXECUTABLE_BUNDLE_BYTES} B"

BUNDLE_MAXIMUM=$(((GUI_BYTES_PER_ARCH + HELPER_BYTES_PER_ARCH) * ARCH_COUNT + NON_EXECUTABLE_BUNDLE_BYTES))
if [ "$BUNDLE_BYTES" -gt "$BUNDLE_MAXIMUM" ]; then
  echo "❌ app bundle 超出体积预算：${BUNDLE_BYTES} B > ${BUNDLE_MAXIMUM} B" >&2
  exit 1
fi
echo "✅ app bundle 正规文件合计：${BUNDLE_BYTES} B / ${BUNDLE_MAXIMUM} B"
