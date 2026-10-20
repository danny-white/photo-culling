#!/usr/bin/env python3
"""Draw Culling Bay's icon. Run: ./venv/bin/python ios/tools/make-icon.py."""

import math
from pathlib import Path
import sys

# The interpreter may live in a shared venv; do not write import caches there.
sys.dont_write_bytecode = True

from PIL import Image, ImageDraw


SIZE = 1024
SCALE = 4
OUTPUT = (
    Path(__file__).resolve().parents[1]
    / "CullingBay/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
)


def draw_icon():
    """Render flat geometry at 4096 px, then antialias with one downsample."""
    image = Image.new("RGB", (SIZE * SCALE, SIZE * SCALE))
    draw = ImageDraw.Draw(image)

    # Full-bleed sea-blue to teal. The system supplies the icon's rounded mask.
    top, bottom = (12, 43, 73), (15, 115, 124)
    for y in range(image.height):
        color = tuple(
            start + (end - start) * y // (image.height - 1)
            for start, end in zip(top, bottom)
        )
        draw.line((0, y, image.width - 1, y), fill=color)

    def polygon(points, color):
        draw.polygon(
            [(round(x * SCALE), round(y * SCALE)) for x, y in points],
            fill=color,
        )

    def circle(center, radius, color):
        x, y = center
        draw.ellipse(
            tuple(round(v * SCALE) for v in (x - radius, y - radius,
                                            x + radius, y + radius)),
            fill=color,
        )

    def card(center, angle, width, height, paper, inset):
        """Draw a card and return its local-to-icon coordinate transform."""
        radians = math.radians(angle)
        cosine, sine = math.cos(radians), math.sin(radians)

        def point(x, y):
            return (center[0] + x * cosine - y * sine,
                    center[1] + x * sine + y * cosine)

        def rectangle(left, top, right, bottom, color):
            polygon([point(left, top), point(right, top),
                     point(right, bottom), point(left, bottom)], color)

        half_w, half_h = width / 2, height / 2
        rectangle(-half_w, -half_h, half_w, half_h, paper)
        rectangle(-half_w + 28, -half_h + 28,
                  half_w - 28, half_h - 56, inset)
        return point, rectangle

    # Two quieter cards show the fan without competing with the selected photo.
    card((466, 437), -13, 548, 440, "#91BFCB", "#367C91")
    card((539, 478), 9, 552, 444, "#C3DEE0", "#489DA7")
    point, rectangle = card((500, 553), -3, 584, 464, "#FFFDF5", "#A9DADE")

    # Front photo: a warm sun, a crisp horizon, and a headland enclosing the bay.
    circle(point(137, -110), 46, "#FFD17C")
    rectangle(-264, -35, 264, 176, "#338FA9")
    polygon([point(-264, -35), point(-190, -66), point(-132, -62),
             point(-67, -18), point(3, 20), point(-264, 20)], "#205467")
    polygon([point(-264, 87), point(-185, 71), point(-103, 82),
             point(-13, 117), point(92, 133), point(264, 112),
             point(264, 176), point(-264, 176)], "#66BCBD")

    # A strong, simple keep badge stays legible at home-screen sizes.
    badge = (770, 746)
    circle(badge, 90, "#FFFDF5")
    circle(badge, 78, "#208862")
    check = [(734, 746), (760, 771), (808, 720)]
    draw.line([(x * SCALE, y * SCALE) for x, y in check],
              fill="#FFFFFF", width=18 * SCALE, joint="curve")
    for end in (check[0], check[-1]):
        circle(end, 9, "#FFFFFF")

    # Drawing directly onto RGB guarantees an opaque PNG, including the corners.
    return image.resize((SIZE, SIZE), Image.Resampling.LANCZOS)


def main():
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    draw_icon().save(OUTPUT, format="PNG", optimize=False, compress_level=9)
    print(f"Wrote {OUTPUT}")


if __name__ == "__main__":
    main()
