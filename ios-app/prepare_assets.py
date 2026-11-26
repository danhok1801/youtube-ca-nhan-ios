from __future__ import annotations

import json
import shutil
from pathlib import Path
from PIL import Image, ImageDraw

IOS_DIR = Path(__file__).resolve().parent
ROOT_DIR = IOS_DIR.parent
IOS_RES = IOS_DIR / "Resources"
ASSETS = IOS_RES / "Assets.xcassets"
APPICON = ASSETS / "AppIcon.appiconset"
LAUNCH_COLOR = ASSETS / "LaunchBackground.colorset"


def build_ios_assets() -> None:
    APPICON.mkdir(parents=True, exist_ok=True)
    LAUNCH_COLOR.mkdir(parents=True, exist_ok=True)

    # 1024x1024 opaque RGB PNG (Apple requires no alpha channel on 1024px AppIcon)
    scale = 2
    sz = 1024 * scale
    img = Image.new("RGB", (sz, sz), (15, 15, 15))
    draw = ImageDraw.Draw(img)

    pad = int(sz * 0.16)
    rw = sz - pad * 2
    rh = int(rw * 0.71)
    ty = (sz - rh) // 2
    rad = int(rh * 0.28)
    draw.rounded_rectangle([pad, ty, pad + rw, ty + rh], radius=rad, fill=(255, 0, 51))

    tw = int(rw * 0.29)
    th = int(rh * 0.43)
    cx = sz // 2 + int(sz * 0.025)
    cy = sz // 2
    pts = [
        (cx - tw // 2, cy - th // 2),
        (cx - tw // 2, cy + th // 2),
        (cx + tw // 2 + int(tw * 0.12), cy),
    ]
    draw.polygon(pts, fill=(255, 255, 255))
    img = img.resize((1024, 1024), Image.Resampling.LANCZOS)
    img.save(APPICON / "icon-1024.png", format="PNG")

    (APPICON / "Contents.json").write_text(
        json.dumps(
            {
                "images": [
                    {
                        "filename": "icon-1024.png",
                        "idiom": "universal",
                        "platform": "ios",
                        "size": "1024x1024",
                    }
                ],
                "info": {"author": "xcode", "version": 1},
            },
            indent=2,
        ),
        encoding="utf-8",
    )

    (LAUNCH_COLOR / "Contents.json").write_text(
        json.dumps(
            {
                "colors": [
                    {
                        "color": {
                            "color-space": "srgb",
                            "components": {
                                "alpha": "1.000",
                                "blue": "0.059",
                                "green": "0.059",
                                "red": "0.059",
                            },
                        },
                        "idiom": "universal",
                    }
                ],
                "info": {"author": "xcode", "version": 1},
            },
            indent=2,
        ),
        encoding="utf-8",
    )

    (ASSETS / "Contents.json").write_text(
        json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2),
        encoding="utf-8",
    )

    # Sync static bundle into ios-app/Resources/static
    dst_static = IOS_RES / "static"
    if dst_static.exists():
        shutil.rmtree(dst_static)
    shutil.copytree(ROOT_DIR / "static", dst_static)


if __name__ == "__main__":
    build_ios_assets()
    print("Prepared Assets.xcassets and synced static bundle.")
