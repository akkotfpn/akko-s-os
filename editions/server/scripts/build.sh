#!/bin/sh
# build.sh — compila o Akko's OS inteiro a partir dos fontes.
#
# Estrutura:
#   config/   configuração do kernel e do BusyBox
#   init/     akko-init (nosso PID 1)
#   rootfs/   arquivos fixos do sistema (/etc, /usr/bin/akko...)
#   src/      fontes baixados (linux, musl, busybox)
#   tools/    ferramentas de build compiladas (musl, flex, libelf)
#   build/    intermediários
#   out/      imagens finais (akkos.iso, akkos.img, bzImage)
#
# Uso: scripts/build.sh [all|kernel|userland|image]

set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC=$ROOT/src
TOOLS=$ROOT/tools
BUILD=$ROOT/build
OUT=$ROOT/out
STAGE=$BUILD/rootfs
JOBS=$(nproc)

export PATH="$TOOLS/host/bin:$TOOLS/musl/bin:$PATH"
export PKG_CONFIG_PATH="$TOOLS/libelf/lib/pkgconfig"
MUSL_CC="musl-gcc"

log() { printf '\033[1;96m==>\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------- headers
kernel_headers() {
    [ -f "$TOOLS/musl/include/linux/version.h" ] && return
    log "Instalando headers do kernel no sysroot do musl"
    make -s -C "$SRC/linux" O="$BUILD/hdr" ARCH=x86_64 headers
    cp -r "$BUILD/hdr/usr/include/." "$TOOLS/musl/include/"
    find "$TOOLS/musl/include" -name '.*' -type f -delete
    # headers de asm/ que o x86 herda do asm-generic (wrappers de 1 linha)
    for h in "$TOOLS/musl/include/asm-generic/"*.h; do
        n=$(basename "$h")
        [ -e "$TOOLS/musl/include/asm/$n" ] || \
            echo "#include <asm-generic/$n>" > "$TOOLS/musl/include/asm/$n"
    done
}

# ---------------------------------------------------------------- busybox
busybox() {
    log "Compilando BusyBox (estático, musl)"
    mkdir -p "$BUILD/busybox"
    cd "$SRC/busybox"
    make -s O="$BUILD/busybox" defconfig >/dev/null
    cd "$BUILD/busybox"
    # ajustes: binário estático; desliga applets que não precisamos ou que
    # não compilam com musl/kernels novos
    sed -i \
        -e 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' \
        -e 's/^CONFIG_TC=y/# CONFIG_TC is not set/' \
        -e 's/^CONFIG_FEATURE_TC_INGRESS=y/# CONFIG_FEATURE_TC_INGRESS is not set/' \
        -e 's/^CONFIG_INIT=y/# CONFIG_INIT is not set/' \
        -e 's/^CONFIG_LINUXRC=y/# CONFIG_LINUXRC is not set/' \
        -e 's/^CONFIG_FEATURE_SH_STANDALONE=y/# CONFIG_FEATURE_SH_STANDALONE is not set/' \
        -e 's/^CONFIG_SELINUX=y/# CONFIG_SELINUX is not set/' \
        -e 's/^CONFIG_PAM=y/# CONFIG_PAM is not set/' \
        .config
    yes '' | make -s CC="$MUSL_CC" oldconfig >/dev/null
    make -s CC="$MUSL_CC" -j"$JOBS" busybox >/dev/null
    strip busybox
}

# ---------------------------------------------------------------- init
akko_init() {
    log "Compilando akko-init"
    mkdir -p "$BUILD/init"
    $MUSL_CC -static -Os -Wall -Wextra -Wno-unused-parameter \
        -o "$BUILD/init/akko-init" "$ROOT/init/akko-init.c"
    strip "$BUILD/init/akko-init"
}

# ---------------------------------------------------------------- rootfs
rootfs() {
    log "Montando o rootfs"
    rm -rf "$STAGE"
    mkdir -p "$STAGE"
    cd "$STAGE"
    mkdir -p bin sbin usr/bin usr/sbin usr/local/bin etc root \
             proc sys dev run tmp var/log var/tmp home mnt
    chmod 700 root
    chmod 1777 tmp var/tmp

    install -m 755 "$BUILD/busybox/busybox" bin/busybox
    # um link por comando do BusyBox
    for app in $("$BUILD/busybox/busybox" --list-full); do
        [ -e "$app" ] || ln -s /bin/busybox "$app"
    done
    install -m 755 "$BUILD/init/akko-init" sbin/akko-init
    ln -sf /sbin/akko-init init

    cp -a "$ROOT/rootfs/." "$STAGE/"
    chmod 755 usr/bin/akko
    echo akkos > etc/hostname

    # nós de dispositivo que precisam existir antes do devtmpfs montar
    cat > "$BUILD/devnodes.list" <<EOF
dir /dev 0755 0 0
nod /dev/console 0600 0 0 c 5 1
nod /dev/null 0666 0 0 c 1 3
EOF
}

# ---------------------------------------------------------------- kernel
kernel() {
    log "Configurando o kernel (tinyconfig + fragmento do Akko's OS)"
    K="$BUILD/linux"
    mkdir -p "$K"
    sed "s|@INITRAMFS_LIST@|$STAGE $BUILD/devnodes.list|" \
        "$ROOT/config/kernel.fragment" > "$BUILD/kernel.fragment"
    make -s -C "$SRC/linux" O="$K" ARCH=x86_64 tinyconfig >/dev/null
    "$SRC/linux/scripts/kconfig/merge_config.sh" -m -O "$K" \
        "$K/.config" "$BUILD/kernel.fragment" >/dev/null
    make -s -C "$SRC/linux" O="$K" ARCH=x86_64 olddefconfig >/dev/null

    # confere se tudo que pedimos ficou ligado
    missing=0
    grep '^CONFIG_.*=y' "$BUILD/kernel.fragment" | while read -r line; do
        grep -qx "$line" "$K/.config" || { echo "  aviso: não aplicado: $line"; }
    done

    log "Compilando o kernel ($JOBS núcleos)"
    make -s -C "$SRC/linux" O="$K" ARCH=x86_64 -j"$JOBS" \
        KBUILD_BUILD_USER=akko KBUILD_BUILD_HOST=akkos bzImage
    mkdir -p "$OUT"
    cp "$K/arch/x86/boot/bzImage" "$OUT/bzImage"
}

# ---------------------------------------------------------------- image
image() {
    log "Gerando imagens bootáveis"
    python3 "$ROOT/scripts/mkimage.py" "$OUT/bzImage" "$OUT"
}

case "${1:-all}" in
    all)      kernel_headers; busybox; akko_init; rootfs; kernel; image ;;
    userland) kernel_headers; busybox; akko_init; rootfs ;;
    kernel)   rootfs; kernel ;;
    image)    image ;;
    *)        echo "uso: $0 [all|userland|kernel|image]"; exit 1 ;;
esac
log "Pronto."
