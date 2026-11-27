#!/usr/bin/env bash
# 构建独立 CLI exe（不需要 Dart SDK 的最终用户可执行文件）
#
# 原理：
#   CLI 依赖链是纯 Dart（只用 image 包），不含 Flutter。
#   但要 AOT 编译必须有一个不含 flutter SDK 依赖的 pubspec，所以建 cli_aot 子项目。
#   Dart AOT 编译会在 TEMP 下生成 program.dill；本机安全软件会删除系统 TEMP 里的
#   .dill，且 Dart 工具链对中文路径敏感 —— 所以 TEMP 必须重定向到纯 ASCII 路径。
#
# 用法：bash scripts/build_cli.sh [输出路径]
#   默认输出到 ../编制生成器v0.2.2/orbat-cli.exe

set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
AOT_DIR="$APP_DIR/cli_aot"
BASE_DIR="$(cd "$APP_DIR/.." && pwd)"
OUT="${1:-$BASE_DIR/编制生成器v0.2.2/orbat-cli.exe}"
# 纯 ASCII 的构建临时目录（关键：不能有中文）。
# 默认放在盘根的中性路径；如果你的环境不便用，可用 ORBAT_BUILD_TMP 环境变量覆盖。
BUILD_TMP="${ORBAT_BUILD_TMP:-/c/orbat_darttmp}"
DART="/c/flutter/bin/cache/dart-sdk/bin/dart.exe"

echo "[1/5] 同步源码 lib/ -> cli_aot/lib/"
"$DART" run "$APP_DIR/tool/sync_cli_sources.dart"

# 双保险：确认无 Flutter 依赖混入（混入会导致 AOT 编译或运行失败）
if grep -rq "package:flutter" "$AOT_DIR/lib/"; then
  echo "错误：cli_aot 源码里混入了 package:flutter 依赖" >&2
  exit 1
fi

echo "[2/5] 确认 pub get"
(cd "$AOT_DIR" && "$DART" pub get >/dev/null 2>&1)

echo "[3/5] 准备 ASCII 临时目录: $BUILD_TMP"
mkdir -p "$BUILD_TMP"
# MSYS 路径 /c/xxx -> Windows 路径 C:\xxx（Dart 需要 Windows 格式）
BUILD_TMP_WIN=$(cygpath -w "$BUILD_TMP")

echo "[4/5] AOT 编译 (临时目录重定向)"
mkdir -p "$(dirname "$OUT")"
TEMP="$BUILD_TMP_WIN" TMP="$BUILD_TMP_WIN" \
  "$DART" compile exe "$AOT_DIR/lib/cli/main.dart" -o "$OUT" 2>&1 | tail -2

echo "[5/5] 验证"
"$OUT" --help >/dev/null 2>&1 && echo "OK: $OUT"
ls -lh "$OUT" | awk '{print "大小:", $5}'
