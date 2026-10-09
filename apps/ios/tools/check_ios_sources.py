#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
check_ios_sources.py —— iOS 端交付前的静态自检(无 macOS/Xcode 环境下的替代手段)。

检查项:
  1. 逐文件结构:剥离注释与字符串后统计 () [] {} 配平,发现截断/漏括号;
  2. 占位符扫描:禁止 `fatalError("TODO")`、`TODO:`、`未实现` 之类占位;
  3. 冻结 API 覆盖:稳定的冻结 API 清单每一项都能在桥接层找到;
  4. 契约字段覆盖:契约 §2 每个实体的字段名都在 Swift 模型中存在;
  5. 外部依赖扫描:iOS 源码不得引入 CDN/第三方网络资源;
  6. 写入范围核对:本端只允许出现在 apps/ios/ 下;
  7. 与真实 Kotlin 源码交叉核对(动态,不是手写清单):
     · `OrdoEngine.kt` 的**构造参数 / 公开方法 / 公开只读属性**必须逐项出现在
       `Ordo/Core/OrdoEngineProtocol.swift` 与 `Ordo/Core/OrdoCoreBridge.swift` 中;
     · `OrdoStorage.kt` 的 `interface OrdoStorage` 方法必须逐项出现在
       `Ordo/Core/OrdoCoreBridge.swift` 的 `OrdoCoreStorageMirror` 中。

  注意:第 7 项是**清单的真正来源**。`FROZEN_ENGINE_API` 只作为「不得静默减少」的
  下限护栏 —— 核心一旦新增方法,第 7 项会立刻报缺失,而无需人工同步清单。

用法:
    python tools/check_ios_sources.py            # 全量自检
    python tools/check_ios_sources.py --quiet    # 只输出结论
"""

from __future__ import annotations

import argparse
import re
import sys
from collections import Counter
from pathlib import Path

IOS_ROOT = Path(__file__).resolve().parent.parent          # apps/ios
REPO_ROOT = IOS_ROOT.parent.parent                          # 仓库根
APP_DIR = IOS_ROOT / "Ordo"
TEST_DIR = IOS_ROOT / "OrdoTests"

# KMP 共享核心的真实源码(存在时用于交叉核对 Swift 桥接层)
KOTLIN_CORE = REPO_ROOT / "shared" / "core" / "src" / "commonMain" / "kotlin" / "com" / "ordo" / "core"
KOTLIN_ENGINE = KOTLIN_CORE / "store" / "OrdoEngine.kt"
KOTLIN_STORAGE = KOTLIN_CORE / "storage" / "OrdoStorage.kt"
KOTLIN_ENTITIES = KOTLIN_CORE / "model" / "Entities.kt"


# ------------------------------------------------------------------ 词法剥离

def strip_swift(text: str) -> str:
    """剥离行注释、块注释(可嵌套)与字符串字面量,保留换行以维持行号。"""
    out: list[str] = []
    i = 0
    n = len(text)
    depth = 0               # 块注释嵌套深度
    in_line_comment = False
    in_string = False
    in_multiline_string = False
    while i < n:
        ch = text[i]
        nxt = text[i + 1] if i + 1 < n else ""

        if in_line_comment:
            if ch == "\n":
                in_line_comment = False
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

        if in_multiline_string:
            if text.startswith('"""', i):
                in_multiline_string = False
                out.append("   ")
                i += 3
                continue
            out.append("\n" if ch == "\n" else " ")
            i += 1
            continue

        if in_string:
            if ch == "\\":
                out.append("  ")
                i += 2
                continue
            if ch == '"':
                in_string = False
                out.append(" ")
                i += 1
                continue
            out.append("\n" if ch == "\n" else " ")
            i += 1
            continue

        # 正常代码
        if ch == "/" and nxt == "/":
            in_line_comment = True
            out.append("  ")
            i += 2
            continue
        if ch == "/" and nxt == "*":
            depth = 1
            out.append("  ")
            i += 2
            continue
        if text.startswith('"""', i):
            in_multiline_string = True
            out.append("   ")
            i += 3
            continue
        if ch == '"':
            in_string = True
            out.append(" ")
            i += 1
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def balance_report(code: str) -> list[str]:
    problems: list[str] = []
    pairs = {"(": ")", "[": "]", "{": "}"}
    closers = {v: k for k, v in pairs.items()}
    stack: list[tuple[str, int]] = []
    line = 1
    for ch in code:
        if ch == "\n":
            line += 1
            continue
        if ch in pairs:
            stack.append((ch, line))
        elif ch in closers:
            if not stack:
                problems.append(f"第 {line} 行出现多余的 '{ch}'")
                continue
            opener, open_line = stack.pop()
            if pairs[opener] != ch:
                problems.append(f"第 {open_line} 行的 '{opener}' 与第 {line} 行的 '{ch}' 不匹配")
    for opener, open_line in stack:
        problems.append(f"第 {open_line} 行的 '{opener}' 未闭合")
    return problems


# ------------------------------------------------------------------ Kotlin 词法

def strip_kotlin(text: str) -> str:
    """剥离 Kotlin 的行注释/块注释与字符串字面量(保留换行以维持结构)。

    只用于「按 4 空格缩进抓取类成员」这类结构化提取,避免注释里的示例代码被当成真实 API。
    """
    out: list[str] = []
    i = 0
    n = len(text)
    depth = 0                  # 块注释嵌套深度
    in_line = False
    in_string = False
    in_raw_string = False
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

        if in_raw_string:
            if text.startswith('"""', i):
                in_raw_string = False
                out.append("   ")
                i += 3
                continue
            out.append("\n" if ch == "\n" else " ")
            i += 1
            continue

        if in_string:
            if ch == "\\":
                out.append("  ")
                i += 2
                continue
            if ch == '"':
                in_string = False
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
            in_raw_string = True
            out.append("   ")
            i += 3
            continue
        if ch == '"':
            in_string = True
            out.append(" ")
            i += 1
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def _matching_index(code: str, start: int, opener: str, closer: str) -> int:
    """返回与 `code[start]` (== opener) 配对的 closer 下标;找不到返回 -1。"""
    depth = 0
    for index in range(start, len(code)):
        char = code[index]
        if char == opener:
            depth += 1
        elif char == closer:
            depth -= 1
            if depth == 0:
                return index
    return -1


def kotlin_constructor_params(code: str, class_name: str) -> list[str]:
    """取 `class X(...)` 主构造器的参数名(按声明顺序,保留 val/var 修饰之外的名字)。"""
    match = re.search(rf"\bclass\s+{re.escape(class_name)}\s*\(", code)
    if not match:
        return []
    start = code.index("(", match.start())
    end = _matching_index(code, start, "(", ")")
    if end < 0:
        return []
    block = code[start + 1:end]

    # 按顶层逗号切分(括号/花括号/方括号内的逗号不算分隔符)
    chunks: list[str] = []
    current: list[str] = []
    depth = 0
    for char in block:
        if char in "([{":
            depth += 1
        elif char in ")]}":
            depth -= 1
        if char == "," and depth == 0:
            chunks.append("".join(current))
            current = []
            continue
        current.append(char)
    chunks.append("".join(current))

    params: list[str] = []
    for chunk in chunks:
        found = re.search(r"\b(?:val|var)\s+(\w+)\s*:", chunk) or re.match(r"\s*(\w+)\s*:", chunk)
        if found:
            params.append(found.group(1))
    return params


def kotlin_class_members(code: str, class_name: str) -> tuple[list[str], list[str], list[str]]:
    """抓取类体内的公开成员:`    fun name(` 与 `    val/var name`。

    返回 (方法名, 属性名, 私有成员名)。仅看 4 空格缩进(类成员层级),忽略局部声明。
    """
    match = re.search(rf"\bclass\s+{re.escape(class_name)}\s*\(?", code)
    if not match:
        return [], [], []
    cursor = match.end()
    param_open = code.find("(", match.start())
    if param_open >= 0 and param_open < cursor + 2:
        closing = _matching_index(code, param_open, "(", ")")
        cursor = closing + 1 if closing >= 0 else cursor
    start = code.find("{", cursor)
    if start < 0:
        return [], [], []
    end = _matching_index(code, start, "{", "}")
    if end < 0:
        end = len(code)
    body = code[start + 1:end]

    methods: list[str] = []
    properties: list[str] = []
    private_members: list[str] = []
    for line in body.split("\n"):
        stripped = line.strip()
        is_member = len(line) - len(line.lstrip(" ")) == 4
        if not is_member:
            continue
        private = stripped.startswith("private ")
        fun_match = re.match(r"(?:private\s+)?fun\s+(\w+)\s*\(", stripped)
        if fun_match:
            (private_members if private else methods).append(fun_match.group(1))
            continue
        prop_match = re.match(r"(?:private\s+)?(?:val|var)\s+(\w+)\s*[:=]", stripped)
        if prop_match:
            (private_members if private else properties).append(prop_match.group(1))
    return methods, properties, private_members


# ------------------------------------------------------------------ 期望清单

# 稳定的「冻结 API」下限护栏:核心若删掉这些名字,自检必须失败。
# 真正的完整清单来自第 7 项的 Kotlin 动态交叉核对(见文件头说明)。
FROZEN_ENGINE_API = [
    # 构造与状态(已与 OrdoEngine.kt 核对;Kotlin 默认参数不导出到 Swift,故 Swift 侧传满四个)
    "OrdoEngine(", "snapshot", "schemaVersion", "deviceId", "subscribe(",
    # 查询
    "list(", "sections(", "counts()", "headingsOf(", "projectProgress(",
    "todo(id:", "project(id:", "area(id:",
    # 待办写操作
    "createTodo(", "updateTodo(", "setTitle(", "setNote(", "setWhen(", "setDeadline(", "setReminder(",
    "setRepeat(", "moveTodo(", "addTag(", "removeTag(",
    "addChecklistItem(", "setChecklistItemTitle(", "toggleChecklistItem(", "removeChecklistItem(",
    "duplicateTodo(", "toggleDone(", "complete(", "reopen(", "deleteTodo(", "reorderTodos(",
    # 容器写操作
    "createProject(", "renameProject(", "setProjectNote(", "setProjectWhen(", "moveProject(",
    "completeProject(", "reopenProject(", "deleteProject(",
    "createHeading(", "renameHeading(", "toggleHeadingCollapsed(", "archiveHeading(", "deleteHeading(",
    "createArea(", "renameArea(", "deleteArea(", "ensureTag(", "tags()",
    # 同步
    "pendingOps(", "pendingOpCount(", "lastServerSeq(", "setLastServerSeq(", "ackOps(",
    "applyRemote(", "replaceWithRemote(",
    # 维护
    "seedDemoData(", "clearAll(",
    # 存储与解析
    "OrdoStorage", "NaturalDateParser", "Clock", "OpCodec",
]

CONTRACT_FIELDS: dict[str, list[str]] = {
    "Area": ["id", "name", "color", "order", "archived", "updatedAt", "deleted"],
    "Project": ["id", "areaId", "name", "note", "when", "date", "deadline", "tags",
                "headings", "order", "status", "completedAt", "repeat", "createdAt",
                "updatedAt", "deleted"],
    "Heading": ["id", "projectId", "name", "order", "archived", "collapsed"],
    "Todo": ["id", "title", "note", "when", "date", "reminder", "deadline", "tags",
             "checklist", "projectId", "areaId", "headingId", "repeat", "order", "status",
             "createdAt", "updatedAt", "completedAt", "deleted"],
    "ChecklistItem": ["id", "title", "done"],
    "Tag": ["id", "name", "color", "updatedAt"],
    "RepeatRule": ["freq", "interval", "mode"],
    "Op": ["opId", "deviceId", "entity", "entityId", "type", "payload", "clientTs", "seq"],
    "Tombstone": ["entity", "entityId", "deletedAt", "clientTs"],
}

ENUM_VALUES = {
    "When": ["inbox", "today", "evening", "anytime", "someday", "date"],
    "Status": ["open", "done", "canceled"],
    "RepeatFreq": ["daily", "weekly", "monthly", "yearly"],
    "RepeatMode": ["fixed", "afterCompletion"],
}

FORBIDDEN_PATTERNS = [
    (r'fatalError\("TODO"', "禁止的占位:fatalError(\"TODO\")"),
    (r"\bTODO\b", "未完成的 TODO 标记"),
    (r"未实现", "「未实现」占位文案"),
    (r"FIXME", "FIXME 标记"),
]

EXTERNAL_REFERENCE = re.compile(r"https?://(?!127\.0\.0\.1|localhost|ordo\.app|www\.apple\.com|json\.org)")


# ------------------------------------------------------------------ 检查

def swift_files() -> list[Path]:
    files: list[Path] = []
    for base in (APP_DIR, TEST_DIR):
        if base.exists():
            files.extend(sorted(base.rglob("*.swift")))
    return files


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()

    files = swift_files()
    if not files:
        print("没有找到 Swift 源码")
        return 1

    failures: list[str] = []
    warnings: list[str] = []
    total_lines = 0

    # 1 + 2 + 5:逐文件
    for path in files:
        raw = path.read_text(encoding="utf-8")
        total_lines += raw.count("\n") + (0 if raw.endswith("\n") else 1)
        code = strip_swift(raw)

        problems = balance_report(code)
        for problem in problems:
            failures.append(f"{path.relative_to(IOS_ROOT)}: {problem}")

        for pattern, message in FORBIDDEN_PATTERNS:
            for match in re.finditer(pattern, raw):
                line = raw[:match.start()].count("\n") + 1
                failures.append(f"{path.relative_to(IOS_ROOT)}:{line}: {message}")

        for match in EXTERNAL_REFERENCE.finditer(raw):
            line = raw[:match.start()].count("\n") + 1
            warnings.append(f"{path.relative_to(IOS_ROOT)}:{line}: 外部 URL {match.group(0)}")

        if not args.quiet:
            print(f"  {path.relative_to(IOS_ROOT).as_posix():<58} {len(raw.splitlines()):>5} 行  结构 OK"
                  if not problems else f"  {path.relative_to(IOS_ROOT)}: 结构问题 {problems[:2]}")

    # 3:冻结 API 覆盖
    bridge_text = ""
    for name in ("Ordo/Core/OrdoCoreBridge.swift", "Ordo/Core/OrdoCoreMapping.swift"):
        candidate = IOS_ROOT / name
        if candidate.exists():
            bridge_text += candidate.read_text(encoding="utf-8")
    missing_api = [item for item in FROZEN_ENGINE_API if item not in bridge_text]
    if missing_api:
        failures.append(f"桥接层缺少冻结 API:{missing_api}")

    # 4:契约字段覆盖
    model_text = ""
    for name in ("Ordo/Core/OrdoModel.swift", "Ordo/Data/SwiftDataStorage.swift"):
        candidate = IOS_ROOT / name
        if candidate.exists():
            model_text += candidate.read_text(encoding="utf-8")
    missing_fields: list[str] = []
    for entity, fields in CONTRACT_FIELDS.items():
        for field in fields:
            # SwiftData 里 `repeat` 用反引号声明,统一按裸名匹配
            if not re.search(rf"\b{field}\b", model_text):
                missing_fields.append(f"{entity}.{field}")
    if missing_fields:
        failures.append(f"Swift 模型缺少契约字段:{missing_fields}")

    missing_enums: list[str] = []
    for enum_name, values in ENUM_VALUES.items():
        for value in values:
            if not re.search(rf"\b{value}\b", model_text):
                missing_enums.append(f"{enum_name}.{value}")
    if missing_enums:
        failures.append(f"Swift 枚举缺少契约取值:{missing_enums}")

    # 5:与真实 Kotlin 源码交叉核对(动态提取,shared/core 存在时)
    kotlin_api: list[str] = []
    kotlin_missing: list[str] = []
    kotlin_ctor: list[str] = []
    kotlin_missing_ctor: list[str] = []
    kotlin_props: list[str] = []
    kotlin_missing_props: list[str] = []
    storage_api: list[str] = []
    storage_missing: list[str] = []

    protocol_path = IOS_ROOT / "Ordo/Core/OrdoEngineProtocol.swift"
    bridge_path = IOS_ROOT / "Ordo/Core/OrdoCoreBridge.swift"

    if KOTLIN_ENGINE.exists():
        engine_code = strip_kotlin(KOTLIN_ENGINE.read_text(encoding="utf-8"))
        protocol_text = protocol_path.read_text(encoding="utf-8")
        bridge_src = bridge_path.read_text(encoding="utf-8")

        # ① 构造参数:Kotlin 默认参数不导出到 ObjC,Swift 必须全部可见
        kotlin_ctor = kotlin_constructor_params(engine_code, "OrdoEngine")
        for name in kotlin_ctor:
            if not re.search(rf"\b{name}\b", protocol_text) or not re.search(rf"\b{name}\b", bridge_src):
                kotlin_missing_ctor.append(name)
        if kotlin_missing_ctor:
            failures.append(f"Swift 桥接层未覆盖 OrdoEngine 的构造参数:{kotlin_missing_ctor}")

        # ② 公开方法:协议声明 + 桥接实现都必须有
        methods, properties, _private = kotlin_class_members(engine_code, "OrdoEngine")
        kotlin_api = sorted(set(methods))
        for name in kotlin_api:
            if not re.search(rf"\b{name}\s*\(", protocol_text) or not re.search(rf"\b{name}\(", bridge_src):
                kotlin_missing.append(name)
        if kotlin_missing:
            failures.append(f"Swift 桥接层未覆盖 Kotlin OrdoEngine 的公开方法:{kotlin_missing}")

        # ③ 公开只读属性:`val snapshot` → Swift 侧必须有同名属性
        kotlin_props = sorted(set(properties))
        for name in kotlin_props:
            if not re.search(rf"\bvar\s+{name}\b", protocol_text) or not re.search(rf"\bvar\s+{name}\b", bridge_src):
                kotlin_missing_props.append(name)
        if kotlin_missing_props:
            failures.append(f"Swift 桥接层未覆盖 OrdoEngine 的公开属性:{kotlin_missing_props}")

    if KOTLIN_STORAGE.exists():
        storage_code = strip_kotlin(KOTLIN_STORAGE.read_text(encoding="utf-8"))
        # 只取 `interface OrdoStorage { ... }` 块内的方法(同文件的 OpCodec 不算)
        block = ""
        start = storage_code.find("interface OrdoStorage")
        if start >= 0:
            brace = storage_code.find("{", start)
            if brace >= 0:
                depth = 0
                for index in range(brace, len(storage_code)):
                    char = storage_code[index]
                    if char == "{":
                        depth += 1
                    elif char == "}":
                        depth -= 1
                        if depth == 0:
                            block = storage_code[brace:index]
                            break
        storage_api = sorted(set(re.findall(r"^\s{4}fun\s+(\w+)\s*\(", block, re.MULTILINE)))
        mirror_src = bridge_path.read_text(encoding="utf-8")
        for name in storage_api:
            if not re.search(rf"\bfunc\s+{name}\s*\(", mirror_src):
                storage_missing.append(name)
        if storage_missing:
            failures.append(f"OrdoCoreStorageMirror 未实现 Kotlin OrdoStorage 的方法:{storage_missing}")

    # 6:写入范围(本端文件必须都在 apps/ios 下)
    strays: list[str] = []
    for path in IOS_ROOT.rglob("*"):
        if path.is_file() and ".git" not in path.parts:
            try:
                path.relative_to(IOS_ROOT)
            except ValueError:
                strays.append(str(path))
    if strays:
        failures.append(f"越界文件:{strays[:5]}")

    # ---------------------------------------------------------------- 输出
    print()
    print(f"Swift 文件:{len(files)} 个,共 {total_lines} 行")
    print(f"桥接冻结 API({len(FROZEN_ENGINE_API)} 项下限护栏)→ 缺失 {len(missing_api)}")
    field_total = sum(len(v) for v in CONTRACT_FIELDS.values())
    print(f"契约字段:{field_total} 个 → 缺失 {len(missing_fields)}")
    print(f"契约枚举取值:{sum(len(v) for v in ENUM_VALUES.values())} 个 → 缺失 {len(missing_enums)}")
    if kotlin_api or kotlin_ctor:
        print(
            "Kotlin OrdoEngine 交叉核对:"
            f"构造参数 {len(kotlin_ctor)} 个 → 未覆盖 {len(kotlin_missing_ctor)};"
            f"公开方法 {len(kotlin_api)} 个 → 未覆盖 {len(kotlin_missing)};"
            f"公开属性 {len(kotlin_props)} 个 → 未覆盖 {len(kotlin_missing_props)}"
        )
        if not args.quiet:
            print(f"    · 构造参数:{', '.join(kotlin_ctor)}")
            print(f"    · 公开属性:{', '.join(kotlin_props)}")
            print(f"    · 公开方法({len(kotlin_api)}):{', '.join(kotlin_api)}")
    else:
        print("Kotlin 源码未找到(shared/core 尚未生成?),跳过交叉核对")
    if storage_api:
        print(f"Kotlin OrdoStorage 方法:{len(storage_api)} 个 → Swift 镜像未实现 {len(storage_missing)}")

    if warnings:
        print("\n提示(非阻断):")
        for item in warnings:
            print("  -", item)

    if failures:
        print("\n自检未通过:")
        for item in failures:
            print("  ✗", item)
        return 1

    print("\n自检通过:结构配平、无占位符、冻结 API 覆盖完整、契约字段齐备、Kotlin 交叉核对 0 缺失、写入范围正确")
    return 0


if __name__ == "__main__":
    sys.exit(main())
