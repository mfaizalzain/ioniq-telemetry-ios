#!/usr/bin/env python3
"""
Generate iOS App Icon set and BrandLogo from Android vector drawables.

Design (108x108 viewport):
- Background: linear gradient #13203A -> #0B1220 -> #060B15 (diagonal)
- Two subtle diagonal speed lines (#0D17E8C2, #0A17E8C2)
- SOC gauge: arc at center (54,54), radius 24.6, from 160° to 380° (220° sweep),
  stroke width 6.5, color #2E3F5F (dim track)
- SOC ring: same arc trimmed to 78%, gradient #0FBFA0 -> #3CF5D8, stroke width 6.5, round cap
- Lightning bolt: white with subtle teal overlay #3317E8C2
"""

import json
import math
import os
from pathlib import Path
from typing import Tuple

from PIL import Image, ImageDraw

# Canvas / viewport size used by the Android vector
VIEWPORT = 108.0

# Colors
BG_TOP = (0x13, 0x20, 0x3A)
BG_MID = (0x0B, 0x12, 0x20)
BG_BOT = (0x06, 0x0B, 0x15)

TRACK_COLOR = (0x2E, 0x3F, 0x5F)
RING_START = (0x0F, 0xBF, 0xA0)
RING_END = (0x3C, 0xF5, 0xD8)

SPEED_LINE_1 = (0x17, 0xE8, 0xC2, 0x0D)  # alpha 13
SPEED_LINE_2 = (0x17, 0xE8, 0xC2, 0x0A)  # alpha 10

BOLT_WHITE = (0xFF, 0xFF, 0xFF)
BOLT_OVERLAY = (0x17, 0xE8, 0xC2, 0x33)  # alpha 51

# Geometry
CENTER = (54.0, 54.0)
RADIUS = 24.6
STROKE_WIDTH = 6.5
ARC_START_DEG = 160.0
ARC_SWEEP_DEG = 220.0  # 160 -> 380
TRIM_END = 0.78

# Lightning bolt path (108 viewport)
BOLT_POINTS = [
    (57.5, 36.5),
    (43.0, 57.5),
    (51.5, 57.5),
    (48.5, 71.5),
    (64.5, 50.0),
    (55.5, 50.0),
]


def hex_to_rgba(hex_str: str) -> Tuple[int, int, int, int]:
    """Parse #AARRGGBB or #RRGGBB to RGBA tuple."""
    h = hex_str.lstrip("#")
    if len(h) == 8:
        a = int(h[0:2], 16)
        r = int(h[2:4], 16)
        g = int(h[4:6], 16)
        b = int(h[6:8], 16)
        return (r, g, b, a)
    if len(h) == 6:
        r = int(h[0:2], 16)
        g = int(h[2:4], 16)
        b = int(h[4:6], 16)
        return (r, g, b, 255)
    raise ValueError(f"Unsupported hex: {hex_str}")


def lerp(a: int, b: int, t: float) -> int:
    return int(round(a + (b - a) * t))


def lerp_color(c1, c2, t: float):
    return tuple(lerp(c1[i], c2[i], t) for i in range(3))


def draw_background(size: int) -> Image.Image:
    """Diagonal linear gradient background with subtle speed lines."""
    # Render gradient at small size and upscale (much faster than per-pixel loop)
    SMALL = 64
    small = Image.new("RGB", (SMALL, SMALL))
    for y in range(SMALL):
        for x in range(SMALL):
            t = (x + y) / (2.0 * (SMALL - 1))
            if t <= 0.55:
                tt = t / 0.55
                color = lerp_color(BG_TOP, BG_MID, tt)
            else:
                tt = (t - 0.55) / 0.45
                color = lerp_color(BG_MID, BG_BOT, tt)
            small.putpixel((x, y), color)
    img = small.resize((size, size), Image.BILINEAR).convert("RGBA")
    draw = ImageDraw.Draw(img)

    # Speed lines (scaled)
    scale = size / VIEWPORT
    # Line 1: M-10,84 L60,14  stroke 10
    x1, y1 = -10 * scale, 84 * scale
    x2, y2 = 60 * scale, 14 * scale
    draw.line([(x1, y1), (x2, y2)], fill=SPEED_LINE_1, width=int(10 * scale))

    # Line 2: M20,110 L104,26  stroke 14
    x1, y1 = 20 * scale, 110 * scale
    x2, y2 = 104 * scale, 26 * scale
    draw.line([(x1, y1), (x2, y2)], fill=SPEED_LINE_2, width=int(14 * scale))

    return img


def draw_arc_segment(
    draw: ImageDraw.Draw,
    center: Tuple[float, float],
    radius: float,
    start_deg: float,
    end_deg: float,
    width: int,
    color,
):
    """Draw an arc segment with round caps (chord segments for clean AA)."""
    segments = max(64, int(abs(end_deg - start_deg) * 2))
    pts = _arc_points(center, radius, start_deg, end_deg, segments)
    draw.line(pts, fill=color, width=width, joint="curve")
    # round caps
    r = width / 2.0
    for p in (pts[0], pts[-1]):
        draw.ellipse([p[0] - r, p[1] - r, p[0] + r, p[1] + r], fill=color)


def _arc_points(center, radius, start_deg, end_deg, segments):
    """Yield points along an arc. Angles in degrees, 0 = 3 o'clock, clockwise (y-down)."""
    cx, cy = center
    pts = []
    for i in range(segments + 1):
        t = i / segments
        a = math.radians(start_deg + t * (end_deg - start_deg))
        pts.append((cx + radius * math.cos(a), cy + radius * math.sin(a)))
    return pts


def draw_arc_gradient(
    img: Image.Image,
    center: Tuple[float, float],
    radius: float,
    start_deg: float,
    sweep_deg: float,
    width: int,
    start_color,
    end_color,
):
    """Draw an arc with a linear gradient along its length (chord segments)."""
    segments = max(64, int(sweep_deg * 2))
    pts = _arc_points(center, radius, start_deg, start_deg + sweep_deg, segments)
    draw = ImageDraw.Draw(img)
    for i in range(segments):
        t = i / (segments - 1)
        color = lerp_color(start_color, end_color, t)
        draw.line([pts[i], pts[i + 1]], fill=(*color, 255), width=width)
    # round caps: draw filled circles at each end
    r = width / 2.0
    for p, col_t in ((pts[0], 0.0), (pts[-1], 1.0)):
        color = lerp_color(start_color, end_color, col_t)
        draw.ellipse(
            [p[0] - r, p[1] - r, p[0] + r, p[1] + r],
            fill=(*color, 255),
        )


def draw_icon(size: int, transparent: bool = False) -> Image.Image:
    """Compose full icon at given pixel size."""
    scale = size / VIEWPORT
    center = (CENTER[0] * scale, CENTER[1] * scale)
    radius = RADIUS * scale
    stroke = max(1, int(STROKE_WIDTH * scale))

    if transparent:
        img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    else:
        img = draw_background(size)

    draw = ImageDraw.Draw(img)

    # SOC gauge track (dim full arc)
    draw_arc_segment(draw, center, radius, ARC_START_DEG, ARC_START_DEG + ARC_SWEEP_DEG, stroke, (*TRACK_COLOR, 255))

    # SOC ring (trimmed 78%) with gradient
    trim_sweep = ARC_SWEEP_DEG * TRIM_END
    draw_arc_gradient(img, center, radius, ARC_START_DEG, trim_sweep, stroke, RING_START, RING_END)

    # Lightning bolt (white + teal overlay)
    bolt_scaled = [(x * scale, y * scale) for x, y in BOLT_POINTS]
    draw.polygon(bolt_scaled, fill=(*BOLT_WHITE, 255))

    # Overlay: draw bolt again with low-alpha teal using a temporary layer
    overlay = Image.new("RGBA", img.size, (0, 0, 0, 0))
    overlay_draw = ImageDraw.Draw(overlay)
    overlay_draw.polygon(bolt_scaled, fill=BOLT_OVERLAY)
    img = Image.alpha_composite(img, overlay)

    return img


def remove_near_white(img: Image.Image, threshold: int = 240) -> Image.Image:
    """Make near-white pixels transparent (for brand logo)."""
    data = img.getdata()
    out = []
    for item in data:
        r, g, b, a = item
        if r >= threshold and g >= threshold and b >= threshold:
            out.append((r, g, b, 0))
        else:
            out.append(item)
    img.putdata(out)
    return img


def save_png(img: Image.Image, path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    img.save(path, "PNG")


def main():
    repo_root = Path(__file__).resolve().parent.parent
    assets = repo_root / "IoniqTelemetry" / "Resources" / "Assets.xcassets"
    appicon_dir = assets / "AppIcon.appiconset"
    brandlogo_dir = assets / "BrandLogo.imageset"

    # iOS icon sizes: (idiom, size_pt, scale, filename)
    icon_specs = [
        ("iphone", "20x20", "2x", "Icon-20@2x.png"),
        ("iphone", "20x20", "3x", "Icon-20@3x.png"),
        ("iphone", "29x29", "2x", "Icon-29@2x.png"),
        ("iphone", "29x29", "3x", "Icon-29@3x.png"),
        ("iphone", "40x40", "2x", "Icon-40@2x.png"),
        ("iphone", "40x40", "3x", "Icon-40@3x.png"),
        ("iphone", "60x60", "2x", "Icon-60@2x.png"),
        ("iphone", "60x60", "3x", "Icon-60@3x.png"),
        ("ipad", "76x76", "1x", "Icon-76.png"),
        ("ipad", "76x76", "2x", "Icon-76@2x.png"),
        ("ipad", "83.5x83.5", "2x", "Icon-83.5@2x.png"),
        ("ios-marketing", "1024x1024", "1x", "Icon-1024.png"),
    ]

    contents = {
        "images": [],
        "info": {"author": "xcode", "version": 1},
    }

    print("Generating AppIcon set...")
    for idiom, size_str, scale, filename in icon_specs:
        if "x" in size_str:
            w_str, h_str = size_str.split("x")
            pt = float(w_str)
        else:
            pt = float(size_str)
        multiplier = 1 if scale == "1x" else (2 if scale == "2x" else 3)
        px = int(round(pt * multiplier))

        img = draw_icon(px, transparent=False)
        save_png(img, appicon_dir / filename)
        print(f"  {filename}  ({px}x{px})")

        contents["images"].append(
            {
                "filename": filename,
                "idiom": idiom,
                "scale": scale,
                "size": size_str,
            }
        )

    with open(appicon_dir / "Contents.json", "w") as f:
        json.dump(contents, f, indent=2)
    print(f"  Contents.json")

    # BrandLogo: 1024px transparent with near-white removed
    print("Generating BrandLogo...")
    logo = draw_icon(1024, transparent=True)
    logo = remove_near_white(logo, threshold=240)
    save_png(logo, brandlogo_dir / "BrandLogo.png")

    brand_contents = {
        "images": [
            {
                "filename": "BrandLogo.png",
                "idiom": "universal",
                "scale": "1x",
            }
        ],
        "info": {"author": "xcode", "version": 1},
    }
    with open(brandlogo_dir / "Contents.json", "w") as f:
        json.dump(brand_contents, f, indent=2)
    print("  BrandLogo.png")
    print("  Contents.json")

    print("Done.")


if __name__ == "__main__":
    main()
