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
export -f asu; export U UIDN   # para usar asu dentro de "bash -c"
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
check apparmor bash -c "aa-status --enabled && aa-status 2>&1 | head -4 && aa-status | grep -q firejail-default || { systemctl status apparmor --no-pager -l 2>&1 | tail -12; journalctl -b -u apparmor --no-pager 2>&1 | tail -15; false; }"
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
asu bash -c "akko-arquivos /usr/share/backgrounds/akkos >/tmp/akko-arquivos.log 2>&1" &
for i in $(seq 1 15); do asu wmctrl -l 2>/dev/null | grep -q ' akkos$' && break; sleep 1; done
check janela_arquivos bash -c "asu wmctrl -l | grep ' akkos$' || { tail -20 /tmp/akko-arquivos.log; false; }"
shot 02-explorador
asu xdotool key ctrl+3 2>/dev/null; sleep 2
shot 03-explorador-lista
asu wmctrl -c akkos 2>/dev/null

asu bash -c "akko-rede >/tmp/akko-rede.log 2>&1" &
for i in $(seq 1 15); do asu wmctrl -l 2>/dev/null | grep -q ' Rede$' && break; sleep 1; done
check janela_rede bash -c "asu wmctrl -l | grep ' Rede$' || { tail -20 /tmp/akko-rede.log; false; }"
shot 04-rede
asu wmctrl -c Rede 2>/dev/null

asu akko-painel --menu
sleep 3
shot 05-menu
asu xdotool key Escape 2>/dev/null

# ---------------------------------------------------------- área de trabalho, Este Computador, tarefas
check area_de_trabalho bash -c "pgrep -u $U -f akko-desktop && asu wmctrl -l | grep 'Área de Trabalho'"
check atalhos_area_de_trabalho bash -c "ls \"\$(asu xdg-user-dir DESKTOP)\""
asu bash -c "akko-arquivos computador:// >/tmp/akko-pc.log 2>&1" &
for i in $(seq 1 15); do asu wmctrl -l 2>/dev/null | grep -q 'Este Computador' && break; sleep 1; done
check janela_este_computador bash -c "asu wmctrl -l | grep 'Este Computador' || { tail -20 /tmp/akko-pc.log; false; }"
shot 05b-este-computador
asu wmctrl -c 'Este Computador' 2>/dev/null
asu bash -c "akko-tarefas --desempenho >/tmp/akko-tarefas.log 2>&1" &
for i in $(seq 1 15); do asu wmctrl -l 2>/dev/null | grep -q 'Gerenciador de Tarefas' && break; sleep 1; done
sleep 4
check janela_tarefas bash -c "asu wmctrl -l | grep 'Gerenciador de Tarefas' || { tail -20 /tmp/akko-tarefas.log; false; }"
shot 05c-gerenciador-de-tarefas
asu wmctrl -c 'Gerenciador de Tarefas' 2>/dev/null

# ---------------------------------------------------------- instalador e persistência
check calamares_marca bash -c "grep '^branding:' /etc/calamares/settings.conf && grep -c \"'calamares'\" /etc/calamares/modules/packages.conf"
asu bash -c "akko-instalar >/tmp/akko-instalar.log 2>&1" &
for i in $(seq 1 40); do asu wmctrl -lx 2>/dev/null | grep -qi calamares && break; sleep 1; done
sleep 5
check janela_instalador bash -c "asu wmctrl -lx | grep -i calamares || { tail -20 /tmp/akko-instalar.log; false; }"
shot 05d-instalador
pkill -x calamares 2>/dev/null; sleep 2
asu bash -c "akko-persistencia >/tmp/akko-persist.log 2>&1" &
for i in $(seq 1 15); do asu wmctrl -l 2>/dev/null | grep -q 'Guardar alterações' && break; sleep 1; done
check janela_persistencia bash -c "asu wmctrl -l | grep 'Guardar alterações' || { tail -20 /tmp/akko-persist.log; false; }"
sleep 3
shot 05e-guardar-alteracoes
asu wmctrl -c 'Guardar alterações' 2>/dev/null

# ---------------------------------------------------------- vídeo e memória
check gpu_mesa bash -c "dpkg-query -W -f '\${Version}\n' mesa-vulkan-drivers:amd64 mesa-vulkan-drivers:i386"
check gpu_nvidia_modulo bash -c "modinfo -F version nvidia-current 2>/dev/null || modinfo -F version nvidia"
check gpu_nvidia_32bits bash -c "dpkg -l nvidia-driver-libs:i386 | tail -1"
check gpu_escolha bash -c "systemctl is-active akkos-gpu; cat /run/akkos-gpu"
check gpu_vulkan asu bash -c "vulkaninfo --summary 2>/dev/null | grep -E 'deviceName|driverName' | head -4"
check zram bash -c "swapon --show=NAME,SIZE,PRIO --noheadings | grep zram"
check espaco_live bash -c "df -h /home/$U | tail -1 | tr -s ' '; findmnt -no FSTYPE,OPTIONS /run/live/overlay 2>/dev/null | cut -c1-100; true"

asu akko-navegador >/dev/null 2>&1 &
sleep 15
check janela_navegador asu bash -c "wmctrl -lx | grep -i chromium"
check navegador_pagina_inicial asu bash -c "wmctrl -l | grep \"Akko's OS - Chromium\""
check navegador_em_sandbox bash -c "firejail --list | grep -i chromium"
# diagnóstico (não reprova): o Chromium abriria com o AppArmor do firejail?
check diag_chromium_apparmor bash -c "asu timeout 40 firejail --quiet --profile=chromium --apparmor /usr/bin/chromium --headless=new --disable-gpu --dump-dom file:///usr/share/akkos/inicio/index.html 2>&1 | grep -v '^ *$' | tail -6 | cut -c1-200; echo \"rc=\${PIPESTATUS[0]}\"; journalctl -k --no-pager 2>/dev/null | grep -a 'apparmor=\"DENIED\"' | tail -8 | sed -E 's/.*(operation=[^ ]+).*(profile=[^ ]+).*(name=[^ ]+).*/\1 \2 \3/'; true"
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
check windows_apparmor bash -c "for p in \$(pgrep -u $U -f notepad); do cat /proc/\$p/attr/current 2>/dev/null; echo; done | sort -u | grep -m3 firejail-default"
check windows_log bash -c "ls -t /home/$U/.local/share/akkos/wine/logs/ | head -3; tail -4 \$(ls -t /home/$U/.local/share/akkos/wine/logs/notepad-*.log | head -1)"
# fecha como uma pessoa fecharia (o wineserver -k fazia o lançador acusar erro)
asu bash -c "wmctrl -c 'Bloco de Notas'" 2>/dev/null
for i in $(seq 1 15); do asu wmctrl -lx 2>/dev/null | grep -qi notepad || break; sleep 1; done
check windows_fechou_sem_erro bash -c "! asu wmctrl -l | grep 'não abriu'"
asu bash -c "WINEPREFIX='$PFX' wineserver -k" 2>/dev/null
sleep 2

# ---------------------------------------------------------- instalar um programa Windows de verdade
# qBittorrent 5.3.0 (o mesmo que falhou com "erro ao gravar" no modo sem instalar)
QB="/home/$U/Downloads/qbittorrent_5.3.0_x64_setup.exe"
QB_SHA=aff5b3bdc00d6e5773d6099ba30f9696dd3dfd1669ab0f64ce5c4e7168486436
asu mkdir -p "/home/$U/Downloads"
asu curl -fsSL --retry 3 --max-time 300 -o "$QB" \
    "https://downloads.sourceforge.net/project/qbittorrent/qbittorrent-win32/qbittorrent-5.3.0/qbittorrent_5.3.0_x64_setup.exe"
check qbittorrent_download bash -c "sha256sum '$QB' | grep -q $QB_SHA && ls -la '$QB'"
check espaco_antes bash -c "df -h /home/$U | tail -1 | tr -s ' '"
asu timeout 600 win-launcher --modo app --sem-tela "$QB" /S >/tmp/qb.log 2>&1
check qbittorrent_instalado bash -c "ls -la '$PFX/drive_c/Program Files/qBittorrent/qbittorrent.exe' || { tail -15 /tmp/qb.log; tail -25 \$(ls -t /home/$U/.local/share/akkos/wine/logs/qbittorrent*.log | head -1); df -h /home/$U; false; }"
check espaco_depois bash -c "df -h /home/$U | tail -1 | tr -s ' '"
QBEXE="$PFX/drive_c/Program Files/qBittorrent/qbittorrent.exe"
asu env WINEDEBUG=err+all,fixme-all win-launcher --modo app "$QBEXE" >/dev/null 2>&1 &
for i in $(seq 1 120); do asu wmctrl -l 2>/dev/null | grep -qiE 'qbittorrent|aviso legal|legal notice' && break; sleep 1; done
sleep 5
check diag_qbittorrent_sandbox bash -c "asu wmctrl -l | tail -4; ps -u $U -o pid,stat,etime,rss,args | grep -iE 'wine|qbit|firejail' | grep -v grep | cut -c1-160 | head -12; tail -15 \$(ls -t /home/$U/.local/share/akkos/wine/logs/qbittorrent-*.log | head -1); true"
if ! asu wmctrl -l 2>/dev/null | grep -qiE 'qbittorrent|aviso legal|legal notice'; then
    asu bash -c "WINEPREFIX='$PFX' wineserver -k" 2>/dev/null; sleep 3
    asu env WINEDEBUG=err+all,fixme-all win-launcher --modo app --sem-sandbox "$QBEXE" >/dev/null 2>&1 &
    for i in $(seq 1 120); do asu wmctrl -l 2>/dev/null | grep -qiE 'qbittorrent|aviso legal|legal notice' && break; sleep 1; done
    sleep 5
    check diag_qbittorrent_sem_sandbox bash -c "asu wmctrl -l | tail -4; ps -u $U -o pid,stat,etime,rss,args | grep -iE 'wine|qbit' | grep -v grep | cut -c1-160 | head -12; tail -15 \$(ls -t /home/$U/.local/share/akkos/wine/logs/qbittorrent-*.log | head -1); true"
fi
check janela_qbittorrent bash -c "asu wmctrl -l | grep -iE 'qbittorrent|aviso legal|legal notice'"
shot 07b-qbittorrent
asu bash -c "WINEPREFIX='$PFX' wineserver -k" 2>/dev/null
sleep 3

# ---------------------------------------------------------- escolha Aplicativo/Jogo
check umu_launcher asu umu-run --version
asu win-launcher --perguntar "$NOTEPAD" >/dev/null 2>&1 &
for i in $(seq 1 30); do asu wmctrl -l 2>/dev/null | grep -q "Abrir programa Windows" && break; sleep 1; done
check janela_escolha asu bash -c "wmctrl -l | grep 'Abrir programa Windows'"
shot 08-escolha-app-jogo
asu bash -c "wmctrl -c 'Abrir programa Windows'" 2>/dev/null   # fechar = cancelar
sleep 2
check apparmor_confinando bash -c "aa-status 2>/dev/null | grep -A200 'processes are in enforce mode' | grep -m5 -E 'firejail|chromium|wine' || aa-status 2>/dev/null | sed -n '1,12p'; true"
check escolha_cancelada bash -c "! pgrep -u $U -f akko-win-escolha && ! pgrep -u $U -f 'wine.*notepad'"
shot 09-final

echo "AKKOS-TESTE-FIM"
sleep 3
systemctl poweroff
