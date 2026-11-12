#!/usr/bin/env bash
# 生成时延验收用的两段 fixture：12.680s / 24.000s（16kHz 单声道 16bit）。
#
# 文本取 apps/sotto/tests/chain.sh 里 lat12 / lat24 的原文——那是仓库里唯一
# 现成的、被回归闸门用过的口述文本。say 合成后用 stdlib 的 wave 裁/补到精确
# 时长（长音频截尾，短音频补静音），保证每台机器量的是同一段时长。
#
# 产物写 .build/fixtures/（gitignore），不提交二进制。
# 用法：bash sotto/scripts/make_latency_fixtures.sh
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=".build/fixtures"
mkdir -p "$OUT"

LAT12="我们昨天把转写链路的分段策略改成了八到十二秒一段，切点取静音中点，每段都带热词表和上一段的结尾，长句也不会再出问题。"
LAT24="我们昨天把转写链路的分段策略改成了八到十二秒一段，切点取静音中点，每段都带热词表和上一段的结尾，这样长音频就不会把整段写成提示词了。下一步准备把常驻进程的端口探活和异常重启补上，然后再找几个人用真实的口述场景跑一周。"

clip_wav() {   # src dst seconds
  python3 -I - "$1" "$2" "$3" <<'PY'
import sys, wave
src, dst, seconds = sys.argv[1], sys.argv[2], float(sys.argv[3])
with wave.open(src, "rb") as reader:
    params = reader.getparams()
    frames = reader.readframes(params.nframes)
target = int(round(params.framerate * seconds)) * params.sampwidth * params.nchannels
frames = frames[:target].ljust(target, b"\0")
with wave.open(dst, "wb") as writer:
    writer.setnchannels(params.nchannels)
    writer.setsampwidth(params.sampwidth)
    writer.setframerate(params.framerate)
    writer.writeframes(frames)
print(dst)
PY
}

say -v Tingting "$LAT12" --data-format=LEI16@16000 -o "$OUT/raw-12.wav"
say -v Tingting "$LAT24" --data-format=LEI16@16000 -o "$OUT/raw-24.wav"
clip_wav "$OUT/raw-12.wav" "$OUT/lat-12.680.wav" 12.680
clip_wav "$OUT/raw-24.wav" "$OUT/lat-24.000.wav" 24.000
rm -f "$OUT/raw-12.wav" "$OUT/raw-24.wav"

for file in "$OUT/lat-12.680.wav" "$OUT/lat-24.000.wav"; do
  printf '%s  ' "$file"
  afinfo "$file" | awk '/estimated duration/ { print $3 "s" }'
done
