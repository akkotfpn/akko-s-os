#!/bin/sh
# security_hardening.sh — blindagem do Akko's OS.
#
# Roda DENTRO do chroot durante o build da ISO (chamado pelo hook
# 0500-akkos-sistema). Também pode ser rodado de novo num sistema instalado:
#   sudo /usr/lib/akkos/security_hardening.sh
# É idempotente: rodar duas vezes dá o mesmo resultado.
#
#  1. Firewall nftables: entrada e encaminhamento BLOQUEADOS por padrão,
#     só respostas a conexões que o próprio computador abriu entram;
#     bloqueios registrados no log (com limite de taxa)
#  2. Parâmetros do kernel (sysctl): anti-spoofing, ASLR máximo, dmesg e
#     ponteiros do kernel restritos, proteções de links e BPF
#  3. AppArmor ativo + perfis extras em modo de aplicação
#  4. Firejail: sandbox para Wine e navegador, com AppArmor
#  5. Core dumps desligados, módulos de rede raros bloqueados, root travado

set -eu

log() { echo "[akkos-hardening] $*"; }

# ---------------------------------------------------------------- 1. firewall
log "1/5 Firewall (nftables)"
cat > /etc/nftables.conf <<'EOF'
#!/usr/sbin/nft -f
# Akko's OS — firewall padrão.
# Entrada: só o que este computador pediu (conexões estabelecidas) + o mínimo
# para a rede funcionar (loopback, ICMP essencial, DHCP). Tudo o mais é
# descartado e registrado no log (journalctl -k | grep akkos-fw).
# Para liberar uma porta (ex.: SSH), adicione em /etc/nftables.d/*.nft:
#   add rule inet akkos entrada tcp dport 22 accept

flush ruleset

table inet akkos {
    chain entrada {
        type filter hook input priority filter; policy drop;

        iif "lo" accept
        ct state established,related accept
        ct state invalid drop

        # ICMP necessário (path MTU, ping de diagnóstico com limite)
        ip protocol icmp icmp type { destination-unreachable, time-exceeded, parameter-problem } accept
        ip protocol icmp icmp type echo-request limit rate 5/second accept
        ip6 nexthdr icmpv6 icmpv6 type { destination-unreachable, packet-too-big, time-exceeded,
            parameter-problem, nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert } accept
        ip6 nexthdr icmpv6 icmpv6 type echo-request limit rate 5/second accept

        # respostas de DHCP (IPv4 e IPv6)
        udp sport 67 udp dport 68 accept
        ip6 saddr fe80::/10 udp sport 547 udp dport 546 accept

        limit rate 10/minute burst 20 packets log prefix "akkos-fw-bloqueado: " level info
    }

    chain encaminhamento {
        type filter hook forward priority filter; policy drop;
    }

    chain saida {
        type filter hook output priority filter; policy accept;
    }
}

include "/etc/nftables.d/*.nft"
EOF
mkdir -p /etc/nftables.d
[ -f /etc/nftables.d/README ] || cat > /etc/nftables.d/README <<'EOF'
Regras extras do firewall do Akko's OS. Arquivos *.nft desta pasta são
carregados depois das regras padrão. Exemplo (liberar SSH):
  add rule inet akkos entrada tcp dport 22 accept
Depois: sudo systemctl restart nftables
EOF
# o include falha se não houver nenhum arquivo .nft: cria um vazio documentado
[ -f /etc/nftables.d/00-local.nft ] || echo "# regras locais (veja README)" > /etc/nftables.d/00-local.nft
chmod 0600 /etc/nftables.conf
nft -c -f /etc/nftables.conf && log "  regras válidas (nft -c)"
systemctl enable nftables.service

# ---------------------------------------------------------------- 2. sysctl
log "2/5 Parâmetros do kernel"
cat > /etc/sysctl.d/99-custom-os-security.conf <<'EOF'
# Akko's OS — proteção do kernel

## Rede: anti-spoofing e redirecionamentos
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rfc1337 = 1

## Memória: ASLR no máximo
kernel.randomize_va_space = 2
vm.mmap_rnd_bits = 32
vm.mmap_rnd_compat_bits = 16

## Informação do kernel: só para administradores
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.perf_event_paranoid = 3

## Processos e arquivos
kernel.yama.ptrace_scope = 1
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2
fs.suid_dumpable = 0
kernel.core_pattern = |/bin/false

## BPF e kexec
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2
kernel.kexec_load_disabled = 1
kernel.sysrq = 4
EOF
chmod 0644 /etc/sysctl.d/99-custom-os-security.conf

# ---------------------------------------------------------------- 3. AppArmor
log "3/5 AppArmor"
systemctl enable apparmor.service
# Só os perfis que o Debian instala em /etc/apparmor.d (pacotes, firejail).
# Os de /usr/share/apparmor/extra-profiles são experimentais: copiar todos
# fazia o carregamento falhar e o sistema subia com 0 perfis. Versões
# anteriores deste script copiavam; remove as cópias idênticas.
if [ -d /usr/share/apparmor/extra-profiles ]; then
    for p in /usr/share/apparmor/extra-profiles/usr.bin.*; do
        destino="/etc/apparmor.d/$(basename "$p")"
        [ -f "$destino" ] && cmp -s "$p" "$destino" && rm -f "$destino"
    done
fi
# Valida os perfis quando o kernel tem AppArmor (sistema instalado). No build
# (chroot sem /sys/kernel/security) a validação não é confiável: só avisa.
if [ -d /sys/kernel/security/apparmor ]; then
    for p in /etc/apparmor.d/usr.bin.* /etc/apparmor.d/firejail-default; do
        [ -f "$p" ] || continue
        apparmor_parser -Q -T "$p" >/dev/null 2>&1 || log "  AVISO: perfil com erro: $p"
    done
else
    log "  (sem AppArmor no kernel do build: perfis serão carregados no boot)"
fi

# ---------------------------------------------------------------- 4. Firejail
log "4/5 Firejail (sandbox do Wine e do navegador)"
cat > /etc/firejail/akkos-wine.profile <<'EOF'
# Akko's OS — sandbox para programas Windows (usada pelo win-launcher).
# Base: perfil wine do firejail + pasta pessoal restrita + AppArmor.
# O win-launcher acrescenta --whitelist com a pasta do programa e o ambiente.
include akkos-wine.local
include wine.profile

# pasta pessoal: só o necessário (o resto some dentro da sandbox)
mkdir ${HOME}/.local/share/akkos/wine
whitelist ${HOME}/.local/share/akkos/wine
mkdir ${HOME}/.cache/winetricks
whitelist ${HOME}/.cache/winetricks
mkdir ${HOME}/.local/share/applications
whitelist ${HOME}/.local/share/applications
mkdir ${HOME}/.config/menus
whitelist ${HOME}/.config/menus
mkdir ${HOME}/.local/share/desktop-directories
whitelist ${HOME}/.local/share/desktop-directories
mkdir ${HOME}/.local/share/icons
whitelist ${HOME}/.local/share/icons
whitelist ${DOWNLOADS}
whitelist ${DOCUMENTS}
include whitelist-common.inc

apparmor
EOF
echo "# ajustes locais da sandbox do Wine" > /etc/firejail/akkos-wine.local
cat > /etc/firejail/chromium.local <<'EOF'
# Akko's OS: o Chromium roda no firejail (seccomp, sem novos privilégios,
# pasta pessoal restrita) e na sandbox própria dele. O perfil AppArmor do
# firejail impede o Chromium de abrir no sistema live (testado no CI), então
# fica desligado só para o navegador; o Wine continua com AppArmor.
ignore apparmor
# a página inicial do Akko's OS (o perfil só libera algumas pastas de /usr/share)
whitelist /usr/share/akkos
EOF
# o navegador abre sempre pela sandbox: /usr/local/bin vem antes no PATH
ln -sf /usr/bin/firejail /usr/local/bin/chromium

# ---------------------------------------------------------------- 5. extras
log "5/5 Core dumps, módulos raros, contas"
mkdir -p /etc/security/limits.d /etc/systemd/coredump.conf.d /etc/modprobe.d
echo "* hard core 0" > /etc/security/limits.d/90-akkos-sem-coredump.conf
printf '[Coredump]\nStorage=none\nProcessSizeMax=0\n' > /etc/systemd/coredump.conf.d/akkos.conf
cat > /etc/modprobe.d/akkos-protocolos-raros.conf <<'EOF'
# protocolos de rede raramente usados, com histórico de falhas de segurança
install dccp /bin/false
install sctp /bin/false
install rds /bin/false
install tipc /bin/false
EOF
# root sem senha de login (administração por sudo)
passwd -l root >/dev/null 2>&1 || true
chmod 0700 /root
# arquivos de contas
chmod 0640 /etc/shadow /etc/gshadow 2>/dev/null || true

log "concluído"
