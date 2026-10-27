#!/usr/bin/env python3
"""
qemu_install_test.py — teste de ponta a ponta da ISO do Akko's OS Desktop.

  1. Boota a ISO (UEFI/OVMF, KVM) com um disco virtual vazio e descartável.
  2. Espera a instalação automática terminar (a ISO de teste desliga sozinha).
  3. Boota o disco instalado, sem a ISO.
  4. Entra pelo console serial com o usuário de teste e roda verificações.
  5. Tira prints da tela ao longo do caminho.

Saída em <pasta>/: serial-*.log, *.png, resultado.json. Código de saída 0 só
se todas as verificações passarem.

Uso: qemu_install_test.py <iso> <pasta-saida>
"""

import json
import os
import re
import shutil
import socket
import subprocess
import sys
import time

USER = "akkoteste"
PASS = "akkos-ci-teste"

INSTALL_TIMEOUT = 75 * 60
BOOT_TIMEOUT = 20 * 60


def find_ovmf():
    pairs = [
        ("/usr/share/OVMF/OVMF_CODE_4M.fd", "/usr/share/OVMF/OVMF_VARS_4M.fd"),
        ("/usr/share/OVMF/OVMF_CODE.fd", "/usr/share/OVMF/OVMF_VARS.fd"),
        ("/usr/share/edk2/ovmf/OVMF_CODE.fd", "/usr/share/edk2/ovmf/OVMF_VARS.fd"),
    ]
    for code, vars_ in pairs:
        if os.path.exists(code) and os.path.exists(vars_):
            return code, vars_
    sys.exit("OVMF não encontrado (instale o pacote ovmf)")


class VM:
    def __init__(self, out, name, args):
        self.out, self.name = out, name
        self.serial_log = os.path.join(out, f"serial-{name}.log")
        self.qmp_path = os.path.join(out, f"qmp-{name}.sock")
        self.ser_path = os.path.join(out, f"ser-{name}.sock")
        for p in (self.qmp_path, self.ser_path):
            if os.path.exists(p):
                os.unlink(p)
        cmd = ["qemu-system-x86_64", *args,
               "-serial", f"unix:{self.ser_path},server=on,wait=off",
               "-qmp", f"unix:{self.qmp_path},server=on,wait=off",
               "-display", "none"]
        print("+", " ".join(cmd), flush=True)
        self.proc = subprocess.Popen(cmd)
        self.ser = self._connect(self.ser_path)
        self.ser.settimeout(0.5)
        self.qmp = self._connect(self.qmp_path)
        self.qmp.settimeout(10)
        self._qmp_cmd({"execute": "qmp_capabilities"}, greet=True)
        self.buf = bytearray()
        self.log = open(self.serial_log, "wb")
        self.shots = 0

    def _connect(self, path):
        for _ in range(300):
            try:
                s = socket.socket(socket.AF_UNIX)
                s.connect(path)
                return s
            except OSError:
                time.sleep(0.1)
        raise RuntimeError(f"sem conexão em {path}")

    def _qmp_cmd(self, obj, greet=False):
        f = self.qmp.makefile("rwb")
        if greet:
            f.readline()
        f.write((json.dumps(obj) + "\n").encode())
        f.flush()
        while True:
            line = f.readline()
            if not line:
                return None
            msg = json.loads(line)
            if "return" in msg or "error" in msg:
                return msg

    def pump(self, seconds=0.5):
        end = time.time() + seconds
        while time.time() < end:
            try:
                chunk = self.ser.recv(65536)
                if not chunk:
                    time.sleep(0.2)
                    continue
                self.buf.extend(chunk)
                self.log.write(chunk)
                self.log.flush()
            except socket.timeout:
                pass
            except OSError:
                time.sleep(0.2)

    def wait_for(self, pattern, timeout, since=0):
        rx = re.compile(pattern.encode() if isinstance(pattern, str) else pattern)
        end = time.time() + timeout
        last_shot = time.time()
        while time.time() < end:
            self.pump(1)
            if rx.search(self.buf, since):
                return True
            if self.proc.poll() is not None:
                return False
            if time.time() - last_shot > 180:
                self.screenshot("progresso")
                last_shot = time.time()
        return False

    def send(self, text):
        self.ser.sendall(text.encode())

    def screenshot(self, label):
        self.shots += 1
        ppm = os.path.join(self.out, f"{self.name}-{self.shots:02d}-{label}.ppm")
        try:
            self._qmp_cmd({"execute": "screendump", "arguments": {"filename": ppm}})
            time.sleep(1)
            try:
                from PIL import Image
                png = ppm[:-4] + ".png"
                Image.open(ppm).save(png)
                os.unlink(ppm)
                print(f"print: {png}", flush=True)
            except Exception as e:
                print(f"print salvo como PPM ({e})", flush=True)
        except Exception as e:
            print(f"falha no print: {e}", flush=True)

    def wait_exit(self, timeout):
        end = time.time() + timeout
        last_shot = time.time()
        while time.time() < end:
            self.pump(2)
            if self.proc.poll() is not None:
                return True
            if time.time() - last_shot > 240:
                self.screenshot("instalando")
                last_shot = time.time()
        return False

    def kill(self):
        if self.proc.poll() is None:
            try:
                self._qmp_cmd({"execute": "quit"})
            except Exception:
                pass
            time.sleep(2)
            if self.proc.poll() is None:
                self.proc.kill()
        self.log.close()


def main():
    iso, out = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)
    code, vars_tpl = find_ovmf()
    vars_ = os.path.join(out, "OVMF_VARS.fd")
    shutil.copy(vars_tpl, vars_)
    disk = os.path.join(out, "disco-teste.qcow2")
    subprocess.run(["qemu-img", "create", "-f", "qcow2", disk, "80G"], check=True)

    accel = ["-enable-kvm", "-cpu", "host"] if os.access("/dev/kvm", os.W_OK) else ["-cpu", "max"]
    common = ["-machine", "q35", *accel, "-smp", "4", "-m", "8192",
              "-drive", f"if=pflash,format=raw,readonly=on,file={code}",
              "-drive", f"if=pflash,format=raw,file={vars_}",
              "-drive", f"file={disk},if=virtio,format=qcow2,cache=unsafe",
              "-netdev", "user,id=n0", "-device", "virtio-net-pci,netdev=n0",
              "-vga", "std",
              "-device", "qemu-xhci", "-device", "usb-tablet"]

    result = {"etapas": {}, "verificacoes": {}}

    def step(name, ok, detail=""):
        result["etapas"][name] = {"ok": bool(ok), "detalhe": detail}
        print(f"\n### {name}: {'OK' if ok else 'FALHOU'} {detail}\n", flush=True)
        return ok

    # ---- 1+2. instalação --------------------------------------------------
    t0 = time.time()
    vm = VM(out, "instalacao", [*common, "-cdrom", iso, "-boot", "order=d", "-no-reboot"])
    time.sleep(90)
    vm.screenshot("instalador")
    finished = vm.wait_exit(INSTALL_TIMEOUT)
    vm.kill()
    ok = step("instalacao", finished, f"{(time.time() - t0) / 60:.1f} min")
    if not ok:
        return finish(out, result)

    # ---- 3. primeiro boot do disco ----------------------------------------
    t0 = time.time()
    vm = VM(out, "boot", common)
    booted = vm.wait_for(r"login:", BOOT_TIMEOUT)
    step("boot_instalado", booted, f"{(time.time() - t0) / 60:.1f} min até o login no serial")
    vm.screenshot("primeiro-boot")
    if booted:
        issue = vm.buf.decode("utf-8", "replace")
        step("nome_no_login", "Akko's OS" in issue, "texto antes do login contém Akko's OS")

        # ---- 4. login e verificações --------------------------------------
        mark = len(vm.buf)
        vm.send(USER + "\n")
        vm.wait_for(r"[Ss]enha|[Pp]assword", 60, mark)
        vm.send(PASS + "\n")
        logged = vm.wait_for(r"\$ ", 90, mark)
        step("login_serial", logged)
        if logged:
            checks = {
                "os_release": ("grep -E '^(NAME|PRETTY_NAME|VARIANT)=' /usr/lib/os-release", r"NAME=\"Akko's OS\""),
                "akkos_cli": ("akkos version", r"Akko's OS Desktop"),
                "imagem_atualizacao": ("bootc status 2>&1 | head -20", r"ghcr\.io/akkotfpn/akkos"),
                "idioma": ("localectl status | head -3; echo LANG=$LANG", r"pt_BR"),
                "papel_de_parede": ("ls /usr/share/wallpapers/AkkoOS/contents/images_dark/", r"3840x2160\.png"),
                "sessao_grafica": ("systemctl is-active display-manager.service; loginctl list-sessions --no-legend", r"\bactive\b"),
                "gpu": ("akkos gpu", r"Placas de vídeo"),
                "firewall": ("systemctl is-active firewalld", r"\bactive\b"),
                "flatpak": ("flatpak remotes --columns=name", r"flathub"),
            }
            for name, (cmd, expect) in checks.items():
                mark = len(vm.buf)
                vm.send(f"echo '<<<{name}'; {cmd}; echo '>>>{name}'\n")
                vm.wait_for(re.escape(f">>>{name}") + r"\r?\n", 120, mark)
                seg = vm.buf[mark:].decode("utf-8", "replace")
                body = seg.split(f"<<<{name}", 1)[-1].split(f">>>{name}", 1)[0]
                passed = re.search(expect, body) is not None
                result["verificacoes"][name] = {"ok": passed, "comando": cmd, "saida": body.strip()[-1500:]}
                print(f"--- {name}: {'OK' if passed else 'FALHOU'}\n{body.strip()}\n", flush=True)

        time.sleep(60)   # tempo pra sessão gráfica aparecer
        vm.screenshot("sessao-grafica")
        time.sleep(120)
        vm.screenshot("sessao-grafica-2")
    vm.kill()
    return finish(out, result)


def finish(out, result):
    all_ok = all(v["ok"] for v in result["etapas"].values()) and \
        all(v["ok"] for v in result["verificacoes"].values())
    result["sucesso"] = all_ok
    with open(os.path.join(out, "resultado.json"), "w") as f:
        json.dump(result, f, indent=2, ensure_ascii=False)
    print(json.dumps(result, indent=2, ensure_ascii=False))
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
