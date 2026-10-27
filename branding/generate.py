#!/usr/bin/env python3
"""
generate.py — gera os arquivos de identidade visual do Akko's OS a partir de
palette.json: logotipo (SVG + PNGs) e papéis de parede claro/escuro.

Uso:  python3 branding/generate.py <fonte-Inter.ttf>
Requer: Pillow. Saída em branding/out/ (versionada, pra o build não depender disto).
"""

import json
import math
import os
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out")
PAL = json.load(open(os.path.join(HERE, "palette.json")))


def rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


CYAN, INDIGO, MAGENTA = (rgb(PAL["brand"][k]) for k in ("cyan", "indigo", "magenta"))


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def brand_gradient(t):
    """ciano → índigo → magenta"""
    return lerp(CYAN, INDIGO, t * 2) if t < 0.5 else lerp(INDIGO, MAGENTA, (t - 0.5) * 2)


# ---------------------------------------------------------------- logotipo
# Monograma "A" em traço arredondado, dentro de um quadrado com o degradê da marca.

LOGO_SVG = """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256">
  <defs>
    <linearGradient id="g" x1="0" y1="1" x2="1" y2="0">
      <stop offset="0" stop-color="{c}"/>
      <stop offset="0.5" stop-color="{i}"/>
      <stop offset="1" stop-color="{m}"/>
    </linearGradient>
  </defs>
  <rect x="8" y="8" width="240" height="240" rx="56" fill="url(#g)"/>
  <path d="M72 196 L128 60 L184 196" fill="none" stroke="#FFFFFF" stroke-width="26"
        stroke-linecap="round" stroke-linejoin="round"/>
  <path d="M100 148 H156" fill="none" stroke="#FFFFFF" stroke-width="20"
        stroke-linecap="round"/>
</svg>
""".format(c=PAL["brand"]["cyan"], i=PAL["brand"]["indigo"], m=PAL["brand"]["magenta"])


def draw_logo(size):
    S = 4  # supersampling pra bordas suaves
    W = size * S
    k = W / 256.0
    # fundo em degradê diagonal recortado num quadrado arredondado
    grad = Image.new("RGB", (W, W))
    gp = grad.load()
    for y in range(W):
        for x in range(W):
            t = ((x / W) + (1 - y / W)) / 2
            gp[x, y] = brand_gradient(t)
    mask = Image.new("L", (W, W), 0)
    ImageDraw.Draw(mask).rounded_rectangle([8 * k, 8 * k, 248 * k, 248 * k], radius=56 * k, fill=255)
    img = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    img.paste(grad, (0, 0), mask)

    d = ImageDraw.Draw(img)
    white = (255, 255, 255, 255)

    def stroke(points, width):
        w = int(width * k)
        pts = [(x * k, y * k) for x, y in points]
        d.line(pts, fill=white, width=w, joint="curve")
        for p in (pts[0], pts[-1]):
            d.ellipse([p[0] - w / 2, p[1] - w / 2, p[0] + w / 2, p[1] + w / 2], fill=white)

    stroke([(72, 196), (128, 60), (184, 196)], 26)
    stroke([(100, 148), (156, 148)], 20)
    return img.resize((size, size), Image.LANCZOS)


# ---------------------------------------------------------- papel de parede

def wallpaper(w, h, mode, font_path):
    bg = rgb(PAL[mode]["background"])
    base = Image.new("RGB", (w, h), bg)
    glow = Image.new("RGB", (w, h), (0, 0, 0))
    gd = ImageDraw.Draw(glow)
    strength = 0.30 if mode == "dark" else 1.0
    # duas manchas de luz suaves nas cores da marca
    for cx, cy, r, color in ((0.18, 0.85, 0.55, CYAN), (0.85, 0.15, 0.6, MAGENTA), (0.6, 0.7, 0.35, INDIGO)):
        R = int(r * w)
        c = tuple(int(v * strength) for v in color)
        gd.ellipse([cx * w - R, cy * h - R, cx * w + R, cy * h + R], fill=c)
    glow = glow.filter(ImageFilter.GaussianBlur(w // 14))
    if mode == "dark":
        img = _add(base, glow)
    else:
        # no claro: mistura as cores da marca sobre o fundo, bem de leve
        mask = glow.convert("L").point(lambda v: int(v * 0.22))
        img = Image.composite(glow, base, mask)

    # linhas diagonais finas (assinatura sutil)
    lines = Image.new("L", (w, h), 0)
    ld = ImageDraw.Draw(lines)
    step = w // 24
    for i in range(-h, w, step):
        ld.line([(i, h), (i + h, 0)], fill=10 if mode == "dark" else 14, width=max(1, w // 1920))
    tint = (255, 255, 255) if mode == "dark" else (40, 50, 90)
    img = Image.composite(Image.new("RGB", (w, h), tint), img, lines)

    # logotipo + nome, discretos, no canto inferior direito
    logo_size = h // 14
    logo = draw_logo(logo_size)
    margin = h // 16
    x = w - margin - logo_size
    y = h - margin - logo_size
    font = ImageFont.truetype(font_path, int(logo_size * 0.42))
    try:
        font.set_variation_by_axes([24, 600])   # Inter variável: tamanho óptico, peso
    except Exception:
        pass
    d = ImageDraw.Draw(img)
    text = "Akko's OS"
    tw = d.textlength(text, font=font)
    tx = x - int(tw) - logo_size // 3
    color = rgb(PAL[mode]["text"])
    alpha_layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ad = ImageDraw.Draw(alpha_layer)
    ad.text((tx, y + logo_size // 2), text, font=font, fill=color + (200,), anchor="lm")
    img = img.convert("RGBA")
    img.alpha_composite(alpha_layer)
    logo_faded = logo.copy()
    logo_faded.putalpha(logo.getchannel("A").point(lambda a: int(a * 0.9)))
    img.alpha_composite(logo_faded, (x, y))
    return img.convert("RGB")


def _add(a, b):
    from PIL import ImageChops
    return ImageChops.add(a, b)


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(1)
    font_path = sys.argv[1]
    os.makedirs(OUT, exist_ok=True)

    with open(os.path.join(OUT, "akkos-logo.svg"), "w") as f:
        f.write(LOGO_SVG)
    for s in (16, 32, 48, 64, 128, 256, 512):
        draw_logo(s).save(os.path.join(OUT, f"akkos-logo-{s}.png"), optimize=True)

    for mode in ("dark", "light"):
        wallpaper(3840, 2160, mode, font_path).save(
            os.path.join(OUT, f"akkos-wallpaper-{mode}.png"), optimize=True)
        wallpaper(1280, 720, mode, font_path).save(
            os.path.join(OUT, f"akkos-wallpaper-{mode}-preview.png"), optimize=True)
    print("gerado em", OUT)


if __name__ == "__main__":
    main()
