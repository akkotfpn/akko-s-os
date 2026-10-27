#!/usr/bin/env bash
# ci-run.sh — roda um comando no CI e publica a evidência como anotação.
#
#   scripts/ci-run.sh "Título" [--notice N] comando args...
#
# Sempre: saída completa no log do job.
# Se falhar: anotação de erro com o final do log (sem linhas de progresso de
# download, até ~3500 caracteres: as anotações têm limite de tamanho).
# Com --notice N: em caso de sucesso, anotação com as últimas N linhas.
# As anotações aparecem na aba Actions e também pela API de check-runs.

set -uo pipefail

title="$1"; shift
notice=0
if [ "${1:-}" = "--notice" ]; then notice="$2"; shift 2; fi

log="$(mktemp)"
"$@" 2>&1 | tee "$log"
rc=${PIPESTATUS[0]}

escape() { sed -e 's/%/%25/g' -e 's/\r/%0D/g' | sed ':a;N;$!ba;s/\n/%0A/g'; }

useful() {   # tira ruído e corta pelo fim
    grep -v -E 'Copying (blob|config)|Writing manifest|Getting image source|Storing signatures' "$log" |
        tail -n "$1" | tail -c 3500
}

if [ "$rc" -ne 0 ]; then
    echo "::error title=${title} (código ${rc})::$(useful 80 | escape)"
elif [ "$notice" -gt 0 ]; then
    echo "::notice title=${title}::$(useful "$notice" | escape)"
fi
rm -f "$log"
exit "$rc"
