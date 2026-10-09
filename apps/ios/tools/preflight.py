#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
preflight.py —— 在 Windows / Linux 上把"能查的都查掉",让 macOS 上的首次编译尽量一次过。

背景:本工程的 iOS 端无法在 Windows 上编译
  · Swift on Windows 存在,但工程 import 的 SwiftUI / SwiftData / EventKit / UIKit /
    AppIntents / UserNotifications / CoreGraphics 都是 Apple 平台专属模块;
  · KMP 的 Apple 目标(iosX64/iosArm64/iosSimulatorArm64)只在 macOS 主机启用,
    因此连 OrdoCore.xcframework 都产不出来(已实测:Windows 上 :shared:core 没有任何
    *XCFramework 任务)。
所以本脚本做的是**编译前**能做的全部机械校验:配置解析、契约键、pbxproj 引用、
以及"Swift 源码引用的桥接符号是否真的存在"。这些正是首次编译最容易踩的坑。

用法(任意平台):
    python tools/preflight.py            # 全量
    python tools/preflight.py --quiet     # 只输出结论

退出码:0 = 全部通过;1 = 有阻断问题。
"""

from __future__ import annotations

import argparse
import json
import plistlib
import re
import sys
from pathlib import Path

IOS_ROOT = Path(__file__).resolve().parent.parent           # apps/ios
REPO_ROOT = IOS_ROOT.parent.parent                          # 仓库根
APP_DIR = IOS_ROOT / "Ordo"
TEST_DIR = IOS_ROOT / "OrdoTests"
CONFIG_DIR = IOS_ROOT / "Config"
PBXPROJ = IOS_ROOT / "Ordo.xcodeproj" / "project.pbxproj"
PROJECT_YML = IOS_ROOT / "project.yml"

# Apple 平台专属模块:Windows/Linux 上的 Swift 工具链**不提供**,因此无法编译
APPLE_ONLY_MODULES = {
    "SwiftUI", "SwiftData", "UIKit", "AppIntents", "EventKit",
    "UserNotifications", "CoreGraphics", "Network", "Observation",
    "UniformTypeIdentifiers", "WidgetKit", "Intents", "CoreSpotlight",
}

failures: list[str] = []
warnings: list[str] = []
checks: list[tuple[str, bool, str]] = []


def record(name: str, ok: bool, detail: str = "") -> None:
    checks.append((name, ok, detail))
    if not ok:
        failures.append(f"{name}: {detail}")


def warn(name: str, detail: str) -> None:
    warnings.append(f"{name}: {detail}")


def swift_sources() -> list[Path]:
    files: list[Path] = []
    for base in (APP_DIR, TEST_DIR):
        if base.exists():
            files.extend(sorted(base.rglob("*.swift")))
    return files


def strip_swift(text: str) -> str:
    """剥离注释与字符串(与 check_ios_sources.py 同策略),用于符号检索。"""
    out: list[str] = []
    i, n = 0, len(text)
    depth = 0
    in_line = in_str = in_multi = False
    while i < n:
        ch = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if in_line:
            if ch == "\n":
                in_line = False
                out.append(ch)
            else:
                out.append(" ")
            i += 1
            continue
        if depth > 0:
            if ch == "/" and nxt == "*":
                depth += 1
                out.append("  ")
                i += 2
                continue
            if ch == "*" and nxt == "/":
                depth -= 1
                out.append("  ")
                i += 2
                continue
            out.append("\n" if ch == "\n" else " ")
            i += 1
            continue
        if in_multi:
            if text.startswith('"""', i):
                in_multi = False
                out.append("   ")
                i += 3
                continue
            out.append("\n" if ch == "\n" else " ")
            i += 1
            continue
        if in_str:
            if ch == "\\":
                out.append("  ")
                i += 2
                continue
            if ch == '"':
                in_str = False
                out.append(" ")
                i += 1
                continue
            out.append("\n" if ch == "\n" else " ")
            i += 1
            continue
        if ch == "/" and nxt == "/":
            in_line = True
            out.append("  ")
            i += 2
            continue
        if ch == "/" and nxt == "*":
            depth = 1
            out.append("  ")
            i += 2
            continue
        if text.startswith('"""', i):
            in_multi = True
            out.append("   ")
            i += 3
            continue
        if ch == '"':
            in_str = True
            out.append(" ")
            i += 1
            continue
        out.append(ch)
        i += 1
    return "".join(out)


# ---------------------------------------------------------------- 1. 平台能力

def section(text: str, start_marker: str, end_marker: str) -> str:
    """取 `start_marker` 到 `end_marker` 之间的片段(用于把检查限定在单个类型内)。"""
    start = text.find(start_marker)
    if start < 0:
        return ""
    end = text.find(end_marker, start + len(start_marker))
    return text[start:] if end < 0 else text[start:end]


def check_platform() -> None:
    """记录"本机能否编译 iOS"。这是**环境事实**,不是代码缺陷,因此不计入失败项。"""
    import platform

    system = platform.system()
    files = swift_sources()
    imports: set[str] = set()
    for path in files:
        for line in strip_swift(path.read_text(encoding="utf-8")).split("\n"):
            match = re.match(r"\s*import\s+([A-Za-z_][\w]*)", line)
            if match:
                imports.add(match.group(1))

    unmet = sorted(imports & APPLE_ONLY_MODULES)
    kpm = sorted(imports - APPLE_ONLY_MODULES - {"Foundation"})

    if system != "Darwin":
        print(f"  · 主机 {system}:{len(unmet)} 个 Apple 专属模块不可用"
              f"({', '.join(unmet)})")
        print(f"  · KMP 模块 {kpm} 需由 macOS 主机编译出 XCFramework")
        print("  · 结论:**本机无法编译 iOS**,详见 apps/ios/README.md §5.1;"
              "macOS 上执行 `bash apps/ios/tools/verify_ios.sh`")
        record("平台能力(记录环境事实)", True, f"{system}:编译需 macOS")
    else:
        print(f"  · 主机 {system}:具备编译条件")
        record("平台能力(记录环境事实)", True, f"{system}:可编译")


# ---------------------------------------------------------------- 2. 配置解析

def check_configs() -> None:
    info_plist = CONFIG_DIR / "Info.plist"
    try:
        with info_plist.open("rb") as handle:
            plist = plistlib.load(handle)
        record("Info.plist 解析", True, "")
    except Exception as exc:                                   # noqa: BLE001
        record("Info.plist 解析", False, str(exc))
        return

    # 契约 §2.8 + §9:日历只读。iOS 17+ 需要 FullAccess 键,iOS 16 回退需要旧键
    for key in ("NSCalendarsFullAccessUsageDescription", "NSCalendarsUsageDescription"):
        value = plist.get(key)
        record(f"Info.plist 含 {key}", bool(value), "缺少该键会导致日历授权请求直接失败")
        if value and len(value) < 10:
            warn("Info.plist", f"{key} 文案过短,App Store 审核可能要求更完整的用途说明")

    # 深链(设计规范 §7)
    url_types = plist.get("CFBundleURLTypes") or []
    schemes = [s for entry in url_types for s in (entry.get("CFBundleURLSchemes") or [])]
    record("Info.plist 注册 ordo:// scheme", "ordo" in schemes, f"实际 schemes={schemes}")

    # 本地开发 ATS 例外
    ats = plist.get("NSAppTransportSecurity") or {}
    record("Info.plist ATS 本地例外", bool(ats.get("NSExceptionDomains")),
           "缺少时无法连本机 http://127.0.0.1:8787")

    # 通知说明(自定义键,设置页展示)
    record("Info.plist 含 OrdoNotificationPermissionExplanation",
           bool(plist.get("OrdoNotificationPermissionExplanation")), "")

    # entitlements
    ent_path = CONFIG_DIR / "Ordo.entitlements"
    try:
        with ent_path.open("rb") as handle:
            ent = plistlib.load(handle)
        record("Ordo.entitlements 解析", True, "")
        record("entitlements 含 aps-environment", bool(ent.get("aps-environment")), "")
        domains = ent.get("com.apple.developer.associated-domains") or []
        record("entitlements 含 associated-domains", bool(domains), f"实际={domains}")
        # 日历读不需要 entitlement,多了反而会被签名拒绝
        stray = [k for k in ent if "calendar" in k.lower()]
        record("entitlements 未误加日历权限", not stray, f"多余键={stray}")
    except Exception as exc:                                   # noqa: BLE001
        record("Ordo.entitlements 解析", False, str(exc))

    # project.yml 与 pbxproj 的关键设置必须一致
    try:
        yml = PROJECT_YML.read_text(encoding="utf-8")
    except Exception as exc:                                   # noqa: BLE001
        record("project.yml 读取", False, str(exc))
        return
    for needle, label in (
        ('IPHONEOS_DEPLOYMENT_TARGET: "17.0"', "project.yml 部署目标 17.0"),
        ("INFOPLIST_FILE: Config/Info.plist", "project.yml Info.plist 指向"),
        ("CODE_SIGN_ENTITLEMENTS: Config/Ordo.entitlements", "project.yml entitlements 指向"),
        ("SWIFT_VERSION: \"6.0\"", "project.yml Swift 语言版本 6.0"),
    ):
        record(label, needle in yml, f"未找到 `{needle}`")


# ---------------------------------------------------------------- 3. pbxproj 引用

def check_pbxproj() -> None:
    if not PBXPROJ.exists():
        record("project.pbxproj 存在", False, str(PBXPROJ))
        return
    text = PBXPROJ.read_text(encoding="utf-8")
    record("project.pbxproj 存在", True, "")

    for needle, label in (
        ("INFOPLIST_FILE = Config/Info.plist", "pbxproj 设置 INFOPLIST_FILE"),
        ("CODE_SIGN_ENTITLEMENTS = Config/Ordo.entitlements", "pbxproj 设置 CODE_SIGN_ENTITLEMENTS"),
        ("-framework", "pbxproj 链接 OrdoCore(-framework)"),
        ("OrdoCore", "pbxproj 引用 OrdoCore"),
        ("IPHONEOS_DEPLOYMENT_TARGET = 17.0", "pbxproj 部署目标 17.0"),
    ):
        record(label, needle in text, f"未找到 `{needle}`")

    # 每个 .swift 都必须进入编译目标,否则 macOS 上会"少编译一个文件"却不报错
    missing: list[str] = []
    for path in swift_sources():
        if path.name not in text:
            missing.append(path.relative_to(IOS_ROOT).as_posix())
    record(f"全部 {len(swift_sources())} 个 Swift 文件已纳入工程", not missing,
           f"未纳入={missing[:5]}")

    # 新增/删除文件后必须重跑生成器
    gen = IOS_ROOT / "tools" / "gen_xcodeproj.py"
    if gen.exists():
        warn("提示", "新增/删除 .swift 后请重跑 `python tools/gen_xcodeproj.py`")


# ---------------------------------------------------------------- 4. 桥接符号

def check_bridge_symbols() -> None:
    """iOS 代码调用的桥接类型/方法,必须真的在协议或桥接层里有定义。

    这是 Windows 上最接近"类型检查"的机械替代:抓出 `engine.xxx(` 形式的调用,
    验证每一项都在 `OrdoEngineProtocol` 里声明、且在 `OrdoCoreBridge` 里实现。
    """
    protocol_path = APP_DIR / "Core" / "OrdoEngineProtocol.swift"
    bridge_path = APP_DIR / "Core" / "OrdoCoreBridge.swift"
    if not protocol_path.exists() or not bridge_path.exists():
        record("桥接层文件存在", False, "缺少 OrdoEngineProtocol.swift / OrdoCoreBridge.swift")
        return
    record("桥接层文件存在", True, "")

    # 只取 `OrdoEngineProtocol` 这一个协议的成员,避免把 OrdoClock / OrdoUUIDProvider 等算进来
    protocol_src = strip_swift(protocol_path.read_text(encoding="utf-8"))
    protocol_body = section(protocol_src, "public protocol OrdoEngineProtocol", "\n}\n")
    # 只取 `OrdoCoreBridge` 这一个类的成员
    bridge_src = strip_swift(bridge_path.read_text(encoding="utf-8"))
    bridge_body = section(bridge_src, "public final class OrdoCoreBridge", "\n}\n")

    declared = set(re.findall(r"func\s+(\w+)\s*\(", protocol_body))
    implemented = set(re.findall(r"func\s+(\w+)\s*\(", bridge_body))
    record(f"OrdoEngineProtocol 解析出方法({len(declared)} 个)", len(declared) > 40,
           f"只解析到 {len(declared)} 个,协议文件结构可能变了")

    missing_impl = sorted(declared - implemented)
    record(f"协议 {len(declared)} 个方法在 OrdoCoreBridge 均有实现", not missing_impl,
           f"未实现={missing_impl}")

    # 全工程对 engine.xxx( 的调用都必须是协议成员(flushStorage 是桥接层扩展方法)
    extra_allowed = {"flushStorage"}
    called: set[str] = set()
    for path in swift_sources():
        code = strip_swift(path.read_text(encoding="utf-8"))
        called |= set(re.findall(r"\bengine\.(\w+)\s*\(", code))
    unknown = sorted(called - declared - extra_allowed)
    record(f"对 engine 的 {len(called)} 个调用点都在协议内", not unknown,
           f"协议未声明={unknown}")

    # Kotlin 闭包式 API 的 Swift 面约定
    for name in ("updateTodo", "updateProject", "updateHeading"):
        signature_ok = bool(re.search(rf"func\s+{name}\s*\(id:\s*String,\s*mutate:", bridge_body))
        record(f"桥接层 {name}(id:mutate:) 签名符合约定", signature_ok,
               "应为 `(id: String, mutate: (inout OrdoX) -> Void)`")


# ---------------------------------------------------------------- 5. Swift 侧风险

def check_swift_hazards() -> None:
    files = swift_sources()
    swiftdata = APP_DIR / "Data" / "SwiftDataStorage.swift"
    model = APP_DIR / "Core" / "OrdoModel.swift"

    # SwiftData 的 `repeat` 必须带反引号(裸 repeat 是 Swift 关键字)
    for path in (swiftdata, model):
        if not path.exists():
            continue
        code = strip_swift(path.read_text(encoding="utf-8"))
        bare_repeat = re.findall(r"(?<![`\w])repeat\s*[:=]", code)
        record(f"{path.name} 的 repeat 字段使用反引号", not bare_repeat,
               f"裸 `repeat` 是 Swift 关键字,必须写 `` `repeat` ``;命中 {bare_repeat[:3]}")

    # SwiftData 里"自定义 Codable 结构数组"是易碎点:能编译不代表能落库,
    # 建议在 macOS 上用一个真实的增删改查往返测试确认(README §5.2 第 5 条)。
    if swiftdata.exists():
        code = strip_swift(swiftdata.read_text(encoding="utf-8"))
        composite_arrays = sorted(set(re.findall(r"var\s+\w+\s*:\s*\[(Ordo\w+)\]", code)))
        if composite_arrays:
            warn("SwiftData 风险点",
                 f"自定义 Codable 结构数组 {composite_arrays} 直接作为属性;"
                 "SwiftData 对这类属性支持较弱,请在 macOS 上跑一次落库往返测试,"
                 "失败则改为 JSON 字符串存储(README §5.2 第 5 条)")
        else:
            record("SwiftData 无自定义结构数组属性", True, "")
        # 纯值类型数组([String])是原生支持的,不应被误报
        record("SwiftData 的 [String] 数组属原生支持", "var tags: [String]" in code, "")

    # 可用性:iOS 17 双参数 onChange(真正需要保护的是 API 版本,不是该修饰器本身)
    for path in files:
        code = strip_swift(path.read_text(encoding="utf-8"))
        if re.search(r"\.onChange\(of:\s*[^)]+\)\s*\{\s*[^,)]+,\s*[^)]+in", code):
            # 双参数闭包 = iOS 17+ API;部署目标已是 17.0,故只是提示
            warn("可用性", f"{path.relative_to(IOS_ROOT).as_posix()} 使用 iOS 17 双参数 onChange"
                          "(部署目标 17.0 已满足;若回退 iOS 16 需改回单参数形式)")
            break

    # 明确的 iOS 17 专属 API 必须有 #available(或位于 #available 分支内)
    guarded_apis = ("requestFullAccessToEvents",)
    for path in files:
        code = strip_swift(path.read_text(encoding="utf-8"))
        for api in guarded_apis:
            if api in code and "#available(iOS 17" not in code:
                record(f"{path.name} 的 {api} 有版本保护", False,
                       "iOS 17 专属 API 需 #available 分支 + iOS 16 回退")
    if all(ok for name, ok, _ in checks if "有版本保护" in name) and \
       not any("有版本保护" in name for name, _, _ in checks):
        record("iOS 17 专属 API 均有版本保护", True, "")

    # 第三方网络依赖
    joined = "\n".join(p.read_text(encoding="utf-8") for p in files)
    external = EXTERNAL.search(joined)
    record("无第三方/CDN 网络依赖", external is None,
           f"命中={external.group(0) if external else ''}")


EXTERNAL = re.compile(r"https?://(?!127\.0\.0\.1|localhost|ordo\.app|www\.apple\.com|json\.org)")


# ---------------------------------------------------------------- 主流程

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--quiet", action="store_true")
    parser.add_argument("--json", metavar="PATH", help="把结果写成 JSON")
    args = parser.parse_args()

    sections = [
        ("1) 平台能力", check_platform),
        ("2) 配置解析(Info.plist / entitlements / project.yml)", check_configs),
        ("3) Xcode 工程引用(project.pbxproj)", check_pbxproj),
        ("4) KMP 桥接符号", check_bridge_symbols),
        ("5) Swift 侧编译风险", check_swift_hazards),
    ]

    for title, fn in sections:
        if not args.quiet:
            print(f"\n=== {title} ===")
        fn()

    print("")
    passed = sum(1 for _, ok, _ in checks if ok)
    print(f"编译前预检:{len(checks)} 项,通过 {passed},未通过 {len(checks) - passed}")
    if warnings:
        print("\n提示(非阻断):")
        for item in warnings:
            print("  -", item)
    if failures:
        print("\n预检未通过:")
        for item in failures:
            print("  ✗", item)
    else:
        print("\n预检通过:配置、工程引用、桥接符号、Swift 风险项均无阻断问题。")
        print("下一步(macOS):bash apps/ios/tools/verify_ios.sh")

    if args.json:
        Path(args.json).write_text(
            json.dumps(
                {
                    "checks": [{"name": n, "ok": ok, "detail": d} for n, ok, d in checks],
                    "warnings": warnings,
                    "failures": failures,
                },
                ensure_ascii=False,
                indent=2,
            ),
            encoding="utf-8",
        )

    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
