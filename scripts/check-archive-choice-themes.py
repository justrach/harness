#!/usr/bin/env python3
"""Check native archive-choice-fixture all-themes captures (requires Pillow).

The fixture uses a fixed 1100 x 720 logical-pixel viewport. Sample padding
inside each choice button, away from its label, corners, and border. Compare
Just close it to the theme's solid role, and Archive it to the unfilled
card background.
"""

import argparse
import json
from pathlib import Path

from PIL import Image, ImageDraw


def check(directory):
    report = json.loads((directory / "theme-matrix.json").read_text())
    assert report["minimum_contrast"] >= 4.5, report["minimum_contrast"]
    themes = report["builtin_variants"] + report["synthetic_custom_variants"]
    cases = {(case["theme"], case["surface"]) for case in report["captures"]}
    assert len(cases) == len(report["captures"]) == themes * 3, "Incomplete render matrix"
    assert report["contrast_cases"] == themes * 3 * 8, "Incomplete accent matrix"
    sheets = {}
    failures = []
    for case in report["captures"]:
        image = Image.open(directory / case["file"]).convert("RGB")
        scale = image.width / 1100
        assert image.height == round(720 * scale), case["file"]
        samples = [
            image.getpixel((round(x * scale), round(y * scale)))
            for x, y in [(563, 443.5), (658, 443.5), (480, 443.5)]
        ]
        secondary, primary, background = samples
        if secondary == primary or any(
            abs(actual - expected) > 1
            for actual, expected in zip(primary, case["fill"])
        ) or any(
            abs(actual - expected) > 1
            for actual, expected in zip(secondary, background)
        ):
            failures.append((case["file"], samples, case["fill"]))
        crop = image.crop(tuple(round(n * scale) for n in (368, 224.5, 732.5, 496)))
        crop.thumbnail((550, 397))
        tile = Image.new("RGB", (560, 425), "#d0d0d0")
        tile.paste(crop, ((560 - crop.width) // 2, 25))
        ImageDraw.Draw(tile).text((8, 6), case["theme"], fill="black")
        sheets.setdefault(case["surface"], []).append(tile)
    assert not failures, "Incorrect primary/secondary button fills: {!r}".format(failures[:3])
    for surface, tiles in sheets.items():
        sheet = Image.new("RGB", (560 * 3, 425 * ((len(tiles) + 2) // 3)), "#d0d0d0")
        for i, tile in enumerate(tiles):
            sheet.paste(tile, ((i % 3) * 560, (i // 3) * 425))
        sheet.save(directory / ("contact-" + surface.lower() + ".png"))
    print(
        "PASS: {} bundled + {} synthetic custom themes; {} rendered cases with "
        "theme-correct primary and unfilled secondary buttons; {} primary-label "
        "contrast checks; minimum {:.2f}:1".format(
            report["builtin_variants"],
            report["synthetic_custom_variants"],
            len(report["captures"]),
            report["contrast_cases"],
            report["minimum_contrast"],
        )
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    check(parser.parse_args().directory)
