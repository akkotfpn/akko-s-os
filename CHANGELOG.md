# Registro de alterações

## 2026-10-28

### Desktop — fase D1 validada em VM
- Teste de instalação completo verde no CI (instala, boota, 10 verificações).
- Correções: ISO com raiz Btrfs; runner Ubuntu 24.04 para o
  bootc-image-builder (AppArmor no 26.04); padrões pt-BR/ABNT2 na imagem;
  hostname `akkos` no instalador; teste lendo saídas corretamente.

## 2026-10-27

### Desktop — fase D1 (aguardando validação no CI)
- Arquitetura definida: duas edições; Desktop derivada do Bazzite (Fedora
  Atomic 44, variantes deck e deck-nvidia). Justificativa em docs/ARQUITETURA.md.
- Identidade visual inicial: paleta central, logotipo (SVG + PNG), papéis de
  parede claro/escuro gerados por `branding/generate.py`.
- Imagem `editions/desktop/Containerfile`: idioma pt-BR, `os-release` e
  `image-info` do Akko's OS, logotipo, papel de parede padrão (KDE e SDDM),
  ferramenta `akkos` (info, gpu, status, update, rollback).
- ISO interativa em pt-BR (`bootc-image-builder`) que deixa o sistema
  seguindo `ghcr.io/akkotfpn/akkos[-nvidia]`.
- CI: build diário das duas variantes, ISO e teste de instalação de ponta a
  ponta em VM com KVM.

### Server
- Pausada. Código preservado em `editions/server/` (Marco 1 validado;
  Marcos 2–6 em desenvolvimento).
