#!/usr/bin/env python3
"""
gerar_arte_boot.py — imagens do boot do Akko's OS, geradas a partir da
identidade (branding/palette.json, logo e fonte Inter):

  GRUB (pasta grub):      splash.png (1920x1080), select_*.png (destaque do menu)
  Plymouth (pasta ply):   logo.png, nome.png, ponto.png, caixa.png, bala.png

Uso: gerar_arte_boot.py <raiz-do-repo> <saida-grub> <saida-plymouth>
Requer Pillow.
"""

import json
import os
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont


def rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def fonte(caminho, tamanho, peso=700):
    f = ImageFont.truetype(caminho, tamanho)
    try:
        f.set_variation_by_axes([min(32, max(14, tamanho)), peso])   # Inter variável: opsz, wght
    except Exception:
        pass
    return f


def splash_grub(raiz, pal, inter, destino):
    W, H = 1920, 1080
    fundo = Image.open(os.path.join(raiz, "branding/out/akkos-wallpaper-dark.png")).convert("RGB")
    fundo = fundo.resize((W, H), Image.LANCZOS)
    # escurece o centro pra o menu ficar legível
    veu = Image.new("L", (W, H), 0)
    ImageDraw.Draw(veu).rounded_rectangle([W * 0.27, H * 0.47, W * 0.73, H * 0.83], radius=28, fill=150)
    veu = veu.filter(ImageFilter.GaussianBlur(30))
    fundo = Image.composite(Image.new("RGB", (W, H), rgb(pal["dark"]["background"])), fundo, veu)
    img = fundo.convert("RGBA")
    d = ImageDraw.Draw(img)
    # caixa do menu
    d.rounded_rectangle([W * 0.28, H * 0.48, W * 0.72, H * 0.82], radius=22,
                        fill=rgb(pal["dark"]["surface"]) + (235,), outline=rgb(pal["dark"]["surface_alt"]) + (255,), width=2)
    # logo e nome no topo
    logo = Image.open(os.path.join(raiz, "branding/out/akkos-logo-256.png")).convert("RGBA").resize((168, 168), Image.LANCZOS)
    img.alpha_composite(logo, ((W - 168) // 2, int(H * 0.13)))
    f = fonte(inter, 64, 800)
    texto = "Akko's OS"
    tw = d.textlength(texto, font=f)
    d.text(((W - tw) / 2, H * 0.13 + 190), texto, font=f, fill=rgb(pal["dark"]["text"]))
    f2 = fonte(inter, 26, 500)
    sub = "Escolha como iniciar"
    tw = d.textlength(sub, font=f2)
    d.text(((W - tw) / 2, H * 0.13 + 270), sub, font=f2, fill=rgb(pal["dark"]["text_muted"]))
    img.convert("RGB").save(os.path.join(destino, "splash.png"), optimize=True)


def selecao_grub(pal, destino):
    """Nove pedaços (estilo 9-slice) do destaque do item selecionado no menu."""
    r = 10
    s = 3 * r
    base = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(base)
    d.rounded_rectangle([0, 0, s - 1, s - 1], radius=r, fill=rgb(pal["brand"]["indigo"]) + (255,))
    partes = {"nw": (0, 0), "n": (r, 0), "ne": (2 * r, 0), "w": (0, r), "c": (r, r), "e": (2 * r, r),
              "sw": (0, 2 * r), "s": (r, 2 * r), "se": (2 * r, 2 * r)}
    for nome, (x, y) in partes.items():
        base.crop((x, y, x + r, y + r)).save(os.path.join(destino, f"select_{nome}.png"))


def plymouth(raiz, pal, inter, destino):
    logo = Image.open(os.path.join(raiz, "branding/out/akkos-logo-256.png")).convert("RGBA").resize((150, 150), Image.LANCZOS)
    logo.save(os.path.join(destino, "logo.png"))

    f = fonte(inter, 40, 800)
    texto = "Akko's OS"
    medida = ImageDraw.Draw(Image.new("RGBA", (1, 1))).textbbox((0, 0), texto, font=f)
    img = Image.new("RGBA", (medida[2] + 8, medida[3] + 12), (0, 0, 0, 0))
    ImageDraw.Draw(img).text((4, 2), texto, font=f, fill=rgb(pal["dark"]["text"]) + (255,))
    img.save(os.path.join(destino, "nome.png"))

    ponto = Image.new("RGBA", (12, 12), (0, 0, 0, 0))
    ImageDraw.Draw(ponto).ellipse([0, 0, 11, 11], fill=rgb(pal["brand"]["cyan"]) + (255,))
    ponto.save(os.path.join(destino, "ponto.png"))

    caixa = Image.new("RGBA", (360, 48), (0, 0, 0, 0))
    ImageDraw.Draw(caixa).rounded_rectangle([0, 0, 359, 47], radius=12, fill=rgb(pal["dark"]["surface"]) + (255,),
                                            outline=rgb(pal["brand"]["cyan"]) + (255,), width=2)
    caixa.save(os.path.join(destino, "caixa.png"))

    bala = Image.new("RGBA", (12, 12), (0, 0, 0, 0))
    ImageDraw.Draw(bala).ellipse([1, 1, 10, 10], fill=rgb(pal["dark"]["text"]) + (255,))
    bala.save(os.path.join(destino, "bala.png"))


def main():
    if len(sys.argv) != 4:
        print(__doc__)
        sys.exit(1)
    raiz, saida_grub, saida_ply = sys.argv[1:]
    pal = json.load(open(os.path.join(raiz, "branding/palette.json")))
    inter = os.path.join(raiz, "branding/fonts/Inter.ttf")
    os.makedirs(saida_grub, exist_ok=True)
    os.makedirs(saida_ply, exist_ok=True)
    splash_grub(raiz, pal, inter, saida_grub)
    selecao_grub(pal, saida_grub)
    plymouth(raiz, pal, inter, saida_ply)
    for pasta in (saida_grub, saida_ply):
        print(pasta, sorted(os.listdir(pasta)))


if __name__ == "__main__":
    main()
