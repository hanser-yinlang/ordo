#!/usr/bin/env bash
#
# mac_onboarding.sh —— 在**刚拿到的 macOS 机器**上一条命令把 iOS 编译环境准备好并开始编译。
#
# 背景:Ordo 的开发机是 Windows 11(无 macOS/Xcode),iOS 端源码 54 个文件 / 13764 行
#       **从未编译过**。本脚本是"拿到 Mac 之后的第一条命令"。
#
# 用法(在 Mac 上,把仓库放到任意位置后执行):
#   bash apps/ios/tools/mac_onboarding.sh                 # 全流程:环境自检 → 依赖 → 编译
#   bash apps/ios/tools/mac_onboarding.sh --setup-only    # 只装/检查环境,不编译
#
# 前置:已 clone 或拷贝整个 ordo 仓库(本脚本要求在仓库内运行)。
#
set -uo pipefail

SETUP_ONLY=0
[[ "${1:-}" == "--setup-only" ]] && SETUP_ONLY=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$IOS_DIR/../.." && pwd)"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "本脚本只能在 macOS 上运行(当前:$(uname -s))。"
  echo "需要 macOS 的原因见 apps/ios/README.md §5.1。"
  exit 2
fi

FAIL=0
say()  { echo ""; echo "=== $* ==="; }
need() { command -v "$1" >/dev/null 2>&1 && echo "  ✓ $1 -> $(command -v "$1")" || { echo "  ✗ 缺少 $1"; FAIL=1; }; }

say "0) 系统与硬件"
sw_vers
echo "  架构:$(uname -m)"
echo "  仓库根:$REPO_ROOT"

say "1) Xcode / 命令行工具"
if xcode-select -p >/dev/null 2>&1; then
  echo "  ✓ developer dir: $(xcode-select -p)"
else
  echo "  ✗ 未选择 Xcode 路径 → 先执行:sudo xcode-select --install 或在 Xcode 里装命令行工具"
  FAIL=1
fi
if command -v xcodebuild >/dev/null 2>&1; then
  xcodebuild -version | sed 's/^/  /'
  # 需要 Xcode 16+(Swift 6 / SwiftData / @Observable)
  major="$(xcodebuild -version | awk '/Xcode/{print $2}' | cut -d. -f1)"
  if [[ -n "$major" && "$major" -lt 16 ]]; then
    echo "  ! Xcode $major < 16:工程用 Swift 6 语言模式与 SwiftData,建议升级到 16+"
  fi
else
  echo "  ✗ 没有 xcodebuild → 安装 Xcode 16+(App Store)后重跑"
  FAIL=1
fi
echo "  可用模拟器(iPhone 15 及以上 = iOS 17+):"
xcrun simctl list devices available 2>/dev/null | grep -E "iPhone 1[5-9]" | head -5 | sed 's/^/    /'

say "2) JDK(KMP 核心需要 21)"
if command -v java >/dev/null 2>&1; then
  java -version 2>&1 | head -1 | sed 's/^/  /'
else
  echo "  ! 未发现 java。若已装 Homebrew:brew install --cask temurin@21"
  echo "    或到此目录取本仓库自带的 JDK(仅 Windows 版,Mac 需另行安装)"
  FAIL=1
fi

say "3) 仓库自带 Gradle Wrapper"
if [[ -f "$REPO_ROOT/gradlew" ]]; then
  echo "  ✓ gradlew 存在(Gradle 8.14,首次运行会自动下载)"
  [[ -x "$REPO_ROOT/gradlew" ]] || { chmod +x "$REPO_ROOT/gradlew"; echo "  · 已补上可执行权限"; }
else
  echo "  ✗ 找不到 gradlew,请确认在 ordo 仓库内运行"
  FAIL=1
fi

say "4) Python(自检脚本用,可选)"
need python3 || true

if [[ "$FAIL" != "0" ]]; then
  echo ""
  echo "环境检查有未通过项,请按上面提示补装后重跑本脚本。"
  exit 1
fi

echo ""
echo "环境就绪。"
if [[ "$SETUP_ONLY" == "1" ]]; then
  echo "(--setup-only:未执行编译)下一步:bash apps/ios/tools/verify_ios.sh"
  exit 0
fi

say "5) 编译 iOS(探测任务名 → XCFramework → xcodebuild build → test → 自检)"
exec bash "$SCRIPT_DIR/verify_ios.sh"
