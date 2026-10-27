#!/usr/bin/bash
# Roda DENTRO do build da imagem. Cada etapa registra o que fez, pra o log do
# CI servir de evidência. Falha cedo em qualquer erro.

set -euo pipefail

CTX=/ctx
log() { printf '\n\033[1;96m[akkos-build]\033[0m %s\n' "$*"; }

: "${BASE_IMAGE:?}" "${IMAGE_NAME:?}" "${IMAGE_VENDOR:?}" "${IMAGE_VARIANT:?}" "${AKKOS_VERSION:?}"

log "Base: ${BASE_IMAGE} | Imagem: ${IMAGE_VENDOR}/${IMAGE_NAME} | Variante: ${IMAGE_VARIANT} | Versão: ${AKKOS_VERSION}"

log "1/6 Copiando arquivos do sistema"
cp -av "${CTX}/system_files/." /

log "2/6 Pacotes: idioma português (Brasil) e conversor de imagem"
dnf5 -y install --skip-unavailable \
    glibc-langpack-pt \
    langpacks-pt_BR \
    libjxl-utils
rpm -q glibc-langpack-pt langpacks-pt_BR libjxl-utils || true

log "3/6 Identidade: os-release e system-release"
# ID continua o da base (bazzite): ferramentas da base dependem dele.
# Tudo que o usuário vê passa a ser Akko's OS.
OSR=/usr/lib/os-release
FEDORA_VERSION=$(rpm -E %fedora)
set_osr() {   # set_osr CHAVE "valor"
    if grep -q "^$1=" "$OSR"; then
        sed -i "s|^$1=.*|$1=\"$2\"|" "$OSR"
    else
        echo "$1=\"$2\"" >> "$OSR"
    fi
}
set_osr NAME "Akko's OS"
set_osr PRETTY_NAME "Akko's OS Desktop ${AKKOS_VERSION}"
set_osr VARIANT "Desktop (${IMAGE_VARIANT})"
set_osr VARIANT_ID "${IMAGE_NAME}"
set_osr HOME_URL "https://github.com/akkotfpn/akko-s-os"
set_osr DOCUMENTATION_URL "https://github.com/akkotfpn/akko-s-os/tree/main/docs"
set_osr SUPPORT_URL "https://github.com/akkotfpn/akko-s-os/issues"
set_osr BUG_REPORT_URL "https://github.com/akkotfpn/akko-s-os/issues"
set_osr DEFAULT_HOSTNAME "akkos"
set_osr LOGO "akkos-logo"
set_osr ANSI_COLOR "1;96"
set_osr BUILD_ID "${AKKOS_VERSION}"
set_osr IMAGE_ID "${IMAGE_NAME}-${AKKOS_VERSION}"
set_osr BOOTLOADER_NAME "Akko's OS ${AKKOS_VERSION}"
set_osr AKKOS_EDITION "desktop"
set_osr AKKOS_VERSION "${AKKOS_VERSION}"
set_osr AKKOS_BASE_IMAGE "${BASE_IMAGE}"
echo "Akko's OS release ${FEDORA_VERSION} (Desktop)" > /etc/system-release
echo akkos > /etc/hostname
# Padrões de idioma e teclado (português do Brasil). O instalador sobrescreve
# se a pessoa escolher outro idioma/teclado.
echo 'LANG=pt_BR.UTF-8' > /etc/locale.conf
echo 'KEYMAP=br-abnt2' > /etc/vconsole.conf
install -Dm644 /dev/stdin /etc/X11/xorg.conf.d/00-keyboard.conf <<'EOF'
Section "InputClass"
        Identifier "system-keyboard"
        MatchIsKeyboard "on"
        Option "XkbLayout" "br"
EndSection
EOF
# padrão de raiz para "bootc install" e geradores de disco/ISO
install -Dm644 /dev/stdin /usr/lib/bootc/install/20-akkos.toml <<'EOF'
[install.filesystem.root]
type = "btrfs"
EOF
cat "$OSR"

log "4/6 Informações da imagem (usadas pelas ferramentas de atualização da base)"
INFO=/usr/share/ublue-os/image-info.json
IMAGE_REF="ostree-unverified-registry:ghcr.io/${IMAGE_VENDOR}/${IMAGE_NAME}"
if [ -f "$INFO" ]; then
    tmp=$(mktemp)
    jq --arg n "$IMAGE_NAME" --arg v "$IMAGE_VENDOR" --arg r "$IMAGE_REF" --arg ver "$AKKOS_VERSION" \
       '."image-name"=$n | ."image-vendor"=$v | ."image-ref"=$r | ."image-tag"="latest" | ."version"=$ver | ."version-pretty"=("Akko'"'"'s OS " + $ver)' \
       "$INFO" > "$tmp"
    install -m 644 "$tmp" "$INFO"
    cat "$INFO"
else
    echo "aviso: $INFO não existe na base"
fi

log "5/6 Logotipo e papéis de parede"
B="${CTX}/branding"
for s in 16 32 48 64 128 256 512; do
    install -Dm644 "$B/akkos-logo-$s.png" "/usr/share/icons/hicolor/${s}x${s}/apps/akkos-logo.png"
done
install -Dm644 "$B/akkos-logo.svg" /usr/share/icons/hicolor/scalable/apps/akkos-logo.svg
install -Dm644 "$B/akkos-logo-256.png" /usr/share/pixmaps/akkos-logo.png
gtk-update-icon-cache -f /usr/share/icons/hicolor 2>/dev/null || true

# Pacote de papel de parede do KDE: claro em images/, escuro em images_dark/
WP=/usr/share/wallpapers/AkkoOS
install -Dm644 "$B/akkos-wallpaper-light.png" "$WP/contents/images/3840x2160.png"
install -Dm644 "$B/akkos-wallpaper-dark.png" "$WP/contents/images_dark/3840x2160.png"
install -Dm644 "$B/akkos-wallpaper-dark-preview.png" "$WP/contents/screenshot.png"
cat > "$WP/metadata.json" <<'EOF'
{
    "KPlugin": {
        "Authors": [ { "Name": "Akko's OS" } ],
        "Id": "AkkoOS",
        "License": "Apache-2.0",
        "Name": "Akko's OS",
        "Name[pt_BR]": "Akko's OS"
    }
}
EOF
DARK="$WP/contents/images_dark/3840x2160.png"

# Os "padrões" da base apontam para /usr/share/backgrounds/default*. Substituímos
# no formato que cada arquivo usa (jxl, png...).
shopt -s nullglob
for f in /usr/share/backgrounds/default*.{jxl,png,webp}; do
    ext="${f##*.}"
    rm -f "$f"
    case "$ext" in
        jxl)  cjxl "$DARK" "$f" -q 95 >/dev/null ;;
        png)  install -m644 "$DARK" "$f" ;;
        webp) echo "aviso: $f (webp) removido, sem conversor" ;;
    esac
    echo "papel de parede padrão substituído: $f"
done

# Aparência global (look-and-feel) do KDE: aponta o papel de parede pro nosso
for d in /usr/share/plasma/look-and-feel/*/contents/defaults; do
    if grep -q '^\[Wallpaper\]' "$d"; then
        sed -i '/^\[Wallpaper\]/,/^\[/{s|^Image=.*|Image=AkkoOS|}' "$d"
        echo "look-and-feel ajustado: $d"
    fi
done

# Tela de login (SDDM): a base aponta para um tema que pode não existir
# ("01-breeze-fedora"), e aí o SDDM cai no tema embutido. Usamos o primeiro
# tema existente desta lista.
for th in 01-breeze-fedora breeze; do
    if [ -f "/usr/share/sddm/themes/$th/theme.conf" ] || [ -f "/usr/share/sddm/themes/$th/metadata.desktop" ]; then
        install -Dm644 /dev/stdin /etc/sddm.conf.d/zz-akkos.conf <<EOF
[Theme]
Current=$th
EOF
        echo "tema do SDDM: $th"
        break
    fi
done
ls /usr/share/sddm/themes/ || true
# Tela de login (SDDM): fundo próprio no tema em uso
for t in /usr/share/sddm/themes/*/; do
    if [ -f "$t/theme.conf" ]; then
        printf '[General]\nbackground=%s\n' "$DARK" > "$t/theme.conf.user"
        echo "fundo do SDDM: $t"
    fi
done
for f in /usr/lib/plasmalogin/defaults.conf; do
    [ -f "$f" ] && sed -i "s|file:///usr/share/backgrounds/default.jxl|file://$DARK|g" "$f" && echo "plasmalogin: $f"
done
shopt -u nullglob

log "6/6 Ferramenta akkos e limpeza"
chmod 755 /usr/bin/akkos
/usr/bin/akkos version
dnf5 clean all
rm -rf /var/lib/dnf /run/dnf
log "Build concluído"
