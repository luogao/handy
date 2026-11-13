#!/bin/bash
# 把 whisper-cli / whisper-server 连同它们的动态库一起装进 app，
# 让「下载即用」真的成立——不需要用户自己 brew install whisper-cpp。
#
# 用法: ./scripts/bundle-whisper.sh build/Sotto.app
#
# 依赖来源默认取本机 Homebrew（whisper-cpp + ggml + libomp），
# 可用 WHISPER_BIN_DIR / WHISPER_LIB_DIR / GGML_LIB_DIR / LIBOMP_DIR 覆盖。
set -euo pipefail

APP="${1:-build/Sotto.app}"
BIN_SRC="${WHISPER_BIN_DIR:-/opt/homebrew/opt/whisper-cpp/bin}"
WHISPER_LIB="${WHISPER_LIB_DIR:-/opt/homebrew/opt/whisper-cpp/lib}"
GGML_LIB="${GGML_LIB_DIR:-/opt/homebrew/opt/ggml/lib}"
LIBOMP_DIR="${LIBOMP_DIR:-/opt/homebrew/opt/libomp/lib}"
GGML_BACKEND_SRC="${GGML_BACKEND_SRC:-/opt/homebrew/Cellar/ggml/0.20.1/libexec}"

DEST_BIN="$APP/Contents/Resources/bin"
DEST_LIB="$APP/Contents/Resources/lib"

for f in whisper-cli whisper-server; do
  [ -x "$BIN_SRC/$f" ] || { echo "缺少 $BIN_SRC/$f（先 brew install whisper-cpp）" >&2; exit 1; }
done

mkdir -p "$DEST_BIN" "$DEST_LIB"

# 1) 可执行文件
for f in whisper-cli whisper-server; do
  cp "$BIN_SRC/$f" "$DEST_BIN/$f"
  chmod +x "$DEST_BIN/$f"
done

# 2) 动态库：解析真实文件名（去掉版本软链），只拷需要的几个
copy_lib() {
  local src="$1"
  [ -f "$src" ] || { echo "缺少动态库 $src" >&2; exit 1; }
  cp "$(cd "$(dirname "$src")" && pwd)/$(basename "$src")" "$DEST_LIB/"
}

copy_lib "$WHISPER_LIB/libwhisper.1.dylib"
copy_lib "$GGML_LIB/libggml.0.dylib"
copy_lib "$GGML_LIB/libggml-base.0.dylib"
copy_lib "$LIBOMP_DIR/libomp.dylib"

# ggml 的 backend（cpu-apple_m*/metal/blas）是运行时 dlopen 的，必须跟着走。
# 放在 whisper-* 旁边：ggml_backend_load_best 会搜「可执行文件所在目录」，
# 而 GGML_BACKEND_PATH 走的是全量加载路径，实测会让 ggml_backend_dev_init abort。
BACKEND_DEST="$DEST_BIN"
mkdir -p "$BACKEND_DEST"
if compgen -G "$GGML_BACKEND_SRC/libggml-*.so" >/dev/null; then
  cp "$GGML_BACKEND_SRC"/libggml-*.so "$BACKEND_DEST/"
else
  echo "警告：没找到 ggml backend .so（$GGML_BACKEND_SRC），干净机器上会退化成纯 CPU 或起不来" >&2
fi

# 3) 改安装名：绝对路径 → @executable_path/../lib（可执行）或 @loader_path（库）
HOME_PREFIXES=(
  "/opt/homebrew/opt/whisper-cpp/lib"
  "/opt/homebrew/opt/ggml/lib"
  "/opt/homebrew/opt/libomp/lib"
  "/opt/homebrew/lib"
  "/usr/local/opt/whisper-cpp/lib"
  "/usr/local/opt/ggml/lib"
  "/usr/local/opt/libomp/lib"
  "/usr/local/lib"
)

rewrite() {
  local file="$1" prefix_for_libs="$2"   # prefix_for_libs: @executable_path/../lib 或 @loader_path
  local deps
  deps=$(otool -L "$file" | tail -n +2 | awk '{print $1}')
  while IFS= read -r dep; do
    [ -z "$dep" ] && continue
    case "$dep" in
      /opt/homebrew/*|/usr/local/*)
        local base; base=$(basename "$dep")
        install_name_tool -change "$dep" "$prefix_for_libs/$base" "$file" 2>/dev/null || true
        ;;
    esac
  done <<< "$deps"

  if [ "$prefix_for_libs" = "@executable_path/../lib" ]; then
    install_name_tool -add_rpath "@executable_path/../lib" "$file" 2>/dev/null || true
  else
    install_name_tool -add_rpath "@loader_path" "$file" 2>/dev/null || true
  fi
}

for f in whisper-cli whisper-server; do
  rewrite "$DEST_BIN/$f" "@executable_path/../lib"
done

for f in "$DEST_LIB"/*.dylib; do
  # 库自己的 install name 也改成 @rpath，避免引用旧绝对路径
  install_name_tool -id "@rpath/$(basename "$f")" "$f" 2>/dev/null || true
  rewrite "$f" "@loader_path"
done

# 4) backend .so：依赖同样指向系统/包内库，签名也一起补
for f in "$BACKEND_DEST"/libggml-*.so; do
  [ -f "$f" ] || continue
  install_name_tool -add_rpath "@loader_path/../lib" "$f" 2>/dev/null || true
  rewrite "$f" "@loader_path/../lib" 2>/dev/null || true
done

# 5) 改过的二进制签名全废了，arm64 必须重新 ad-hoc 签一次
for f in "$DEST_BIN"/whisper-* "$DEST_LIB"/*.dylib "$BACKEND_DEST"/libggml-*.so; do
  codesign --force --sign - --timestamp=none "$f" >/dev/null 2>&1
done

echo "内置 whisper: $(du -sh "$DEST_BIN" "$DEST_LIB" | awk '{print $1" "$2}' | tr '\n' ' ')"
for f in whisper-cli whisper-server; do
  printf "  %-15s %s\n" "$f" "$(otool -L "$DEST_BIN/$f" | tail -n +2 | awk '{print $1}' | grep -v '^/usr/lib' | tr '\n' ' ')"
done
