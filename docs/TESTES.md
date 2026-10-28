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

### 2026-10-28 — Fase D1: imagem, ISO e instalação — **Validado (em VM)**

- Execução: GitHub Actions, run `40605694166` (commit `265b592`), imagem
  `ghcr.io/akkotfpn/akkos` versão `2026.10.27.8`
  (digest `sha256:1364937514d9…`), base `bazzite-deck:stable` (Fedora 44).
- Imagens: `akkos` e `akkos-nvidia` construídas, verificadas
  (`scripts/build-image.sh`) e publicadas; acessíveis sem login.
- ISOs (`bootc-image-builder`, anaconda-iso): `akkos` 7,96 GB,
  `akkos-nvidia` 8,54 GB. Artefatos da execução (14 dias).
- Teste de instalação (`tests/desktop/qemu_install_test.py`): QEMU + KVM,
  q35, OVMF, 4 CPUs, 8 GB, disco virtio de 80 GB descartável, VGA std, sem GPU.

| Etapa / verificação | Resultado | Evidência |
|---|---|---|
| Instalação automática | OK | 7,6 min, VM desligou sozinha |
| Boot do disco instalado | OK | 1,5 min até o login no serial |
| Nome no login | OK | `/etc/issue` mostra Akko's OS |
| `os-release` | OK | `NAME="Akko's OS"`, `PRETTY_NAME="Akko's OS Desktop 2026.10.27.8"`, `VARIANT="Desktop (AMD/Intel)"` |
| Ferramenta `akkos` | OK | `akkos version` |
| Imagem de atualização | OK | `rpm-ostree status`: `ostree-unverified-registry:ghcr.io/akkotfpn/akkos:latest` |
| Idioma e teclado | OK | `LANG=pt_BR.UTF-8`, console `br-abnt2`, X11 `br` |
| Hostname | OK | `akkos` |
| Papel de parede | OK | pacote `AkkoOS` instalado |
| Sessão gráfica | OK | `graphical.target`, SDDM ativo, greeter no tty1 |
| GPU / Vulkan | OK | `bochs-drm` (VGA virtual), Vulkan 1.4 via `llvmpipe` (CPU) |
| Firewall | OK | `firewalld` ativo |
| Flatpak | OK | remoto `flathub` |

Problemas encontrados e corrigidos durante a validação (histórico no git):
geração da ISO (sistema de arquivos raiz; AppArmor no Ubuntu 26.04 → runner
24.04), alvo de boot em modo texto no teste, idioma `C.UTF-8`, hostname
`bazzite`, leitura das saídas no próprio teste.

**Limitações conhecidas desta validação**
- Tela de login: o SDDM procura o tema `01-breeze-fedora`, que não existe na
  base, e usa o tema embutido; nosso fundo não aparece nela (fase D2).
- `user@958.service` (gerenciador de usuário do SDDM) falha na VM; sem
  impacto observado no login, a investigar.
- Os prints da tela estão no artefato `teste-instalacao`; não foram
  conferidos visualmente por mim (o download é bloqueado no meu ambiente).
- Testado só em VM, sem GPU real, e só a variante AMD/Intel foi instalada;
  a ISO NVIDIA foi gerada mas não instalada.
- O modo gaming (Gamescope) não foi exercitado: sem GPU real na VM.

### Pendentes de validação física

GPU AMD, GPU NVIDIA, Vulkan em hardware, HDR, controles USB/Bluetooth,
modo gaming com GPU real, Secure Boot com NVIDIA.
