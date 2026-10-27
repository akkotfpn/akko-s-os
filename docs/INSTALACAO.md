# Instalar o Akko's OS Desktop

> Estado: fase D1, **aguardando validação**. Use em máquina de teste ou VM.

## Qual ISO baixar

| Sua placa de vídeo | ISO |
|---|---|
| AMD, Intel, ou VM sem GPU dedicada | `akkos-AAAA.MM.DD.iso` |
| NVIDIA | `akkos-nvidia-AAAA.MM.DD.iso` |

As ISOs ficam nos artefatos da execução mais recente do workflow
**"Desktop - ISO e teste de instalação"** na aba *Actions* do repositório
(ficam disponíveis por 14 dias). Confira o `.sha256` antes de usar.

## Em um PC

1. Grave a ISO num pendrive (Fedora Media Writer, Ventoy ou `dd`).
2. Boot em modo **UEFI**.
3. O instalador abre em português. Escolha o disco, confirme as partições e
   crie sua conta. **Nada é apagado sem a sua confirmação.**
4. Ao terminar, reinicie e remova o pendrive. O sistema inicia no modo gaming;
   o desktop KDE fica no menu de energia do Steam ("Mudar para a área de trabalho").

## Em VM no Proxmox

- **Sistema:** BIOS **OVMF (UEFI)**, máquina q35, com disco EFI.
- **Disco:** pelo menos 64 GB (VirtIO SCSI ou VirtIO Block).
- **Memória:** 8 GB ou mais. **CPU:** tipo `host`, 4 núcleos ou mais.
- **Vídeo:** sem GPU em passthrough, o modo gaming fica limitado (sem
  aceleração 3D real). Para jogar numa VM, passe a GPU física (PCI
  passthrough) e use a ISO correspondente à placa.

## Secure Boot com NVIDIA

Os módulos NVIDIA vêm assinados pela chave do Universal Blue. Com Secure Boot
ligado, a chave precisa ser registrada (MOK) no primeiro boot. O procedimento
exato para a nossa ISO ainda **não foi validado**; até lá, desligue o Secure
Boot ou siga a documentação do Bazzite sobre registro da chave.

## Depois de instalar

```sh
akkos info       # edição, imagem em uso, CPU, memória, GPU
akkos gpu        # placas de vídeo, driver em uso e Vulkan
akkos update     # baixa a versão nova (vale no próximo boot)
akkos rollback   # volta para a versão anterior (no próximo boot)
```

## Atualizações chegando? (para o mantenedor)

O sistema instalado baixa atualizações de `ghcr.io/akkotfpn/akkos` sem login,
então o pacote no GitHub precisa ser **público**:
github.com → seu perfil → *Packages* → `akkos` → *Package settings* →
*Change visibility* → **Public**. Repita para `akkos-nvidia`. O CI avisa se
algum estiver privado.
