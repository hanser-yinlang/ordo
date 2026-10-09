#!/usr/bin/env bash
#
# verify_ios.sh —— 在 macOS 上"一条命令"跑通 iOS 端(生成 XCFramework → 构建 → 测试 → 自检)
#
# 为什么需要这个脚本:本仓库的开发机是 Windows,**没有任何 macOS 环境**
# (Swift on Windows 存在,但本工程 import 的 SwiftUI / SwiftData / EventKit / UIKit /
#  AppIntents / UserNotifications / CoreGraphics 全部是 Apple 平台专属模块,
#  且 KMP 的 Apple 目标必须由 macOS 主机编译 —— 见 README §5.1)。
#  因此"编译"这一步只能在 macOS 上执行,本脚本把这一步固化成可复现的一条命令。
#
# 用法(在 macOS 上,仓库根目录或任意目录均可):
#   bash apps/ios/tools/verify_ios.sh              # 全流程
#   bash apps/ios/tools/verify_ios.sh --build-only # 只生成 framework + 构建
#   bash apps/ios/tools/verify_ios.sh --no-tests   # 跳过 xcodebuild test
#
# 退出码:0 = 全部通过;非 0 = 有步骤失败(并打印失败步骤名)。
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"      # apps/ios/tools
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"                          # apps/ios
REPO_ROOT="$(cd "$IOS_DIR/../.." && pwd)"                        # 仓库根(含 gradlew)

BUILD_ONLY=0
RUN_TESTS=1
for arg in "$@"; do
  case "$arg" in
    --build-only) BUILD_ONLY=1 ;;
    --no-tests)   RUN_TESTS=0 ;;
    -h|--help)    sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "未知参数:$arg"; exit 2 ;;
  esac
done

FAILED=()
step() {
  local title="$1"; shift
  echo ""
  echo "=== $title ==="
  if "$@"; then
    echo "  OK"
  else
    echo "  FAILED: $title"
    FAILED+=("$title")
  fi
}

# ---------------------------------------------------------------- 0. 前置检查

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "本脚本只能在 macOS 上运行(当前:$(uname -s))。"
  echo "原因见 apps/ios/README.md §5.1:SwiftUI / SwiftData / EventKit 与 KMP Apple 目标都需要 macOS。"
  exit 2
fi

echo "仓库根:$REPO_ROOT"
echo "iOS 工程:$IOS_DIR"
command -v xcodebuild >/dev/null || { echo "缺少 xcodebuild,请先安装 Xcode 16+"; exit 2; }
command -v java       >/dev/null || { echo "缺少 JDK,请安装 JDK 21(或设置 JAVA_HOME)"; exit 2; }
# 用仓库自带的 wrapper(已提交 gradlew / gradlew.bat,Gradle 8.14)
GRADLE="$REPO_ROOT/gradlew"
[[ -x "$GRADLE" ]] || chmod +x "$GRADLE"
xcodebuild -version | head -2

# ---------------------------------------------------------------- 1. 探测 XCFramework 任务名

# KMP 会按 framework 的 baseName 注册 `assemble<BaseName>XCFramework`;
# 本工程 baseName = "OrdoCore",但不同 KMP 版本/DSL 写法也可能是通用的 `assembleXCFramework`。
# 因此这里**以本机探测为准**,并把探测结果打印出来(与 README §1 步骤 1 一致)。
detect_xcframework_task() {
  echo "探测 :shared:core 的 XCFramework 任务…"
  local tasks
  tasks="$("$GRADLE" -p "$REPO_ROOT" :shared:core:tasks --all --console=plain 2>/dev/null \
           | grep -i 'xcframework' || true)"
  if [[ -z "$tasks" ]]; then
    echo "  未发现任何 XCFramework 任务。"
    echo "  请确认:① 当前主机是 macOS;② shared/core/build.gradle.kts 的 iOS 目标已启用"
    echo "  (它在 if (HostManager.hostIsMac) 块里)。"
    return 1
  fi
  echo "$tasks" | sed 's/^/    /'
  if grep -qi 'assembleOrdoCoreXCFramework' <<<"$tasks"; then
    echo "  → 选用 assembleOrdoCoreXCFramework(baseName 派生,推荐)"
    XCFRAMEWORK_TASK="assembleOrdoCoreXCFramework"
  elif grep -qi '\bassembleXCFramework\b' <<<"$tasks"; then
    echo "  → 选用 assembleXCFramework(通用任务)"
    XCFRAMEWORK_TASK="assembleXCFramework"
  else
    echo "  → 取列表中第一个 assemble*XCFramework 任务"
    XCFRAMEWORK_TASK="$(grep -oiE 'assemble[A-Za-z]*XCFramework' <<<"$tasks" | head -1)"
  fi
  [[ -n "${XCFRAMEWORK_TASK:-}" ]]
}
XCFRAMEWORK_TASK=""
step "探测 XCFramework 任务名" detect_xcframework_task

if [[ -z "$XCFRAMEWORK_TASK" ]]; then
  echo ""
  echo "无法确定 XCFramework 任务名,后续步骤跳过。"
  exit 1
fi

# ---------------------------------------------------------------- 2. 生成 XCFramework

assemble_framework() {
  "$GRADLE" -p "$REPO_ROOT" ":shared:core:${XCFRAMEWORK_TASK}" --console=plain
}
step "生成 OrdoCore.xcframework(:shared:core:${XCFRAMEWORK_TASK})" assemble_framework

# 产物位置提示(供 Package.swift / 手工链接使用)
FRAMEWORK_DIR="$REPO_ROOT/shared/core/build/XCFrameworks/release"
if [[ -d "$FRAMEWORK_DIR" ]]; then
  echo "产物目录:"
  ls -1 "$FRAMEWORK_DIR" | sed 's/^/    /'
  echo "如需让 Package.swift 指向别处:export ORDO_CORE_XCFRAMEWORK=$FRAMEWORK_DIR/OrdoCore.xcframework"
fi

# ---------------------------------------------------------------- 3. 构建 iOS 工程

# 选一个本机确实存在的模拟器(iPhone 15 及以后都是 iOS 17+,满足部署目标)
pick_destination() {
  local name
  name="$(xcrun simctl list devices available 2>/dev/null \
          | grep -oE 'iPhone 1[5-9][^(]*' | head -1 | sed 's/ *$//')"
  [[ -z "$name" ]] && name="iPhone 16"
  echo "platform=iOS Simulator,name=${name}"
}
DEST="$(pick_destination)"
echo ""
echo "目标设备:$DEST"

# xcodebuild 不会自动创建 -resultBundlePath 的父目录
mkdir -p "$IOS_DIR/build"

build_app() {
  ( cd "$IOS_DIR" && xcodebuild \
      -project Ordo.xcodeproj \
      -scheme Ordo \
      -destination "$DEST" \
      -resultBundlePath build/Ordo-build.xcresult \
      build )
}
step "构建 iOS App(xcodebuild build)" build_app

if [[ "$BUILD_ONLY" == "1" ]]; then
  echo ""
  echo "(--build-only,跳过测试与自检)"
else
  if [[ "$RUN_TESTS" == "1" ]]; then
    test_app() {
      ( cd "$IOS_DIR" && xcodebuild \
          -project Ordo.xcodeproj \
          -scheme Ordo \
          -destination "$DEST" \
          -resultBundlePath build/Ordo-test.xcresult \
          test )
    }
    step "运行单元测试(xcodebuild test)" test_app
  fi

  # ---------------------------------------------------------------- 4. 仓库自检

  check_sources() {
    python3 "$IOS_DIR/tools/check_ios_sources.py"
  }
  step "iOS 源码自检(check_ios_sources.py)" check_sources

  check_pbxproj() {
    python3 "$IOS_DIR/tools/gen_xcodeproj.py" --check
  }
  step "Xcode 工程结构校验(gen_xcodeproj.py --check)" check_pbxproj

  check_encoding() {
    python3 "$REPO_ROOT/tools/check-encoding.py"
  }
  step "编码扫描(check-encoding.py)" check_encoding
fi

# ---------------------------------------------------------------- 汇总

echo ""
if [[ ${#FAILED[@]} -eq 0 ]]; then
  echo "全部步骤通过 —— iOS 端已在本机(macOS)真实编译。"
  exit 0
fi
echo "失败步骤:"
for f in "${FAILED[@]}"; do echo "  - $f"; done
echo ""
echo "提示:首次编译最可能报错的是 ObjC 导出成员名与 SwiftData 宏,"
echo "      逐条风险与应对见 apps/ios/README.md §5.2。"
exit 1
