#!/usr/bin/env python3
"""One generator for every game's boot splash, icon and window icon, from the table game_splash.tsv.

  gen_game_splash.py [--root DIR] [--only game-x ...] [--path game-x=DIR ...] MODE

Modes (default --write):
  --make-icons  crop each row's cover to a rounded square and write <game>/branding/icon_source.png (art step; run once or when the art changes)
  --write       regenerate branding/icon.png, branding/icon.ico, branding/splash.png from icon_source.png and the name, and set the project.godot keys
  --check       exit 1 when any generated file or project.godot key is stale (no files written)

project.godot keys it owns: config/name, config/icon, config/windows_native_icon, boot_splash/{image,show_image,use_filter,bg_color,fullsize}.
config/name is authoritative: the server deploy loading screen reads the same name and config/icon from pack metadata.
Godot logo: Andrea Calabro, CC BY 4.0 (tools/splash/godot-logo-LICENSE.txt). Font: Kenney Future (CC0).
"""
import argparse
import io
import re
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

HERE = Path(__file__).resolve().parent
ASSETS = HERE / "splash"
SPLASH_SIZE = (1280, 720)
ICON_SIZE = 512
BRAND = "GameSpice"


def read_table():
    rows = []
    for line in (HERE / "game_splash.tsv").read_text().splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        d, name, cover, bg = line.split("\t")
        rows.append({"dir": d, "name": name, "cover": cover, "bg": bg})
    return rows


def hex_rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def rounded(img, radius):
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, img.width - 1, img.height - 1), radius, fill=255)
    out = img.convert("RGBA")
    out.putalpha(mask)
    return out


def make_icon_source(cover):
    src = Image.open(cover).convert("RGB")
    side = min(src.size)
    left, top = (src.width - side) // 2, (src.height - side) // 2
    sq = src.crop((left, top, left + side, top + side)).resize((ICON_SIZE, ICON_SIZE), Image.LANCZOS)
    return rounded(sq, ICON_SIZE // 6)


def fit(img, height):
    return img.resize((round(img.width * height / img.height), height), Image.LANCZOS)


def make_splash(row, icon):
    w, h = SPLASH_SIZE
    bg = hex_rgb(row["bg"])
    im = Image.new("RGBA", SPLASH_SIZE, bg + (255,))
    ic = icon.resize((288, 288), Image.LANCZOS)
    im.alpha_composite(ic, ((w - 288) // 2, 96))
    d = ImageDraw.Draw(im)
    size = 76
    font = ImageFont.truetype(str(ASSETS / "KenneyFuture.ttf"), size)
    while d.textlength(row["name"].upper(), font=font) > w - 160 and size > 24:
        size -= 4
        font = ImageFont.truetype(str(ASSETS / "KenneyFuture.ttf"), size)
    d.text((w // 2, 470), row["name"].upper(), font=font, fill=(244, 244, 248), anchor="mt")
    # footer: GameSpice mark + text left, Godot logo right
    fy = h - 96
    d.line((80, fy - 24, w - 80, fy - 24), fill=(52, 54, 62), width=1)
    mark = fit(Image.open(ASSETS / "gamespice-mark.png").convert("RGBA"), 64)
    im.alpha_composite(mark, (80, fy))
    bfont = ImageFont.truetype(str(ASSETS / "KenneyFuture.ttf"), 30)
    d.text((80 + mark.width + 14, fy + 32), BRAND.upper(), font=bfont, fill=(244, 244, 248), anchor="lm")
    godot = fit(Image.open(ASSETS / "godot-logo.png").convert("RGBA"), 64)
    im.alpha_composite(godot, (w - 80 - godot.width, fy))
    return im.convert("RGB")


def png_bytes(img):
    b = io.BytesIO()
    img.save(b, "PNG", optimize=True)
    return b.getvalue()


def ico_bytes(img):
    b = io.BytesIO()
    img.save(b, "ICO", sizes=[(s, s) for s in (16, 32, 48, 64, 128, 256)])
    return b.getvalue()


def pixels_equal(path, data):
    if not path.exists():
        return False
    a, b = Image.open(path), Image.open(io.BytesIO(data))
    if path.suffix == ".ico":
        return path.read_bytes() == data
    return a.size == b.size and a.convert("RGBA").tobytes() == b.convert("RGBA").tobytes()


WANT = [
    ("config/name", lambda r: '"%s"' % r["name"].replace('"', '\\"')),
    ("config/icon", lambda r: '"res://branding/icon.png"'),
    ("config/windows_native_icon", lambda r: '"res://branding/icon.ico"'),
    ("boot_splash/bg_color", lambda r: "Color(%s, 1)" % ", ".join("%g" % round(c / 255, 4) for c in hex_rgb(r["bg"]))),
    ("boot_splash/fullsize", lambda r: "true"),
    ("boot_splash/image", lambda r: '"res://branding/splash.png"'),
    ("boot_splash/show_image", lambda r: "true"),
    ("boot_splash/use_filter", lambda r: "true"),
]


def patched_project(text, row):
    """Return project.godot text with the owned keys set inside [application]."""
    m = re.search(r"^\[application\]\n(.*?)(?=^\[|\Z)", text, re.S | re.M)
    if not m:
        raise SystemExit("no [application] section")
    lines = [l for l in m.group(1).split("\n")]
    lines = [l for l in lines if l != ""]
    owned = {k for k, _ in WANT}
    kept = [l for l in lines if l.split("=", 1)[0] not in owned]
    out = [f"{k}={fn(row)}" for k, fn in WANT]
    new_lines = [out[0]] + kept + out[1:]
    return text[:m.start(1)] + "\n" + "\n".join(new_lines) + "\n\n" + text[m.end(1):]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default=str(Path.home() / "godot"))
    ap.add_argument("--only", nargs="*", default=[])
    ap.add_argument("--path", action="append", default=[], help="game-x=DIR overrides the checkout used for one game")
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--make-icons", action="store_true")
    mode.add_argument("--write", action="store_true")
    mode.add_argument("--check", action="store_true")
    a = ap.parse_args()
    over = dict(p.split("=", 1) for p in a.path)
    bad = 0
    for row in read_table():
        if a.only and row["dir"] not in a.only:
            continue
        g = Path(over.get(row["dir"], Path(a.root) / row["dir"]))
        br = g / "branding"
        src = br / "icon_source.png"
        if a.make_icons:
            br.mkdir(exist_ok=True)
            src.write_bytes(png_bytes(make_icon_source(row["cover"])))
            print("icon source", src)
            continue
        if not src.exists():
            print("MISSING", src, "(run --make-icons)")
            bad += 1
            continue
        icon = Image.open(src).convert("RGBA")
        outs = {br / "icon.png": png_bytes(icon), br / "icon.ico": ico_bytes(icon),
                br / "splash.png": png_bytes(make_splash(row, icon))}
        for p, data in outs.items():
            if a.check:
                if not pixels_equal(p, data):
                    print("STALE", p)
                    bad += 1
            else:
                br.mkdir(exist_ok=True)
                p.write_bytes(data)
        pj = g / "project.godot"
        text = pj.read_text()
        new = patched_project(text, row)
        if a.check:
            if new != text:
                print("STALE", pj)
                bad += 1
        elif new != text:
            pj.write_text(new)
            print("updated", pj)
    if a.check:
        print("ok" if not bad else "%d stale" % bad)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
