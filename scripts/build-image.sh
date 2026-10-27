#!/usr/bin/env bash
# build-image.sh — constrói a imagem do Akko's OS Desktop com Podman.
#
#   scripts/build-image.sh akkos           AMD/Intel
#   scripts/build-image.sh akkos-nvidia    NVIDIA
#
# Variáveis opcionais: AKKOS_VERSION (padrão: data de hoje), IMAGE_VENDOR.
# Precisa: podman, ~40 GB livres, acesso a ghcr.io e aos repositórios Fedora.

set -euo pipefail
cd "$(dirname "$0")/.."

variant="${1:-akkos}"
case "$variant" in
    akkos)        base="ghcr.io/ublue-os/bazzite-deck:stable";        label="AMD/Intel" ;;
    akkos-nvidia) base="ghcr.io/ublue-os/bazzite-deck-nvidia:stable"; label="NVIDIA" ;;
    *) echo "variante desconhecida: $variant (use akkos ou akkos-nvidia)" >&2; exit 2 ;;
esac

version="${AKKOS_VERSION:-$(date -u +%Y.%m.%d)}"
vendor="${IMAGE_VENDOR:-akkotfpn}"

echo "==> Construindo $variant ($label) versão $version sobre $base"
podman build \
    --pull=newer \
    -f editions/desktop/Containerfile \
    --build-arg BASE_IMAGE="$base" \
    --build-arg IMAGE_NAME="$variant" \
    --build-arg IMAGE_VENDOR="$vendor" \
    --build-arg IMAGE_VARIANT="$label" \
    --build-arg AKKOS_VERSION="$version" \
    -t "localhost/$variant:latest" \
    -t "localhost/$variant:$version" \
    .

echo "==> Verificando a imagem"
podman run --rm "localhost/$variant:latest" bash -c '
    set -e
    . /usr/lib/os-release
    echo "PRETTY_NAME=$PRETTY_NAME"
    echo "VARIANT=$VARIANT"
    test "$NAME" = "Akko'"'"'s OS"
    test -x /usr/bin/akkos
    test -f /usr/share/wallpapers/AkkoOS/contents/images_dark/3840x2160.png
    test -f /usr/share/icons/hicolor/scalable/apps/akkos-logo.svg
    /usr/bin/akkos version
    echo "verificação OK"
'
