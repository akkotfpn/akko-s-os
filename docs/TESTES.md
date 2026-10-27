# Registro de testes

Só entra aqui o que foi executado de verdade, com data, ambiente e resultado.

## Edição Server

### 2026-10-27 — Marco 1: boot UEFI e shell — **Validado**

- Ambiente: QEMU 11.1.2 (TCG, sem KVM), máquina q35, OVMF (edk2 do QEMU),
  512 MB, 2 CPUs, VGA std, virtio-net.
- Artefatos: `akkos.iso` (8,0 MB) e `akkos.img` (GPT, 128 MB), kernel 6.18.59-akkos.
- Procedimento: `scripts/test-qemu.py` boota, espera o prompt no serial, roda
  `akko`, `uname -a`, `ls /sys/class/net`, `cat /etc/os-release`, tira print,
  manda `poweroff`.
- Resultado: shell em ~1,5 s de boot; `eth0` (virtio) detectada; QEMU saiu
  sozinho com `poweroff` (código 0). Mesmo resultado com a imagem de disco.

### Marcos 2–6 — **Em desenvolvimento (pausado)**

Código compila (`akko-init` v2, `akko-part`, `akko-auth`, `akko-user`,
`akko-fw`), mas nada foi integrado nem testado. Único teste: `akko-part`
criou e aumentou uma GPT num arquivo de 2→3 GB (sem verificação externa).

## Edição Desktop

### Fase D1 — **Aguardando a primeira execução do CI**

O teste automatizado (`tests/desktop/qemu_install_test.py`, workflow
`desktop-iso.yml`) vai registrar aqui: tempo de instalação, boot do disco,
verificações pelo serial e prints.

### Pendentes de validação física

GPU AMD, GPU NVIDIA, Vulkan em hardware, HDR, controles USB/Bluetooth,
modo gaming com GPU real, Secure Boot com NVIDIA.
