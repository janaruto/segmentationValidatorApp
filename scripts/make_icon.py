#!/usr/bin/env python3
"""Draws the 1024x1024 app icon (a small timeline of movement segments) without any dependencies.

Usage: python3 scripts/make_icon.py SegmentationValidator/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png
"""
import struct
import sys
import zlib

SIZE = 1024

TOP = (0x12, 0x9A, 0x9C)     # teal
BOTTOM = (0x14, 0x3B, 0x73)  # deep blue

# (x0, y0, x1, y1, color) - three segments of a day, like a Gantt chart
BARS = [
    (170, 262, 560, 372, (0xFF, 0xFF, 0xFF)),
    (500, 419, 860, 529, (0xB4, 0xF0, 0xA8)),
    (290, 576, 720, 686, (0xFF, 0xD5, 0x8A)),
]
RADIUS = 55
# Thin "time axis" under the bars
AXIS = (150, 752, 874, 766, (0xFF, 0xFF, 0xFF))
AXIS_ALPHA = 0.55


def rounded_rect_coverage(px, py, x0, y0, x1, y1, r):
    """Anti-aliased coverage (0..1) of a rounded rectangle at pixel center (px, py)."""
    cx = min(max(px, x0 + r), x1 - r)
    cy = min(max(py, y0 + r), y1 - r)
    dx = px - cx
    dy = py - cy
    if x0 + r <= px <= x1 - r or y0 + r <= py <= y1 - r:
        # Straight edges: distance to the rectangle border.
        inside_x = min(px - x0, x1 - px)
        inside_y = min(py - y0, y1 - py)
        distance = -min(inside_x, inside_y)
    else:
        distance = (dx * dx + dy * dy) ** 0.5 - r
    return min(max(0.5 - distance, 0.0), 1.0)


def blend(base, color, alpha):
    return tuple(b + (c - b) * alpha for b, c in zip(base, color))


def render():
    rows = []
    for y in range(SIZE):
        t = y / (SIZE - 1)
        background = tuple(TOP[i] + (BOTTOM[i] - TOP[i]) * t for i in range(3))
        row = bytearray([0])  # PNG filter type 0
        for x in range(SIZE):
            px, py = x + 0.5, y + 0.5
            pixel = background
            ax0, ay0, ax1, ay1, acolor = AXIS
            if ay0 - 2 <= py <= ay1 + 2 and ax0 - 2 <= px <= ax1 + 2:
                coverage = rounded_rect_coverage(px, py, ax0, ay0, ax1, ay1, 7)
                if coverage > 0:
                    pixel = blend(pixel, acolor, coverage * AXIS_ALPHA)
            for x0, y0, x1, y1, color in BARS:
                if y0 - 2 <= py <= y1 + 2 and x0 - 2 <= px <= x1 + 2:
                    coverage = rounded_rect_coverage(px, py, x0, y0, x1, y1, RADIUS)
                    if coverage > 0:
                        pixel = blend(pixel, color, coverage)
            row.extend(int(round(c)) for c in pixel)
        rows.append(bytes(row))
    return b"".join(rows)


def write_png(path, raw):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    header = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0)  # 8 bit RGB, no alpha
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    with open(path, "wb") as handle:
        handle.write(png)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    write_png(sys.argv[1], render())
