#!/usr/bin/env bash
# akkos-vm.sh — cria no Proxmox VE uma VM do Akko's OS (edição Debian) pronta
# para usar: baixa a ISO mais recente aprovada no CI, confere o SHA-256 e
# cria a VM já configurada (UEFI, q35, VirtIO, disco para instalar).
#
# No shell do Proxmox (como root):
#   bash <(curl -fsSL https://raw.githubusercontent.com/akkotfpn/akko-s-os/edicao-debian/scripts/proxmox/akkos-vm.sh)
#
# Opções (todas opcionais):
#   --id N             número da VM (padrão: o próximo livre)
#   --nome NOME        nome da VM (padrão: akkos)
#   --memoria MB       RAM em MB (padrão: 4096; recomendado 4096 ou mais)
#   --cpus N           núcleos (padrão: 2)
#   --disco GB         disco para instalar o sistema (padrão: 32)
#   --persistencia GB  cria um 2º disco para "Guardar alterações" sem instalar
#   --storage NOME     onde ficam os discos (padrão: local-lvm, ou o 1º que aceite discos)
#   --iso-storage NOME onde fica a ISO (padrão: local)
#   --ponte NOME       placa de rede (padrão: vmbr0)
#   --bios seabios     usa BIOS clássica em vez de UEFI
#   --nao-iniciar      só cria, não liga a VM
#   --so-baixar        só baixa a ISO (não cria VM)
#   --versao TAG       outra Release (padrão: debian-ultima)
set -euo pipefail

REPO="akkotfpn/akko-s-os"
TAG="debian-ultima"
ISO_NOME="akkos-debian-amd64.iso"
ID="" NOME="akkos" MEM=4096 CPUS=2 DISCO=32 PERSIST="" STOR="" ISOSTOR="local" PONTE="vmbr0"
BIOS="ovmf" INICIAR=1 SO_BAIXAR=0

cor() { printf '\033[%sm%s\033[0m\n' "$1" "$2"; }
info() { cor "1;31" "==> $*"; }
erro() { cor "1;91" "ERRO: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --id) ID=$2; shift 2 ;;
        --nome) NOME=$2; shift 2 ;;
        --memoria) MEM=$2; shift 2 ;;
        --cpus) CPUS=$2; shift 2 ;;
        --disco) DISCO=$2; shift 2 ;;
        --persistencia) PERSIST=$2; shift 2 ;;
        --storage) STOR=$2; shift 2 ;;
        --iso-storage) ISOSTOR=$2; shift 2 ;;
        --ponte) PONTE=$2; shift 2 ;;
        --bios) BIOS=$2; shift 2 ;;
        --nao-iniciar) INICIAR=0; shift ;;
        --so-baixar) SO_BAIXAR=1; shift ;;
        --versao) TAG=$2; shift 2 ;;
        -h|--help) sed -n '2,25p' "$0" 2>/dev/null || true; exit 0 ;;
        *) erro "opção desconhecida: $1 (use --help)" ;;
    esac
done

[ "$(id -u)" = 0 ] || erro "rode como root no shell do Proxmox"
command -v qm >/dev/null && command -v pvesm >/dev/null || erro "isto não parece um Proxmox VE (qm/pvesm não encontrados)"
command -v curl >/dev/null || erro "curl não encontrado (apt install curl)"
case "$BIOS" in ovmf|seabios) ;; *) erro "--bios deve ser ovmf ou seabios" ;; esac

# ------------------------------------------------------------------ onde salvar a ISO
pvesm status --storage "$ISOSTOR" >/dev/null 2>&1 || erro "storage de ISO '$ISOSTOR' não existe (veja: pvesm status)"
ISO_VOL="$ISOSTOR:iso/$ISO_NOME"
ISO_ARQ=$(pvesm path "$ISO_VOL" 2>/dev/null) || erro "o storage '$ISOSTOR' não aceita ISOs (habilite o conteúdo 'ISO image')"
mkdir -p "$(dirname "$ISO_ARQ")"

# ------------------------------------------------------------------ download
BASE="https://github.com/$REPO/releases/download/$TAG"
TMP="$ISO_ARQ.baixando"
info "Conferindo a versão publicada ($TAG)"
SHA_ESPERADO=$(curl -fsSL "$BASE/$ISO_NOME.sha256" | awk '{print $1}') || \
    erro "não achei a Release '$TAG' em github.com/$REPO (o CI já publicou?)"
VERSAO=$(curl -fsSL "$BASE/VERSAO" 2>/dev/null || echo "?")
[ ${#SHA_ESPERADO} = 64 ] || erro "SHA-256 inválido na Release"

if [ -f "$ISO_ARQ" ] && [ "$(sha256sum "$ISO_ARQ" | awk '{print $1}')" = "$SHA_ESPERADO" ]; then
    info "ISO já baixada e conferida: $ISO_ARQ (versão $VERSAO)"
else
    info "Baixando o Akko's OS $VERSAO (~2,4 GB, em partes; pode retomar se cair)"
    : > "$TMP.lista"
    for n in 0 1 2 3 4 5 6 7 8 9; do
        parte="$ISO_NOME.part$n"
        # o servidor de downloads do GitHub recusa HEAD (401): testa com 1 byte
        codigo=$(curl -sL -r 0-0 -o /dev/null -w '%{http_code}' "$BASE/$parte")
        case "$codigo" in 200|206) ;; *) break ;; esac
        echo "  parte $n"
        curl -fL --retry 5 --retry-delay 3 -C - --progress-bar -o "$TMP.$n" "$BASE/$parte"
        echo "$TMP.$n" >> "$TMP.lista"
    done
    [ -s "$TMP.lista" ] || erro "nenhuma parte da ISO encontrada na Release"
    info "Juntando as partes e conferindo o SHA-256"
    xargs cat < "$TMP.lista" > "$TMP"
    SHA=$(sha256sum "$TMP" | awk '{print $1}')
    if [ "$SHA" != "$SHA_ESPERADO" ]; then
        rm -f "$TMP"
        erro "SHA-256 não confere (esperado $SHA_ESPERADO, veio $SHA). Rode de novo para baixar outra vez."
    fi
    mv "$TMP" "$ISO_ARQ"
    xargs rm -f < "$TMP.lista"
    rm -f "$TMP.lista"
    info "ISO pronta: $ISO_ARQ"
fi
[ "$SO_BAIXAR" = 1 ] && exit 0

# ------------------------------------------------------------------ VM
[ -n "$ID" ] || ID=$(pvesh get /cluster/nextid)
qm status "$ID" >/dev/null 2>&1 && erro "já existe uma VM $ID (use --id)"
if [ -z "$STOR" ]; then
    if pvesm status --storage local-lvm >/dev/null 2>&1; then
        STOR=local-lvm
    else
        STOR=$(pvesm status --content images 2>/dev/null | awk 'NR>1 && $3=="active" {print $1; exit}')
    fi
fi
[ -n "$STOR" ] || erro "nenhum storage para discos encontrado (use --storage)"
ip link show "$PONTE" >/dev/null 2>&1 || erro "ponte de rede '$PONTE' não existe (use --ponte)"

info "Criando a VM $ID ($NOME): ${MEM} MB, $CPUS núcleos, disco ${DISCO} GB em $STOR, $([ "$BIOS" = ovmf ] && echo UEFI || echo BIOS)"
ARGS=(--name "$NOME" --ostype l26 --machine q35 --bios "$BIOS"
      --memory "$MEM" --balloon 0 --cores "$CPUS" --cpu host
      --scsihw virtio-scsi-single --scsi0 "$STOR:$DISCO,discard=on,iothread=1,ssd=1"
      --ide2 "$ISO_VOL,media=cdrom" --boot "order=ide2;scsi0"
      --net0 "virtio,bridge=$PONTE" --vga std --tablet 1
      --serial0 socket --rng0 source=/dev/urandom
      --description "Akko's OS (edição Debian) $VERSAO — criado por akkos-vm.sh. Usuário do modo sem instalar: akko / senha: live")
[ "$BIOS" = ovmf ] && ARGS+=(--efidisk0 "$STOR:1,efitype=4m,pre-enrolled-keys=0")
[ -n "$PERSIST" ] && ARGS+=(--scsi1 "$STOR:$PERSIST,discard=on,iothread=1,ssd=1")
qm create "$ID" "${ARGS[@]}"
# som (aparece no console SPICE; no noVNC fica mudo)
qm set "$ID" --audio0 device=ich9-intel-hda,driver=spice >/dev/null 2>&1 || true

if [ "$INICIAR" = 1 ]; then
    info "Ligando a VM $ID"
    qm start "$ID"
fi

cat <<FIM

$(cor "1;31" "Pronto! VM $ID — $NOME")
  Abra o console no Proxmox: VM $ID → Console (noVNC ou SPICE para ter som).
  No menu de boot:
    • "Usar o Akko's OS sem instalar"             — experimenta na hora
    • "Instalar o Akko's OS no computador"        — instala no disco de ${DISCO} GB
$( [ -n "$PERSIST" ] && echo "    • \"Usar sem instalar, guardando as alterações\" — prepare antes o 2º disco
      com o app \"Guardar alterações\"" )
  Modo sem instalar: usuário akko, senha live.
  Depois de instalar: desligue, tire a ISO (Hardware → CD/DVD → Não usar mídia) e ligue.
FIM
