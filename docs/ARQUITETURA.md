# Akko's OS — Arquitetura e roadmap

Documento vivo. Estados: **Planejado**, **Em desenvolvimento**,
**Implementado, aguardando validação**, **Validado** (só com teste registrado
em [TESTES.md](TESTES.md)).

## 1. Visão geral: duas edições, uma identidade

```
                         Akko's OS
        branding/ (logo, paleta, papéis de parede) — fonte única
              /                                     \
  Akko's OS Desktop                           Akko's OS Server
  editions/desktop/                           editions/server/
  imagem bootc derivada do Bazzite            kernel Linux + musl + BusyBox
  (Fedora Atomic 44)                          feito à mão, sem gerenciador
  modo Gaming (Steam + Gamescope)             de pacotes
  + desktop KDE Plasma (Wayland)              VM no Proxmox, apps estáticos
  PC com GPU AMD/Intel/NVIDIA,                ESTADO: pausada (Marco 1 validado)
  ou VM com GPU em passthrough
```

## 2. Base da edição Desktop

### Decisão: derivar do Bazzite (Fedora Atomic), variantes "deck"

| Variante Akko's OS | Imagem base | GPUs |
|---|---|---|
| `ghcr.io/akkotfpn/akkos` | `ghcr.io/ublue-os/bazzite-deck:stable` | AMD, Intel, VMs sem GPU dedicada |
| `ghcr.io/akkotfpn/akkos-nvidia` | `ghcr.io/ublue-os/bazzite-deck-nvidia:stable` | NVIDIA |

As variantes "deck" iniciam no modo gaming (Steam + Gamescope) e têm o
desktop KDE Plasma a um clique, que é o comportamento pedido na seção 5 da
especificação.

### Por que Bazzite, e não Fedora Kinoite puro ou Arch

A primeira versão deste documento recomendava Fedora Kinoite e montar o
gaming por conta própria. Ao verificar as fontes oficiais, mudei para o
Bazzite:

1. **É a base padrão do template oficial do Universal Blue** para imagens
   derivadas (`ublue-os/image-template`, `Containerfile`:
   `FROM ghcr.io/ublue-os/bazzite:stable`).
2. **Já integra o que a especificação pede de gaming**: Steam, Gamescope,
   modo gaming estilo SteamOS, HDR e imagens separadas para NVIDIA
   (matriz do `ublue-os/bazzite`, `.github/workflows/build.yml`, verificada
   em 2026-10-27: `bazzite-deck`, `bazzite-deck-nvidia`, sobre Fedora 44).
3. **A regra 18/§18 da especificação**: não desenvolver substitutos para
   ferramentas maduras sem vantagem demonstrável. Remontar Steam + Gamescope
   + HDR + NVIDIA seria exatamente isso.
4. **Atualização atômica e reversão nativas** (bootc), exigidas na §19.

Contra Arch: sem atomicidade nativa e sem precedente redistribuível de modo
gaming (a imagem do SteamOS não pode ser usada como base).

**Custos aceitos:** herdamos decisões do Bazzite (kernel, pacotes, ferramentas
`ujust`) e o `ID=bazzite` no `os-release` (mantido porque ferramentas da base
dependem dele). Tudo que o usuário vê é rebatizado como Akko's OS; o que
ainda mostra a marca da base está listado na §6.

## 3. Como a imagem é construída

```
branding/out/*            ┐
editions/desktop/          ├─► Containerfile (FROM bazzite-deck[-nvidia])
  build_files/build.sh     │     └─ build.sh: idioma pt-BR, os-release,
  system_files/            ┘        image-info, logo, papéis de parede,
                                     SDDM, ferramenta akkos
        │ GitHub Actions: desktop-image.yml (push / diário / manual)
        ▼
ghcr.io/akkotfpn/akkos[-nvidia]:latest  e  :AAAA.MM.DD.N
        │ desktop-iso.yml (após cada imagem publicada por push)
        ├─► ISO interativa (bootc-image-builder, anaconda-iso) → artefato
        └─► ISO de teste automática → instala em VM KVM → boota → verifica
```

Sistemas instalados seguem a imagem `:latest` do seu variante
(`bootc switch` no fim da instalação). Atualizar = baixar a imagem nova;
voltar = `bootc rollback`.

## 4. Tecnologias

| Área | Escolha |
|---|---|
| Imagem do sistema | bootc/OCI, Podman, `Containerfile` |
| Init e serviços | systemd (da base) |
| Desktop | KDE Plasma, Wayland (da base) |
| Gaming | Steam + Gamescope (da base, variante deck) |
| Gráficos | Mesa/RADV (AMD/Intel), driver NVIDIA da imagem `-nvidia` |
| Windows | Wine/Proton/DXVK/VKD3D-Proton via Steam; apps via Bottles (Flatpak) — fase D5 |
| Aplicativos | Flatpak (Flathub, já configurado na base) |
| Firewall | firewalld/nftables da base; interface própria na fase D9 |
| Ferramentas próprias | Bash (CLI `akkos`); Qt/QML para apps gráficos a partir da D2 |
| ISO | bootc-image-builder (`anaconda-iso`) |
| Testes | QEMU + OVMF + KVM no CI; hardware físico para GPU/HDR/controle |

## 5. Estrutura do repositório

```
branding/               identidade visual (palette.json + generate.py → out/)
editions/desktop/       Containerfile, build_files/, system_files/, disk_config/
editions/server/        edição mínima (pausada), igual ao que existia
scripts/                build-image.sh, build-iso.sh (CI e local)
tests/desktop/          teste de instalação em QEMU e ISO de teste
.github/workflows/      desktop-image.yml, desktop-iso.yml
docs/                   este documento, TESTES.md, INSTALACAO.md
```

## 6. O que ainda mostra a marca da base (inventário honesto)

Itens conhecidos que continuam como Bazzite/Steam até a fase D2:

- Tela de boot (Plymouth) e menu de boot: exigem regenerar o initramfs.
- Tela de login: tema embutido do SDDM (o tema configurado pela base não existe).
- Mensagens e comandos `ujust`, `bazzite-*` e o texto de boas-vindas do terminal.
- Interface do Steam no modo gaming (é do Steam; não deve ser rebatizada).
- `ID=bazzite` no `os-release` (intencional, compatibilidade).

## 7. Roadmap da edição Desktop

| Fase | Entrega | Critério de aceitação | Estado |
|---|---|---|---|
| D1 Base | Imagem derivada + identidade mínima + CI + ISO + teste de instalação | CI verde; teste instala, boota e confirma Akko's OS, pt-BR, imagem de atualização própria, sessão gráfica ativa | **Validado em VM** (2026-10-28, ver TESTES.md) |
| D2 Identidade | Plymouth, SDDM, tema KDE claro/escuro da paleta, ícones, boas-vindas | Prints no teste de instalação | Planejado |
| D3 Atualização | `akkos update/rollback` validados, canais estável/teste | Atualizar e reverter em VM no CI | Implementado (CLI), aguardando validação |
| D4 Aplicativos | Central (Discover/Bazaar da base) com nossa marca | Instalar e remover Flatpak pela interface | Planejado |
| D5 Windows | Fluxo `.exe`/`.msi` com Bottles | Programa Windows simples instalado e aberto; registro em TESTES.md | Planejado |
| D6 Gaming | Modo gaming, troca Gaming↔Desktop, controles | **Hardware físico** | Planejado |
| D7 Drivers | "Gráficos e drivers" (CLI `akkos gpu` já lista GPU/driver/Vulkan) | **AMD e NVIDIA físicas** | Em desenvolvimento |
| D8 HDR | HDR no desktop e no gaming onde suportado | **Monitor HDR físico** | Planejado |
| D9 Segurança | Interface do firewall, auditoria, assinatura das imagens (cosign) | Regras aplicadas e bloqueio verificado; assinatura verificada no `bootc` | Planejado |
| D10 Estabilização | Testes de instalação, atualização e recuperação | Roteiro completo no CI + hardware | Planejado |

## 8. Riscos

- **Validação física:** GPU, HDR, controles e desempenho só com o seu
  hardware. Nada disso será marcado como validado antes.
- **Pacote público no ghcr.io:** sistemas instalados baixam atualizações sem
  login; o pacote precisa estar público (o CI avisa se não estiver).
- **Assinatura:** as imagens ainda não são assinadas (cosign), e a instalação
  usa `ostree-unverified-registry`. Fica para a D9.
- **Secure Boot + NVIDIA:** os módulos vêm assinados pela chave do Universal
  Blue; a chave precisa ser registrada (MOK). Procedimento a validar.
- **GPUs NVIDIA anteriores à série 16/RTX:** a variante deck-nvidia pode não
  suportar; a confirmar.
- **Anti-cheat e DRM:** vários jogos online não rodam no Linux.
- **Dependência da base:** mudanças no Bazzite chegam no build diário; o teste
  de instalação no CI é a rede de proteção.

## 9. Ambiente de desenvolvimento

Sem instalar nada: o GitHub Actions constrói tudo. Para construir localmente
(Linux com Podman, ~60 GB livres):

```sh
git clone https://github.com/akkotfpn/akko-s-os && cd akko-s-os
scripts/build-image.sh akkos            # ou akkos-nvidia
sudo scripts/build-iso.sh localhost/akkos:latest editions/desktop/disk_config/iso.toml saida/
```

Regenerar a identidade visual: `python3 branding/generate.py branding/fonts/Inter.ttf`.

## 10. Critérios de aceitação do Desktop 0.1

1. CI constrói e publica `akkos` e `akkos-nvidia`.
2. ISO interativa gerada para as duas variantes.
3. Teste automático: instala em VM UEFI, boota o disco, e confirma
   `NAME="Akko's OS"`, idioma pt_BR, imagem de atualização
   `ghcr.io/akkotfpn/akkos`, sessão gráfica ativa, firewall ativo e Flathub.
4. Resultado registrado em `docs/TESTES.md`.
