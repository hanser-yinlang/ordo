#!/usr/bin/env python3
"""
Ordo · 源码编码扫描(防"乱码还能编译通过"这一类静默损坏)

背景:在 Windows PowerShell 下用 `Get-Content -Raw` + `Set-Content -Encoding UTF8`
读写含中文的源文件,会把 UTF-8 当 ANSI(GBK) 往返,把中文变成乱码 —— 而乱码字符串
仍然是合法的字符串字面量,**编译与测试都会通过**,只有肉眼才能发现。

检测两类问题(逐行判定,因此同一文件里"正常中文 + 局部乱码"也能查出来):
  A 类(可逆乱码):某行去掉引号后仍能 "GBK 编码 → UTF-8 解码" 成功,且解出的仍是中文
     → 可用 --fix 自动还原
  B 类(有损乱码):行内出现 '?' 且去掉 '?' 后其余部分可逆 —— 说明有字节在往返中丢失
     → 只能人工修复(工具会打印出上下文)

用法:
  python tools/check-encoding.py           # 只扫描
  python tools/check-encoding.py --fix     # 自动还原 A 类
"""
import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SKIP_DIRS = {'node_modules', 'oh_modules', 'build', 'dist', '.gradle', '.git', '.kotlin', '.idea', 'schemas'}
TEXT_EXT = {'.kt', '.kts', '.ets', '.ts', '.tsx', '.js', '.mjs', '.json', '.json5',
            '.xml', '.md', '.sql', '.yml', '.yaml', '.properties', '.html', '.css', '.ps1', '.py'}

CJK = re.compile(r'[\u4e00-\u9fff]')
# 检测/修复工具自身会把这些字符当作"数据"使用,需要豁免
SELF_MARKERS = ('MARKERS', 'mojibake_markers', 'repair_encoding')


def reversible(segment: str):
    """若 segment 是"UTF-8 被当 GBK 读"的产物,返回还原后的文本,否则 None"""
    if not CJK.search(segment):
        return None
    try:
        fixed = segment.encode('gbk').decode('utf-8')
    except Exception:
        return None
    return fixed if CJK.search(fixed) else None


def scan(fix: bool = False):
    class_a = []   # (rel, lineno, original, fixed)
    class_b = []   # (rel, lineno, line)
    bad_utf8 = []
    checked = 0
    fixed_files = []

    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for fn in filenames:
            if os.path.splitext(fn)[1].lower() not in TEXT_EXT:
                continue
            path = os.path.join(dirpath, fn)
            rel = os.path.relpath(path, ROOT)
            try:
                raw = io.open(path, encoding='utf-8').read()
            except UnicodeDecodeError as e:
                bad_utf8.append((rel, str(e)))
                continue
            except Exception:
                continue
            checked += 1
            if any(m in raw for m in SELF_MARKERS):
                continue

            lines = raw.split('\n')
            changed = False
            for i, line in enumerate(lines, 1):
                if '\ufffd' in line:
                    class_b.append((rel, i, 'contains U+FFFD (irreversible)'))
                    continue
                fixed = reversible(line)
                if fixed is not None:
                    class_a.append((rel, i, line.strip()[:90], fixed.strip()[:90]))
                    if fix:
                        lines[i - 1] = fixed
                        changed = True
                    continue
                # B 类:丢了字节 —— 去掉 '?' 后其余可逆
                if '?' in line and CJK.search(line):
                    stripped = line.replace('?', '')
                    if reversible(stripped) is not None:
                        class_b.append((rel, i, line.strip()[:90]))
            if fix and changed:
                io.open(path, 'w', encoding='utf-8', newline='').write('\n'.join(lines))
                fixed_files.append(rel)

    print('scanned %d text files under %s' % (checked, ROOT))
    if bad_utf8:
        print('\ninvalid UTF-8 (%d):' % len(bad_utf8))
        for rel, msg in bad_utf8:
            print('  x %s  %s' % (rel, msg))
    if fixed_files:
        print('\nAUTO-FIXED %d file(s):' % len(fixed_files))
        for f in fixed_files:
            print('  ~ %s' % f)
    if class_a and not fix:
        print('\nA) reversible mojibake (%d lines) - run with --fix to repair:' % len(class_a))
        for rel, i, before, after in class_a[:25]:
            print('  x %s:%d' % (rel, i))
            print('      before: %s' % before)
            print('      after : %s' % after)
        if len(class_a) > 25:
            print('  ... and %d more' % (len(class_a) - 25))
    if class_b:
        print('\nB) lossy / suspicious mojibake (%d lines) - needs manual repair:' % len(class_b))
        for rel, i, text in class_b[:25]:
            print('  x %s:%d  %s' % (rel, i, text))
        if len(class_b) > 25:
            print('  ... and %d more' % (len(class_b) - 25))

    problems = len(class_a) + len(class_b) + len(bad_utf8)
    if problems == 0:
        print('\nOK: no encoding problems found')
        return 0
    print('\nNOTE: mojibake still compiles and still passes tests - it must be fixed by hand or tool.')
    return 1


if __name__ == '__main__':
    sys.exit(scan(fix='--fix' in sys.argv))
