#!/usr/bin/env bash
# win-launcher — abre programas Windows (.exe/.msi/.bat) no Akko's OS.
#
#   win-launcher [opções] ARQUIVO [argumentos…]   abre o programa
#   win-launcher primeiro-uso                      prepara o prefixo padrão
#   win-launcher prefixos                          lista os ambientes
#   win-launcher criar NOME                        cria um ambiente separado
#   win-launcher configurar [NOME]                 abre o winecfg do ambiente
#   win-launcher remover NOME                      apaga um ambiente (pede confirmação)
#   win-launcher associar ARQUIVO NOME             esse programa passa a usar o ambiente NOME
#   win-launcher esquecer-modo ARQUIVO             volta a perguntar app/jogo para esse programa
#
# Opções para abrir:
#   --modo app|jogo    app = Wine na sandbox (programas comuns);
#                      jogo = Proton (o mesmo do Steam/SteamOS) pelo umu-launcher.
#                      Sem --modo: usa a escolha salva para o programa ou
#                      pergunta numa janela com menu suspenso.
#   --perguntar        mostra a janela de escolha mesmo com escolha salva
#   --prefixo NOME     usa o ambiente NOME (padrão: o associado ao programa, ou "padrao")
#   --sem-sandbox      roda sem o firejail (só para programas que não funcionam na sandbox)
#   --sem-tela         não mostra a janela de carregamento
#
# Cada "ambiente" (prefixo) é uma instalação separada do Windows emulado em
#   ~/.local/share/akkos/wine/prefixos/NOME
# Ao criar um prefixo: inicializa o Wine, instala fontes (offline, com
# substitutos métricos das fontes do Windows; e as originais da Microsoft se
# houver internet) e ativa o DXVK (Direct3D 9/10/11 → Vulkan).
#
# Segurança: por padrão o programa roda dentro do firejail (perfil
# akkos-wine): sem root, sem novos privilégios, seccomp, AppArmor e acesso
# restrito à pasta pessoal. Isso REDUZ o risco, mas não é isolamento total:
# Wine não é uma sandbox e não protege contra todo malware.
#
# Logs: ~/.local/share/akkos/wine/logs/

set -uo pipefail

BASE="${XDG_DATA_HOME:-$HOME/.local/share}/akkos/wine"
PREFIXOS="$BASE/prefixos"
LOGS="$BASE/logs"
ASSOC="${XDG_CONFIG_HOME:-$HOME/.config}/akkos/wine-programas.conf"
MODOS="${XDG_CONFIG_HOME:-$HOME/.config}/akkos/wine-modos.conf"   # caminho<TAB>app|jogo
JOGOS="$BASE/jogos"          # prefixos do Proton (separados dos do Wine)
SPLASH=/usr/lib/akkos/akko-win-splash
ESCOLHA=/usr/lib/akkos/akko-win-escolha
UMU_BIN="$(command -v umu-run || true)"

mkdir -p "$PREFIXOS" "$LOGS" "$(dirname "$ASSOC")"

# ---------------------------------------------------------------- utilidades

WINE_BIN="$(command -v wine || command -v wine-stable || true)"
WINESERVER_BIN="$(command -v wineserver || command -v wineserver-stable || echo /usr/lib/wine/wineserver)"
export WINEDEBUG="${WINEDEBUG:--all,err+all}"
export WINEARCH="${WINEARCH:-win64}"

tem_tela() { [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; }

dialogo() {   # dialogo info|erro|pergunta "título" "texto"
    local tipo=$1 titulo=$2 texto=$3
    if tem_tela && command -v zenity >/dev/null; then
        case "$tipo" in
            erro)     akko-sound error 2>/dev/null; zenity --error --title="$titulo" --text="$texto" --width=460 2>/dev/null ;;
            pergunta) zenity --question --title="$titulo" --text="$texto" --width=460 2>/dev/null ;;
            *)        zenity --info --title="$titulo" --text="$texto" --width=460 2>/dev/null ;;
        esac
    else
        echo "[$titulo] $texto" >&2
        [ "$tipo" != pergunta ]
    fi
}

notificar() { command -v notify-send >/dev/null && notify-send -i wine "$1" "${2:-}" 2>/dev/null || true; }

nome_valido() { [[ "$1" =~ ^[A-Za-z0-9._-]{1,48}$ ]]; }

prefixo_de_programa() {   # nome do ambiente associado ao executável (ou "padrao")
    local exe=$1 chave
    chave="$(basename "$exe" | tr '[:upper:]' '[:lower:]')"
    if [ -f "$ASSOC" ]; then
        awk -F'=' -v k="$chave" '$1==k {print $2; found=1} END {if(!found) print ""}' "$ASSOC" | tail -1
    fi
}

modo_salvo() {   # modo_salvo CAMINHO_ABSOLUTO → app|jogo|""
    [ -f "$MODOS" ] || return 0
    awk -F'\t' -v k="$1" '$1==k {m=$2} END {print m}' "$MODOS"
}

salvar_modo() {  # salvar_modo CAMINHO app|jogo
    touch "$MODOS"
    awk -F'\t' -v k="$1" '$1!=k' "$MODOS" > "$MODOS.tmp" && mv "$MODOS.tmp" "$MODOS"
    printf '%s\t%s\n' "$1" "$2" >> "$MODOS"
}

esquecer_modo() {
    [ -f "$MODOS" ] || return 0
    awk -F'\t' -v k="$1" '$1!=k' "$MODOS" > "$MODOS.tmp" && mv "$MODOS.tmp" "$MODOS"
}

# ---------------------------------------------------------------- prefixos

instalar_fontes() {   # fontes básicas sem depender de internet
    local pfx=$1 dest="$1/drive_c/windows/Fonts" f
    mkdir -p "$dest"
    for f in /usr/share/fonts/truetype/liberation2/*.ttf /usr/share/fonts/truetype/liberation/*.ttf \
             /usr/share/fonts/truetype/dejavu/*.ttf; do
        [ -f "$f" ] && ln -sf "$f" "$dest/$(basename "$f")"
    done
    # Arial/Times/Courier → Liberation (mesmas métricas: textos não mudam de tamanho)
    local reg
    reg="$(mktemp --suffix=.reg)"
    cat > "$reg" <<'EOF'
REGEDIT4

[HKEY_CURRENT_USER\Software\Wine\Fonts\Replacements]
"Arial"="Liberation Sans"
"Arial Narrow"="Liberation Sans Narrow"
"Times New Roman"="Liberation Serif"
"Courier New"="Liberation Mono"
"Helvetica"="Liberation Sans"
"MS Sans Serif"="Liberation Sans"
"MS Shell Dlg"="Liberation Sans"
"MS Shell Dlg 2"="Liberation Sans"
"Tahoma"="DejaVu Sans"
"Verdana"="DejaVu Sans"
"Segoe UI"="DejaVu Sans"
"Calibri"="Liberation Sans"
"Cambria"="Liberation Serif"
"Consolas"="Liberation Mono"
EOF
    WINEPREFIX="$pfx" "$WINE_BIN" regedit "$reg" >/dev/null 2>&1
    rm -f "$reg"
}

ativar_dxvk() {
    local pfx=$1
    if command -v dxvk-setup >/dev/null; then
        WINEPREFIX="$pfx" dxvk-setup install --stable -y >>"$LOGS/prefixo-$(basename "$pfx").log" 2>&1 \
            && echo "DXVK ativado" || echo "aviso: DXVK não pôde ser ativado (veja o log)"
    fi
}

# ICU do Windows (icu.dll, icuuc.dll, icuin.dll): o Windows 10/11 traz e
# programas novos (qBittorrent 5, apps com Qt 6.7+ ou C++20 <chrono>) exigem;
# o Wine ainda não tem (bug 53354). Usamos o build do ICU da comunidade
# FaithLife (fork do ICU da Microsoft) feito para o Wine, 64 e 32 bits.
ICU_DIR=/usr/share/akkos/wine-icu
garantir_icu() {   # garantir_icu PREFIXO [--sem-registro]  (Proton: sem registro)
    local pfx=$1 w="$1/drive_c/windows" d
    [ -d "$ICU_DIR/system32" ] && [ -d "$w/system32" ] || return 0
    [ -f "$w/system32/icuuc.dll" ] && [ -f "$pfx/.akkos-icu" ] && return 0
    cp -f "$ICU_DIR"/system32/*.dll "$w/system32/" 2>/dev/null || return 0
    [ -d "$w/syswow64" ] && cp -f "$ICU_DIR"/syswow64/*.dll "$w/syswow64/" 2>/dev/null
    if [ -d "$ICU_DIR/globalization" ]; then
        mkdir -p "$w/globalization" && cp -rf "$ICU_DIR/globalization/." "$w/globalization/" 2>/dev/null
    fi
    # prefere estas DLLs a qualquer versão "de mentira" que o Wine venha a trazer
    [ "${2:-}" = --sem-registro ] && { date -Iseconds > "$pfx/.akkos-icu"; return 0; }
    for d in icu icuuc icuin; do
        WINEPREFIX="$pfx" "$WINE_BIN" reg add 'HKCU\Software\Wine\DllOverrides' /v "$d" /d native,builtin /f \
            >/dev/null 2>&1
    done
    date -Iseconds > "$pfx/.akkos-icu"
}

criar_prefixo() {   # criar_prefixo NOME [--silencioso]
    local nome=$1 pfx="$PREFIXOS/$1" log
    log="$LOGS/prefixo-$1.log"
    if [ -f "$pfx/system.reg" ]; then
        return 0
    fi
    echo "Criando ambiente Windows '$nome' em $pfx" | tee -a "$log"
    mkdir -p "$pfx"
    # sem Mono/Gecko automáticos (pediriam download no meio da criação).
    # Sem tela: assim o Wine não mostra a caixa "configuração sendo
    # atualizada" (a janela de carregamento do Akko's OS já avisa).
    if ! env -u DISPLAY -u WAYLAND_DISPLAY WINEPREFIX="$pfx" WINEDLLOVERRIDES="mscoree,mshtml=" \
            "$WINE_BIN" wineboot --init >>"$log" 2>&1 || [ ! -f "$pfx/system.reg" ]; then
        echo "aviso: criação sem tela falhou, tentando com tela" >>"$log"
        if ! WINEPREFIX="$pfx" WINEDLLOVERRIDES="mscoree,mshtml=" "$WINE_BIN" wineboot --init >>"$log" 2>&1; then
            echo "erro: wineboot falhou (veja $log)" >&2
            return 1
        fi
    fi
    WINEPREFIX="$pfx" "$WINESERVER_BIN" -w 2>/dev/null
    instalar_fontes "$pfx"
    garantir_icu "$pfx"
    ativar_dxvk "$pfx" | tee -a "$log"
    # fontes originais da Microsoft, se houver internet (em segundo plano)
    if command -v winetricks >/dev/null; then
        ( WINEPREFIX="$pfx" timeout 900 winetricks -q --unattended corefonts >>"$log" 2>&1 \
            && echo "corefonts instaladas" >>"$log" ) &
    fi
    date -Iseconds > "$pfx/.akkos-criado"
    echo "Ambiente '$nome' pronto" | tee -a "$log"
}

# ---------------------------------------------------------------- diagnóstico

explicar_falha() {   # lê o log e traduz os erros mais comuns
    local log=$1 dica=""
    local dlls
    dlls="$(grep -oE "Library [A-Za-z0-9_.-]+\.(dll|DLL)" "$log" | awk '{print $2}' | sort -u | head -5 | tr '\n' ' ')"
    if [ -n "$dlls" ]; then
        dica+="• Bibliotecas do Windows ausentes: ${dlls}\n  Tente: winetricks (vcrun2022, d3dx9, dotnet48…) neste ambiente.\n"
    fi
    grep -qiE "mscoree|\.NET Framework|clr" "$log" && \
        dica+="• O programa precisa do .NET Framework: winetricks dotnet48 (demorado).\n"
    grep -qiE "vulkan|dxvk|failed to create d3d|D3D11CreateDevice" "$log" && \
        dica+="• Problema gráfico (Vulkan/DXVK): confira o driver de vídeo com 'vulkaninfo --summary' no terminal.\n"
    grep -qiE "page fault|unhandled exception" "$log" && \
        dica+="• O programa travou dentro do Wine (pode não ser compatível).\n"
    grep -qiE "kernel driver|\.sys|anti-?cheat|easyanticheat|battleye" "$log" && \
        dica+="• O programa usa driver de kernel do Windows/anti-cheat: não roda no Linux.\n"
    grep -qiE "seccomp|firejail|Permission denied" "$log" && \
        dica+="• A sandbox bloqueou algo: tente 'Abrir sem sandbox' no menu do Arquivos.\n"
    grep -qiE "No space left|ENOSPC|disk full|erro ao gravar|error writing" "$log" && \
        dica="• Faltou espaço. $(texto_espaco)\n$dica"
    [ -z "$dica" ] && dica="• Não identifiquei a causa automaticamente.\n"
    printf "%b" "$dica"
}

# Rodando sem instalar (live), o que se grava fica na memória RAM: pouco espaço.
eh_live_sem_persistencia() {
    [ -d /run/live/medium ] && ! grep -q " /run/live/persistence/" /proc/mounts
}

texto_espaco() {
    local livre
    livre=$(df -Pk "$HOME" 2>/dev/null | awk 'NR==2{print int($4/1024)}')
    if eh_live_sem_persistencia; then
        echo "Rodando sem instalar, tudo é guardado na memória RAM e restam ${livre:-?} MB. Instale o Akko's OS (ícone na área de trabalho) ou use “Guardar alterações” num disco."
    else
        echo "Restam ${livre:-?} MB livres na sua pasta pessoal."
    fi
}

avisar_espaco() {
    local livre
    livre=$(df -Pk "$HOME" 2>/dev/null | awk 'NR==2{print $4}')
    [ -n "$livre" ] || return 0
    if [ "$livre" -lt 1500000 ] || { eh_live_sem_persistencia && [ "$livre" -lt 3000000 ]; }; then
        tem_tela && command -v notify-send >/dev/null && \
            notify-send -a "Akko's OS" -i dialog-warning "Pouco espaço para programas Windows" "$(texto_espaco)"
        echo "aviso: pouco espaço ($((livre / 1024)) MB)" >&2
    fi
}

# ---------------------------------------------------------------- abrir

abrir() {
    local prefixo="" sandbox=1 tela=1 modo="" perguntar=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --modo) modo="$2"; shift 2 ;;
            --perguntar) perguntar=1; shift ;;
            --prefixo) prefixo="$2"; shift 2 ;;
            --sem-sandbox) sandbox=0; shift ;;
            --sem-tela) tela=0; shift ;;
            --) shift; break ;;
            *) break ;;
        esac
    done
    local arquivo=${1:-}
    shift || true
    if [ -z "$arquivo" ] || [ ! -f "$arquivo" ]; then
        dialogo erro "Programa não encontrado" "O arquivo “${arquivo:-?}” não existe."
        return 2
    fi
    if [ -z "$WINE_BIN" ]; then
        dialogo erro "Compatibilidade Windows indisponível" "O Wine não está instalado neste sistema."
        return 3
    fi
    if [ "$(id -u)" = 0 ]; then
        dialogo erro "Não rode como administrador" "Programas Windows nunca são executados como root no Akko's OS."
        return 4
    fi
    arquivo="$(realpath "$arquivo")"
    local dir nome extensao
    dir="$(dirname "$arquivo")"
    nome="$(basename "$arquivo")"
    extensao="$(echo "${nome##*.}" | tr '[:upper:]' '[:lower:]')"

    # ---- aplicativo (Wine) ou jogo (Proton)?
    case "$modo" in app|jogo|"") ;; *)
        dialogo erro "Modo inválido" "Use --modo app ou --modo jogo."; return 2 ;;
    esac
    case "$extensao" in msi|bat|cmd) modo=app ;; esac   # instaladores/scripts: sempre Wine
    [ -z "$modo" ] && [ $perguntar = 0 ] && modo="$(modo_salvo "$arquivo")"
    if [ -z "$modo" ]; then
        if tem_tela && [ -x "$ESCOLHA" ]; then
            local sugestao=app resp
            echo "$nome" | grep -qiE "setup|install|unins" || {
                # executável dentro de uma pasta de jogo conhecida: sugere Jogo
                echo "$arquivo" | grep -qiE "/(games?|jogos)/|steamapps|epic games|gog" && sugestao=jogo
            }
            [ -n "$(modo_salvo "$arquivo")" ] && sugestao="$(modo_salvo "$arquivo")"
            resp="$("$ESCOLHA" "$nome" "$sugestao")" || return 0   # cancelou
            modo="$(echo "$resp" | head -1)"
            echo "$resp" | grep -qx lembrar && salvar_modo "$arquivo" "$modo"
        else
            modo=app
        fi
    fi
    avisar_espaco
    if [ "$modo" = jogo ]; then
        abrir_jogo "$arquivo" "$prefixo" "$tela" "$@"
        return $?
    fi

    [ -z "$prefixo" ] && prefixo="$(prefixo_de_programa "$arquivo")"
    [ -z "$prefixo" ] && prefixo=padrao
    nome_valido "$prefixo" || { dialogo erro "Ambiente inválido" "Nome de ambiente inválido: $prefixo"; return 2; }
    local pfx="$PREFIXOS/$prefixo"
    local log
    log="$LOGS/$(printf "%s" "${nome%.*}" | tr -c 'A-Za-z0-9._-' '_')-$(date +%Y%m%d-%H%M%S).log"

    local splash_pid=""
    if [ $tela = 1 ] && tem_tela && [ -x "$SPLASH" ]; then
        local msg="Preparando compatibilidade Windows…"
        [ -f "$pfx/system.reg" ] || msg="Criando o ambiente Windows (só na primeira vez, ~1 minuto)…"
        "$SPLASH" "$nome" "$msg" &
        splash_pid=$!
    fi

    if ! criar_prefixo "$prefixo"; then
        [ -n "$splash_pid" ] && kill "$splash_pid" 2>/dev/null
        dialogo erro "Não foi possível preparar o ambiente" "Falha ao criar o ambiente Windows '$prefixo'.\nLog: $LOGS/prefixo-$prefixo.log"
        return 5
    fi
    garantir_icu "$PREFIXOS/$prefixo"   # ambientes criados antes desta versão

    local cmd=()
    case "$extensao" in
        msi) cmd=("$WINE_BIN" msiexec /i "$arquivo" "$@") ;;
        bat|cmd) cmd=("$WINE_BIN" cmd /c "$arquivo" "$@") ;;
        *)   cmd=("$WINE_BIN" "$arquivo" "$@") ;;
    esac

    if [ $sandbox = 1 ] && command -v firejail >/dev/null; then
        # whitelist dinâmica: o próprio programa (pasta onde está) e o ambiente
        cmd=(firejail --quiet --profile=akkos-wine "--whitelist=$dir" "--whitelist=$pfx" -- "${cmd[@]}")
    fi

    {
        echo "== Akko's OS win-launcher $(date -Iseconds)"
        echo "programa: $arquivo"
        echo "ambiente: $pfx"
        echo "sandbox:  $([ $sandbox = 1 ] && echo firejail/akkos-wine || echo desligada)"
        echo "comando:  ${cmd[*]}"
        echo "wine:     $("$WINE_BIN" --version 2>/dev/null)"
        echo "=="
    } > "$log"

    local inicio fim codigo
    inicio=$(date +%s)
    ( cd "$dir" && WINEPREFIX="$pfx" "${cmd[@]}" ) >>"$log" 2>&1 &
    local wine_pid=$!
    wait "$wine_pid"
    codigo=$?
    fim=$(date +%s)
    [ -n "$splash_pid" ] && kill "$splash_pid" 2>/dev/null
    echo "== saiu com código $codigo após $((fim - inicio)) s" >> "$log"

    # atalhos que o instalador criou no menu: passam a abrir dentro da sandbox também
    if [ $sandbox = 1 ] && command -v firejail >/dev/null; then
        find "$HOME/.local/share/applications/wine" -name '*.desktop' -newermt "@$inicio" 2>/dev/null |
        while read -r atalho; do
            grep -q 'firejail' "$atalho" && continue
            sed -i -E "s|^Exec=env WINEPREFIX=\"([^\"]+)\" wine |Exec=env WINEPREFIX=\"\1\" firejail --quiet --profile=akkos-wine --whitelist=\1 -- wine |" "$atalho"
            echo "atalho na sandbox: $atalho" >> "$log"
        done
    fi
    # instalador terminou: avisa sobre atalhos criados no menu
    if [ "$extensao" = msi ] || echo "$nome" | grep -qiE "setup|install"; then
        if [ $codigo = 0 ]; then
            notificar "Instalação concluída" "Os atalhos do programa aparecem no menu de aplicativos (categoria Windows)."
        fi
    fi
    # saída rápida com erro = provavelmente não abriu: explica o que der
    # dentro do firejail o código de saída do programa pode se perder (sai 0):
    # DLL ausente (c0000135) também conta como falha
    if grep -q "c0000135\|err:module:import_dll" "$log" 2>/dev/null && [ $codigo = 0 ]; then codigo=53; fi
    if [ $codigo != 0 ] && [ $((fim - inicio)) -lt 20 ]; then
        dialogo erro "“$nome” não abriu" "O programa fechou com erro (código $codigo).\n\n$(explicar_falha "$log")\nLog completo: $log"
    fi
    return $codigo
}

# ---------------------------------------------------------------- jogos (Proton)

# Modo Jogo: o umu-launcher roda o Proton (Wine da Valve + DXVK + VKD3D-Proton)
# dentro do Steam Linux Runtime, igual ao Steam/SteamOS, mas sem precisar do
# Steam. Na primeira vez ele baixa o runtime e o GE-Proton (~1 GB, precisa de
# internet). Jogos rodam FORA do firejail: o runtime usa seus próprios
# namespaces (bubblewrap) e anti-cheats/overlays quebram dentro da sandbox.
abrir_jogo() {   # abrir_jogo ARQUIVO PREFIXO TELA [args…]
    local arquivo=$1 prefixo=${2:-padrao} tela=$3
    shift 3
    local dir nome
    dir="$(dirname "$arquivo")"; nome="$(basename "$arquivo")"
    if [ -z "$UMU_BIN" ]; then
        dialogo erro "Modo Jogo indisponível" "O umu-launcher (Proton) não está instalado. Abra como Aplicativo."
        return 3
    fi
    nome_valido "$prefixo" || { dialogo erro "Ambiente inválido" "Nome de ambiente inválido: $prefixo"; return 2; }
    local pfx="$JOGOS/$prefixo" log
    mkdir -p "$pfx"
    log="$LOGS/jogo-$(printf "%s" "${nome%.*}" | tr -c 'A-Za-z0-9._-' '_')-$(date +%Y%m%d-%H%M%S).log"

    local primeira=0
    ls -d "$HOME"/.local/share/Steam/compatibilitytools.d/GE-Proton* "$HOME"/.local/share/Steam/compatibilitytools.d/UMU-Proton* \
        >/dev/null 2>&1 || primeira=1
    if [ $primeira = 1 ] && ! getent hosts github.com >/dev/null 2>&1; then
        dialogo erro "Sem internet" "Na primeira vez o modo Jogo precisa baixar o Proton (~1 GB).\nConecte-se à internet ou abra como Aplicativo."
        return 6
    fi
    local splash_pid=""
    if [ "$tela" = 1 ] && tem_tela && [ -x "$SPLASH" ]; then
        local msg="Iniciando com Proton…"
        [ $primeira = 1 ] && msg="Baixando o Proton e o runtime de jogos (só na primeira vez, ~1 GB)…"
        [ -f "$pfx/system.reg" ] || [ $primeira = 1 ] || msg="Criando o ambiente do jogo (só na primeira vez)…"
        AKKOS_SPLASH_MODO=jogo AKKOS_SPLASH_LIMITE=$([ $primeira = 1 ] && echo 1800 || echo 120) "$SPLASH" "$nome" "$msg" &
        splash_pid=$!
    fi
    {
        echo "== Akko's OS win-launcher (modo Jogo) $(date -Iseconds)"
        echo "programa: $arquivo"
        echo "ambiente: $pfx"
        echo "proton:   ${PROTONPATH:-GE-Proton} via $UMU_BIN"
        echo "=="
    } > "$log"
    local inicio fim codigo
    inicio=$(date +%s)
    garantir_icu "$pfx" --sem-registro   # só depois que o Proton criou o ambiente
    ( cd "$dir" && WINEPREFIX="$pfx" GAMEID="${GAMEID:-umu-default}" PROTONPATH="${PROTONPATH:-GE-Proton}" \
        WINEDLLOVERRIDES="icu,icuuc,icuin=n,b${WINEDLLOVERRIDES:+;$WINEDLLOVERRIDES}" \
        "$UMU_BIN" "$arquivo" "$@" ) >>"$log" 2>&1
    codigo=$?
    fim=$(date +%s)
    [ -n "$splash_pid" ] && kill "$splash_pid" 2>/dev/null
    echo "== saiu com código $codigo após $((fim - inicio)) s" >> "$log"
    if [ $codigo != 0 ] && [ $((fim - inicio)) -lt 30 ]; then
        local dica
        dica="$(explicar_falha "$log")"
        grep -qiE "urlopen|timed out|Name or service not known|ConnectionError|HTTPError" "$log" && \
            dica="• Falha ao baixar o Proton/runtime: verifique a internet e tente de novo.\n$dica"
        grep -qiE "bwrap|unprivileged user namespaces|setting up uid map" "$log" && \
            dica="• O runtime de jogos não conseguiu criar o contêiner (user namespaces).\n$dica"
        dialogo erro "“$nome” não abriu como jogo" "Saiu com erro (código $codigo).\n\n$(printf '%b' "$dica")\nDica: tente abrir como Aplicativo (clique direito no Arquivos).\nLog: $log"
    fi
    return $codigo
}

# ---------------------------------------------------------------- comandos

case "${1:-}" in
    primeiro-uso)
        # chamado no início da sessão: prepara o ambiente padrão em segundo plano,
        # pra o primeiro programa Windows abrir rápido
        [ -z "$WINE_BIN" ] && exit 0
        if [ ! -f "$PREFIXOS/padrao/system.reg" ]; then
            renice -n 10 $$ >/dev/null 2>&1
            criar_prefixo padrao >/dev/null 2>&1 \
                && notificar "Compatibilidade Windows pronta" "Programas .exe e .msi abrem com dois cliques."
        fi
        ;;
    prefixos)
        for p in "$PREFIXOS"/*/; do
            [ -d "$p" ] || continue
            n="$(basename "$p")"
            printf "%-20s %s  %s\n" "$n" "$(du -sh "$p" 2>/dev/null | cut -f1)" "$(cat "$p/.akkos-criado" 2>/dev/null)"
        done
        ;;
    criar)
        nome_valido "${2:-}" || { echo "uso: win-launcher criar NOME (letras, números, . _ -)" >&2; exit 2; }
        criar_prefixo "$2"
        ;;
    configurar)
        n="${2:-padrao}"; nome_valido "$n" || exit 2
        criar_prefixo "$n" && WINEPREFIX="$PREFIXOS/$n" "$WINE_BIN" winecfg
        ;;
    remover)
        n="${2:-}"; nome_valido "$n" || { echo "uso: win-launcher remover NOME" >&2; exit 2; }
        [ -d "$PREFIXOS/$n" ] || { echo "ambiente '$n' não existe" >&2; exit 1; }
        if dialogo pergunta "Remover ambiente" "Apagar o ambiente Windows '$n' e TODOS os programas instalados nele?"; then
            WINEPREFIX="$PREFIXOS/$n" "$WINESERVER_BIN" -k 2>/dev/null
            rm -rf --one-file-system "${PREFIXOS:?}/$n"
            echo "ambiente '$n' removido"
        fi
        ;;
    associar)
        [ -f "${2:-}" ] && nome_valido "${3:-}" || { echo "uso: win-launcher associar ARQUIVO NOME" >&2; exit 2; }
        chave="$(basename "$2" | tr '[:upper:]' '[:lower:]')"
        touch "$ASSOC"
        grep -v "^${chave}=" "$ASSOC" > "$ASSOC.tmp" 2>/dev/null; mv "$ASSOC.tmp" "$ASSOC"
        echo "${chave}=$3" >> "$ASSOC"
        echo "$chave → ambiente $3"
        ;;
    esquecer-modo)
        [ -n "${2:-}" ] || { echo "uso: win-launcher esquecer-modo ARQUIVO" >&2; exit 2; }
        esquecer_modo "$(realpath "$2")"
        ;;
    -h|--help|"")
        sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'
        [ -n "${1:-}" ] || exit 2
        ;;
    *)
        abrir "$@"
        ;;
esac
