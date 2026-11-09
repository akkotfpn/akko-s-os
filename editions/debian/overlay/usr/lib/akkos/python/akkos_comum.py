"""
akkos_comum — peças compartilhadas pelos programas do Akko's OS.

  - PALETA / CSS: identidade visual única (vem de branding/palette.json)
  - tocar(evento): pede ao akko-soundd para tocar um som do sistema
  - executar_destacado(): inicia um programa sem prender o processo atual
  - formatar_tamanho(): bytes → texto legível em pt-BR
"""

import json
import os
import socket
import subprocess

SONS_DIR = "/usr/share/sounds/akkos"
EVENTOS = ("boot_chime", "shutdown", "notify", "error", "click", "window_open")

_PALETA_ARQ = "/usr/share/akkos/palette.json"
_PALETA_PADRAO = {
    "brand": {"cyan": "#FF7A59", "indigo": "#E0243B", "magenta": "#9F1239"},
    "dark": {"background": "#120A0D", "surface": "#1C1115", "surface_alt": "#2B171E",
             "text": "#F5E9EB", "text_muted": "#B3959C"},
    "status": {"success": "#22C55E", "warning": "#F59E0B", "error": "#EF4444", "info": "#FB923C"},
}


def paleta():
    try:
        with open(_PALETA_ARQ) as f:
            return json.load(f)
    except (OSError, ValueError):
        return _PALETA_PADRAO


def css_base():
    """CSS GTK3 com as cores da marca. Usado por painel, explorador e rede."""
    p = paleta()
    b, d, s = p["brand"], p["dark"], p["status"]
    return f"""
    @define-color akk_bg {d['background']};
    @define-color akk_surface {d['surface']};
    @define-color akk_surface_alt {d['surface_alt']};
    @define-color akk_text {d['text']};
    @define-color akk_muted {d['text_muted']};
    @define-color akk_cyan {b['cyan']};
    @define-color akk_indigo {b['indigo']};
    @define-color akk_magenta {b['magenta']};
    @define-color akk_ok {s['success']};
    @define-color akk_warn {s['warning']};
    @define-color akk_err {s['error']};

    window.akkos, .akkos-bg {{ background-color: @akk_bg; color: @akk_text; }}
    .akkos-surface {{ background-color: @akk_surface; border-radius: 10px; }}
    .akkos-muted {{ color: @akk_muted; }}
    .akkos-titulo {{ font-size: 15pt; font-weight: 700; }}
    .akkos-erro {{ color: @akk_err; }}
    .akkos-ok {{ color: @akk_ok; }}
    button.akkos-primario {{
        background-image: linear-gradient(90deg, @akk_cyan, @akk_indigo);
        color: #ffffff; border: none; border-radius: 8px; font-weight: 700;
    }}
    button.akkos-plano {{ background: transparent; border: none; box-shadow: none; color: @akk_text; }}
    button.akkos-plano:hover {{ background-color: @akk_surface_alt; }}
    entry.akkos-campo {{
        background-color: @akk_surface; color: @akk_text; border-radius: 8px;
        border: 1px solid @akk_surface_alt; padding: 6px 10px;
    }}
    entry.akkos-campo:focus {{ border-color: @akk_cyan; }}
    """


def aplicar_css(extra=""):
    import gi
    gi.require_version("Gtk", "3.0")
    from gi.repository import Gdk, Gtk
    prov = Gtk.CssProvider()
    prov.load_from_data((css_base() + extra).encode())
    Gtk.StyleContext.add_provider_for_screen(
        Gdk.Screen.get_default(), prov, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)


def _socket_sons():
    run = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
    return os.path.join(run, "akkos-sound.sock")


def tocar(evento, esperar=False):
    """Toca um som do sistema. Tenta o daemon (rápido, respeita as
    preferências); se ele não estiver rodando, toca direto com pw-play."""
    if evento not in EVENTOS:
        return
    if not esperar:
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
            s.sendto(evento.encode(), _socket_sons())
            s.close()
            return
        except OSError:
            pass
    arq = os.path.join(SONS_DIR, f"{evento}.wav")
    for cmd in (["pw-play", arq], ["paplay", arq], ["aplay", "-q", arq]):
        try:
            p = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if esperar:
                p.wait(timeout=10)
            return
        except FileNotFoundError:
            continue
        except subprocess.TimeoutExpired:
            p.kill()
            return


def executar_destacado(argv, cwd=None):
    """Inicia um programa em nova sessão; não vira zumbi do chamador."""
    return subprocess.Popen(argv, cwd=cwd, start_new_session=True,
                            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL)


def formatar_tamanho(n):
    for unidade in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unidade == "TB":
            return f"{n:.0f} {unidade}" if unidade == "B" else f"{n:.1f} {unidade}".replace(".", ",")
        n /= 1024
