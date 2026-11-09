#!/bin/bash
# Verificação automatizada do Akko's OS dentro da VM do CI.
# Cada resultado sai na serial como: AKKOS-CHECK|nome|ok/falhou|detalhe
# Pedidos de print: AKKOS-SHOT|nome  (o QEMU do lado de fora tira o print)
# Fim: AKKOS-TESTE-FIM

U=akko
check() {   # check NOME comando…  (sucesso = código 0)
    local nome=$1; shift
    local saida rc
    saida=$("$@" 2>&1); rc=$?
    saida=$(echo "$saida" | tr '\n|' '  ' | cut -c1-600)
    if [ $rc = 0 ]; then echo "AKKOS-CHECK|$nome|ok|$saida"; else echo "AKKOS-CHECK|$nome|falhou|rc=$rc $saida"; fi
}
shot() { echo "AKKOS-SHOT|$1"; sleep 4; }

echo "AKKOS-TESTE-INICIO"
for i in $(seq 1 300); do
    pgrep -u "$U" -f akko-painel >/dev/null && pgrep -u "$U" -x openbox >/dev/null && break
    sleep 1
done
UIDN=$(id -u "$U" 2>/dev/null || echo 1000)
asu() {
    runuser -u "$U" -- env DISPLAY=:0 XAUTHORITY="/home/$U/.Xauthority" XDG_RUNTIME_DIR="/run/user/$UIDN" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$UIDN/bus" HOME="/home/$U" LANG=pt_BR.UTF-8 "$@"
}
sleep 10   # deixa o som de início terminar e a área de trabalho assentar
shot 01-area-de-trabalho

# ---------------------------------------------------------- identidade e sessão
check os_release grep -E '^(NAME|PRETTY_NAME|ID)=' /etc/os-release
check os_release_nome grep -q "NAME=\"Akko's OS\"" /etc/os-release
check sessao bash -c "pgrep -u $U -x openbox && pgrep -u $U -f akko-painel && pgrep -u $U -f akko-soundd && pgrep -u $U -x dunst"
check sessao_akkos bash -c "loginctl show-session \$(loginctl list-sessions --no-legend | awk '\$3==\"$U\" && \$4==\"seat0\" {print \$1; exit}') -p Desktop -p Type -p State"
check idioma bash -c "grep -h LANG /etc/default/locale /etc/locale.conf 2>/dev/null; locale -a | grep -i pt_BR"
check plymouth_tema bash -c "plymouth-set-default-theme | grep -x akkos"
check sons_gerados bash -c "ls /usr/share/sounds/akkos/*.wav | wc -l | grep -x 6 && ls /usr/share/sounds/akkos/"

# ---------------------------------------------------------- áudio
check pipewire asu bash -c "wpctl status | sed -n '/Sinks:/,/Sources:/p' | head -6"
check som_notify asu akko-sound notify --esperar
check som_click asu akko-sound click --esperar

# ---------------------------------------------------------- rede e internet
for i in $(seq 1 60); do nmcli -t -f STATE general 2>/dev/null | grep -q '^connected' && break; sleep 1; done
check rede_nm nmcli -t -f STATE,CONNECTIVITY general
check rede_ip bash -c "nmcli -t -f DEVICE,STATE,CONNECTION device; ip -4 -br addr"
check internet_tls curl -sS -o /dev/null -w 'http=%{http_code} tls_verificacao=%{ssl_verify_result} tempo=%{time_total}s' https://deb.debian.org/debian/
check dns getent hosts github.com

# ---------------------------------------------------------- segurança
check firewall_regras bash -c "nft list ruleset | grep -E 'policy drop|policy accept' | tr -s ' '"
check firewall_ativo systemctl is-active nftables
check sysctl bash -c "sysctl -n kernel.kptr_restrict kernel.dmesg_restrict kernel.randomize_va_space net.ipv4.conf.all.rp_filter kernel.unprivileged_bpf_disabled | tr '\n' ' ' | grep -x '2 1 2 1 1 '"
check apparmor bash -c "aa-status --enabled && aa-status | head -3 && aa-status | grep -c firejail-default"
check firejail firejail --version
check root_travado bash -c "passwd -S root | awk '{print \$2}' | grep -x L"
# firewall de verdade: um servidor escutando; de fora (QEMU) não pode responder
python3 -m http.server 8080 --bind 0.0.0.0 >/dev/null 2>&1 &
SERVIDOR=$!
sleep 2
check firewall_local_responde curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/
echo "AKKOS-FW-PRONTO"
sleep 15   # o lado de fora tenta conectar neste intervalo
kill $SERVIDOR 2>/dev/null
check firewall_log bash -c "journalctl -k --no-pager | grep -c akkos-fw-bloqueado"

# ---------------------------------------------------------- compatibilidade
check wine asu bash -c "(command -v wine || command -v wine-stable) && (wine --version 2>/dev/null || wine-stable --version)"
check wine32 bash -c "dpkg -l wine32:i386 | tail -1"
check dxvk bash -c "ls /usr/lib/dxvk/wine64 && command -v dxvk-setup"
check binfmt_exe bash -c "cat /proc/sys/fs/binfmt_misc/akkos-windows"
check flatpak flatpak remotes --system
check appimage_fuse bash -c "dpkg -l libfuse2t64 | tail -1"
check navegador_politica python3 -c "import json;print(json.load(open('/etc/chromium/policies/managed/akkos.json'))['HomepageLocation'])"
check navegador_sandbox bash -c "readlink -f /usr/local/bin/chromium; grep Exec= /usr/share/applications/akko-navegador.desktop | head -1"

# ---------------------------------------------------------- programas gráficos
asu akko-arquivos /usr/share/backgrounds/akkos >/dev/null 2>&1 &
sleep 6
check janela_arquivos asu bash -c "wmctrl -l | grep -i 'akkos'"
shot 02-explorador
asu xdotool key ctrl+2 2>/dev/null; sleep 2
shot 03-explorador-lista
asu wmctrl -c akkos 2>/dev/null

asu akko-rede >/dev/null 2>&1 &
sleep 6
check janela_rede asu bash -c "wmctrl -l | grep -i 'Rede'"
shot 04-rede
asu wmctrl -c Rede 2>/dev/null

asu akko-painel --menu
sleep 3
shot 05-menu
asu xdotool key Escape 2>/dev/null

asu akko-navegador >/dev/null 2>&1 &
sleep 15
check janela_navegador asu bash -c "wmctrl -lx | grep -i chromium"
check navegador_em_sandbox bash -c "firejail --list | grep -i chromium"
shot 06-navegador
asu bash -c "wmctrl -lx | awk 'tolower(\$3) ~ /chromium/ {print \$1}' | xargs -r -n1 wmctrl -i -c" 2>/dev/null
sleep 2

# ---------------------------------------------------------- programa Windows de verdade
PFX="/home/$U/.local/share/akkos/wine/prefixos/padrao"
for i in $(seq 1 240); do [ -f "$PFX/.akkos-criado" ] && break; sleep 1; done
check wine_prefixo bash -c "ls '$PFX' && cat '$PFX/.akkos-criado' && ls '$PFX/drive_c/windows/Fonts' | head -3"
check wine_dxvk bash -c "ls -l '$PFX/drive_c/windows/system32/d3d11.dll' | grep -o '\-> .*'"
NOTEPAD="$PFX/drive_c/windows/notepad.exe"
asu win-launcher --modo app "$NOTEPAD" >/dev/null 2>&1 &
for i in $(seq 1 90); do asu wmctrl -lx 2>/dev/null | grep -qi notepad && break; sleep 1; done
shot 07-windows-notepad
check janela_windows asu bash -c "wmctrl -lx | grep -i notepad"
check windows_em_sandbox bash -c "firejail --list | grep -i -E 'wine|notepad'"
check windows_log bash -c "ls -t /home/$U/.local/share/akkos/wine/logs/ | head -3; tail -4 \$(ls -t /home/$U/.local/share/akkos/wine/logs/notepad-*.log | head -1)"
asu bash -c "WINEPREFIX='$PFX' wineserver -k" 2>/dev/null
sleep 2

# ---------------------------------------------------------- escolha Aplicativo/Jogo
check umu_launcher asu umu-run --version
asu win-launcher --perguntar "$NOTEPAD" >/dev/null 2>&1 &
for i in $(seq 1 30); do asu wmctrl -l 2>/dev/null | grep -q "Abrir programa Windows" && break; sleep 1; done
check janela_escolha asu bash -c "wmctrl -l | grep 'Abrir programa Windows'"
shot 08-escolha-app-jogo
asu bash -c "wmctrl -c 'Abrir programa Windows'" 2>/dev/null   # fechar = cancelar
sleep 2
check escolha_cancelada bash -c "! pgrep -u $U -f akko-win-escolha && ! pgrep -u $U -f 'notepad.exe'"
shot 09-final

echo "AKKOS-TESTE-FIM"
sleep 3
systemctl poweroff
