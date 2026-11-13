#!/usr/bin/env bash
# 打包成可双击运行的 .app（ad-hoc 签名，不需要开发者账号）。
#
# 名字只从 Resources/Info.plist 读，不在这里硬编码——改名前先改 plist。
# 用法：./scripts/bundle.sh [debug|release]   默认 release
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
NAME=$(/usr/libexec/PlistBuddy -c "Print :CFBundleName" Resources/Info.plist)
EXEC=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" Resources/Info.plist)
APP="build/$NAME.app"
# SPM 的产物名跟 target 名走（Package.swift 里是 Sotto），和 Info.plist 无关。
BIN=".build/$CONFIG/Sotto"

swift build -c "$CONFIG"
[ -f "$BIN" ] || { echo "构建产物不存在: $BIN"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/$EXEC"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# 图标没生成时先跳过（`swift scripts/make_icon.swift` 可复现），不挡住打包
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# 把 sotto-transcribe 编译好塞进 Resources/bin：装到 /Applications 之后没有开发树，
# 只靠「从可执行文件向上找」会落到 missing，每次录音都报「找不到 sotto-transcribe」。
# 仓库里的 sotto-transcribe 是 shell shim（首次调用才 swiftc），用户机器上没有 swiftc，
# 所以必须在打包机上先编译成独立的可执行文件。
TRANSCRIBE_SRC="sotto-transcribe.swift"
TRANSCRIBE_BIN=".build/$CONFIG/sotto-transcribe"
if [ -f "$TRANSCRIBE_SRC" ]; then
  if [ ! -x "$TRANSCRIBE_BIN" ] || [ "$TRANSCRIBE_SRC" -nt "$TRANSCRIBE_BIN" ]; then
    echo "编译 sotto-transcribe…"
    swiftc -O "$TRANSCRIBE_SRC" -o "$TRANSCRIBE_BIN"
  fi
  mkdir -p "$APP/Contents/Resources/bin"
  cp "$TRANSCRIBE_BIN" "$APP/Contents/Resources/bin/sotto-transcribe"
  chmod +x "$APP/Contents/Resources/bin/sotto-transcribe"
else
  echo "警告：找不到 $TRANSCRIBE_SRC，打包后的 app 将无法转写" >&2
fi

# 发行包把模型一起塞进来：用户下载 dmg 后不该再跑任何下载脚本。
# 模型不进 git（514M），由 scripts/fetch-model.sh 拉到这里。
if [ -f "models/ggml-medium-q5_0.bin" ]; then
  mkdir -p "$APP/Contents/Resources/models"
  cp "models/ggml-medium-q5_0.bin" "$APP/Contents/Resources/models/"
  echo "内置模型: $(du -h "$APP/Contents/Resources/models/ggml-medium-q5_0.bin" | cut -f1)"
else
  echo "提示：没有 models/ggml-medium-q5_0.bin，打出来的包要靠用户自备模型" >&2
fi

# whisper 引擎一起打包：模型在包里、引擎在用户机器上，永远「下载即用」不了。
if [ -x scripts/bundle-whisper.sh ]; then
  ./scripts/bundle-whisper.sh "$APP" || echo "警告：whisper 没打进去，用户仍需 brew install whisper-cpp" >&2
fi

# ad-hoc 签名：没有 Developer ID 也能本机双击。--force 覆盖 cp 之后失效的签名。
codesign --force --sign - --timestamp=none "$APP" >/dev/null

echo "✓ $APP"
echo "  安装: cp -R \"$APP\" /Applications/ && open /Applications/$NAME.app"
