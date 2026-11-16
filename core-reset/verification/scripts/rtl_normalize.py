#!/usr/bin/env python3
"""Normalise generated SystemVerilog and print a manifest (TESTPLAN section 7.1).

usage: rtl_normalize.py <rtl_dir>                      manifest on stdout
       rtl_normalize.py --diff <manifest_a> <manifest_b> [section_a [section_b]]
                                                       list the files that differ (or exist on one side only);
                                                       a section [name] selects a part of elab/ident_ref_*.txt

What is hashed per file (*.sv, *.v, *.svh, *.conf; not *.fir, *.anno.json, filelist.f):
  1. comments are removed (// and /* */, outside string literals): make verilog appends `git log -n 1; git diff`
     as comments to XSTop.sv, CIRCT writes a header;
  2. `Name.scala:12` and `Name.scala:12:3` become `Name.scala:N` (assert and printf messages);
  3. in CommitIDModule*.sv and PrintCommitIDModule*.sv every sized hex literal becomes <CONST> (the commit SHA and
     the dirty flag of the build are in there);
  4. empty lines and trailing blanks are dropped.
Manifest: one line `sha256  relative/path` per file in sorted order, last line `TOTAL <sha256 of the lines above>
files=N`. The RTL itself is not stored; two manifests are compared by TOTAL, and by lines when TOTAL differs.
"""
import hashlib
import os
import re
import sys

EXTS = (".sv", ".v", ".svh", ".conf")
SCALA_LOC = re.compile(r"([A-Za-z0-9_]+\.scala):\d+(?::\d+)?")
HEX_LIT = re.compile(r"\d+'h[0-9a-fA-F_]+")


def strip_comments(text):
    """Remove // and /* */ comments outside of "string literals"; a removed comment leaves its newline."""
    out = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == '"':
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            out.append(text[i:j + 1])
            i = j + 1
        elif c == "/" and i + 1 < n and text[i + 1] == "/":
            j = text.find("\n", i)
            i = n if j < 0 else j       # keep the newline itself
        elif c == "/" and i + 1 < n and text[i + 1] == "*":
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append("\n" * text.count("\n", i, j))
            i = j
        else:
            out.append(c)
            i += 1
    return "".join(out)


def normalise(path, text):
    text = strip_comments(text)
    text = SCALA_LOC.sub(r"\1:N", text)
    base = os.path.basename(path)
    if base.startswith("CommitIDModule") or base.startswith("PrintCommitIDModule"):
        text = HEX_LIT.sub("<CONST>", text)
    lines = [ln.rstrip() for ln in text.splitlines()]
    return "\n".join(ln for ln in lines if ln) + "\n"


def manifest(rtl_dir):
    entries = []
    for root, _, files in os.walk(rtl_dir):
        for fn in files:
            if fn.endswith(EXTS) and fn != "filelist.f":
                entries.append(os.path.relpath(os.path.join(root, fn), rtl_dir))
    entries.sort()
    lines = []
    for rel in entries:
        with open(os.path.join(rtl_dir, rel), encoding="utf-8", errors="surrogateescape") as f:
            norm = normalise(rel, f.read())
        lines.append("%s  %s" % (hashlib.sha256(norm.encode("utf-8", "surrogateescape")).hexdigest(), rel))
    total = hashlib.sha256(("\n".join(lines) + "\n").encode()).hexdigest()
    return lines, "TOTAL %s files=%d" % (total, len(lines))


def read_manifest(path, section=None):
    """{relative path: sha256} from a manifest, or from a file with [section] headers (elab/ident_ref_*.txt)."""
    res = {}
    cur = None
    with open(path) as f:
        for ln in f:
            h = re.match(r"^\[(\w+)\]$", ln.strip())
            if h:
                cur = h.group(1)
                continue
            if section is not None and cur != section:
                continue
            m = re.match(r"^([0-9a-f]{64})  (\S.*)$", ln.rstrip("\n"))
            if m:
                res[m.group(2)] = m.group(1)
    return res


def diff(a_path, b_path, sec_a=None, sec_b=None):
    a, b = read_manifest(a_path, sec_a), read_manifest(b_path, sec_b or sec_a)
    for rel in sorted(set(a) | set(b)):
        if rel not in a:
            print("only in B: %s" % rel)
        elif rel not in b:
            print("only in A: %s" % rel)
        elif a[rel] != b[rel]:
            print("differs:   %s" % rel)


def main():
    if len(sys.argv) in (4, 5, 6) and sys.argv[1] == "--diff":
        diff(*sys.argv[2:])
    elif len(sys.argv) == 2 and not sys.argv[1].startswith("-"):
        lines, total = manifest(sys.argv[1])
        print("\n".join(lines))
        print(total)
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
