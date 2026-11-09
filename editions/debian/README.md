# Akko's OS — edição Debian

Sistema desktop leve com identidade própria sobre **Debian 13 (trixie)**:
sessão gráfica, explorador, applet de rede, identidade sonora e compatibilidade
com programas Windows feitos para o Akko's OS. A base Debian garante drivers,
internet moderna (TLS), Wine e pacotes.

> Estado: veja [docs/TESTES.md](../../docs/TESTES.md). Nada aqui é dado como
> funcionando sem o teste automatizado do CI (`.github/workflows/debian-iso.yml`).

## Por que Debian (e não o kernel feito do zero)

O sistema feito à mão (edição Server) não tem como rodar Wine, drivers de
Wi-Fi/GPU nem uma pilha TCP/IP com TLS moderna sem reconstruir uma
distribuição inteira. O Debian estável entrega isso com atualizações de
segurança; tudo o que o usuário vê e usa no dia a dia é do Akko's OS.

## Árvore

```
editions/debian/
├── build_os.sh                 construtor da ISO (live-build)
├── pacotes.list.chroot         pacotes do sistema
├── hooks/
│   ├── 0100-akkos-wine32.hook.chroot   multiarch i386 (Wine 32 bits, DXVK 32)
│   └── 0500-akkos-sistema.hook.chroot  identidade, serviços, Plymouth, Flathub, segurança
├── audio/gerar_sons.py         sintetizador da identidade sonora (numpy)
├── boot/
│   ├── gerar_arte_boot.py      imagens do GRUB e do Plymouth a partir da marca
│   ├── grub/                   menu e tema do GRUB (BIOS e UEFI)
│   └── plymouth/               tela animada de inicialização (plugin script)
├── compat/win-launcher.sh      lançador de programas Windows
├── security/security_hardening.sh  firewall, sysctl, AppArmor, firejail
└── overlay/                    arquivos copiados para o sistema (caminhos reais)
    ├── usr/lib/akkos/
    │   ├── akko-painel         barra de tarefas (menu, janelas, rede, volume, relógio, energia)
    │   ├── akko-arquivos       explorador de arquivos
    │   ├── akko-rede           conexões Wi-Fi/cabo (libnm)
    │   ├── akko-soundd         serviço de sons do sistema
    │   ├── akko-win-splash     tela de carregamento de programas Windows
    │   ├── akkos-autostart     o que sobe com a sessão
    │   ├── gerar-openbox-rc.py configuração do Openbox (atalhos, tema)
    │   ├── python/akkos_comum.py  paleta, CSS e sons compartilhados
    │   └── ci/                 verificação automatizada (só com akkos.teste=1)
    ├── usr/bin/                akkos-session, akko-sound, akko-captura, akko-navegador…
    ├── etc/                    LightDM, PipeWire, WirePlumber, dunst, GTK, Chromium
    └── usr/share/              sessão X, temas, atalhos (.desktop), página inicial
```

## Módulos

### A. Build e boot
- `build_os.sh` gera um sistema Debian com `lb config`/`lb build` (live-build)
  e produz uma **ISO híbrida**: boota de DVD ou pendrive, em **BIOS** (grub-pc)
  e **UEFI** (grub-efi com **shim assinado**, compatível com Secure Boot).
- Menu do GRUB próprio (pt-BR, tema com a marca, fontes DejaVu) e tela
  **Plymouth** animada (logo + pontos em onda; também pede senha de disco).
- systemd → LightDM → login automático no sistema live → sessão `akkos`.
  Usuário do sistema live: `akko`; senha: `live` (padrão do live-config).

### B. Ambiente gráfico (X11)
- **Openbox** como gerenciador de janelas, com tema `AkkoOS` (paleta da
  marca) e o `rc.xml` gerado a partir do padrão do Openbox (mantém todo o
  comportamento de mouse) mais os atalhos:

| Atalho | Ação |
|---|---|
| Super (tocar) / Alt+F1 | menu de aplicativos |
| Super+E | Arquivos |
| Super+B | Navegador |
| Super+Enter, Ctrl+Alt+T | Terminal |
| Super+N | Rede |
| Super+L | Bloquear |
| Super+D | Mostrar área de trabalho |
| Super+↑ / Super+↓ | Maximizar / minimizar |
| Super+← / Super+→ | Janela na metade esquerda/direita |
| Print / Shift+Print | Captura da tela / da janela (~/Imagens/Capturas) |
| Ctrl+Shift+Esc | Processos (htop) |
| Teclas de volume | Volume (PipeWire) |

- **akko-painel**: menu com busca e categorias (inclui a categoria "Windows"
  com os atalhos que os instaladores criam), lista de janelas, rede, volume,
  relógio/calendário, energia; monta pendrives sozinho.
- **akko-arquivos**: grade/lista, endereço, voltar/avançar/subir, filtro,
  copiar/recortar/colar em segundo plano com progresso, lixeira e exclusão
  definitiva, renomear, nova pasta, pré-visualização (imagem, texto,
  detalhes), pendrives com montagem automática e ejeção (udisks2), e duplo
  clique que executa `.exe/.msi` (Wine), `.AppImage`, binários ELF, `.deb` e
  `.flatpakref` (sempre com confirmação para o que pode alterar o sistema).

### C. Áudio
- **PipeWire + WirePlumber** com quantum de 256 amostras a 48 kHz (~5 ms),
  mínimo de 64, e placa de som sem suspensão automática.
- `gerar_sons.py` sintetiza no build, sem nenhum arquivo externo:
  `boot_chime`, `shutdown`, `notify`, `error`, `click`, `window_open`
  (WAV 48 kHz/24 bits, síntese aditiva e FM, reverb de Schroeder).
- **akko-soundd** (sessão): toca por socket (`akko-sound EVENTO`), em
  janelas novas, pendrive conectado/removido e no início da sessão; o
  **dunst** toca `notify`/`error` em notificações; o desligamento pelo
  painel toca `shutdown` inteiro antes de desligar.
  Preferências: `~/.config/akkos/sons.conf`.

### D. Rede
- **NetworkManager** + `wpa_supplicant`, firmwares de Wi-Fi Intel, Realtek,
  Atheros e Broadcom, verificação de conectividade do Debian.
- **akko-rede**: estado real (IP, gateway, DNS, MAC, sinal, internet sim/não),
  busca de redes, conexão com senha (WPA/WPA2/WPA3), esquecer rede, cabos;
  configurações avançadas (IP manual, VPN, proxy) pelo `nm-connection-editor`.
- **Navegador**: Chromium com políticas do Akko's OS (página inicial
  própria, busca DuckDuckGo, sem telemetria), sempre em sandbox.

### E. Compatibilidade
- `.deb` (apt), **Flatpak** (Flathub configurado), **AppImage** (libfuse2).
- **Wine 10 + DXVK 2.6** do Debian (64 e 32 bits). `win-launcher`:
  ambientes separados por programa, criação com fontes métricas
  compatíveis (Liberation) mesmo offline e as originais da Microsoft se
  houver internet, DXVK ativado, janela de carregamento, logs e explicação
  de falhas comuns. Registrado no **binfmt_misc**: `./programa.exe` no
  terminal também abre pelo lançador.
- Comandos: `win-launcher prefixos | criar NOME | configurar NOME |
  remover NOME | associar ARQUIVO NOME`.

### F. Segurança
`security_hardening.sh` (roda no build; pode ser repetido no sistema):
- **nftables**: entrada e encaminhamento bloqueados; só respostas a
  conexões feitas pelo próprio computador, ICMP essencial e DHCP; bloqueios
  registrados (`journalctl -k | grep akkos-fw`). Regras extras em
  `/etc/nftables.d/*.nft`.
- **sysctl** (`/etc/sysctl.d/99-custom-os-security.conf`): anti-spoofing,
  sem redirecionamentos, ASLR máximo (`randomize_va_space=2`, mmap_rnd_bits),
  `dmesg_restrict`, `kptr_restrict=2`, ptrace restrito, BPF sem privilégio
  desligado, proteções de links.
- **AppArmor** ativo com os perfis extras do Debian (validados no build).
- **Firejail + AppArmor** para o navegador e para os programas Windows
  (pasta pessoal reduzida ao necessário, sem root, seccomp).
- Core dumps desligados, protocolos de rede raros bloqueados, root sem login.

**Limites honestos:** o firewall e as sandboxes reduzem riscos, mas não
substituem cuidado. O Wine **não é** isolamento completo contra malware.
Programas Windows com driver de kernel ou anti-cheat não funcionam.

## Compilar

Em um Debian 13 (ou qualquer Linux com Docker):

```sh
git clone https://github.com/akkotfpn/akko-s-os && cd akko-s-os

# opção 1: direto num Debian 13
sudo editions/debian/build_os.sh

# opção 2: em qualquer Linux, dentro de um container Debian 13
docker run --rm --privileged -v "$PWD:/repo" debian:trixie bash -c '
  sed -i "s/Components: main/Components: main contrib non-free non-free-firmware/" /etc/apt/sources.list.d/debian.sources
  /repo/editions/debian/build_os.sh'
```

A ISO sai em `editions/debian/saida/akkos-debian-<versão>-amd64.iso`
(precisa de ~20 GB livres e internet; leva de 30 a 60 minutos).

## Testar

**QEMU (UEFI):**
```sh
sudo apt install qemu-system-x86 ovmf
qemu-system-x86_64 -enable-kvm -m 4096 -smp 2 -machine q35 \
  -bios /usr/share/ovmf/OVMF.fd -vga std \
  -audiodev pa,id=a0 -device ich9-intel-hda -device hda-output,audiodev=a0 \
  -cdrom editions/debian/saida/akkos-debian-*.iso
```
(Para BIOS, tire o `-bios …`.)

**VirtualBox:** nova VM "Linux / Debian (64-bit)", 4 GB de RAM, controladora
gráfica VMSVGA, *Habilitar EFI* (opcional), e a ISO no drive óptico.

**Proxmox:** VM com a ISO, BIOS OVMF ou SeaBIOS, 4 GB, placa de rede VirtIO.

**Teste automatizado** (o mesmo do CI, precisa de KVM):
```sh
sudo apt install qemu-system-x86 ovmf xorriso python3-pil
python3 tests/debian/teste_iso.py editions/debian/saida/akkos-debian-*.iso /tmp/evidencias
```
