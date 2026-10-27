#!/usr/bin/env python3
"""Publica o resultado.json do teste de instalação como anotações do GitHub Actions."""

import json
import sys


def esc(s):
    return s.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def main():
    try:
        r = json.load(open(sys.argv[1]))
    except Exception as e:
        print(f"::error title=Teste de instalação::sem resultado.json ({e})")
        return 1

    lines = []
    for name, v in r.get("etapas", {}).items():
        lines.append(f"{'OK ' if v['ok'] else 'FALHOU'} etapa {name} {v.get('detalhe', '')}")
    for name, v in r.get("verificacoes", {}).items():
        lines.append(f"{'OK ' if v['ok'] else 'FALHOU'} {name}")
    level = "notice" if r.get("sucesso") else "error"
    print(f"::{level} title=Teste de instalação - resumo::{esc(chr(10).join(lines))}")

    # saída de cada verificação (até 10 anotações por nível por etapa)
    detail = []
    for name, v in r.get("verificacoes", {}).items():
        detail.append(f"== {name} ({'ok' if v['ok'] else 'FALHOU'}) $ {v['comando']}\n{v['saida'][-600:]}")
    if detail:
        print(f"::notice title=Teste de instalação - saídas::{esc(chr(10).join(detail))[:60000]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
