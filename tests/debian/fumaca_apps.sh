#!/usr/bin/env bash
# fumaca_apps.sh — teste rápido dos programas gráficos do Akko's OS.
#
# Roda num container Debian 13 (o mesmo da ISO), com tela virtual (Xvfb) e
# Openbox: abre cada programa, confere se a janela apareceu e se não houve
# erro do Python. Leva poucos minutos; o CI só constrói a ISO se passar.
#
#   docker run --rm -v "$PWD:/repo:ro" -v /tmp/saida:/saida debian:trixie \
#       bash /repo/tests/debian/fumaca_apps.sh /saida
#
# Gera em SAIDA: um print por programa (.png) e o log de cada um.

set -uo pipefail
SAIDA=${1:-/tmp/fumaca}
REPO=$(cd "$(dirname "$0")/../.." && pwd)
OV="$REPO/editions/debian/overlay"
mkdir -p "$SAIDA"

echo "== instalando dependências"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    python3 python3-gi python3-gi-cairo gir1.2-gtk-3.0 gir1.2-wnck-3.0 gir1.2-nm-1.0 \
    xvfb xauth openbox x11-utils wmctrl xdotool imagemagick dbus-x11 dbus \
    adwaita-icon-theme papirus-icon-theme fonts-inter fonts-dejavu-core \
    zenity libnotify-bin wireplumber pipewire-bin >/dev/null || exit 1

echo "== instalando os programas do Akko's OS"
cp -r "$OV/usr/lib/akkos" /usr/lib/
cp "$OV"/usr/bin/* /usr/bin/ 2>/dev/null
cp -r "$OV/etc/xdg" /etc/ 2>/dev/null
[ -d "$OV/etc/gtk-3.0" ] && cp -r "$OV/etc/gtk-3.0" /etc/
cp "$REPO/editions/debian/compat/win-launcher.sh" /usr/bin/win-launcher
chmod +x /usr/lib/akkos/akko-* /usr/bin/akko-* /usr/bin/win-launcher

useradd -m -s /bin/bash akko 2>/dev/null
mkdir -p /home/akko/Documentos /home/akko/Imagens
touch "/home/akko/Documentos/texto de teste.txt" /home/akko/Documentos/jogo.exe
chown -R akko: /home/akko

cat > /tmp/sessao.sh <<'EOF'
#!/bin/bash
# roda como akko, dentro de dbus-run-session, com DISPLAY=:5
SAIDA=$1
export XDG_RUNTIME_DIR=/tmp/run-akko; mkdir -p -m 700 "$XDG_RUNTIME_DIR"
openbox & sleep 2
falhas=0

abrir() {   # abrir NOME PADRAO_JANELA comando...
    local nome=$1 padrao=$2; shift 2
    "$@" >"$SAIDA/$nome.log" 2>&1 &
    local pid=$! ok=0
    for _ in $(seq 1 20); do
        wmctrl -l | grep -q -- "$padrao" && { ok=1; break; }
        kill -0 $pid 2>/dev/null || break
        sleep 0.5
    done
    sleep 1.5
    import -window root "$SAIDA/$nome.png" 2>/dev/null
    local erro=""
    grep -q "Traceback" "$SAIDA/$nome.log" && erro="erro do Python"
    [ $ok = 1 ] || erro="${erro:+$erro; }janela '$padrao' não apareceu"
    if [ -n "$erro" ]; then
        echo "FALHOU $nome: $erro"
        sed 's/^/    /' "$SAIDA/$nome.log" | tail -25
        falhas=$((falhas + 1))
    else
        echo "OK     $nome: $(wmctrl -l | grep -- "$padrao" | head -1 | cut -c 1-90)"
    fi
    kill $pid 2>/dev/null; sleep 0.5; kill -9 $pid 2>/dev/null
}

abrir painel        "Painel"                   /usr/lib/akkos/akko-painel
abrir arquivos      "Documentos"               /usr/lib/akkos/akko-arquivos "$HOME/Documentos"
abrir arquivos-home "akko"                     /usr/lib/akkos/akko-arquivos
abrir rede          "Rede"                     /usr/lib/akkos/akko-rede
abrir escolha       "Abrir programa Windows"   /usr/lib/akkos/akko-win-escolha jogo.exe jogo
abrir splash        "jogo.exe"                 /usr/lib/akkos/akko-win-splash jogo.exe "Preparando…"
exit $falhas
EOF
chmod +x /tmp/sessao.sh
chown -R akko: "$SAIDA"

echo "== abrindo cada programa"
su akko -c "xvfb-run -n 5 -s '-screen 0 1280x800x24' dbus-run-session -- /tmp/sessao.sh '$SAIDA'"
rc=$?
echo "== $rc programa(s) com falha"
exit $rc
