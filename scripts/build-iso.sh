#!/usr/bin/env bash
# build-iso.sh — gera a ISO de instalação a partir de uma imagem publicada.
#
#   sudo scripts/build-iso.sh ghcr.io/akkotfpn/akkos:latest editions/desktop/disk_config/iso.toml saida/
#
# Usa o bootc-image-builder em container (como a action oficial fazia), com
# Podman como root. @IMAGE_REF@ no arquivo de configuração é trocado pela
# imagem informada (sem a tag :latest no bootc switch fica igual à imagem).

set -euo pipefail

image="${1:?imagem}"
config="${2:?config .toml}"
out="${3:?pasta de saída}"
bib="${BIB_IMAGE:-quay.io/centos-bootc/bootc-image-builder:latest}"
rootfs="${ROOTFS:-btrfs}"   # a base (Bazzite/Fedora Atomic) usa Btrfs na raiz

[ "$(id -u)" = 0 ] || { echo "rode como root (sudo)" >&2; exit 1; }

mkdir -p "$out"
cfg="$(mktemp --suffix=.toml)"
sed "s|@IMAGE_REF@|$image|g" "$config" > "$cfg"
echo "==> Configuração usada:"; cat "$cfg"

echo "==> Baixando $image"
podman pull -q "$image"

# Em sistemas com AppArmor (Ubuntu), o osbuild precisa montar dentro do container.
extra=()
[ -d /sys/kernel/security/apparmor ] && extra+=(--security-opt apparmor=unconfined)

echo "==> Gerando a ISO com $bib"
podman run --rm --privileged \
    --security-opt label=type:unconfined_t \
    "${extra[@]}" \
    --volume /var/lib/containers/storage:/var/lib/containers/storage \
    --volume "$(realpath "$out")":/output \
    --volume "$cfg":/config.toml:ro \
    "$bib" \
    build --output /output --use-librepo=True --type anaconda-iso --rootfs "$rootfs" \
    ${CHOWN:+--chown "$CHOWN"} \
    "$image"

rm -f "$cfg"
find "$out" -name '*.iso' -exec ls -la {} \;
