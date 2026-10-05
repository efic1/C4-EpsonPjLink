#!/usr/bin/env python3
"""Convert the small Markdown subset used in www/documentation.md to RTF.

Composer Pro shows www/documentation.rtf on the driver's Documentation tab.
Supported: # / ## / ### headings, paragraphs, '- ' bullets, pipe tables,
fenced code blocks, **bold**, *italic* and `inline code`.
"""
import re
import sys


def esc(text):
    out = []
    for ch in text:
        if ch in "\\{}":
            out.append("\\" + ch)
        elif ord(ch) > 127:
            code = ord(ch)
            if code > 32767:
                code -= 65536
            out.append("\\u%d?" % code)
        else:
            out.append(ch)
    return "".join(out)


def inline(text):
    """Apply bold / italic / code markup, escaping everything else."""
    pattern = re.compile(r"(\*\*.+?\*\*|\*[^*\s][^*]*?\*|`[^`]+`)")
    parts, pos = [], 0
    for m in pattern.finditer(text):
        parts.append(esc(text[pos:m.start()]))
        token = m.group(0)
        if token.startswith("**"):
            parts.append("{\\b " + esc(token[2:-2]) + "}")
        elif token.startswith("`"):
            parts.append("{\\f1 " + esc(token[1:-1]) + "}")
        else:
            parts.append("{\\i " + esc(token[1:-1]) + "}")
        pos = m.end()
    parts.append(esc(text[pos:]))
    return "".join(parts)


def convert(md):
    out = [
        "{\\rtf1\\ansi\\ansicpg1252\\deff0",
        "{\\fonttbl{\\f0\\fswiss Arial;}{\\f1\\fmodern Courier New;}}",
        "\\viewkind4\\uc1\\pard\\f0\\fs20",
    ]
    lines = md.splitlines()
    i = 0
    in_code = False
    while i < len(lines):
        line = lines[i]
        if line.strip().startswith("```"):
            in_code = not in_code
            i += 1
            continue
        if in_code:
            out.append("\\pard\\f1\\fs18 " + esc(line) + "\\par")
            i += 1
            continue
        if not line.strip():
            i += 1
            continue

        m = re.match(r"^(#{1,3})\s+(.*)$", line)
        if m:
            level = len(m.group(1))
            size = {1: 36, 2: 28, 3: 24}[level]
            out.append("\\pard\\sb200\\sa100\\f0\\b\\fs%d %s\\b0\\fs20\\par" % (size, inline(m.group(2))))
            i += 1
            continue

        if line.lstrip().startswith("|"):
            rows = []
            while i < len(lines) and lines[i].lstrip().startswith("|"):
                cells = [c.strip() for c in lines[i].strip().strip("|").split("|")]
                if not all(re.fullmatch(r":?-{2,}:?", c) for c in cells):
                    rows.append(cells)
                i += 1
            for r, cells in enumerate(rows):
                text = "  |  ".join(inline(c) for c in cells)
                if r == 0:
                    out.append("\\pard\\sb60\\sa20\\b " + text + "\\b0\\par")
                else:
                    out.append("\\pard\\li360\\sa20 " + text + "\\par")
            out.append("\\pard\\sa100\\par")
            continue

        m = re.match(r"^\s*-\s+(.*)$", line)
        if m:
            out.append("\\pard\\fi-240\\li480\\sa40 \\bullet\\tab " + inline(m.group(1)) + "\\par")
            i += 1
            continue

        m = re.match(r"^\s*(\d+)\.\s+(.*)$", line)
        if m:
            out.append("\\pard\\fi-300\\li540\\sa40 %s.\\tab %s\\par" % (m.group(1), inline(m.group(2))))
            i += 1
            continue

        out.append("\\pard\\sa100 " + inline(line) + "\\par")
        i += 1

    out.append("}")
    return "\n".join(out) + "\n"


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: md_to_rtf.py input.md output.rtf")
    with open(sys.argv[1], encoding="utf-8") as f:
        rtf = convert(f.read())
    with open(sys.argv[2], "w", encoding="ascii", errors="strict", newline="\n") as f:
        f.write(rtf)
    print("wrote", sys.argv[2])
