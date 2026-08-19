#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
swift build --package-path "$REPO_ROOT/helper" --product claudio >/dev/null
CLI="$REPO_ROOT/helper/.build/debug/claudio"
TEST_AREA="$(mktemp -d "${TMPDIR:-/tmp}/claudio-cli-contract.XXXXXX")"
cleanup() { rm -rf "$TEST_AREA"; }
trap cleanup EXIT

RUNTIME_ROOT="$TEST_AREA/runtime"
mkdir -p "$RUNTIME_ROOT/packs/contract-pack"
printf '%s' 'audio' > "$RUNTIME_ROOT/packs/contract-pack/stop.mp3"
printf '%s\n' '{ "id": "contract-pack", "events": { "stop": "stop.mp3" } }' \
  > "$RUNTIME_ROOT/packs/contract-pack/manifest.json"
printf '%s\n' '{ "selected_pack": "contract-pack", "master_volume": 0.8, "events": {} }' \
  > "$RUNTIME_ROOT/config.json"

run_case() {
  local name="$1"
  local expected="$2"
  local home="$TEST_AREA/$name/home"
  mkdir -p "$home/.claude"
  shift 2
  "$@" "$home"
  local output
  output="$(umask 000; CLAUDIO_TEST_ROOT="$RUNTIME_ROOT" CLAUDIO_TEST_HOME="$home" "$CLI" install)"
  grep -F "$expected" <<<"$output" >/dev/null
  test "$(stat -f '%Lp' "$RUNTIME_ROOT")" = "700"
}

fresh_fixture() { :; }
existing_fixture() {
  local home="$1"
  printf '%s\n' '{ "theme": "dark" }' > "$home/.claude/settings.json"
  chmod 0640 "$home/.claude/settings.json"
}
preserved_fixture() {
  local home="$1"
  printf '%s\n' '{ "theme": "dark" }' > "$home/.claude/settings.json"
  printf '%s\n' '{ "preserved": true }' > "$home/.claude/settings.json.claudio.bak"
  chmod 0600 "$home/.claude/settings.json.claudio.bak"
}

run_case fresh '无需创建备份' fresh_fixture
run_case existing '已创建一次性备份' existing_fixture
test "$(stat -f '%Lp' "$TEST_AREA/existing/home/.claude/settings.json.claudio.bak")" = "640"
run_case preserved '已保留已有一次性备份' preserved_fixture

swift build -c release --package-path "$REPO_ROOT/helper" --product claudio >/dev/null
if strings "$REPO_ROOT/helper/.build/release/claudio" | grep -F 'CLAUDIO_TEST_HOME' >/dev/null; then
  echo 'Release binary unexpectedly contains CLAUDIO_TEST_HOME' >&2
  exit 1
fi

echo 'legacy install CLI contract passed'
