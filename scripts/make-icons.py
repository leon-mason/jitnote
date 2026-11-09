#!/usr/bin/env python3
#
# 从 docs/logo.png 生成两个客户端的 App 图标。换了 logo 之后运行一次，再提交生成的文件：
#
#   python3 scripts/make-icons.py
#
# 生成：
#   android/app/src/main/res/mipmap-*dpi/ic_launcher_foreground.png   自适应图标的前景（各种屏幕密度）
#   mac/Resources/AppIcon.icns                                        Mac 图标（build-mac.sh 会放进 App）
#
# 需要 Pillow 和 numpy（pip3 install pillow numpy），Mac 图标还要用系统自带的 iconutil。
# 单色主题图标（android/app/src/main/res/drawable/ic_launcher_monochrome.xml）是手画的矢量图，换 logo 时要另外改。

import os
import shutil
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image, ImageFilter

ROOT = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True).stdout.strip()
LOGO = os.path.join(ROOT, "docs/logo.png")
ANDROID_RES = os.path.join(ROOT, "android/app/src/main/res")
MAC_ICNS = os.path.join(ROOT, "mac/Resources/AppIcon.icns")

TILE = 1024


def load_tile():
    """The logo's rounded square, cropped and made exactly square and fully opaque inside."""
    logo = Image.open(LOGO).convert("RGBA")
    # The exported PNG has stray near-zero alpha around the shape and ~98% alpha inside it.
    alpha = logo.getchannel("A")
    box = alpha.point(lambda a: 255 if a > 128 else 0).getbbox()
    tile = logo.crop(box).resize((TILE, TILE), Image.LANCZOS)
    alpha = tile.getchannel("A").point(lambda a: 0 if a < 8 else 255 if a > 240 else a)
    tile.putalpha(alpha)
    return tile


def fit_background(tile):
    """A linear colour gradient fitted to the tile's dark border, to extend it beyond the tile."""
    px = np.asarray(tile, dtype=np.float64)
    ys, xs = np.mgrid[0:TILE, 0:TILE] / TILE
    edge = np.minimum(np.minimum(xs, 1 - xs), np.minimum(ys, 1 - ys))
    # Between the anti-aliased rim and the artwork, which starts about 11% in; the orange badge reaches
    # into it on the right, so only bluish pixels count.
    band = (edge > 0.02) & (edge < 0.09) & (px[..., 3] == 255) & (px[..., 2] > px[..., 0] + 8)
    a = np.stack([np.ones(band.sum()), xs[band], ys[band]], axis=1)
    coef, *_ = np.linalg.lstsq(a, px[..., :3][band], rcond=None)
    return coef  # rows: constant, per x, per y (x and y in tile widths)


def gradient(coef, size, origin, scale):
    """The fitted gradient on a size×size canvas whose pixel p sits at tile position (p - origin) / scale.
    Outside the tile it keeps the colour of the nearest tile edge rather than running on."""
    ys, xs = np.mgrid[0:size, 0:size].astype(np.float64)
    tx, ty = np.clip((xs - origin) / scale, 0, 1), np.clip((ys - origin) / scale, 0, 1)
    rgb = coef[0] + tx[..., None] * coef[1] + ty[..., None] * coef[2]
    return Image.fromarray(np.clip(rgb, 0, 255).astype(np.uint8), "RGB").convert("RGBA")


def artwork(tile, coef):
    """Where the artwork is (anything clearly not background)."""
    px = np.asarray(tile, dtype=np.float64)
    ys, xs = np.mgrid[0:TILE, 0:TILE] / TILE
    fitted = coef[0] + xs[..., None] * coef[1] + ys[..., None] * coef[2]
    return (np.abs(px[..., :3] - fitted).max(axis=2) > 60) & (px[..., 3] == 255)


def feather_rim(tile, art):
    """Fades out the light bevel along the tile's rounded edge, but not the artwork that reaches it."""
    small = 128
    inner = tile.getchannel("A").resize((small, small)).filter(ImageFilter.MinFilter(9))
    fade = inner.filter(ImageFilter.GaussianBlur(3)).resize((TILE, TILE), Image.BILINEAR)
    keep = Image.fromarray((art * 255).astype(np.uint8)).filter(ImageFilter.MaxFilter(9)).filter(ImageFilter.GaussianBlur(3))
    alpha = np.minimum(np.asarray(tile.getchannel("A")), np.maximum(np.asarray(fade), np.asarray(keep)))
    out = tile.copy()
    out.putalpha(Image.fromarray(alpha.astype(np.uint8)))
    return out


def android_tile_dp(art):
    """How wide the tile is on Android. Adaptive icons are 108dp squares; launchers show at least the
    middle 66dp circle, so the artwork's farthest point has to stay within 33dp of the centre."""
    ys, xs = np.mgrid[0:TILE, 0:TILE] / TILE
    reach = np.sqrt((xs[art] - 0.5) ** 2 + (ys[art] - 0.5) ** 2).max()
    return 33 / reach


def android(tile, art, coef):
    tile_dp = android_tile_dp(art)
    tile = feather_rim(tile, art)
    for density, dp in [("mdpi", 1), ("hdpi", 1.5), ("xhdpi", 2), ("xxhdpi", 3), ("xxxhdpi", 4)]:
        size = round(108 * dp)
        side = round(tile_dp * dp)
        origin = (size - side) / 2
        # The gradient carries on past the tile's rounded corners, so no edge shows whatever the mask.
        canvas = gradient(coef, size, origin, side)
        canvas.alpha_composite(tile.resize((side, side), Image.LANCZOS), (round(origin), round(origin)))
        out = os.path.join(ANDROID_RES, f"mipmap-{density}")
        os.makedirs(out, exist_ok=True)
        canvas.convert("RGB").save(os.path.join(out, "ic_launcher_foreground.png"), optimize=True)
    print(f"✓ Android：图标占 108dp 里的 {tile_dp:.1f}dp")


def mac(tile, art, coef):
    # macOS icon grid: on a 1024 canvas the shape is 824 wide, with room left for its shadow.
    side, size = 824, 1024
    origin = (size - side) // 2
    # The logo's artwork nearly touches its own edge, which looks cramped at icon size, but Android's
    # margins (84%) made it look clearly smaller than its neighbours in the Dock. 92% is the size picked
    # by eye against system icons. See "App 图标" in docs/design.md.
    art_side = round(side * 0.92)
    art_origin = (side - art_side) // 2
    shape = gradient(coef, side, art_origin, art_side)
    shape.alpha_composite(feather_rim(tile, art).resize((art_side, art_side), Image.LANCZOS), (art_origin, art_origin))
    shape.putalpha(tile.getchannel("A").resize((side, side), Image.LANCZOS))
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 255), (origin, origin + 12), shape.getchannel("A").point(lambda a: a * 0.35))
    icon = shadow.filter(ImageFilter.GaussianBlur(14))
    icon.alpha_composite(shape, (origin, origin))

    with tempfile.TemporaryDirectory() as tmp:
        iconset = os.path.join(tmp, "AppIcon.iconset")
        os.mkdir(iconset)
        for points in [16, 32, 128, 256, 512]:
            for scale in [1, 2]:
                name = f"icon_{points}x{points}{'@2x' if scale == 2 else ''}.png"
                icon.resize((points * scale,) * 2, Image.LANCZOS).save(os.path.join(iconset, name))
        subprocess.run(["iconutil", "-c", "icns", iconset, "-o", MAC_ICNS], check=True)
    print(f"✓ Mac：{os.path.relpath(MAC_ICNS, ROOT)}")


def main():
    if not shutil.which("iconutil"):
        sys.exit("✗ 找不到 iconutil，请在 Mac 上运行。")
    tile = load_tile()
    coef = fit_background(tile)
    art = artwork(tile, coef)
    android(tile, art, coef)
    mac(tile, art, coef)


main()
