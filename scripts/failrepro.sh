#!/usr/bin/env bash
# handy P1 失败路径复现脚本 v3
#
# v3 与 v2 的关键差别：**模型路径当前没有 defaults 键**。
#   实际实现（DYVI-123 / 6c7900d）只用了 hotkey.* 和 log.enabled，
#   模型固定用 ~/.cache/whisper.cpp/ggml-medium-q5_0.bin（不传 --model）。
#   所以「改 defaults 造模型缺失」对当前实现无效——v3 改成「挪走/替换默认模型文件」，
#   并且用 trap 保证无论中途怎么退出，真模型都会回到原位。
#
# 用法：
#   bash failrepro.sh status
#   bash failrepro.sh model-missing
#   bash failrepro.sh model-corrupt
#   bash failrepro.sh mic-denied
#   bash failrepro.sh transcribe-kill
#   bash failrepro.sh restore
#
# 安全约定：
#   1) 真模型只做 mv（原子、不复制 514MB），并记录到状态文件
#   2) 任何异常退出（Ctrl-C / set -e / kill）都会触发 trap 把模型放回去
#   3) restore 幂等：重复执行不会重复移动
#   4) 如果将来实现加了 modelPath 键，脚本会优先用它（见 model_key_mode）
#
# 环境变量（测试用）：
#   HANDY_BUNDLE_ID=...     覆盖 bundle id
#   HANDY_APP=...           指定 Handy.app
#   HANDY_MODEL_FILE=...    覆盖被操作的模型文件（默认 ~/.cache/whisper.cpp/ggml-medium-q5_0.bin）
#   HANDY_NO_LAUNCH=1       不启动/不退出 app
set -uo pipefail

BUNDLE_ID="${HANDY_BUNDLE_ID:-top.rungundam.handy}"
KEY_MODEL="modelPath"
MODEL_FILE="${HANDY_MODEL_FILE:-$HOME/.cache/whisper.cpp/ggml-medium-q5_0.bin}"
HIDDEN="${MODEL_FILE}.failrepro-hidden"
STATE_DIR="$HOME/Library/Caches/handy"
STATE_FILE="$STATE_DIR/failrepro-state.txt"
CACHE="$HOME/Library/Caches/handy"
NO_LAUNCH="${HANDY_NO_LAUNCH:-0}"

say() { printf '%s\n' "$*"; }
die() {
  # 出错时若模型在隐藏位，必须先放回去再退出
  if [ -n "${HIDDEN:-}" ] && [ -f "${HIDDEN:-/nonexistent}" ]; then
    printf '错误前正在恢复模型…\n' >&2
    put_model_back || printf '请手动：mv "%s" "%s"\n' "$HIDDEN" "$MODEL_FILE" >&2
  fi
  rm -f "${STATE_FILE:-/nonexistent}" 2>/dev/null || true
  printf '错误：%s\n' "$*" >&2
  exit 1
}
warn() { printf '注意：%s\n' "$*" >&2; }

model_key_mode() { defaults read "$BUNDLE_ID" "$KEY_MODEL" >/dev/null 2>&1 && return 0 || return 1; }

state_get() { [ -f "$STATE_FILE" ] && grep -E "^$1=" "$STATE_FILE" | head -1 | cut -d= -f2- || true; }
state_set() { mkdir -p "$STATE_DIR" || die "无法创建 $STATE_DIR"; printf '%s=%s\n' "$1" "$2" >> "$STATE_FILE"; }

find_app() {
  if [ -n "${HANDY_APP:-}" ]; then [ -d "$HANDY_APP" ] && { printf '%s\n' "$HANDY_APP"; return 0; }; return 1; fi
  local c
  for c in "$(pwd)/build/Handy.app" "$(pwd)/handy/build/Handy.app" \
           "/Applications/Handy.app" "$HOME/Documents/Hermes/workshop/handy/build/Handy.app"; do
    [ -d "$c" ] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}

quit_app() {
  [ "$NO_LAUNCH" = "1" ] && return 0
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  sleep 1
  pkill -f "Handy.app/Contents/MacOS/Handy" >/dev/null 2>&1 || true
  sleep 0.5
}

launch_app() {
  local app="$1"
  [ "$NO_LAUNCH" = "1" ] && { say "· 跳过启动（HANDY_NO_LAUNCH=1）"; return 0; }
  open "$app" || die "无法启动 $app"
  for _ in {1..10}; do
    sleep 1
    pgrep -f "Handy.app/Contents/MacOS/Handy" >/dev/null && { say "✓ 已启动：$app"; return 0; }
  done
  die "启动后 10 秒内进程仍不存在：$app"
}

# 把真模型挪走（只在还没挪过时执行）
hide_model() {
  [ -f "$MODEL_FILE" ] || die "默认模型不存在：${MODEL_FILE}（这不是预期状态，先确认环境）"
  [ -f "$HIDDEN" ] && { say "· 真模型已在隐藏位，跳过移动"; return 0; }
  local size; size="$(stat -f%z "$MODEL_FILE")"
  mv "$MODEL_FILE" "$HIDDEN" || die "移动模型失败"
  state_set ORIG_SIZE "$size"
  state_set HIDDEN "$HIDDEN"
  say "✓ 已把真模型移到 ${HIDDEN}（$size 字节，mv 不复制，不占额外空间）"
}

put_model_back() {
  if [ -f "$HIDDEN" ]; then
    rm -f "$MODEL_FILE" 2>/dev/null || true
    mv "$HIDDEN" "$MODEL_FILE" || { warn "模型未能自动恢复，请手动：mv \"$HIDDEN\" \"$MODEL_FILE\""; return 1; }
    local want got; want="$(state_get ORIG_SIZE)"; got="$(stat -f%z "$MODEL_FILE")"
    if [ -n "$want" ] && [ "$want" != "$got" ]; then
      warn "恢复后大小不一致（期望 ${want}，实际 ${got}）——请检查模型完整性"
    fi
    say "✓ 真模型已放回 $MODEL_FILE"
  fi
  return 0
}

# 只在中途被中断时自动复原；正常跑完要保留「模型已挪走」的状态供人工复现
cleanup_on_signal() {
  warn "收到中断信号，正在把模型放回原位…"
  put_model_back || true
  rm -f "$STATE_FILE"
  exit 130
}
trap cleanup_on_signal INT TERM HUP

cmd_status() {
  say "── 当前状态 ──"
  say "bundle id   : $BUNDLE_ID"
  say "模型键      : $(model_key_mode && defaults read "$BUNDLE_ID" "$KEY_MODEL" || echo '无（当前实现不读 modelPath，用默认模型）')"
  say "默认模型    : $([ -f "$MODEL_FILE" ] && echo "存在 $(du -h "$MODEL_FILE" | cut -f1)" || echo 缺失) ($MODEL_FILE)"
  say "隐藏位      : $([ -f "$HIDDEN" ] && echo "有残留 $(du -h "$HIDDEN" | cut -f1)" || echo 空)"
  say "app 进程    : $(pgrep -f 'Handy.app/Contents/MacOS/Handy' | tr '\n' ' ')"
  say "最近录音    : $([ -f "$CACHE/last-recording.wav" ] && du -h "$CACHE/last-recording.wav" | cut -f1 || echo 无)"
}

cmd_model_missing() {
  local app; app="$(find_app)" || die "找不到 Handy.app（先在 handy/ 下跑 ./scripts/bundle.sh）"
  quit_app
  if model_key_mode; then
    warn "检测到 modelPath 键存在：改为直接写坏路径（不改文件）"
    cp -n "$STATE_FILE" "$STATE_FILE.bak" 2>/dev/null || true
    defaults write "$BUNDLE_ID" "$KEY_MODEL" -string "/nonexistent/ggml-medium-q5_0.bin"
    say "✓ modelPath=/nonexistent/ggml-medium-q5_0.bin"
  else
    hide_model
  fi
  launch_app "$app"
  cat <<EOF

现在手动做：
  1. 按住 ⌃⌥H 说一句话，松开
  2. 当前实现（6c7900d）的实际文案是：
       找不到 whisper 模型。把 ggml-*.bin 放到 ~/.cache/whisper.cpp/ 后再试。
     卡里指定的是「模型文件未找到 / 在「设置 › 模型」里重新选择 .bin 文件」——
     两者不一致，验收时要按卡判（见 DYVI-123 评论「文案差异」）。

验完恢复：bash failrepro.sh restore
EOF
}

cmd_model_corrupt() {
  local app; app="$(find_app)" || die "找不到 Handy.app"
  quit_app
  hide_model
  head -c 4096 /dev/urandom > "$MODEL_FILE" || { put_model_back; die "无法写入假模型"; }
  state_set FAKE "$MODEL_FILE"
  say "✓ 已在原路径写入 4KB 假模型（真模型在隐藏位，不会丢）"
  launch_app "$app"
  cat <<EOF

现在手动做：
  1. 按住 ⌃⌥H 说一句话，松开
  2. 当前实现的文案预期是「转写失败：<stderr 摘要>」——
     它没有单独识别「模型损坏」，只透传退出码/输出。这条要按卡判不一致。

验完恢复：bash failrepro.sh restore
EOF
}

cmd_mic_denied() {
  quit_app
  say "→ 重置麦克风授权：tccutil reset Microphone $BUNDLE_ID"
  tccutil reset Microphone "$BUNDLE_ID" 2>&1 | sed 's/^/  /' || warn "tccutil 失败，可手动到 系统设置 › 隐私与安全性 › 麦克风 取消勾选"
  local app; app="$(find_app)" || die "找不到 Handy.app"
  launch_app "$app"
  cat <<'EOF'

现在手动做：
  1. 按住 ⌃⌥H → 系统弹窗 → 点【不允许】
  2. 期望（卡里指定）：主「需要麦克风权限」/ 副「在系统设置里勾选 Handy 后可继续」
  3. 再按一次 ⌃⌥H → 应仍显示同一文案，不崩溃、不静默

恢复：系统设置 › 隐私与安全性 › 麦克风 › 勾选 Handy
EOF
}

cmd_transcribe_kill() {
  say "准备就绪。按住 ⌃⌥H 说 3 秒，松开后 1 秒内执行："
  say ""
  say "  pkill -9 -f 'whisper-server -m'"
  say ""
  say "期望：主「转写失败，音频已保留」/ 副「可在菜单里重试，或查看日志」"
  say "验证音频保留："
  say "  ls -lh $CACHE/last-recording.wav"
  say "  afinfo $CACHE/last-recording.wav | grep duration"
  say "再点菜单「重试上次录音」→ pbpaste 验证"
}

cmd_restore() {
  local did=0
  if model_key_mode; then
    defaults delete "$BUNDLE_ID" "$KEY_MODEL" 2>/dev/null && { say "✓ 已删除测试用 modelPath"; did=1; }
  fi
  if [ -f "$HIDDEN" ]; then
    put_model_back || die "模型恢复失败"
    did=1
  else
    say "· 没有隐藏的真模型，无需恢复"
  fi
  if [ -f "$MODEL_FILE" ]; then
    local sz; sz="$(stat -f%z "$MODEL_FILE")"
    if [ "$sz" -lt 1048576 ]; then
      warn "当前 $MODEL_FILE 只有 $sz 字节（像假模型）——真模型在 $HIDDEN 吗？$([ -f "$HIDDEN" ] && echo 是 || echo 否，请检查)"
    fi
  fi
  rm -f "$STATE_FILE" && say "✓ 已清理状态文件"
  [ "$did" = "0" ] && say "· 本次无需改动"
  local app; app="$(find_app)" || { say "· 找不到 Handy.app，跳过重启"; return 0; }
  quit_app; launch_app "$app"; cmd_status
}

case "${1:-}" in
  status)          cmd_status ;;
  model-missing)   cmd_model_missing ;;
  model-corrupt)   cmd_model_corrupt ;;
  mic-denied)      cmd_mic_denied ;;
  transcribe-kill) cmd_transcribe_kill ;;
  restore)         cmd_restore ;;
  *) say "用法: bash failrepro.sh {status|model-missing|model-corrupt|mic-denied|transcribe-kill|restore}"; exit 2 ;;
esac
