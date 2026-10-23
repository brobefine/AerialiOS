"""Иконка iOS 1024×1024 из знака Aerial: подложка и литера плоские, как у ТВ; волны — стекло в духе Liquid Glass
(сквозь волну видно литеру и подложку — чуть сдвинутыми и размытыми, оттенок волны, тонкий световой край).

Геометрия — вектор адаптивной иконки ТВ (литера и две волны), цвета волн — #7FDCFF и #3E7BEA.
Запуск: python tools/make_icon.py [путь к ic_launcher_foreground.xml]
Результат — Aerial/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png.
"""
import re
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
SOURCE = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("F:/Aerial/app/src/main/res/drawable/ic_launcher_foreground.xml")
OUT = ROOT / "Aerial/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png"

SIZE = 1024
SUPER = 2  # рисуем вдвое крупнее и уменьшаем — сглаженные края
W = SIZE * SUPER
# Видимая часть адаптивной иконки Android — центральные 72 из 108 единиц; её и растягиваем на всю иконку iOS.
VIEW_FROM, VIEW_SIZE = 18.0, 72.0


def px(value):
    """Размер в пикселях итоговой иконки → рабочий размер."""
    return value * SUPER


def rgb(value):
    value = value.lstrip("#")
    return tuple(int(value[i:i + 2], 16) for i in (0, 2, 4))


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def points(path_data):
    scale = W / VIEW_SIZE
    coords = re.findall(r"(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)", path_data)
    return [((float(x) - VIEW_FROM) * scale, (float(y) - VIEW_FROM) * scale) for x, y in coords]


def blur(image, radius):
    return image.filter(ImageFilter.GaussianBlur(radius))


def moved(image, dx, dy):
    out = Image.new(image.mode, image.size, 0)
    out.paste(image, (round(dx), round(dy)))
    return out


def eroded(mask, distance):
    """Сжатие маски примерно на `distance` пикселей: размытие и порог у самого белого."""
    return blur(mask, distance / 2).point(lambda v: 255 if v >= 250 else 0)


def paint(canvas, color, mask, opacity=1.0):
    layer = Image.new("RGBA", canvas.size, color + (255,))
    layer.putalpha(mask.point(lambda v: round(v * opacity)) if opacity != 1 else mask)
    canvas.alpha_composite(layer)


def background():
    """Подложка ТВ: ровный графит сверху-слева к почти чёрному."""
    small = 256
    image = Image.new("RGB", (small, small))
    stops = [(0, rgb("#24262B")), (0.55, rgb("#15161A")), (1, rgb("#0A0B0D"))]
    for y in range(small):
        for x in range(small):
            t = (x + y) / (2 * (small - 1))
            (o1, c1), (o2, c2) = (stops[0], stops[1]) if t <= stops[1][0] else (stops[1], stops[2])
            image.putpixel((x, y), lerp(c1, c2, (t - o1) / (o2 - o1)))
    return image.resize((W, W), Image.BICUBIC).convert("RGBA")


def letter(canvas, mask):
    """Литера ТВ: почти белый сверху, холодный серый снизу (y 30…78 в единицах вектора)."""
    scale = W / VIEW_SIZE
    top, bottom = (30 - VIEW_FROM) * scale, (78 - VIEW_FROM) * scale
    body = Image.new("RGBA", (W, W))
    draw = ImageDraw.Draw(body)
    light, dark = rgb("#F7F8FA"), rgb("#8D939D")
    for y in range(W):
        t = min(1, max(0, (y - top) / (bottom - top)))
        draw.line([(0, y), (W, y)], fill=lerp(light, dark, t) + (255,))
    body.putalpha(mask)
    canvas.alpha_composite(body)


def stroke_mask(line, width):
    mask = Image.new("L", (W, W), 0)
    draw = ImageDraw.Draw(mask)
    draw.line(line, fill=255, width=round(width))
    r = width / 2
    for x, y in line:
        draw.ellipse([x - r, y - r, x + r, y + r], fill=255)
    return blur(mask, 0.6)


def glass_wave(canvas, mask, color, width):
    # Едва заметная тень: стекло чуть приподнято над подложкой.
    paint(canvas, (0, 0, 0), blur(moved(mask, 0, px(5)), px(7)), 0.25)
    # Преломление: то, что под волной, сдвинуто вниз и слегка размыто, затем подкрашено её цветом.
    under = moved(canvas.convert("RGB"), 0, px(7))
    glass = Image.blend(blur(under, px(4)), Image.new("RGB", (W, W), color), 0.7)
    glass = Image.blend(glass, Image.new("RGB", (W, W), (255, 255, 255)), 0.06).convert("RGBA")
    glass.putalpha(mask)
    canvas.alpha_composite(glass)
    # Свет внутри: чуть светлее у верхнего края, чуть темнее у нижнего.
    top_band = ImageChops.subtract(mask, moved(mask, 0, width * 0.5))
    bottom_band = ImageChops.subtract(mask, moved(mask, 0, -width * 0.5))
    paint(canvas, (255, 255, 255), blur(top_band, px(5)), 0.16)
    paint(canvas, (0, 0, 0), blur(bottom_band, px(5)), 0.14)
    # Световой край: яркий сверху, слабый снизу — как блик Liquid Glass.
    rim = ImageChops.subtract(mask, eroded(mask, px(2.5)))
    paint(canvas, (255, 255, 255), ImageChops.multiply(rim, blur(top_band, px(2))), 0.85)
    paint(canvas, (255, 255, 255), ImageChops.multiply(rim, blur(bottom_band, px(2))), 0.3)


def main():
    xml = SOURCE.read_text(encoding="utf-8")
    letter_path, *waves = re.findall(r"<path(.*?)(?:/>|</path>)", xml, flags=re.S)

    canvas = background()
    letter_mask = Image.new("L", (W, W), 0)
    ImageDraw.Draw(letter_mask).polygon(points(re.search(r'pathData="([^"]+)"', letter_path).group(1)), fill=255)
    letter(canvas, blur(letter_mask, 0.6))

    scale = W / VIEW_SIZE
    for wave in waves:
        color = rgb(re.search(r'strokeColor="([^"]+)"', wave).group(1))
        width = float(re.search(r'strokeWidth="([^"]+)"', wave).group(1)) * scale
        line = points(re.search(r'pathData="([^"]+)"', wave).group(1))
        glass_wave(canvas, stroke_mask(line, width), color, width)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    canvas.resize((SIZE, SIZE), Image.LANCZOS).convert("RGB").save(OUT, optimize=True)
    print(OUT)


if __name__ == "__main__":
    main()
