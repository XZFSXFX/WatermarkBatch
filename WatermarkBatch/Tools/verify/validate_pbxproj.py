#!/usr/bin/env python3
"""project.pbxproj（OpenStep plist）语法 + 引用校验器。

Xcode 的 CFPropertyList old-style parser 规则，与本文件里实现的文法一致：
  dict  := '{' ( key '=' value ';' )* '}'
  array := '(' ( value ','? )* ')'
  value := quoted-string | bare-string | dict | array
裸字符串只允许 [A-Za-z0-9_$+/:.-]（Apple 文档口径），其余字符（含中文、逗号、
括号、空格）必须加双引号——手写 pbxproj 出的事故 90% 在这一条上。

用法:
  python3 Tools/verify/validate_pbxproj.py WatermarkBatch.xcodeproj/project.pbxproj
退出码 0 = 合法。
"""

import re
import sys

DELIMS = set("{}()=;,\"")
# Apple old-style parser 允许出现在裸字符串里的字符
BARE_OK = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_$+/:.-")
WS = " \t\r\n"
UUID_RE = re.compile(r"[0-9A-Fa-f]{24}")


class Tok:
    __slots__ = ("kind", "text", "line", "bare")

    def __init__(self, kind, text, line, bare=False):
        self.kind, self.text, self.line, self.bare = kind, text, line, bare


def tokenize(src):
    toks, errs = [], []
    i, line, n = 0, 1, len(src)
    while i < n:
        c = src[i]
        if c == "\n":
            line += 1
            i += 1
            continue
        if c in WS:
            i += 1
            continue
        if src.startswith("/*", i):
            end = src.find("*/", i + 2)
            if end < 0:
                errs.append((line, "块注释未闭合"))
                break
            line += src.count("\n", i, end)
            i = end + 2
            continue
        if src.startswith("//", i):
            end = src.find("\n", i)
            i = n if end < 0 else end
            continue
        if c == '"':
            start_line, i, buf, closed = line, i + 1, [], False
            while i < n:
                ch = src[i]
                if ch == "\\" and i + 1 < n:
                    buf.append(src[i:i + 2])
                    if src[i + 1] == "\n":
                        line += 1
                    i += 2
                    continue
                if ch == '"':
                    closed, i = True, i + 1
                    break
                if ch == "\n":
                    line += 1
                buf.append(ch)
                i += 1
            if not closed:
                errs.append((start_line, "双引号字符串未闭合"))
                break
            toks.append(Tok("str", "".join(buf), start_line))
            continue
        if c in "{}()=;,":
            toks.append(Tok(c, c, line))
            i += 1
            continue
        start, start_line = i, line
        while i < n and src[i] not in DELIMS and src[i] not in WS:
            i += 1
        toks.append(Tok("str", src[start:i], start_line, bare=True))
    return toks, errs


class Parser:
    def __init__(self, toks, lines):
        self.t, self.i, self.lines = toks, 0, lines
        self.errors = []      # (line, msg)
        self.warnings = []    # (line, msg)

    def peek(self):
        return self.t[self.i] if self.i < len(self.t) else None

    def line_text(self, line):
        return self.lines[line - 1] if 1 <= line <= len(self.lines) else "<EOF>"

    def err(self, line, msg):
        self.errors.append((line, msg))

    def parse(self):
        if not self.t:
            self.err(1, "文件为空")
            return None
        root = self.value()
        extra = self.peek()
        if extra is not None:
            self.err(extra.line, f"根字典已闭合，后面还有多余内容 {extra.text!r}")
        return root

    def value(self):
        tok = self.peek()
        if tok is None:
            self.err(self.t[-1].line if self.t else 1, "文件意外结束，此处缺值")
            return None
        if tok.kind == "{":
            return self.dict(tok)
        if tok.kind == "(":
            return self.array(tok)
        if tok.kind == "str":
            self.i += 1
            if tok.bare:
                bad = sorted({ch for ch in tok.text if ch not in BARE_OK})
                if bad:
                    self.err(tok.line,
                             f"裸字符串 {tok.text!r} 含非法字符 {''.join(bad)!r}，必须用双引号包住")
            return tok.text
        self.err(tok.line, f"此处应为值，实际是 {tok.text!r}")
        self.i += 1
        return None

    def dict(self, open_tok):
        node = {}
        self.i += 1
        while True:
            tok = self.peek()
            if tok is None:
                self.err(open_tok.line, "字典未闭合：缺 '}'")
                return node
            if tok.kind == "}":
                self.i += 1
                return node
            if tok.kind != "str":
                self.err(tok.line, f"字典内此处应为键名，实际是 {tok.text!r}")
                self.i += 1
                continue
            key, key_line = tok.text, tok.line
            self.i += 1
            eq = self.peek()
            if eq is None or eq.kind != "=":
                self.err(key_line if eq is None else eq.line,
                         f"键 {key!r} 后缺 '='（实际 {eq.text!r}）" if eq else f"键 {key!r} 后缺 '='（文件结束）")
                while self.peek() is not None and self.peek().kind not in (";", "}"):
                    self.i += 1
                if self.peek() is not None and self.peek().kind == ";":
                    self.i += 1
                    continue
                if self.peek() is None:
                    return node
                continue
            self.i += 1
            val_tok = self.peek()
            val = self.value()
            semi = self.peek()
            if semi is None:
                self.err(val_tok.line if val_tok else key_line,
                         f"键 {key!r} 的值后缺 ';'（文件结束）")
                node[key] = val
                return node
            if semi.kind != ";":
                self.err(semi.line,
                         f"键 {key!r} 的值缺结尾 ';'，实际遇到 {semi.text!r}")
                node[key] = val
                if semi.kind == "}":
                    continue          # 留给循环顶部报"字典未闭合/键名"路径
                if semi.kind == "=":
                    self.i += 1
                    continue
                continue
            self.i += 1
            node[key] = val

    def array(self, open_tok):
        out = []
        self.i += 1
        while True:
            tok = self.peek()
            if tok is None:
                self.err(open_tok.line, "数组未闭合：缺 ')'")
                return out
            if tok.kind == ")":
                self.i += 1
                return out
            if tok.kind == ",":
                self.i += 1
                continue
            if tok.kind in ("{", "("):
                out.append(self.value())
                continue
            if tok.kind == "str":
                out.append(self.value())
                continue
            if tok.kind == "=":
                # 常见手写错误：数组元素里混进 "key = value"
                self.err(tok.line, "数组内出现 '='，这里应该是元素而不是键值对")
                self.i += 1
                continue
            if tok.kind == ";":
                self.err(tok.line, "数组内出现 ';'（数组元素用逗号分隔，可能是上一行漏了 ')'）")
                self.i += 1
                continue
            self.err(tok.line, f"数组内此处应为元素，实际是 {tok.text!r}")
            self.i += 1


def collect(node, defined, refs, path="root"):
    if isinstance(node, dict):
        for k, v in node.items():
            if UUID_RE.fullmatch(k) and k not in defined:
                defined.add(k)
            collect(v, defined, refs, k)
    elif isinstance(node, list):
        for v in node:
            if isinstance(v, str) and UUID_RE.fullmatch(v):
                refs.setdefault(v, path)
            collect(v, defined, refs, path)
    elif isinstance(node, str) and UUID_RE.fullmatch(node):
        refs.setdefault(node, path)


def main(path):
    src = open(path, "r", encoding="utf-8").read()
    lines = src.split("\n")
    toks, tok_errs = tokenize(src)
    p = Parser(toks, lines)
    root = p.parse()

    print("=" * 74)
    print(f"{path}")
    print(f"行数 {len(lines)}  token {len(toks)}  语法错误 {len(tok_errs) + len(p.errors)} 处")
    print("=" * 74)

    if tok_errs or p.errors:
        for line, msg in tok_errs + p.errors:
            print(f"\n  ✗ L{line}: {msg}")
            print(f"      {p.line_text(line).strip()}")

    defined, refs = set(), {}
    if isinstance(root, dict) and isinstance(root.get("objects"), dict):
        defined = set(root["objects"].keys())
        collect(root["objects"], defined, refs)
    dangling = {k: v for k, v in refs.items() if k not in defined}

    print(f"\n对象 {len(defined)} 个，被引用 {len(refs)} 个，悬空引用 {len(dangling)} 个")
    for k, v in sorted(dangling.items()):
        print(f"  ✗ 悬空 {k}（在 {v} 中被引用）")

    ok = not (tok_errs or p.errors or dangling)
    print("\n结果:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "WatermarkBatch.xcodeproj/project.pbxproj"))
