#!/usr/bin/env python3
"""Convert the simulator's P6 PPM screenshot to PNG (stdlib only): ppm2png.py in.ppm out.png [scale]"""
import struct
import sys
import zlib


def main() -> None:
    src, dst = sys.argv[1], sys.argv[2]
    scale = int(sys.argv[3]) if len(sys.argv) > 3 else 1
    data = open(src, "rb").read()
    parts = data.split(maxsplit=4)
    if parts[0] != b"P6":
        raise SystemExit("not a P6 PPM")
    w, h = int(parts[1]), int(parts[2])
    pixels = parts[4][: w * h * 3]
    rows = []
    for y in range(h):
        line = pixels[y * w * 3 : (y + 1) * w * 3]
        wide = b"".join(line[x * 3 : x * 3 + 3] * scale for x in range(w))
        rows += [b"\0" + wide] * scale

    def chunk(tag: bytes, body: bytes) -> bytes:
        return struct.pack(">I", len(body)) + tag + body + struct.pack(">I", zlib.crc32(tag + body))

    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w * scale, h * scale, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(b"".join(rows), 9)) + chunk(b"IEND", b"")
    open(dst, "wb").write(png)


if __name__ == "__main__":
    main()
