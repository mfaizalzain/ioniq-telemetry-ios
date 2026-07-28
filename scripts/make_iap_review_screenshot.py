#!/usr/bin/env python3
"""Fit a paywall capture into the size App Store Connect accepts for an IAP
review screenshot.

That uploader is far pickier than the app-screenshot one: current device sizes
such as 1320x2868 are rejected outright as the wrong size, and 640x920 is the
size that goes through. A modern capture is taller than 640:920, so it is scaled
to fit and centred on the app's background colour rather than squashed — the
reviewer needs to read the price, not admire the aspect ratio.

    python3 scripts/make_iap_review_screenshot.py <capture.png>
"""

import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "store_assets/iap_review_screenshot_640x920.png"

W, H = 640, 920
BG = (11, 18, 32)


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    shot = Image.open(sys.argv[1]).convert("RGB")

    scale = min(W / shot.width, H / shot.height)
    fitted = shot.resize((round(shot.width * scale), round(shot.height * scale)), Image.LANCZOS)

    canvas = Image.new("RGB", (W, H), BG)
    canvas.paste(fitted, ((W - fitted.width) // 2, (H - fitted.height) // 2))

    OUT.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(OUT, "PNG", dpi=(72, 72))
    print(f"wrote {OUT.relative_to(ROOT)} {canvas.size}")


if __name__ == "__main__":
    main()
