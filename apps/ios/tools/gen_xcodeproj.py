#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_xcodeproj.py —— 生成 Ordo.xcodeproj/project.pbxproj(并校验结构)。

为什么用生成器:pbxproj 里每个对象都需要 24 位十六进制唯一 ID,手写极易出错。
生成器扫描 `Ordo/**/*.swift` 与 `OrdoTests/**/*.swift`,按文件路径派生稳定 ID
(同一路径永远得到同一个 ID),因此重新生成不会产生无意义的 diff。

用法(在 apps/ios 目录下):
    python tools/gen_xcodeproj.py            # 生成 + 校验
    python tools/gen_xcodeproj.py --check    # 只校验现有 pbxproj

校验内容:括号配平、ID 长度与唯一性、所有被引用 ID 均已定义。
"""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent            # apps/ios
APP_DIR = ROOT / "Ordo"
TEST_DIR = ROOT / "OrdoTests"
PROJECT_DIR = ROOT / "Ordo.xcodeproj"
PBXPROJ = PROJECT_DIR / "project.pbxproj"

BUNDLE_ID = "com.ordo.app"
TEST_BUNDLE_ID = "com.ordo.app.tests"
DEPLOYMENT_TARGET = "17.0"
SWIFT_VERSION = "6.0"

SKIP_DIRS = {"Resources", ".git"}


def uid(key: str) -> str:
    """由稳定键派生 24 位十六进制 ID。"""
    return hashlib.md5(key.encode("utf-8")).hexdigest()[:24].upper()


def swift_sources(directory: Path) -> list[Path]:
    if not directory.exists():
        return []
    result: list[Path] = []
    for path in sorted(directory.rglob("*.swift")):
        if any(part in SKIP_DIRS for part in path.relative_to(directory).parts):
            continue
        result.append(path)
    return result


def rel(path: Path) -> str:
    """相对 apps/ios 的 POSIX 路径。"""
    return path.relative_to(ROOT).as_posix()


def quote(value: str) -> str:
    if re.fullmatch(r"[A-Za-z0-9_./$()\-]+", value):
        return value
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


class Pbx:
    def __init__(self) -> None:
        self.sections: dict[str, list[str]] = {}
        self.objects: dict[str, str] = {}

    def add(self, section: str, obj_id: str, body: str, label: str | None = None) -> None:
        if obj_id in self.objects:
            raise SystemExit(f"ID 冲突: {obj_id}")
        self.objects[obj_id] = body
        # pbxproj 的对象条目必须以 `;` 结尾;注释里只放标签,避免出现 `/* { */` 这类噪音。
        self.sections.setdefault(section, []).append(
            f"\t\t{obj_id} /* {label or section} */ = {body};"
        )

    def render(self) -> str:
        out: list[str] = ["// !$*UTF8*$!", "{", "\tarchiveVersion = 1;", "\tclasses = {", "\t};",
                          "\tobjectVersion = 56;", "\tobjects = {", ""]
        for section in sorted(self.sections):
            out.append(f"/* Begin {section} section */")
            out.extend(self.sections[section])
            out.append(f"/* End {section} section */")
            out.append("")
        out.append("\t};")
        out.append(f"\trootObject = {uid('project')} /* Project object */;")
        out.append("}")
        out.append("")
        return "\n".join(out)


def build() -> str:
    project = Pbx()

    app_swift = swift_sources(APP_DIR)
    test_swift = swift_sources(TEST_DIR)
    assets = APP_DIR / "Resources" / "Assets.xcassets"

    # ---------------------------------------------------------------- 文件引用
    file_refs: dict[str, str] = {}     # 绝对路径 → fileRef ID

    def file_ref(path: Path, file_type: str | None = None, name: str | None = None) -> str:
        key = str(path)
        if key in file_refs:
            return file_refs[key]
        ref = uid("fileref:" + key)
        file_refs[key] = ref
        # 统一用 SOURCE_ROOT + 相对 apps/ios 的路径:分组只做导航,不叠加路径,
        # 避免出现 "Ordo/Ordo/..." 这类 Xcode 找不到的红色引用。
        rel_path = rel(path) if path.is_relative_to(ROOT) else str(path)
        attributes = ["isa = PBXFileReference"]
        if file_type:
            attributes.append(f"lastKnownFileType = {file_type}")
        attributes.append(f"name = {quote(path.name)}")
        attributes.append(f"path = {quote(rel_path)}")
        attributes.append("sourceTree = SOURCE_ROOT")
        project.add("PBXFileReference", ref, "{ " + "; ".join(attributes) + "; }")
        return ref

    for path in app_swift + test_swift:
        file_ref(path, "sourcecode.swift")
    assets_ref = file_ref(assets, "folder.assetcatalog")
    info_ref = file_ref(ROOT / "Config" / "Info.plist", "text.plist.xml")
    entitlements_ref = file_ref(ROOT / "Config" / "Ordo.entitlements", "text.plist.entitlements")

    # ---------------------------------------------------------------- 产物引用
    app_product = uid("product:app")
    test_product = uid("product:tests")
    project.add("PBXFileReference", app_product,
                "{ isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; "
                "path = Ordo.app; sourceTree = BUILT_PRODUCTS_DIR; }")
    project.add("PBXFileReference", test_product,
                "{ isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; "
                "path = OrdoTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; }")

    # ---------------------------------------------------------------- 构建文件
    app_build_files: list[str] = []
    for path in app_swift:
        ref = file_refs[str(path)]
        build_id = uid("build:app:" + str(path))
        project.add("PBXBuildFile", build_id,
                    f"{{ isa = PBXBuildFile; fileRef = {ref} /* {path.name} */; }}")
        app_build_files.append(build_id)

    assets_build = uid("build:assets")
    project.add("PBXBuildFile", assets_build,
                f"{{ isa = PBXBuildFile; fileRef = {assets_ref} /* Assets.xcassets */; }}")

    test_build_files: list[str] = []
    for path in test_swift:
        ref = file_refs[str(path)]
        build_id = uid("build:test:" + str(path))
        project.add("PBXBuildFile", build_id,
                    f"{{ isa = PBXBuildFile; fileRef = {ref} /* {path.name} */; }}")
        test_build_files.append(build_id)

    # ---------------------------------------------------------------- 分组
    # 分组只承担导航层级(不设置 path);文件引用统一用 SOURCE_ROOT 的完整相对路径,
    # 因此不会出现「组路径 + 文件路径」重复拼接导致文件变红的问题。
    def group(group_id: str, name: str | None, children: list[str]) -> None:
        parts = ["isa = PBXGroup", "children = ("]
        for child in children:
            parts.append(f"\t\t\t\t{child},")
        parts.append("\t\t\t)")
        if name:
            parts.append(f"name = {quote(name)}")
        parts.append("sourceTree = \"<group>\"")
        body = "{\n" + "\n".join(parts) + "\n\t\t}"
        project.add("PBXGroup", group_id, body)

    # Ordo 组:顶层源码 + 每个子目录一个虚拟分组(本端源码最深一层)
    ordo_children: list[str] = [file_refs[str(p)] for p in app_swift if p.parent == APP_DIR]
    by_dir: dict[Path, list[Path]] = {}
    for path in app_swift:
        if path.parent != APP_DIR:
            by_dir.setdefault(path.parent, []).append(path)
    for subdir, files in sorted(by_dir.items(), key=lambda item: str(item[0])):
        children = [file_refs[str(p)] for p in files]
        gid = uid("group:" + rel(subdir))
        group(gid, subdir.name, children)
        ordo_children.append(gid)
    # 资源目录(Assets.xcassets)挂在 Ordo 组末尾
    ordo_children.append(assets_ref)

    ordo_group = uid("group:Ordo")
    group(ordo_group, "Ordo", ordo_children)

    test_group = uid("group:OrdoTests")
    group(test_group, "OrdoTests", [file_refs[str(p)] for p in test_swift])

    config_group = uid("group:Config")
    group(config_group, "Config", [info_ref, entitlements_ref])

    products_group = uid("group:Products")
    group(products_group, "Products", [app_product, test_product])

    root_group = uid("group:root")
    group(root_group, None, [ordo_group, test_group, config_group, products_group])

    # ---------------------------------------------------------------- 构建阶段
    app_sources = uid("phase:app:sources")
    body = "{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n" + \
           "".join(f"\t\t\t\t{bid},\n" for bid in app_build_files) + "\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}"
    project.add("PBXSourcesBuildPhase", app_sources, body)

    app_resources = uid("phase:app:resources")
    body = "{\n\t\t\tisa = PBXResourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n" + \
           f"\t\t\t\t{assets_build},\n" + "\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}"
    project.add("PBXResourcesBuildPhase", app_resources, body)

    app_frameworks = uid("phase:app:frameworks")
    body = "{\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n" + \
           "\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}"
    project.add("PBXFrameworksBuildPhase", app_frameworks, body)

    test_sources = uid("phase:test:sources")
    body = "{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n" + \
           "".join(f"\t\t\t\t{bid},\n" for bid in test_build_files) + "\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}"
    project.add("PBXSourcesBuildPhase", test_sources, body)

    test_frameworks = uid("phase:test:frameworks")
    body = "{\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n" + \
           "\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}"
    project.add("PBXFrameworksBuildPhase", test_frameworks, body)

    test_resources = uid("phase:test:resources")
    body = "{\n\t\t\tisa = PBXResourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n" + \
           "\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}"
    project.add("PBXResourcesBuildPhase", test_resources, body)

    # Gradle:构建并嵌入 KMP 框架(必须在编译 Swift 之前执行)
    gradle_phase = uid("phase:gradle")
    script = ("cd \\\"$SRCROOT/../../shared/core\\\"\\n"
              "./gradlew :shared:core:embedAndSignAppleFrameworkForXcode\\n")
    body = ("{\n\t\t\tisa = PBXShellScriptBuildPhase;\n\t\t\talwaysOutOfDate = 1;\n"
            "\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n"
            "\t\t\tinputPaths = (\n\t\t\t);\n"
            "\t\t\tname = \"Build KMP OrdoCore framework\";\n"
            "\t\t\toutputPaths = (\n\t\t\t);\n"
            "\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t\tshellPath = /bin/sh;\n"
            f"\t\t\tshellScript = \"{script}\";\n\t\t}}")
    project.add("PBXShellScriptBuildPhase", gradle_phase, body)

    # ---------------------------------------------------------------- 目标
    app_target = uid("target:app")
    body = ("{\n\t\t\tisa = PBXNativeTarget;\n"
            "\t\t\tbuildConfigurationList = " + uid("configlist:app") + ";\n"
            "\t\t\tbuildPhases = (\n"
            f"\t\t\t\t{gradle_phase},\n\t\t\t\t{app_sources},\n\t\t\t\t{app_frameworks},\n\t\t\t\t{app_resources},\n"
            "\t\t\t);\n"
            "\t\t\tbuildRules = (\n\t\t\t);\n"
            "\t\t\tdependencies = (\n\t\t\t);\n"
            "\t\t\tname = Ordo;\n"
            "\t\t\tproductName = Ordo;\n"
            f"\t\t\tproductReference = {app_product};\n"
            "\t\t\tproductType = \"com.apple.product-type.application\";\n\t\t}"
            )
    project.add("PBXNativeTarget", app_target, body)

    test_target = uid("target:tests")
    body = ("{\n\t\t\tisa = PBXNativeTarget;\n"
            "\t\t\tbuildConfigurationList = " + uid("configlist:tests") + ";\n"
            "\t\t\tbuildPhases = (\n"
            f"\t\t\t\t{test_sources},\n\t\t\t\t{test_frameworks},\n\t\t\t\t{test_resources},\n"
            "\t\t\t);\n"
            "\t\t\tbuildRules = (\n\t\t\t);\n"
            f"\t\t\tdependencies = (\n\t\t\t\t{uid('dependency:tests')},\n\t\t\t);\n"
            "\t\t\tname = OrdoTests;\n"
            "\t\t\tproductName = OrdoTests;\n"
            f"\t\t\tproductReference = {test_product};\n"
            "\t\t\tproductType = \"com.apple.product-type.bundle.unit-test\";\n\t\t}"
            )
    project.add("PBXNativeTarget", test_target, body)

    project.add("PBXTargetDependency", uid("dependency:tests"),
                "{ isa = PBXTargetDependency; target = " + app_target + "; targetProxy = " +
                uid("proxy:tests") + "; }")
    project.add("PBXContainerItemProxy", uid("proxy:tests"),
                "{ isa = PBXContainerItemProxy; containerPortal = " + uid("project") +
                "; proxyType = 1; remoteGlobalIDString = " + app_target +
                "; remoteInfo = Ordo; }")

    # ---------------------------------------------------------------- 工程
    body = ("{\n\t\t\tisa = PBXProject;\n\t\t\tattributes = {\n"
            "\t\t\t\tBuildIndependentTargetsInParallel = 1;\n"
            "\t\t\t\tLastSwiftUpdateCheck = 1600;\n\t\t\t\tLastUpgradeCheck = 1600;\n"
            "\t\t\t\tTargetAttributes = {\n"
            f"\t\t\t\t\t{app_target} = {{ CreatedOnToolsVersion = 16.0; }};\n"
            f"\t\t\t\t\t{test_target} = {{ CreatedOnToolsVersion = 16.0; TestTargetID = {app_target}; }};\n"
            "\t\t\t\t};\n\t\t\t};\n"
            "\t\t\tbuildConfigurationList = " + uid("configlist:project") + ";\n"
            "\t\t\tcompatibilityVersion = \"Xcode 14.0\";\n"
            "\t\t\tdevelopmentRegion = \"zh-Hans\";\n"
            "\t\t\thasScannedForEncodings = 0;\n"
            "\t\t\tknownRegions = (\n\t\t\t\t\"zh-Hans\",\n\t\t\t\ten,\n\t\t\t\tBase,\n\t\t\t);\n"
            "\t\t\tmainGroup = " + root_group + ";\n"
            f"\t\t\tproductRefGroup = {products_group};\n"
            "\t\t\tprojectDirPath = \"\";\n\t\t\tprojectRoot = \"\";\n"
            "\t\t\ttargets = (\n"
            f"\t\t\t\t{app_target},\n\t\t\t\t{test_target},\n"
            "\t\t\t);\n\t\t}"
            )
    project.add("PBXProject", uid("project"), body)

    # ---------------------------------------------------------------- 构建设置
    def settings_block(settings: dict[str, str]) -> str:
        lines = ["{\n\t\t\tbuildSettings = {"]
        for key in sorted(settings):
            lines.append(f"\t\t\t\t{key} = {settings[key]};")
        lines.append("\t\t\t};")
        lines.append("\t\t\tname = \"$(CONFIGURATION)\";")   # 占位,稍后替换
        lines.append("\t\t}")
        return "\n".join(lines)

    def configuration(config_id: str, name: str, settings: dict[str, str]) -> None:
        lines = ["{\n\t\t\tisa = XCBuildConfiguration;", "\t\t\tbuildSettings = {"]
        for key in sorted(settings):
            lines.append(f"\t\t\t\t{key} = {settings[key]};")
        lines.append("\t\t\t};")
        lines.append(f"\t\t\tname = {name};")
        lines.append("\t\t}")
        project.add("XCBuildConfiguration", config_id, "\n".join(lines))

    def config_list(list_id: str, debug_id: str, release_id: str) -> None:
        body = ("{\n\t\t\tisa = XCConfigurationList;\n"
                "\t\t\tbuildConfigurations = (\n"
                f"\t\t\t\t{debug_id},\n\t\t\t\t{release_id},\n"
                "\t\t\t);\n"
                "\t\t\tdefaultConfigurationIsVisible = 0;\n"
                "\t\t\tdefaultConfigurationName = Release;\n\t\t}")
        project.add("XCConfigurationList", list_id, body)

    common_project = {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "CLANG_ANALYZER_NONNULL": "YES",
        "CLANG_ENABLE_MODULES": "YES",
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "CLANG_WARN_BOOL_CONVERSION": "YES",
        "CLANG_WARN_DOCUMENTATION_COMMENTS": "YES",
        "CLANG_WARN_EMPTY_BODY": "YES",
        "CLANG_WARN_UNREACHABLE_CODE": "YES",
        "COPY_PHASE_STRIP": "NO",
        "ENABLE_STRICT_OBJC_MSGSEND": "YES",
        "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
        "GCC_C_LANGUAGE_STANDARD": "gnu17",
        "GCC_NO_COMMON_BLOCKS": "YES",
        "GCC_WARN_UNINITIALIZED_AUTOS": "YES",
        "IPHONEOS_DEPLOYMENT_TARGET": DEPLOYMENT_TARGET,
        "SDKROOT": "iphoneos",
        "SWIFT_VERSION": SWIFT_VERSION,
        "SWIFT_STRICT_CONCURRENCY": "complete",
        "ENABLE_MODULE_VERIFIER": "NO",
    }
    debug_project = dict(common_project, **{
        "DEBUG_INFORMATION_FORMAT": "dwarf",
        "ENABLE_TESTABILITY": "YES",
        "GCC_OPTIMIZATION_LEVEL": "0",
        "GCC_PREPROCESSOR_DEFINITIONS": "(\n\t\t\t\t\t\"DEBUG=1\",\n\t\t\t\t\t\"$(inherited)\",\n\t\t\t\t)",
        "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
        "ONLY_ACTIVE_ARCH": "YES",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG",
        "SWIFT_OPTIMIZATION_LEVEL": "\"-Onone\"",
    })
    release_project = dict(common_project, **{
        "DEBUG_INFORMATION_FORMAT": "\"dwarf-with-dsym\"",
        "ENABLE_NS_ASSERTIONS": "NO",
        "MTL_ENABLE_DEBUG_INFO": "NO",
        "SWIFT_COMPILATION_MODE": "wholemodule",
        "VALIDATE_PRODUCT": "YES",
    })

    framework_search = ("(\n\t\t\t\t\t\"$(inherited)\",\n"
                        "\t\t\t\t\t\"$(SRCROOT)/../../shared/core/build/xcode-frameworks/$(CONFIGURATION)/$(SDK_NAME)\",\n"
                        "\t\t\t\t)")
    other_ldflags = "(\n\t\t\t\t\t\"$(inherited)\",\n\t\t\t\t\t\"-framework\",\n\t\t\t\t\tOrdoCore,\n\t\t\t\t)"

    app_common = {
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
        "CODE_SIGN_ENTITLEMENTS": "Config/Ordo.entitlements",
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "1",
        "FRAMEWORK_SEARCH_PATHS": framework_search,
        "GENERATE_INFOPLIST_FILE": "NO",
        "INFOPLIST_FILE": "Config/Info.plist",
        "LD_RUNPATH_SEARCH_PATHS": "(\n\t\t\t\t\t\"$(inherited)\",\n\t\t\t\t\t\"@executable_path/Frameworks\",\n\t\t\t\t)",
        "MARKETING_VERSION": "1.0.0",
        "OTHER_LDFLAGS": other_ldflags,
        "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
        "PRODUCT_NAME": "Ordo",
        "SUPPORTS_MACCATALYST": "NO",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
        "TARGETED_DEVICE_FAMILY": "\"1,2\"",
    }
    test_common = {
        "BUNDLE_LOADER": "\"$(TEST_HOST)\"",
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "1",
        "FRAMEWORK_SEARCH_PATHS": framework_search,
        "GENERATE_INFOPLIST_FILE": "YES",
        "MARKETING_VERSION": "1.0.0",
        "OTHER_LDFLAGS": other_ldflags,
        "PRODUCT_BUNDLE_IDENTIFIER": TEST_BUNDLE_ID,
        "PRODUCT_NAME": "OrdoTests",
        "SWIFT_EMIT_LOC_STRINGS": "NO",
        "TARGETED_DEVICE_FAMILY": "\"1,2\"",
        "TEST_HOST": "\"$(BUILT_PRODUCTS_DIR)/Ordo.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/Ordo\"",
    }

    for name, settings in (("Debug", debug_project), ("Release", release_project)):
        configuration(uid(f"config:project:{name}"), name, settings)
    config_list(uid("configlist:project"), uid("config:project:Debug"), uid("config:project:Release"))

    for name in ("Debug", "Release"):
        configuration(uid(f"config:app:{name}"), name, app_common)
    config_list(uid("configlist:app"), uid("config:app:Debug"), uid("config:app:Release"))

    for name in ("Debug", "Release"):
        configuration(uid(f"config:tests:{name}"), name, test_common)
    config_list(uid("configlist:tests"), uid("config:tests:Debug"), uid("config:tests:Release"))

    _ = settings_block  # 保留辅助函数以备扩展
    return project.render()


# ------------------------------------------------------------------ 校验

SCHEME_TEMPLATE = """<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1600"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{app_target}"
               BuildableName = "Ordo.app"
               BlueprintName = "Ordo"
               ReferencedContainer = "container:Ordo.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference
            skipped = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{test_target}"
               BuildableName = "OrdoTests.xctest"
               BlueprintName = "OrdoTests"
               ReferencedContainer = "container:Ordo.xcodeproj">
            </BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{app_target}"
            BuildableName = "Ordo.app"
            BlueprintName = "Ordo"
            ReferencedContainer = "container:Ordo.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{app_target}"
            BuildableName = "Ordo.app"
            BlueprintName = "Ordo"
            ReferencedContainer = "container:Ordo.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""


def write_scheme() -> Path:
    """生成共享 Scheme(BlueprintIdentifier 必须与 pbxproj 中的目标 ID 一致)。"""
    path = PROJECT_DIR / "xcshareddata" / "xcschemes" / "Ordo.xcscheme"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        SCHEME_TEMPLATE.format(app_target=uid("target:app"), test_target=uid("target:tests")),
        encoding="utf-8",
        newline="\n",
    )
    return path


def validate(text: str) -> list[str]:
    problems: list[str] = []
    # 注释里也会出现花括号/括号,先剥离注释再计数。
    stripped = re.sub(r"/\*.*?\*/", "", text, flags=re.DOTALL)
    if stripped.count("{") != stripped.count("}"):
        problems.append(f"花括号不配平:{{={stripped.count('{')} }}={stripped.count('}')}")
    if stripped.count("(") != stripped.count(")"):
        problems.append(f"圆括号不配平:(={stripped.count('(')} )={stripped.count(')')}")
    # 每个对象条目都要以 `};` 收尾(单行与多行两种写法都适用)
    if stripped.count("= {") != stripped.count("};"):
        problems.append(
            f"对象条目未正确收尾:= {{ 出现 {stripped.count('= {')} 次,}}; 出现 {stripped.count('};')} 次"
        )

    defined = set(re.findall(r"^\t\t([0-9A-F]{24}) /\*", text, re.MULTILINE))
    if len(defined) != len(re.findall(r"^\t\t([0-9A-F]{24}) /\*", text, re.MULTILINE)):
        problems.append("存在重复对象 ID")
    referenced = set(re.findall(r"\b([0-9A-F]{24})\b", text))
    undefined = sorted(referenced - defined - {uid("project")})
    # rootObject 也会在 objects 中定义,这里仅报告真正缺失的引用
    undefined = [item for item in undefined if item not in defined]
    if undefined:
        problems.append(f"引用了未定义的 ID: {undefined[:5]}")
    if "rootObject" not in text:
        problems.append("缺少 rootObject")
    if "PBXNativeTarget" not in text or "PBXSourcesBuildPhase" not in text:
        problems.append("缺少目标或构建阶段")
    if not re.search(r"INFOPLIST_FILE = Config/Info\.plist;", text):
        problems.append("缺少 INFOPLIST_FILE 设置")
    if "-framework" not in text or "OrdoCore" not in text:
        problems.append("缺少对 OrdoCore 的链接设置")
    return problems


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="只校验现有 pbxproj")
    args = parser.parse_args()

    if args.check:
        if not PBXPROJ.exists():
            print(f"未找到 {PBXPROJ}")
            return 1
        text = PBXPROJ.read_text(encoding="utf-8")
    else:
        text = build()
        PROJECT_DIR.mkdir(parents=True, exist_ok=True)
        PBXPROJ.write_text(text, encoding="utf-8", newline="\n")
        scheme = write_scheme()
        print(f"已生成 {PBXPROJ} ({len(text.splitlines())} 行)")
        print(f"已生成 {scheme}")

    problems = validate(text)
    if problems:
        print("校验失败:")
        for item in problems:
            print("  -", item)
        return 1
    print("校验通过:括号配平、ID 唯一、引用完整、链接与 Info.plist 设置齐备")
    return 0


if __name__ == "__main__":
    sys.exit(main())
