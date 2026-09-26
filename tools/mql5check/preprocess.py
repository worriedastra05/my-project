#!/usr/bin/env python3
"""
Translate an .mq5 source file into something g++ can type-check against
tools/mql5check/mql5_shim.hpp.

This is a development aid only - it never touches the file that MetaEditor
compiles. It catches typos, undefined helpers, wrong argument counts and
type errors without needing a Windows machine.

Transformations
---------------
  #property ...                 -> dropped
  #include <Trade\Trade.mqh>    -> dropped (the shim supplies CTrade)
  input group "..." ;           -> dropped
  input  / sinput  / extern     -> static
  TYPE name[];                  -> MqlArr<TYPE> name;
  TYPE &name[]                  -> MqlArr<TYPE>& name      (function parameters)
"""

import re
import sys

BUILTIN_STRUCTS = {"MqlRates", "MqlTick", "MqlDateTime", "MqlBookInfo", "MqlParam"}

# TYPE &name[]  ->  MqlArr<TYPE>& name      (must run before the decl rule)
RE_REF_ARRAY = re.compile(r"\b(const\s+)?([A-Za-z_]\w*)\s*&\s*([A-Za-z_]\w*)\s*\[\s*\]")

# TYPE name[];  ->  MqlArr<TYPE> name;
RE_DECL_ARRAY = re.compile(r"\b([A-Za-z_]\w*)\s+([A-Za-z_]\w*)\s*\[\s*\]\s*;")

RE_PROPERTY = re.compile(r"^\s*#property\b")
RE_INCLUDE_MQH = re.compile(r"^\s*#include\s*<.*\.mqh>", re.IGNORECASE)
RE_INPUT_GROUP = re.compile(r"^\s*(?:s)?input\s+group\b")
RE_INPUT = re.compile(r"^(\s*)(?:s?input|extern)\s+")


def convert(text: str) -> str:
    out = []
    for line in text.splitlines():
        if RE_PROPERTY.match(line) or RE_INCLUDE_MQH.match(line) or RE_INPUT_GROUP.match(line):
            out.append("// [stripped] " + line.strip())
            continue

        line = RE_INPUT.sub(r"\1static ", line)

        # Skip transformation inside pure comment lines.
        stripped = line.lstrip()
        if not stripped.startswith("//"):
            line = RE_REF_ARRAY.sub(r"\1MqlArr<\2>& \3", line)
            line = RE_DECL_ARRAY.sub(r"MqlArr<\1> \2;", line)

        out.append(line)
    return "\n".join(out) + "\n"


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: preprocess.py <input.mq5> <output.cpp>", file=sys.stderr)
        return 2

    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        src = fh.read()

    body = convert(src)

    header = (
        '#include "mql5_shim.hpp"\n'
        "\n"
        "// ---- translated MQL5 source below ----\n"
    )
    footer = (
        "\n"
        "// ---- force the event handlers to be referenced so g++ checks them ----\n"
        "int  OnInit();\n"
        "void OnDeinit(const int reason);\n"
        "void OnTick();\n"
        "void OnTimer();\n"
        "int main() { OnInit(); OnTick(); OnTimer(); OnDeinit(0); return 0; }\n"
    )

    with open(sys.argv[2], "w", encoding="utf-8") as fh:
        fh.write(header + body + footer)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
