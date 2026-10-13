#!/usr/bin/env python3
"""Fail when app text uses a character the device's built-in font cannot draw.

    python3 scripts/check_glyphs.py [--giiicon ../GiiiCon]
"""
import argparse
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def font_codepoints(path: Path) -> set[int]:
    data = path.read_bytes()
    if data[:4] != b"GFT1":
        raise SystemExit(f"{path}: not a GFT1 font")
    (count,) = struct.unpack_from("<I", data, 8)
    return {struct.unpack_from("<I", data, 16 + i * 8)[0] & 0xFFFFFF for i in range(count)}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--giiicon", default=str(ROOT.parent / "GiiiCon"))
    a = ap.parse_args()
    have = font_codepoints(Path(a.giiicon) / "assets/fonts/giii-12.gft")
    missing: dict[str, set[str]] = {}
    for src in sorted((ROOT / "app").rglob("*.lua")):
        if "dist" in src.relative_to(ROOT / "app").parts:
            continue
        for lineno, line in enumerate(src.read_text(encoding="utf-8").splitlines(), 1):
            code = line.split("--", 1)[0]  # comments are never drawn
            for ch in code:
                if ord(ch) >= 128 and ord(ch) not in have:
                    missing.setdefault(ch, set()).add(f"{src.relative_to(ROOT)}:{lineno}")
    for ch, where in sorted(missing.items()):
        print(f"missing glyph {ch!r} U+{ord(ch):04X}: {', '.join(sorted(where))}")
    print("glyphs: " + ("OK" if not missing else f"{len(missing)} missing"))
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
