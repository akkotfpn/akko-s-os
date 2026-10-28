<p align="center"><img src="branding/out/akkos-logo-128.png" width="96" alt="Akko's OS"></p>

<h1 align="center">Akko's OS</h1>

<p align="center">Sistema operacional desktop e gaming, com identidade própria, sobre Linux.</p>

> **Estado:** em desenvolvimento. A fase D1 (base, identidade mínima, ISO e
> teste de instalação) foi **validada em máquina virtual** em 2026-10-28.
> Veja [docs/TESTES.md](docs/TESTES.md) para o que já foi validado.

## Edições

| Edição | Para quê | Base | Estado |
|---|---|---|---|
| **Desktop** | PC (AMD, Intel ou NVIDIA) ou VM com GPU: modo gaming + desktop KDE | Bazzite / Fedora Atomic | Fase D1 |
| **Server** | VM mínima no Proxmox para rodar aplicações | Kernel Linux + musl + BusyBox, feito à mão | Pausada |

## Imagens

| Variante | Imagem |
|---|---|
| AMD / Intel | `ghcr.io/akkotfpn/akkos:latest` |
| NVIDIA | `ghcr.io/akkotfpn/akkos-nvidia:latest` |

Já usa Bazzite ou outro Fedora Atomic? Dá pra trocar direto:

```sh
sudo bootc switch ghcr.io/akkotfpn/akkos:latest   # reinicie depois
```

## Documentação

- [Arquitetura e roadmap](docs/ARQUITETURA.md)
- [Instalação](docs/INSTALACAO.md)
- [Registro de testes](docs/TESTES.md)
- [Alterações](CHANGELOG.md)

## Créditos e licenças

O Akko's OS Desktop é derivado do [Bazzite](https://github.com/ublue-os/bazzite)
e das imagens do [Universal Blue](https://universal-blue.org), sobre o
[Fedora](https://fedoraproject.org). Os workflows partem do
`ublue-os/image-template` (Apache-2.0). Steam, Proton e drivers NVIDIA têm
licenças próprias e vêm pelos canais oficiais da base.

Código deste repositório: Apache-2.0 ([LICENSE](LICENSE)).
Fonte Inter: SIL Open Font License ([branding/fonts/Inter-OFL.txt](branding/fonts/Inter-OFL.txt)).
