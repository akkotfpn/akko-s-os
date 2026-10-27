# Akko's OS Server

> **Pausada em 2026-10-27.** Marco 1 validado (ver docs/TESTES.md). Os Marcos 2–6
> (disco, rede/SSH, serviços, endurecimento, interface gráfica) estão com código
> escrito e compilando, mas **não integrados nem testados**. O `kernel.fragment`
> já contém as opções desses marcos e também não foi compilado nem testado.

Sistema mínimo próprio em cima do kernel Linux. Sem distro por baixo: kernel
configurado do zero, libc musl, BusyBox e um init próprio (`akko-init`).

## Estado atual: Marco 1 ✅

- Boot UEFI direto (o kernel é o executável EFI, sem bootloader)
- Tudo roda da RAM (initramfs embutido no kernel)
- `akko-init` como PID 1: monta /proc /sys /dev, tela de boas-vindas, shells na
  tela (tty1) e na serial (ttyS0), recolhe processos órfãos, desliga limpo
  (`poweroff`, `reboot`, Ctrl+Alt+Del e botão Shutdown do Proxmox via ACPI)
- Drivers virtio (disco, SCSI, rede, console, balloon) já incluídos

## Estrutura

    config/kernel.fragment   o que ligamos no kernel (sobre o tinyconfig)
    init/akko-init.c         nosso PID 1
    rootfs/                  arquivos fixos do sistema (/etc, comando akko)
    scripts/build.sh         compila tudo: headers, BusyBox, init, kernel, imagens
    scripts/mkimage.py       gera ISO (El Torito UEFI) e disco GPT sem ferramentas externas
    scripts/test-qemu.py     boota no QEMU+OVMF e testa automaticamente

## Versões

- Linux 6.18.59 (LTS)
- musl 1.2.6
- BusyBox 1.36.1

## Próximos marcos

2. Disco e sistema de arquivos persistente
3. Rede (DHCP, SSH)
4. Serviços e execução das aplicações
5. Endurecimento (raiz somente leitura, firewall)
6. Interface gráfica
