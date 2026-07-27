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

    # Speed lines on a separate overlay so alpha blends properly
    overlay = Image.new("RGBA", img.size, (0, 0, 0, 0))
    overlay_draw = ImageDraw.Draw(overlay)
    scale = size / VIEWPORT
    # Line 1: M-10,84 L60,14  stroke 10
    overlay_draw.line(
        [(-10 * scale, 84 * scale), (60 * scale, 14 * scale)],
        fill=SPEED_LINE_1,
        width=max(1, int(10 * scale)),
    )
    # Line 2: M20,110 L104,26  stroke 14
    overlay_draw.line(
        [(20 * scale, 110 * scale), (104 * scale, 26 * scale)],
        fill=SPEED_LINE_2,
        width=max(1, int(14 * scale)),
    )
    img = Image.alpha_composite(img, overlay)
    return img


def _arc_mask(size: int, center, radius, start_deg, end_deg, width) -> Image.Image:
    """Grayscale mask of an arc with round caps, built via donut + pieslice (no spikes)."""
    mask = Image.new("L", (size, size), 0)
    md = ImageDraw.Draw(mask)
    cx, cy = center
    r_outer = radius + width / 2.0
    r_inner = radius - width / 2.0

    # PIL pieslice/arc use 0 = 3 o'clock, increasing CLOCKWISE (y-axis down),
    # matching Android's angle convention.
    # PIL pieslice draws from start to end going clockwise.
    # Our start=160, end=380 (i.e. 20 deg past full 360). PIL handles end > 360.
    # Draw filled donut slice via two steps:
    # 1) filled outer pieslice
    md.pieslice(
        [cx - r_outer, cy - r_outer, cx + r_outer, cy + r_outer],
        start=start_deg,
        end=end_deg,
        fill=255,
    )
    # 2) cut out inner pieslice
    md.pieslice(
        [cx - r_inner, cy - r_inner, cx + r_inner, cy + r_inner],
        start=start_deg,
        end=end_deg,
        fill=0,
    )

    # Round caps: filled circles at arc endpoints
    s_rad = math.radians(start_deg)
    e_rad = math.radians(end_deg)
    sx, sy = cx + radius * math.cos(s_rad), cy + radius * math.sin(s_rad)
    ex, ey = cx + radius * math.cos(e_rad), cy + radius * math.sin(e_rad)
    r = width / 2.0
    md.ellipse([sx - r, sy - r, sx + r, sy + r], fill=255)
    md.ellipse([ex - r, ey - r, ex + r, ey + r], fill=255)
    return mask


def draw_arc_segment(
    img: Image.Image,
    center: Tuple[float, float],
    radius: float,
    start_deg: float,
    end_deg: float,
    width: int,
    color,
):
    """Paste a solid-color arc through a mask (clean anti-aliased edges)."""
    mask = _arc_mask(img.size[0], center, radius, start_deg, end_deg, width)
    layer = Image.new("RGBA", img.size, (*color[:3], color[3] if len(color) > 3 else 255))
    img.paste(layer, (0, 0), mask)


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
    """Draw an arc with a linear gradient along its length via mask + gradient layer."""
    # Build gradient layer along the arc direction (start -> end point)
    end_deg = start_deg + sweep_deg
    # Use the chord from arc start to arc end as the gradient axis
    s_rad = math.radians(start_deg)
    e_rad = math.radians(end_deg)
    cx, cy = center
    sx, sy = cx + radius * math.cos(s_rad), cy + radius * math.sin(s_rad)
    ex, ey = cx + radius * math.cos(e_rad), cy + radius * math.sin(e_rad)

    # Project each pixel onto the gradient axis to find t (computed at low res, upscaled)
    SMALL = 256
    small_grad = Image.new("RGB", (SMALL, SMALL))
    sg = small_grad.load()
    dx = ex - sx
    dy = ey - sy
    scale_f = SMALL / img.size[0]
    sx_s, sy_s = sx * scale_f, sy * scale_f
    dx_s, dy_s = dx * scale_f, dy * scale_f
    len_sq_s = dx_s * dx_s + dy_s * dy_s or 1.0
    for y in range(SMALL):
        for x in range(SMALL):
            t = ((x - sx_s) * dx_s + (y - sy_s) * dy_s) / len_sq_s
            t = max(0.0, min(1.0, t))
            sg[x, y] = lerp_color(start_color, end_color, t)
    grad = small_grad.resize(img.size, Image.BILINEAR).convert("RGBA")

    # Mask the gradient by the arc shape
    mask = _arc_mask(img.size[0], center, radius, start_deg, end_deg, width)
    img.paste(grad, (0, 0), mask)


def draw_icon(size: int, transparent: bool = False) -> Image.Image:
    """Compose full icon at given pixel size (rendered at 2x then downsampled)."""
    SS = 2  # supersample factor
    big = size * SS
    scale = big / VIEWPORT
    center = (CENTER[0] * scale, CENTER[1] * scale)
    radius = RADIUS * scale
    stroke = max(1, int(STROKE_WIDTH * scale))

    if transparent:
        img = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    else:
        img = draw_background(big)

    draw = ImageDraw.Draw(img)

    # SOC gauge track (dim full arc)
    draw_arc_segment(img, center, radius, ARC_START_DEG, ARC_START_DEG + ARC_SWEEP_DEG, stroke, (*TRACK_COLOR, 255))

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

    # Downsample to target size with high-quality filter
    img = img.resize((size, size), Image.LANCZOS)
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
