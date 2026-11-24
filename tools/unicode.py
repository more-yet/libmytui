"""Regenerate Unicode tables and source checksums; use --check to verify both."""
import argparse
import hashlib
import pathlib
import subprocess
import urllib.request

FILES = {
    "GraphemeBreakProperty.txt": "auxiliary/GraphemeBreakProperty.txt",
    "DerivedCoreProperties.txt": "DerivedCoreProperties.txt",
    "EastAsianWidth.txt": "EastAsianWidth.txt",
    "emoji-data.txt": "emoji/emoji-data.txt",
    "WordBreakProperty.txt": "auxiliary/WordBreakProperty.txt",
    "LineBreak.txt": "LineBreak.txt",
    "DerivedGeneralCategory.txt": "extracted/DerivedGeneralCategory.txt",
}
GCB = ["other", "cr", "lf", "control", "extend", "zwj", "regional_indicator",
       "prepend", "spacing_mark", "l", "v", "t", "lv", "lvt"]
INCB = ["none", "consonant", "extend", "linker"]
WB = "other cr lf newline extend format zwj wsegspace aletter hebrew_letter numeric katakana extendnumlet regional_indicator midletter midnum midnumlet single_quote double_quote".split()
LB = "xx ai ak al ap as b2 ba bb bk cb cj cl cm cp cr eb em ex gl h2 h3 hh hl hy id in is jl jt jv lf nl ns nu op po pr qu ri sa sg sp sy vf vi wj zw zwj".split()


def generate(source_dir):
    tables = {name: [] for name in ["gcb", "incb", "wide", "ambiguous", "pictographic", "emoji", "word", "line", "combining", "initial", "final", "unassigned", "halfwidth"]}
    checksums = []
    for name, path in FILES.items():
        raw = ((source_dir / name).read_bytes() if source_dir else
               urllib.request.urlopen("https://www.unicode.org/Public/17.0.0/ucd/" + path, timeout=60).read())
        checksums.append(f"{hashlib.sha256(raw).hexdigest()}  {name}")
        for line in raw.decode().splitlines():
            fields = [part.strip() for part in line.split("#")[0].split(";")]
            if len(fields) < 2:
                continue
            bounds = fields[0].split("..")
            first, last = int(bounds[0], 16), int(bounds[-1], 16)
            assert 0 <= first <= last <= 0x10ffff
            prop = fields[1]
            table, value = None, 1
            if name == "GraphemeBreakProperty.txt":
                prop = prop.lower().replace("spacingmark", "spacing_mark")
                if prop in ("lv", "lvt"):
                    continue
                table, value = "gcb", GCB.index(prop)
            elif name == "DerivedCoreProperties.txt" and prop == "InCB":
                table, value = "incb", INCB.index(fields[2].lower())
            elif name == "EastAsianWidth.txt":
                table = "wide" if prop in ("W", "F") else "ambiguous" if prop == "A" else "halfwidth" if prop == "H" else None
            elif name == "emoji-data.txt":
                table = {"Extended_Pictographic": "pictographic", "Emoji_Presentation": "emoji"}.get(prop)
            elif name == "WordBreakProperty.txt":
                table, value = "word", WB.index(prop.lower())
            elif name == "LineBreak.txt":
                table, value = "line", LB.index(prop.lower())
            elif name == "DerivedGeneralCategory.txt":
                table = {"Mn": "combining", "Mc": "combining", "Pi": "initial", "Pf": "final", "Cn": "unassigned"}.get(prop)
            if table:
                tables[table].append((first, last, value))
    changes = {0: 0}
    for (name, ranges), shift in zip(tables.items(), (0, 4, 6, 7, 8, 9, 10, 15, 21, 22, 23, 24, 25)):
        previous_end = -1
        for first, last, value in sorted(ranges):
            assert first > previous_end, name
            previous_end = last
            changes[first] = changes.get(first, 0) ^ (value << shift)
            changes[last + 1] = changes.get(last + 1, 0) ^ (value << shift)
    lines = ["pub const Gcb = enum(u4) { " + ", ".join(GCB) + " };",
             "pub const Incb = enum(u2) { " + ", ".join(INCB) + " };",
             "pub const Word = enum(u5) { " + ", ".join(WB) + " };",
             "pub const LineBreak = enum(u6) { " + ", ".join(LB) + " };",
             """pub const Properties = packed struct(u32) {
    gcb: Gcb = .other,
    incb: Incb = .none,
    wide: bool = false,
    ambiguous: bool = false,
    pictographic: bool = false,
    emoji: bool = false,
    word: Word = .other,
    line: LineBreak = .xx,
    combining: bool = false,
    initial: bool = false,
    final: bool = false,
    unassigned: bool = false,
    halfwidth: bool = false,
    padding: u6 = 0,
};
const Range = struct { first: u21, value: u32 };
const ranges = [_]Range{"""]
    value = 0
    for first, change in sorted(changes.items()):
        value ^= change
        if first < 0x110000 and (first == 0 or change):
            lines.append(f"    .{{ .first = 0x{first:X}, .value = 0x{value:X} }},")
    lines.append("};")
    lines.append("""
pub fn properties(codepoint: u21) Properties {
    if (codepoint >= 0x20 and codepoint <= 0x7e) return .{};
    if (codepoint >= 0xac00 and codepoint <= 0xd7a3)
        return .{ .gcb = if ((codepoint - 0xac00) % 28 == 0) .lv else .lvt, .wide = true };
    return lookup(codepoint);
}
pub fn lookup(codepoint: u21) Properties {
    var low: usize = 0;
    var high = ranges.len;
    while (low + 1 < high) {
        const middle = low + (high - low) / 2;
        if (codepoint < ranges[middle].first) high = middle else low = middle;
    }
    return @bitCast(ranges[low].value);
}
""")
    return "\n".join(lines).encode(), ("\n".join(checksums) + "\n").encode()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-dir", type=pathlib.Path)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    output = pathlib.Path(__file__).resolve().parents[1] / "src" / "unicode.zig"
    data, checksums = generate(args.source_dir)
    # Match Zig's canonical formatting in both generation and verification.
    data = subprocess.check_output(["zig", "fmt", "--stdin"], input=data)
    for path, content in ((output, data), (pathlib.Path(__file__).with_suffix(".sha256"), checksums)):
        if args.check:
            if path.read_bytes() != content:
                raise SystemExit(f"{path.name} differs; regenerate with tools/unicode.py")
        else:
            path.write_bytes(content)
