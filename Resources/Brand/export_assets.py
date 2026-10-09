"""Recolor the approved S-path icon and export ready-to-use brand assets.

No image generation or shape redesign: all variants share the selected master.
Requires Pillow and macOS iconutil. Run from any directory with Python 3.
"""
from pathlib import Path
import hashlib
import json
import subprocess
import tempfile

from PIL import Image, ImageChops, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent
MASTER = ROOT / "source/approved-s-icon.png"
if not MASTER.exists():
    raise SystemExit(f"Approved master is missing: {MASTER}")

original = Image.open(MASTER).convert("RGBA")
tile_alpha = original.getchannel("A")
# The selected flat master is charcoal on off-white. Recover its antialiased
# silhouette directly from that image; retain every arrow, curve and indicator.
coverage = original.convert("L").point(
    lambda value: round(max(0, min(255, (245 - value) * 255 / 195))))
coverage = ImageChops.multiply(coverage, tile_alpha)
coverage.save(ROOT / "source/approved-symbol-alpha.png")
symbol_bounds = coverage.getbbox()
symbol_alpha = coverage.crop(symbol_bounds)
palettes = json.loads((ROOT / "palettes.json").read_text())
records = []


def font(size, chinese=False):
    path = "/System/Library/Fonts/Hiragino Sans GB.ttc" if chinese else "/System/Library/Fonts/Avenir Next.ttc"
    return ImageFont.truetype(path, size, index=2)


def fit_font(text, size, max_width, chinese=False):
    while True:
        face = font(size, chinese)
        box = face.getbbox(text)
        if box[2] - box[0] <= max_width:
            return face
        size -= 1


def draw_text(canvas, text, face, position, fill, center=False):
    x, y = position
    box = face.getbbox(text)
    if center:
        x -= (box[2] - box[0]) / 2
    ImageDraw.Draw(canvas).text((round(x - box[0]), round(y - box[1])),
                               text, font=face, fill=fill)


def symbol(palette, width):
    mask = symbol_alpha.resize((width, round(symbol_alpha.height * width / symbol_alpha.width)),
                               Image.Resampling.LANCZOS)
    mark = Image.new("RGBA", mask.size, palette["foreground"])
    mark.putalpha(mask)
    return mark


def icon(palette):
    if palette["id"] == "graphite":
        return original.copy()
    tile = Image.new("RGBA", original.size, palette["tile"])
    tile.putalpha(tile_alpha)
    mark = Image.new("RGBA", original.size, palette["foreground"])
    mark.putalpha(coverage)
    return Image.alpha_composite(tile, mark)


def plain(palette):
    canvas = Image.new("RGBA", (1024, 1024))
    mark = symbol(palette, 760)
    canvas.alpha_composite(mark, ((1024 - mark.width) // 2, (1024 - mark.height) // 2))
    return canvas


def horizontal(palette, bilingual):
    canvas = Image.new("RGBA", (2400, 900))
    mark = symbol(palette, 630)
    canvas.alpha_composite(mark, (150, (900 - mark.height) // 2))
    if bilingual:
        draw_text(canvas, "盘渡", font(150, True), (930, 240), palette["foreground"])
        draw_text(canvas, "DiskFerry", font(130), (930, 450), palette["foreground"])
    else:
        face = fit_font("DiskFerry", 200, 1320)
        box = face.getbbox("DiskFerry")
        draw_text(canvas, "DiskFerry", face, (930, (900 - (box[3] - box[1])) // 2),
                  palette["foreground"])
    return canvas


def stacked(palette, bilingual):
    canvas = Image.new("RGBA", (1600, 1600))
    mark = symbol(palette, 850)
    canvas.alpha_composite(mark, ((1600 - mark.width) // 2, 180))
    text = "盘渡 DiskFerry" if bilingual else "DiskFerry"
    face = fit_font(text, 122 if bilingual else 150, 1270, chinese=bilingual)
    draw_text(canvas, text, face, (800, 1160), palette["foreground"], center=True)
    return canvas


def save_pair(palette, layout, canvas):
    for extension in ("png", "jpg"):
        relative = Path(extension) / palette["id"] / f"diskferry-{layout}.{extension}"
        output = ROOT / relative
        output.parent.mkdir(parents=True, exist_ok=True)
        if extension == "png":
            canvas.save(output, optimize=True)
        else:
            background = Image.new("RGBA", canvas.size, palette["jpg_background"])
            Image.alpha_composite(background, canvas).convert("RGB").save(
                output, quality=96, subsampling=0, optimize=True)
        records.append({"path": str(relative), "palette": palette["id"],
                        "layout": layout, "format": extension,
                        "width": canvas.width, "height": canvas.height,
                        "transparent": extension == "png",
                        "background": None if extension == "png" else palette["jpg_background"],
                        "sha256": hashlib.sha256(output.read_bytes()).hexdigest()})


for palette in palettes:
    app_icon = icon(palette)
    layouts = {"icon": app_icon, "symbol": plain(palette),
               "name-en-horizontal": horizontal(palette, False),
               "name-zh-en-horizontal": horizontal(palette, True),
               "name-en-stacked": stacked(palette, False),
               "name-zh-en-stacked": stacked(palette, True)}
    for layout, canvas in layouts.items():
        save_pair(palette, layout, canvas)

    for size in (16, 32, 64, 128, 256, 512, 1024):
        path = ROOT / "app-icons/png" / palette["id"] / f"diskferry-{size}.png"
        path.parent.mkdir(parents=True, exist_ok=True)
        app_icon.resize((size, size), Image.Resampling.LANCZOS).save(path, optimize=True)

    with tempfile.TemporaryDirectory(prefix="diskferry-iconset-") as temporary:
        iconset = Path(temporary) / "DiskFerry.iconset"
        iconset.mkdir()
        for points in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                suffix = "@2x" if scale == 2 else ""
                size = points * scale
                app_icon.resize((size, size), Image.Resampling.LANCZOS).save(
                    iconset / f"icon_{points}x{points}{suffix}.png")
        icns = ROOT / "app-icons/icns" / f"diskferry-{palette['id']}.icns"
        icns.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(icns)], check=True)

manifest = {"selected_direction": "2026-10-08 comparison option 1, S-shaped two-way path",
            "approved_on": "2026-10-09", "master": "source/approved-s-icon.png",
            "master_sha256": hashlib.sha256(MASTER.read_bytes()).hexdigest(),
            "palettes": palettes, "primary_asset_count": len(records), "assets": records}
(ROOT / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")

# Show each app icon and its bilingual name treatment together, using actual assets.
overview = Image.new("RGB", (1600, 1080), "#E8EAED")
draw = ImageDraw.Draw(overview)
draw_text(overview, "盘渡 DiskFerry", font(38, True), (50, 34), "#303235")
draw_text(overview, "配色与名称组合", font(22, True), (50, 92), "#74777D")
for index, palette in enumerate(palettes):
    x, y = 20 + index % 4 * 395, 145 + index // 4 * 455
    background = palette["jpg_background"] if palette["id"] == "inverse" else "#FFFFFF"
    draw.rounded_rectangle((x, y, x + 375, y + 430), radius=22, fill=background)
    thumb = icon(palette).resize((280, 280), Image.Resampling.LANCZOS)
    overview.paste(thumb, (x + 48, y + 14), thumb)
    draw_text(overview, palette["name"], font(25, True), (x + 187, y + 290),
              palette["foreground"], center=True)
    named = horizontal(palette, True).resize((335, 126), Image.Resampling.LANCZOS)
    overview.paste(named, (x + 20, y + 312), named)
preview_path = ROOT / "previews/color-overview.png"
preview_path.parent.mkdir(exist_ok=True)
overview.save(preview_path)
overview.save(preview_path.with_suffix(".jpg"), quality=96, subsampling=0)

print(f"Exported {len(records)} primary PNG/JPG files across {len(palettes)} palettes.")
print("Also exported 56 app-icon PNG sizes, 8 ICNS files, overview and manifest.")
