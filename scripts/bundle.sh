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
# SPM 的产物名跟 target 名走（Package.swift 里是 Handy），和 Info.plist 无关。
BIN=".build/$CONFIG/Handy"

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

# 把 handy-transcribe 编译好塞进 Resources/bin：装到 /Applications 之后没有开发树，
# 只靠「从可执行文件向上找」会落到 missing，每次录音都报「找不到 handy-transcribe」。
# 仓库里的 handy-transcribe 是 shell shim（首次调用才 swiftc），用户机器上没有 swiftc，
# 所以必须在打包机上先编译成独立的可执行文件。
TRANSCRIBE_SRC="handy-transcribe.swift"
TRANSCRIBE_BIN=".build/$CONFIG/handy-transcribe"
if [ -f "$TRANSCRIBE_SRC" ]; then
  if [ ! -x "$TRANSCRIBE_BIN" ] || [ "$TRANSCRIBE_SRC" -nt "$TRANSCRIBE_BIN" ]; then
    echo "编译 handy-transcribe…"
    swiftc -O "$TRANSCRIBE_SRC" -o "$TRANSCRIBE_BIN"
  fi
  mkdir -p "$APP/Contents/Resources/bin"
  cp "$TRANSCRIBE_BIN" "$APP/Contents/Resources/bin/handy-transcribe"
  chmod +x "$APP/Contents/Resources/bin/handy-transcribe"
else
  echo "警告：找不到 $TRANSCRIBE_SRC，打包后的 app 将无法转写" >&2
fi

# ad-hoc 签名：没有 Developer ID 也能本机双击。--force 覆盖 cp 之后失效的签名。
codesign --force --sign - --timestamp=none "$APP" >/dev/null

echo "✓ $APP"
echo "  安装: cp -R \"$APP\" /Applications/ && open /Applications/$NAME.app"
