#!/usr/bin/env bash
# build_os.sh — gera a ISO do Akko's OS (edição Debian) do zero.
#
#   sudo editions/debian/build_os.sh
#
# Resultado: editions/debian/saida/akkos-debian-<versão>-amd64.iso
#            (ISO híbrida: boota em BIOS e UEFI, de DVD ou pendrive,
#             com Secure Boot pelo shim assinado do Debian)
#
# Variáveis opcionais:
#   AKKOS_VERSAO   versão no sistema (padrão: AAAA.MM.DD)
#   AKKOS_TRAB     pasta de trabalho do live-build (padrão: editions/debian/trabalho; ~15 GB)
#   AKKOS_SAIDA    pasta da ISO final (padrão: editions/debian/saida)
#   AKKOS_MIRROR   espelho Debian (padrão: http://deb.debian.org/debian)
#
# Precisa de: Debian 13 (ou um container debian:trixie com --privileged),
# root, internet e ~20 GB livres. As ferramentas de build são instaladas
# automaticamente se faltarem.
#
# Etapas:
#   1. dependências do build
#   2. configuração do live-build (lb config)
#   3. pacotes e hooks (o que roda dentro do sistema)
#   4. arquivos do sistema: overlay + programas + segurança + sons + identidade
#   5. bootloader: tema do GRUB (BIOS/UEFI) e Plymouth
#   6. lb build
#   7. ISO final, checksum e lista de pacotes

set -euo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAIZ="$(cd "$AQUI/../.." && pwd)"
TRAB="${AKKOS_TRAB:-$AQUI/trabalho}"
SAIDA="${AKKOS_SAIDA:-$AQUI/saida}"
VERSAO="${AKKOS_VERSAO:-$(date -u +%Y.%m.%d)}"
MIRROR="${AKKOS_MIRROR:-http://deb.debian.org/debian}"
DIST=trixie

passo() { printf '\n\033[1;96m==> [%s] %s\033[0m\n' "$(date +%H:%M:%S)" "$*"; }
erro() { printf '\033[1;31mERRO: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || erro "rode como root (sudo $0)"

# ------------------------------------------------------------------ 1
passo "1/7 Dependências do build"
DEPS=(live-build debootstrap xorriso squashfs-tools mtools dosfstools grub-common grub-pc-bin
      grub-efi-amd64-bin python3 python3-numpy python3-pil fonts-dejavu-core rsync ca-certificates curl)
FALTAM=()
for p in "${DEPS[@]}"; do dpkg -s "$p" >/dev/null 2>&1 || FALTAM+=("$p"); done
if [ ${#FALTAM[@]} -gt 0 ]; then
    echo "instalando: ${FALTAM[*]}"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${FALTAM[@]}"
fi
echo "live-build $(dpkg-query -W -f '${Version}' live-build)"

# ------------------------------------------------------------------ 2
passo "2/7 Configuração do live-build ($DIST, versão $VERSAO)"
mkdir -p "$TRAB" "$SAIDA"
cd "$TRAB"
if [ -d config ]; then
    lb clean --purge >/dev/null 2>&1 || true
    rm -rf config
fi
APPEND="boot=live components quiet splash username=akko user-fullname=Akko hostname=akkos overlay-size=75%"
APPEND+=" locales=pt_BR.UTF-8 keyboard-layouts=br timezone=America/Sao_Paulo"
APPEND+=" init_on_alloc=1 slab_nomerge page_alloc.shuffle=1"

lb config \
    --mode debian \
    --distribution "$DIST" \
    --architecture amd64 \
    --linux-flavours amd64 \
    --archive-areas "main contrib non-free non-free-firmware" \
    --mirror-bootstrap "$MIRROR" \
    --mirror-chroot "$MIRROR" \
    --mirror-binary "$MIRROR" \
    --security true \
    --updates true \
    --system live \
    --initsystem systemd \
    --apt-recommends true \
    --firmware-chroot false \
    --firmware-binary false \
    --debian-installer none \
    --memtest none \
    --binary-image iso-hybrid \
    --bootloaders "grub-pc grub-efi" \
    --uefi-secure-boot enable \
    --bootappend-live "$APPEND" \
    --bootappend-live-failsafe none \
    --iso-application "Akko's OS" \
    --iso-publisher "Akko's Corporation; https://github.com/akkotfpn/akko-s-os" \
    --iso-volume "AKKOS_${VERSAO//./}" \
    --image-name "akkos-debian" \
    --chroot-squashfs-compression-type xz \
    --checksums sha256 \
    --cache true

# ------------------------------------------------------------------ 3
passo "3/7 Pacotes e hooks"
cp "$AQUI/pacotes.list.chroot" config/package-lists/akkos.list.chroot
mkdir -p config/hooks/normal
cp "$AQUI"/hooks/*.hook.chroot config/hooks/normal/
chmod +x config/hooks/normal/*.hook.chroot
grep -cv -E '^\s*(#|$)' config/package-lists/akkos.list.chroot | xargs echo "pacotes listados:"

# ------------------------------------------------------------------ 4
passo "4/7 Arquivos do sistema (overlay, programas, segurança, sons, identidade)"
INC=config/includes.chroot_after_packages
mkdir -p "$INC"
rsync -a "$AQUI/overlay/" "$INC/"

install -Dm755 "$AQUI/compat/win-launcher.sh" "$INC/usr/bin/win-launcher"
install -Dm755 "$AQUI/security/security_hardening.sh" "$INC/usr/lib/akkos/security_hardening.sh"

# umu-launcher: roda o Proton (modo Jogo do win-launcher) sem o Steam.
# Versão e hash fixos; o próprio umu baixa o runtime e o GE-Proton no 1º uso.
UMU_VERSAO=1.4.4
UMU_SHA256=eb590691841f7fad3fc3ad8fd5db4ccb87849fe7948e62b28ece7a4ee48cc851
echo "-- umu-launcher $UMU_VERSAO (Proton fora do Steam)"
UMU_TAR="$TRAB/umu-$UMU_VERSAO.tar"
[ -f "$UMU_TAR" ] || curl -fsSL --retry 4 -o "$UMU_TAR" \
    "https://github.com/Open-Wine-Components/umu-launcher/releases/download/$UMU_VERSAO/umu-launcher-$UMU_VERSAO-zipapp.tar"
echo "$UMU_SHA256  $UMU_TAR" | sha256sum -c --quiet - || erro "hash do umu-launcher não confere"
mkdir -p "$INC/usr/lib/akkos/umu" "$INC/usr/bin"
tar -xf "$UMU_TAR" -C "$INC/usr/lib/akkos/umu" --strip-components=1 umu/umu-run
chmod 755 "$INC/usr/lib/akkos/umu/umu-run"
ln -sf /usr/lib/akkos/umu/umu-run "$INC/usr/bin/umu-run"

# ICU do Windows para o Wine (icu/icuuc/icuin.dll, 64 e 32 bits): o Wine ainda
# não tem e programas novos exigem (ex.: qBittorrent 5). Build da comunidade
# FaithLife (fork do ICU da Microsoft, licença ICU/Unicode), versão e hash fixos.
ICU_TAG=75.1
ICU_SHA256=63a6e66d8b80f57a96b4421da3b431a834265974279dd12888a8578d418ae3e3
echo "-- ICU do Windows $ICU_TAG para o Wine"
ICU_TAR="$TRAB/icu-win-$ICU_TAG.tar.gz"
[ -f "$ICU_TAR" ] || curl -fsSL --retry 4 -o "$ICU_TAR" \
    "https://github.com/FaithLife-Community/icu/releases/download/$ICU_TAG/icu-win.tar.gz"
echo "$ICU_SHA256  $ICU_TAR" | sha256sum -c --quiet - || erro "hash do ICU não confere"
mkdir -p "$INC/usr/share/akkos/wine-icu"
tar -xzf "$ICU_TAR" -C "$INC/usr/share/akkos/wine-icu" --strip-components=1 --no-same-owner -m windows/
ls "$INC/usr/share/akkos/wine-icu/system32/icuuc.dll" "$INC/usr/share/akkos/wine-icu/syswow64/icuuc.dll" "$INC/usr/share/akkos/wine-icu/globalization/ICU/icudtl.dat"
echo "$VERSAO" > "$INC/usr/share/akkos/versao"

echo "-- sintetizando a identidade sonora"
python3 "$AQUI/audio/gerar_sons.py" "$INC/usr/share/sounds/akkos"

echo "-- identidade visual"
B="$RAIZ/branding"
install -Dm644 "$B/palette.json" "$INC/usr/share/akkos/palette.json"
install -Dm644 "$B/out/akkos-wallpaper-dark.png" "$INC/usr/share/backgrounds/akkos/akkos-wallpaper-dark.png"
install -Dm644 "$B/out/akkos-wallpaper-light.png" "$INC/usr/share/backgrounds/akkos/akkos-wallpaper-light.png"
install -Dm644 "$B/out/akkos-logo.svg" "$INC/usr/share/icons/hicolor/scalable/apps/akkos-logo.svg"
for s in 16 32 48 64 128 256 512; do
    install -Dm644 "$B/out/akkos-logo-$s.png" "$INC/usr/share/icons/hicolor/${s}x${s}/apps/akkos-logo.png"
done
install -Dm644 "$B/out/akkos-logo-256.png" "$INC/usr/share/pixmaps/akkos-logo.png"
# fundo do GRUB do sistema instalado e imagens do instalador (Calamares)
install -Dm644 "$B/out/akkos-wallpaper-dark.png" "$INC/usr/share/akkos/grub-fundo.png"
install -Dm644 "$B/out/akkos-logo-256.png" "$INC/etc/calamares/branding/akkos/akkos-logo.png"
install -Dm644 "$B/out/akkos-logo-512.png" "$INC/etc/calamares/branding/akkos/welcome.png"

# ------------------------------------------------------------------ 5
passo "5/7 Boot: tema do GRUB (BIOS + UEFI) e Plymouth"
ARTE="$(mktemp -d)"
python3 "$AQUI/boot/gerar_arte_boot.py" "$RAIZ" "$ARTE/grub" "$ARTE/plymouth"

PLY="$INC/usr/share/plymouth/themes/akkos"
mkdir -p "$PLY"
cp "$AQUI/boot/plymouth/akkos.plymouth" "$AQUI/boot/plymouth/akkos.script" "$PLY/"
cp "$ARTE"/plymouth/*.png "$PLY/"

GRUB=config/bootloaders/grub-pc
rm -rf "$GRUB"
mkdir -p "$GRUB/live-theme"
cp "$AQUI/boot/grub/grub.cfg" "$AQUI/boot/grub/config.cfg" "$AQUI/boot/grub/theme.cfg" "$GRUB/"
cp "$AQUI/boot/grub/live-theme/theme.txt" "$GRUB/live-theme/"
cp "$ARTE/grub/splash.png" "$GRUB/splash.png"
# a etapa binary_bootloader_splash do live-build usa config/bootloaders/splash.png
# (se não existir, renderiza o splash.svg padrão do Debian por cima do nosso)
cp "$ARTE/grub/splash.png" config/bootloaders/splash.png
cp "$ARTE"/grub/select_*.png "$GRUB/live-theme/"
DEJAVU=/usr/share/fonts/truetype/dejavu
grub-mkfont -s 16 -o "$GRUB/live-theme/akkos-regular-16.pf2" "$DEJAVU/DejaVuSans.ttf"
grub-mkfont -s 20 -o "$GRUB/live-theme/akkos-regular-20.pf2" "$DEJAVU/DejaVuSans.ttf"
grub-mkfont -s 20 -o "$GRUB/live-theme/akkos-bold-20.pf2" "$DEJAVU/DejaVuSans-Bold.ttf"
# os arquivos que o live-build ainda espera encontrar (submenus de instalador/memtest
# não são usados, mas o script de cópia os referencia)
for f in install_start_gui.cfg install_start_text.cfg install_gui.cfg install_text.cfg memtest.cfg; do
    [ -f "/usr/share/live/build/bootloaders/grub-pc/$f" ] && cp "/usr/share/live/build/bootloaders/grub-pc/$f" "$GRUB/"
done
rm -rf "$ARTE"
find "$GRUB" -type f | sort

# ------------------------------------------------------------------ 6
passo "6/7 lb build (demora: baixa ~2 GB de pacotes e comprime o sistema)"
lb build 2>&1 | tee "$SAIDA/build.log"
[ "${PIPESTATUS[0]}" = 0 ] || erro "lb build falhou (veja $SAIDA/build.log)"

# ------------------------------------------------------------------ 7
passo "7/7 ISO final"
ISO_LB="$(ls -1 "$TRAB"/*.iso 2>/dev/null | head -1)"
[ -n "$ISO_LB" ] || erro "o live-build não gerou a ISO"
ISO="$SAIDA/akkos-debian-$VERSAO-amd64.iso"
mv "$ISO_LB" "$ISO"
(cd "$SAIDA" && sha256sum "$(basename "$ISO")" > "$(basename "$ISO").sha256")
cp "$TRAB"/*.packages "$SAIDA/akkos-debian-$VERSAO-pacotes.txt" 2>/dev/null || true
ls -la "$SAIDA"
echo
echo "ISO pronta: $ISO ($(du -h "$ISO" | cut -f1))"
echo "Testar no QEMU (UEFI):"
echo "  qemu-system-x86_64 -enable-kvm -m 4096 -smp 2 -machine q35 \\"
echo "    -bios /usr/share/ovmf/OVMF.fd -cdrom $ISO"
