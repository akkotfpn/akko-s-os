#!/usr/bin/env python3
"""
teste_iso.py — testa a ISO do Akko's OS (edição Debian) no QEMU com KVM.

Quatro boots:
  funcional   kernel/initrd da ISO + akkos.teste=1: o serviço de teste dentro
              do sistema verifica cada módulo e pede prints pela serial;
              daqui tentamos acessar um servidor do sistema (o firewall tem
              que bloquear); o áudio da VM é gravado e analisado
  uefi        boot pelo menu do GRUB em UEFI (OVMF)
  uefi-sb     UEFI com Secure Boot ligado (chaves da Microsoft)
  bios        boot pelo menu do GRUB em BIOS (SeaBIOS)

Saída em <pasta>: *.png, serial-*.log, audio-funcional.wav (resumo),
resultado.json. Código 0 só se tudo passar.

Uso: teste_iso.py <iso> <pasta-saida>
"""

import json
import os
import re
import shutil
import socket
import subprocess
import sys
import time
import wave

KVM = ["-enable-kvm", "-cpu", "host"] if os.access("/dev/kvm", os.W_OK) else ["-cpu", "max"]


def achar(*caminhos):
    for c in caminhos:
        if os.path.exists(c):
            return c
    return None


OVMF_CODE = achar("/usr/share/OVMF/OVMF_CODE_4M.fd", "/usr/share/OVMF/OVMF_CODE.fd")
OVMF_VARS = achar("/usr/share/OVMF/OVMF_VARS_4M.fd", "/usr/share/OVMF/OVMF_VARS.fd")
OVMF_SB_CODE = achar("/usr/share/OVMF/OVMF_CODE_4M.secboot.fd", "/usr/share/OVMF/OVMF_CODE.secboot.fd")
OVMF_SB_VARS = achar("/usr/share/OVMF/OVMF_VARS_4M.ms.fd", "/usr/share/OVMF/OVMF_VARS.ms.fd")


class VM:
    def __init__(self, nome, saida, args):
        self.nome, self.saida = nome, saida
        self.ser_path = os.path.join(saida, f".{nome}.ser")
        self.qmp_path = os.path.join(saida, f".{nome}.qmp")
        for p in (self.ser_path, self.qmp_path):
            if os.path.exists(p):
                os.unlink(p)
        cmd = ["qemu-system-x86_64", *args, "-display", "none",
               "-serial", f"unix:{self.ser_path},server=on,wait=off",
               "-qmp", f"unix:{self.qmp_path},server=on,wait=off"]
        print("+", " ".join(cmd), flush=True)
        self.proc = subprocess.Popen(cmd)
        self.ser = self._conectar(self.ser_path)
        self.ser.settimeout(0.3)
        self.qmp = self._conectar(self.qmp_path).makefile("rwb")
        self.qmp.readline()
        self._qmp({"execute": "qmp_capabilities"})
        self.buf = bytearray()
        self.log = open(os.path.join(saida, f"serial-{nome}.log"), "wb")
        self.n = 0

    def _conectar(self, caminho):
        for _ in range(300):
            try:
                s = socket.socket(socket.AF_UNIX)
                s.connect(caminho)
                return s
            except OSError:
                time.sleep(0.1)
        raise RuntimeError(f"sem conexão: {caminho}")

    def _qmp(self, obj):
        self.qmp.write((json.dumps(obj) + "\n").encode())
        self.qmp.flush()
        while True:
            linha = self.qmp.readline()
            if not linha:
                return None
            msg = json.loads(linha)
            if "return" in msg or "error" in msg:
                return msg

    def ler(self, segundos=0.5):
        fim = time.time() + segundos
        novas = []
        while time.time() < fim:
            try:
                dados = self.ser.recv(65536)
                if not dados:
                    time.sleep(0.1)
                    continue
                inicio = len(self.buf)
                self.buf.extend(dados)
                self.log.write(dados)
                self.log.flush()
                novas.append(inicio)
            except socket.timeout:
                pass
            except OSError:
                time.sleep(0.2)
        return novas

    def print(self, rotulo):
        self.n += 1
        ppm = os.path.join(self.saida, f"{self.nome}-{self.n:02d}-{rotulo}.ppm")
        self._qmp({"execute": "screendump", "arguments": {"filename": ppm}})
        time.sleep(0.8)
        try:
            from PIL import Image
            png = ppm[:-4] + ".png"
            Image.open(ppm).save(png, optimize=True)
            os.unlink(ppm)
            print(f"print: {png}", flush=True)
        except Exception as erro:   # noqa: BLE001
            print(f"print falhou: {erro}", flush=True)

    def vivo(self):
        return self.proc.poll() is None

    def encerrar(self):
        if self.vivo():
            try:
                self._qmp({"execute": "quit"})
            except Exception:   # noqa: BLE001
                pass
            for _ in range(20):
                if not self.vivo():
                    break
                time.sleep(0.5)
            if self.vivo():
                self.proc.kill()
        self.log.close()


def extrair_da_iso(iso, destino):
    os.makedirs(destino, exist_ok=True)
    for interno in ("/live/vmlinuz", "/live/initrd.img", "/boot/grub/grub.cfg"):
        alvo = os.path.join(destino, os.path.basename(interno))
        subprocess.run(["xorriso", "-osirrox", "on", "-indev", iso, "-extract", interno, alvo],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    grub = open(os.path.join(destino, "grub.cfg")).read()
    m = re.search(r'menuentry "Iniciar o Akko\'s OS".*?\n\s*linux\s+(\S+)\s+(.*?)\n', grub, re.S)
    if not m:
        raise RuntimeError("entrada principal não encontrada no grub.cfg da ISO")
    return os.path.join(destino, "vmlinuz"), os.path.join(destino, "initrd.img"), m.group(2).strip(), grub


def analisar_audio(caminho):
    """Mede quanto tempo de som (não silêncio) a VM produziu."""
    if not os.path.exists(caminho):
        return {"ok": False, "detalhe": "sem gravação"}
    w = wave.open(caminho)
    taxa, canais, largura, n = w.getframerate(), w.getnchannels(), w.getsampwidth(), w.getnframes()
    import array
    dados = array.array("h")
    dados.frombytes(w.readframes(n))
    bloco = taxa * canais // 10   # janelas de 100 ms
    ativos, picos = 0, 0
    for i in range(0, len(dados), bloco):
        janela = dados[i:i + bloco]
        if not janela:
            continue
        pico = max(abs(min(janela)), abs(max(janela)))
        picos = max(picos, pico)
        if pico > 300:   # acima de ~-40 dBFS
            ativos += 1
    segundos = ativos / 10
    return {"ok": segundos >= 2.0, "detalhe": f"{segundos:.1f} s de som em {n / taxa:.0f} s gravados; "
            f"pico {picos} ({taxa} Hz, {canais} ch, {largura * 8} bits)"}


def testar_firewall_de_fora(porta):
    """Conecta na porta encaminhada pelo QEMU e pede uma página. Com o firewall
    funcionando, o sistema descarta o pacote e nada volta."""
    try:
        s = socket.create_connection(("127.0.0.1", porta), timeout=8)
        s.settimeout(8)
        s.sendall(b"GET / HTTP/1.0\r\nHost: akkos\r\n\r\n")
        resposta = s.recv(64)
        s.close()
        if resposta.startswith(b"HTTP"):
            return {"ok": False, "detalhe": f"o servidor RESPONDEU de fora: {resposta[:40]!r}"}
        return {"ok": True, "detalhe": "conexão de fora sem resposta (bloqueada)"}
    except (socket.timeout, ConnectionResetError, ConnectionRefusedError, BrokenPipeError, OSError) as erro:
        return {"ok": True, "detalhe": f"conexão de fora bloqueada ({type(erro).__name__})"}


def boot_funcional(iso, saida, resultado):
    kernel, initrd, append, grub = extrair_da_iso(iso, os.path.join(saida, ".iso"))
    resultado["grub_cfg_entradas"] = re.findall(r'menuentry "([^"]+)"', grub)
    append = f"{append} akkos.teste=1 console=tty0 console=ttyS0,115200"
    audio = os.path.join(saida, ".audio-funcional.wav")
    vars_ = os.path.join(saida, ".vars-funcional.fd")
    shutil.copy(OVMF_VARS, vars_)
    vm = VM("funcional", saida, [
        "-machine", "q35", *KVM, "-smp", "4", "-m", "6144",
        "-drive", f"if=pflash,format=raw,readonly=on,file={OVMF_CODE}",
        "-drive", f"if=pflash,format=raw,file={vars_}",
        "-kernel", kernel, "-initrd", initrd, "-append", append,
        "-drive", f"file={iso},media=cdrom,readonly=on",
        "-vga", "std",
        "-netdev", "user,id=n0,hostfwd=tcp:127.0.0.1:18080-:8080", "-device", "virtio-net-pci,netdev=n0",
        "-audiodev", f"wav,id=a0,path={audio}", "-device", "ich9-intel-hda", "-device", "hda-output,audiodev=a0",
        "-device", "qemu-xhci", "-device", "usb-tablet",
    ])
    checks = {}
    inicio = time.time()
    limite = inicio + 45 * 60
    processadas = 0
    fim = False
    printou_boot = False
    while time.time() < limite and vm.vivo() and not fim:
        vm.ler(0.5)
        if not printou_boot and time.time() - inicio > 25:
            vm.print("boot")   # Plymouth ou início da sessão
            printou_boot = True
        linhas = vm.buf.decode("utf-8", "replace").split("\n")[:-1]   # a última pode estar incompleta
        novas, processadas = linhas[processadas:], len(linhas)
        for linha in novas:
            linha = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", linha).strip("\r")
            i = linha.find("AKKOS-")
            if i < 0:
                continue
            linha = linha[i:]
            partes = linha.split("|", 3)
            if partes[0] == "AKKOS-CHECK" and len(partes) >= 3:
                checks[partes[1]] = {"ok": partes[2] == "ok", "detalhe": partes[3] if len(partes) > 3 else ""}
                print(f"  {partes[1]:24} {partes[2]:7} {checks[partes[1]]['detalhe'][:160]}", flush=True)
            elif partes[0] == "AKKOS-SHOT" and len(partes) >= 2:
                vm.print(partes[1].strip())
            elif partes[0].startswith("AKKOS-FW-PRONTO"):
                checks["firewall_bloqueia_de_fora"] = testar_firewall_de_fora(18080)
                print(f"  firewall de fora: {checks['firewall_bloqueia_de_fora']}", flush=True)
            elif partes[0].startswith("AKKOS-TESTE-FIM"):
                fim = True
    tempo = time.time() - inicio
    for _ in range(60):   # espera o poweroff gravar o fim do áudio
        if not vm.vivo():
            break
        vm.ler(0.5)
    vm.encerrar()
    checks["audio_gravado"] = analisar_audio(audio)
    resultado["etapas"]["funcional"] = {"ok": fim, "detalhe": f"{tempo / 60:.1f} min; teste {'concluído' if fim else 'NÃO terminou'}"}
    resultado["verificacoes"].update(checks)


def boot_firmware(iso, saida, resultado, nome, args_firmware, esperar=150):
    vm = VM(nome, saida, ["-machine", "q35" + (",smm=on" if nome == "uefi-sb" else ""), *KVM,
                          "-smp", "2", "-m", "4096", *args_firmware,
                          "-drive", f"file={iso},media=cdrom,readonly=on",
                          "-boot", "d", "-vga", "std",
                          "-netdev", "user,id=n0", "-device", "virtio-net-pci,netdev=n0"])
    time.sleep(6)
    vm.print("grub")
    time.sleep(esperar)
    vm.print("sistema")
    vivo = vm.vivo()
    vm.encerrar()
    resultado["etapas"][nome] = {"ok": vivo, "detalhe": "prints do menu e do sistema; conferir visualmente"}


def main():
    iso, saida = sys.argv[1], sys.argv[2]
    os.makedirs(saida, exist_ok=True)
    resultado = {"iso": os.path.basename(iso), "tamanho_gb": round(os.path.getsize(iso) / 1e9, 2),
                 "etapas": {}, "verificacoes": {}}

    boot_funcional(iso, saida, resultado)

    vars_uefi = os.path.join(saida, ".vars-uefi.fd")
    shutil.copy(OVMF_VARS, vars_uefi)
    boot_firmware(iso, saida, resultado, "uefi", [
        "-drive", f"if=pflash,format=raw,readonly=on,file={OVMF_CODE}",
        "-drive", f"if=pflash,format=raw,file={vars_uefi}"])
    if OVMF_SB_CODE and OVMF_SB_VARS:
        vars_sb = os.path.join(saida, ".vars-sb.fd")
        shutil.copy(OVMF_SB_VARS, vars_sb)
        boot_firmware(iso, saida, resultado, "uefi-sb", [
            "-global", "driver=cfi.pflash01,property=secure,value=on",
            "-drive", f"if=pflash,format=raw,unit=0,readonly=on,file={OVMF_SB_CODE}",
            "-drive", f"if=pflash,format=raw,unit=1,file={vars_sb}"])
    boot_firmware(iso, saida, resultado, "bios", [])

    obrigatorias = ["os_release_nome", "sessao", "sons_gerados", "pipewire", "som_notify", "rede_nm",
                    "internet_tls", "firewall_ativo", "firewall_local_responde", "firewall_bloqueia_de_fora",
                    "sysctl", "apparmor", "binfmt_exe", "janela_arquivos", "janela_rede", "janela_navegador",
                    "wine_prefixo", "janela_windows", "audio_gravado"]
    faltando = [c for c in obrigatorias if c not in resultado["verificacoes"]]
    resultado["faltando"] = faltando
    resultado["sucesso"] = (not faltando and all(v["ok"] for v in resultado["etapas"].values())
                            and all(v["ok"] for v in resultado["verificacoes"].values()))
    with open(os.path.join(saida, "resultado.json"), "w") as f:
        json.dump(resultado, f, indent=2, ensure_ascii=False)
    print(json.dumps(resultado, indent=2, ensure_ascii=False))
    return 0 if resultado["sucesso"] else 1


if __name__ == "__main__":
    sys.exit(main())
