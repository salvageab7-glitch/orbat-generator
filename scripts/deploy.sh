#!/bin/bash
# 构建并部署到本地工作目录（开发机用；发布给用户请用 Inno Setup，见 scripts/make_installer.iss）
#
# 关键坑：`flutter build windows` 只重新链接 runner（orbat_core.exe，90KB，时间戳常年不变），
# **真正的 Dart 代码在 data/app.so 里**。只复制 exe 会导致"看起来部署了，实际还是旧代码"。
# 所以这里必须整目录覆盖 data/。
#
# 用法：bash scripts/deploy.sh [构建目录] [部署目录]
#   构建目录默认 C:/bld（纯 ASCII 路径——中文路径会触发 MSBuild 编码 bug）
#   部署目录默认 ./deploy（项目根下新建）
set -e

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${1:-/c/bld}"
DEPLOY_DIR="${2:-$APP_DIR/../deploy}"
REL="$BUILD_DIR/build/windows/x64/runner/Release"

echo "== 1/4 同步源码 =="
mkdir -p "$BUILD_DIR"
cp -rf "$APP_DIR/lib" "$APP_DIR/runtime" "$APP_DIR/windows" \
       "$APP_DIR/pubspec.yaml" "$APP_DIR/pubspec.lock" "$BUILD_DIR/"

echo "== 2/4 构建 =="
export PATH="/c/flutter/bin:$PATH"
cd "$BUILD_DIR"
flutter build windows --release 2>&1 | tail -2

echo "== 3/4 部署到 $DEPLOY_DIR =="
mkdir -p "$DEPLOY_DIR"
cp -rf "$REL/data" "$REL/runtime" "$REL/flutter_windows.dll" "$DEPLOY_DIR/"

echo "== 4/4 部署主程序 =="
# 若目标程序正在运行，先停进程，否则文件被占用会静默失败
taskkill //F //IM "启动.exe" 2>/dev/null || true
taskkill //F //IM orbat_core.exe 2>/dev/null || true
sleep 1
cp "$REL/orbat_core.exe" "$DEPLOY_DIR/启动.exe"

echo ""
echo "=== 校验 app.so 时间戳 ==="
ls -la --time-style=+%H:%M:%S "$REL/data/app.so" "$DEPLOY_DIR/data/app.so" | awk '{print $6, $7}'
echo "部署完成。若两处 app.so 时间一致，说明代码已同步。"
echo "提示：CLI exe 用 bash scripts/build_cli.sh 单独编译。"
