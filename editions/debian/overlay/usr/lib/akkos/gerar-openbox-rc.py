#!/usr/bin/python3
"""
gerar-openbox-rc.py — cria /etc/xdg/akkos/openbox/rc.xml a partir do rc.xml
padrão do Openbox (que traz todos os comportamentos de mouse e janela),
aplicando a identidade e os atalhos do Akko's OS.

Rodado no build (hook 0500). Partir do padrão evita perder as dezenas de
ligações de mouse do Openbox que fazem as janelas funcionarem.
"""

import sys
import xml.etree.ElementTree as ET

NS = "http://openbox.org/3.4/rc"
ET.register_namespace("", NS)
Q = lambda tag: f"{{{NS}}}{tag}"  # noqa: E731

ORIGEM = sys.argv[1] if len(sys.argv) > 1 else "/etc/xdg/openbox/rc.xml"
DESTINO = sys.argv[2] if len(sys.argv) > 2 else "/etc/xdg/akkos/openbox/rc.xml"

ATALHOS = [
    # tecla, ação, comando (ou None para ações internas)
    # Super sozinha: o xcape (akkos-autostart) transforma o toque em Super+Espaço
    ("W-space", "Execute", "akko-painel --menu"),
    ("A-F1", "Execute", "akko-painel --menu"),
    ("W-e", "Execute", "akko-arquivos"),
    ("W-b", "Execute", "akko-navegador"),
    ("W-Return", "Execute", "xfce4-terminal"),
    ("C-A-t", "Execute", "xfce4-terminal"),
    ("W-n", "Execute", "akko-rede"),
    ("W-l", "Execute", "dm-tool lock"),
    ("Print", "Execute", "akko-captura"),
    ("S-Print", "Execute", "akko-captura --janela"),
    ("C-S-Escape", "Execute", "xfce4-terminal -T Processos -x htop"),
    ("XF86AudioRaiseVolume", "Execute", "wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+"),
    ("XF86AudioLowerVolume", "Execute", "wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"),
    ("XF86AudioMute", "Execute", "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"),
    ("W-d", "ToggleShowDesktop", None),
    ("W-Up", "ToggleMaximize", None),
    ("W-Down", "Iconify", None),
]


def acao(nome, comando=None):
    a = ET.Element(Q("action"), {"name": nome})
    if comando:
        ET.SubElement(a, Q("command")).text = comando
    return a


def encaixe(lado):
    """Super+←/→: janela ocupa metade da tela (encaixe lateral)."""
    a = ET.Element(Q("action"), {"name": "UnmaximizeFull"})
    b = ET.Element(Q("action"), {"name": "MoveResizeTo"})
    ET.SubElement(b, Q("x")).text = "0" if lado == "esquerda" else "-0"
    ET.SubElement(b, Q("y")).text = "0"
    ET.SubElement(b, Q("width")).text = "50%"
    ET.SubElement(b, Q("height")).text = "100%"
    return [a, b]


def main():
    arvore = ET.parse(ORIGEM)
    raiz = arvore.getroot()

    tema = raiz.find(Q("theme"))
    tema.find(Q("name")).text = "AkkoOS"
    for fonte in tema.findall(Q("font")):
        fonte.find(Q("name")).text = "Inter"
        if fonte.get("place") == "ActiveWindow":
            fonte.find(Q("weight")).text = "Bold"
    tema.find(Q("titleLayout")).text = "NLIMC"
    tema.find(Q("animateIconify")).text = "yes"

    # uma área de trabalho só (o painel não mostra áreas de trabalho)
    desk = raiz.find(Q("desktops"))
    desk.find(Q("number")).text = "1"
    desk.find(Q("popupTime")).text = "0"

    # janelas novas: centralizadas, inteligentes
    place = raiz.find(Q("placement"))
    if place is not None and place.find(Q("center")) is not None:
        place.find(Q("center")).text = "yes"

    teclado = raiz.find(Q("keyboard"))
    existentes = {kb.get("key") for kb in teclado.findall(Q("keybind"))}
    for tecla, nome, comando in ATALHOS:
        if tecla in existentes:
            for kb in teclado.findall(Q("keybind")):
                if kb.get("key") == tecla:
                    teclado.remove(kb)
        kb = ET.SubElement(teclado, Q("keybind"), {"key": tecla})
        kb.append(acao(nome, comando))
    for tecla, lado in (("W-Left", "esquerda"), ("W-Right", "direita")):
        for kb in teclado.findall(Q("keybind")):
            if kb.get("key") == tecla:
                teclado.remove(kb)
        kb = ET.SubElement(teclado, Q("keybind"), {"key": tecla})
        for a in encaixe(lado):
            kb.append(a)

    # menu do botão direito na área de trabalho: só o nosso
    menu = raiz.find(Q("menu"))
    for f in menu.findall(Q("file")):
        menu.remove(f)
    ET.SubElement(menu, Q("file")).text = "/etc/xdg/akkos/openbox/menu.xml"

    arvore.write(DESTINO, encoding="UTF-8", xml_declaration=True)
    print(f"rc.xml do Akko's OS gerado em {DESTINO}")


if __name__ == "__main__":
    main()
