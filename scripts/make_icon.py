#!/usr/bin/env python3
"""The Home icon (app/images/icon.bmp, 96x96, #ff00ff transparent): original procedural
pixel art, Python standard library only. Usage: make_icon.py [preview.bmp]

BMPs use BITMAPINFOHEADER, uncompressed BGR, positive height, and padded bottom-up rows.
"""
import sys
import struct
from pathlib import Path

SIZE = 96
KEY = (255, 0, 255)
pixels = [[KEY for _ in range(SIZE)] for _ in range(SIZE)]

# The scene uses a two-pixel drawing grid, with deliberately broad facets.
for y in range(SIZE):
    for x in range(SIZE):
        cx = min(max(x, 16), 79)
        cy = min(max(y, 16), 79)
        if (x-cx)**2 + (y-cy)**2 <= 16**2:
            t = y / 95
            pixels[y][x] = (int(16-9*t), int(29-13*t), int(62-22*t))


def polygon(points, color):
    """Fill a polygon on a 2px grid using pixel-centre winding crossings."""
    for y in range(0, SIZE, 2):
        for x in range(0, SIZE, 2):
            px, py = x + 1, y + 1
            inside = False
            for i, (ax, ay) in enumerate(points):
                bx, by = points[(i+1) % len(points)]
                if (ay > py) != (by > py):
                    if px < ax + (py-ay) * (bx-ax) / (by-ay):
                        inside = not inside
            if inside:
                for dy in range(2):
                    for dx in range(2):
                        if pixels[y+dy][x+dx] != KEY:
                            pixels[y+dy][x+dx] = color


def rect(x, y, w, h, color):
    polygon([(x,y),(x+w,y),(x+w,y+h),(x,y+h)], color)


# Quiet star field: five plain 2px white points, clear of the main objects.
for x, y in [(48,12),(12,38),(42,40),(86,48),(16,80)]:
    rect(x,y,2,2,(230,242,255))


def meteor(cx, cy, radius):
    def shape(coords, color):
        polygon([(cx + a*radius, cy + b*radius) for a,b in coords], color)
    shape([(-1,-.35),(-.65,-.9),(.15,-1),(.8,-.6),(1,.1),(.65,.8),(-.1,1),(-.8,.6)], (76,48,37))
    shape([(-.85,-.35),(-.55,-.75),(.1,-.85),(.7,-.45),(.8,.1),(.5,.65),(-.1,.8),(-.7,.5)], (143,94,62))
    shape([(-.8,-.35),(-.5,-.75),(.1,-.85),(.35,-.4),(-.15,0),(-.65,.05)], (201,150,101))
    shape([(.35,-.4),(.7,-.45),(.8,.1),(.5,.65),(.1,.65),(.1,.1)], (110,70,48))
    shape([(-.45,-.15),(-.1,-.3),(.15,-.05),(0,.3),(-.4,.25)], (91,59,43))
    shape([(-.4,-.15),(-.1,-.3),(.15,-.05),(-.1,-.02)], (162,112,74))

meteor(26,24,14)
meteor(66,40,11)
meteor(78,16,6)

# Hand-tuned five-point collectible; deep valleys keep both lower legs clear.
polygon([(20,44),(24,50),(32,50),(26,56),(28,66),
         (20,60),(12,66),(14,56),(8,50),(16,50)], (255,216,67))
polygon([(20,46),(22,50),(20,56),(12,52),(18,52)], (255,246,156))
polygon([(20,58),(26,62),(26,64),(20,60),(14,64),(14,62)], (244,165,39))

# Compact barrier pickup: cyan outline around a readable blue shield.
polygon([(72,60),(78,58),(86,62),(84,70),(78,76),(72,72),(70,64)], (53,168,226))
polygon([(74,62),(78,60),(84,64),(82,70),(78,74),(74,70)], (103,229,255))
polygon([(76,64),(80,64),(80,68),(78,72),(76,68)], (29,91,166))

# Flame is drawn behind the ship. Its broad orange body survives downsampling.
polygon([(42,78),(54,78),(54,84),(50,92),(46,90),(42,84)], (244,98,31))
polygon([(44,78),(52,78),(52,84),(48,88),(44,84)], (255,181,54))
polygon([(46,78),(50,78),(50,84),(46,84)], (255,241,156))

# Upward fighter: silver needle nose, cyan canopy, swept red wing tips.
polygon([(48,48),(52,56),(54,66),(58,70),(66,80),(66,84),(56,80),(54,82),(42,82),(40,80),(30,84),(30,80),(38,70),(42,66),(44,56)], (52,69,104))
polygon([(38,72),(42,68),(42,78),(32,82)], (222,65,78))
polygon([(54,68),(58,72),(64,82),(54,78)], (184,44,62))
polygon([(38,72),(42,70),(38,78),(34,80)], (255,113,111))
polygon([(54,70),(58,74),(62,80),(56,78)], (234,81,86))
polygon([(48,50),(50,56),(52,68),(54,78),(50,80),(44,80),(42,78),(44,68),(46,56)], (158,182,207))
polygon([(48,50),(48,78),(44,78),(44,68),(46,56)], (221,236,247))
polygon([(48,56),(52,62),(50,68),(46,68),(44,62)], (28,101,151))
polygon([(48,56),(50,60),(50,64),(48,66),(46,64),(46,60)], (95,222,252))
rect(46,58,2,4,(197,253,255))
rect(44,78,8,4,(80,105,139))


def write_bmp(path, data):
    height, width = len(data), len(data[0])
    stride = (width*3+3) & ~3
    image_size = stride*height
    with path.open('wb') as output:
        output.write(struct.pack('<2sIHHI', b'BM', 54+image_size, 0, 0, 54))
        output.write(struct.pack('<IiiHHIIiiII', 40, width, height, 1, 24,
                                 0, image_size, 2835, 2835, 0, 0))
        for row in reversed(data):
            output.write(bytes(channel for r,g,b in row for channel in (b,g,r)))
            output.write(bytes(stride-width*3))


if __name__ == '__main__':
    out = Path(__file__).resolve().parent.parent / 'app' / 'images' / 'icon.bmp'
    out.parent.mkdir(exist_ok=True)
    write_bmp(out, pixels)
    print(f'Wrote {out} (96x96).')
    if len(sys.argv) > 1:  # a 4x enlargement to look at
        preview = [[pixels[y//4][x//4] for x in range(SIZE*4)] for y in range(SIZE*4)]
        write_bmp(Path(sys.argv[1]), preview)
