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

## Edição Debian

Workflow `.github/workflows/debian-iso.yml`, execução **42648306836**
(09/11/2026): **aprovada, 70 de 70 verificações**, VM com **4 GB de RAM**.
Prints e logs no branch `evidencias-debian`.

| Área | Verificado no QEMU/KVM |
|---|---|
| Boot | GRUB próprio (usar sem instalar / guardando alterações / instalar) e área de trabalho em UEFI, UEFI com Secure Boot e BIOS; Plymouth `akkos` |
| Sistema | os-release "Akko's OS", pt-BR, sessão própria; área de trabalho com ícones (Este Computador, Lixeira, Instalar, atalhos) |
| Programas | Explorador estilo Windows (Este Computador, C:, Novo ▾), Rede, menu, Gerenciador de Tarefas (Desempenho), Chromium com página inicial em firejail |
| Instalador | Calamares com a marca do Akko's OS abre (a VM de teste não tem disco: instalação em si não testada) |
| Persistência | ferramenta "Guardar alterações" abre e lista discos |
| Áudio | PipeWire, sons do sistema, som gravado da VM |
| Rede | NetworkManager, HTTPS com certificado válido, DNS |
| Segurança | nftables (entrada bloqueada e registrada), sysctl, root travado, AppArmor com 134 perfis também no live; Wine confinado (`firejail-default (enforce)`) |
| Vídeo | Mesa 26.1 (64 e 32 bits), módulo NVIDIA 550 compilado + bibliotecas 32 bits, `akkos-gpu` ativo, zram |
| Windows | Wine 10, DXVK, ICU do Windows no ambiente; Bloco de Notas; **qBittorrent 5.3.0 baixado, instalado (NSIS silencioso) e aberto** na sandbox |
| Aplicativo/Jogo | janela de escolha; umu-launcher 1.4.4 instalado |

Teste rápido (job `apps`): painel, área de trabalho, Arquivos (criar pasta
com Ctrl+Shift+N, Este Computador), Gerenciador de Tarefas, Guardar
alterações, Rede, escolha e tela de carregamento num Debian 13 com Xvfb.

**Não verificado:** instalação em disco pelo Calamares (falta disco na VM
de teste), boot com persistência, jogo real pelo Proton e placas NVIDIA/AMD/
Intel reais (precisam de hardware), Wi-Fi físico.

**Limites conhecidos:** kernel 6.12 (o driver NVIDIA 550 não compila no 7.x
dos backports); RTX 50 e GTX 600/700 usam o nouveau; o Chromium roda no
firejail sem AppArmor (o perfil bloqueia `userns_create`).
