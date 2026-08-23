#!/usr/bin/env bash
# 真实 CLI 子进程契约：受支持的宿主 hook 无论结果如何，都必须 exit 0 且零输出。
set -euo pipefail

cd "$(dirname "$0")/.."

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/claudio-hook-contract.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

swift build --package-path helper --product claudio >/dev/null
DEBUG_BIN_DIR="$(swift build --package-path helper --product claudio --show-bin-path)"
DEBUG_BIN="$DEBUG_BIN_DIR/claudio"

swift build -c release --package-path helper --product claudio >/dev/null
RELEASE_BIN_DIR="$(swift build -c release --package-path helper --product claudio --show-bin-path)"
RELEASE_BIN="$RELEASE_BIN_DIR/claudio"

if ! LC_ALL=C strings "$DEBUG_BIN" | grep -F "CLAUDIO_TEST_ROOT" >/dev/null; then
  echo "FAIL: Debug helper 未包含 CLAUDIO_TEST_ROOT 测试入口" >&2
  exit 1
fi
if LC_ALL=C strings "$RELEASE_BIN" | grep -F "CLAUDIO_TEST_ROOT" >/dev/null; then
  echo "FAIL: Release helper 不得包含 CLAUDIO_TEST_ROOT" >&2
  exit 1
fi

INSTALLATION_ID="11111111-2222-4333-8444-555555555555"
STALE_ID="aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"

prepare_root() {
  local root="$1"
  local host="$2"
  local mode="$3"

  mkdir -p "$root/integrations/installations"
  cat > "$root/integrations/installations/$host.json" <<JSON
{
  "schema": 2,
  "host": "$host",
  "installation_id": "$INSTALLATION_ID",
  "scope_fingerprint": "test-hook-cli-contract:$host"
}
JSON

  case "$mode" in
    ready|muted)
      mkdir -p "$root/packs"
      cp -R packs/minimal-chime "$root/packs/minimal-chime"
      if [[ "$mode" == "muted" ]]; then
        cat > "$root/config.json" <<'JSON'
{"selected_pack":"minimal-chime","master_volume":0,"events":{"task_start":false}}
JSON
      else
        cat > "$root/config.json" <<'JSON'
{"selected_pack":"minimal-chime","master_volume":0,"events":{}}
JSON
      fi
      ;;
    not-ready)
      cat > "$root/config.json" <<'JSON'
{"selected_pack":"missing-pack","master_volume":0,"events":{}}
JSON
      ;;
    *)
      echo "FAIL: unknown fixture mode $mode" >&2
      exit 1
      ;;
  esac
}

run_silent_hook() {
  local label="$1"
  local root="$2"
  shift 2
  local stdout_file="$TEST_ROOT/$label.stdout"
  local stderr_file="$TEST_ROOT/$label.stderr"
  local status

  set +e
  CLAUDIO_TEST_ROOT="$root" "$DEBUG_BIN" hook "$@" >"$stdout_file" 2>"$stderr_file"
  status=$?
  set -e

  if [[ $status -ne 0 ]]; then
    echo "FAIL: $label exit=$status" >&2
    exit 1
  fi
  if [[ -s "$stdout_file" ]]; then
    echo "FAIL: $label stdout 非零字节" >&2
    exit 1
  fi
  if [[ -s "$stderr_file" ]]; then
    echo "FAIL: $label stderr 非零字节" >&2
    exit 1
  fi
}

receipt_result() {
  /usr/bin/plutil -extract playback_result raw -o - "$1"
}

READY_ROOT="$TEST_ROOT/ready"
prepare_root "$READY_ROOT" claude-code ready
run_silent_hook played "$READY_ROOT" \
  claude-code UserPromptSubmit --installation-id "$INSTALLATION_ID"
READY_RECEIPT="$READY_ROOT/integrations/receipts/claude-code/UserPromptSubmit.json"
if [[ "$(receipt_result "$READY_RECEIPT")" != "played" ]]; then
  echo "FAIL: 首次 UserPromptSubmit 未写 played 回执" >&2
  exit 1
fi
run_silent_hook debounced "$READY_ROOT" \
  claude-code UserPromptSubmit --installation-id "$INSTALLATION_ID"
if [[ "$(receipt_result "$READY_RECEIPT")" != "debounced" ]]; then
  echo "FAIL: 250ms 内重复 UserPromptSubmit 未写 debounced 回执" >&2
  exit 1
fi

MUTED_ROOT="$TEST_ROOT/muted"
prepare_root "$MUTED_ROOT" codex muted
run_silent_hook muted "$MUTED_ROOT" \
  codex UserPromptSubmit --installation-id "$INSTALLATION_ID"
MUTED_RECEIPT="$MUTED_ROOT/integrations/receipts/codex/UserPromptSubmit.json"
if [[ "$(receipt_result "$MUTED_RECEIPT")" != "muted" ]]; then
  echo "FAIL: 任务开始单事件静音未写 muted 回执" >&2
  exit 1
fi

MISSING_ROOT="$TEST_ROOT/not-ready"
prepare_root "$MISSING_ROOT" claude-code not-ready
run_silent_hook not-ready "$MISSING_ROOT" \
  claude-code UserPromptSubmit --installation-id "$INSTALLATION_ID"
MISSING_RECEIPT="$MISSING_ROOT/integrations/receipts/claude-code/UserPromptSubmit.json"
if [[ "$(receipt_result "$MISSING_RECEIPT")" != "not_ready" ]]; then
  echo "FAIL: 缺少 task_start 映射时未写 not_ready 回执" >&2
  exit 1
fi

PLAYBACK_FAILED_ROOT="$TEST_ROOT/playback-failed"
prepare_root "$PLAYBACK_FAILED_ROOT" claude-code ready
# 让宿主播放锁路径成为目录，稳定触发真实文件系统 lock failure；回执目录仍可写，
# 因而这条能同时证明 playback_failed 结果和零输出 CLI 契约。
mkdir -p "$PLAYBACK_FAILED_ROOT/integrations/claude-code-play.lock"
run_silent_hook playback-failed "$PLAYBACK_FAILED_ROOT" \
  claude-code UserPromptSubmit --installation-id "$INSTALLATION_ID"
PLAYBACK_FAILED_RECEIPT="$PLAYBACK_FAILED_ROOT/integrations/receipts/claude-code/UserPromptSubmit.json"
if [[ "$(receipt_result "$PLAYBACK_FAILED_RECEIPT")" != "playback_failed" ]]; then
  echo "FAIL: 播放锁文件系统失败未写 playback_failed 回执" >&2
  exit 1
fi

run_silent_hook unsupported "$MISSING_ROOT" \
  codex StopFailure --installation-id "$INSTALLATION_ID"
run_silent_hook stale-installation "$MISSING_ROOT" \
  claude-code UserPromptSubmit --installation-id "$STALE_ID"

echo "PASS: claudi0 hook 真实子进程 exit/stdout/stderr 与 Debug-only root 契约"
