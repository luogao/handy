#!/usr/bin/env bash
# 下载 Sotto 默认用的 whisper 模型（ggml-medium-q5_0，约 514MB）。
#
# 放的位置就是 sotto-transcribe 和 app 预检共用的默认路径，
# 下完直接能用；想换模型在「设置 › 模型」里选。
#
# 用法：./scripts/fetch-model.sh [目标路径]
set -euo pipefail

DEST="${1:-$HOME/.cache/whisper.cpp/ggml-medium-q5_0.bin}"
URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium-q5_0.bin"

if [ -f "$DEST" ]; then
  size=$(stat -f%z "$DEST" 2>/dev/null || stat -c%s "$DEST")
  echo "已存在：$DEST（$size 字节）"
  exit 0
fi

mkdir -p "$(dirname "$DEST")"
echo "下载 $URL"
echo "→ $DEST"
# -L 跟随重定向；-C - 断点续传，中断了重跑同一条命令即可
curl -L --fail --progress-bar -C - "$URL" -o "$DEST"

head4=$(head -c 4 "$DEST" | xxd -p)
case "$head4" in
  6c6d6767|67676d6c) echo "✓ 校验通过（GGML magic $head4）" ;;
  *) echo "✗ 文件头不是 GGML（$head4），下载可能不完整，删掉重试" >&2; exit 1 ;;
esac
echo "✓ 完成：$DEST"
