#!/usr/bin/env python3
"""
test-qemu.py — boota a imagem do Akko's OS no QEMU (UEFI/OVMF, como no Proxmox),
espera o shell, roda comandos pela serial e salva um print da tela.

Uso: test-qemu.py <akkos.iso|akkos.img> <saida-dir> [comando ...]
"""

import os
import socket
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
QEMU = os.path.join(ROOT, "src/qemu/build/qemu-system-x86_64")
BIOS_DIR = os.path.join(ROOT, "src/qemu/pc-bios")
FW = os.path.join(ROOT, "tools/fw")


def main():
    image, out = sys.argv[1], sys.argv[2]
    commands = sys.argv[3:] or ["akko"]
    os.makedirs(out, exist_ok=True)
    ser_sock = os.path.join(out, "serial.sock")
    mon_sock = os.path.join(out, "monitor.sock")
    for s in (ser_sock, mon_sock):
        if os.path.exists(s):
            os.unlink(s)

    vars_copy = os.path.join(out, "OVMF_VARS.fd")
    with open(os.path.join(FW, "OVMF_VARS.fd"), "rb") as a, open(vars_copy, "wb") as b:
        b.write(a.read())

    drive = (["-drive", f"file={image},media=cdrom,readonly=on,if=ide"]
             if image.endswith(".iso") else
             ["-drive", f"file={image},format=raw,if=virtio,readonly=on"])

    # parecido com uma VM padrão do Proxmox: q35, OVMF, VGA std, virtio-net
    cmd = [QEMU, "-L", BIOS_DIR, "-machine", "q35", "-m", "512", "-smp", "2",
           "-drive", f"if=pflash,format=raw,readonly=on,file={FW}/OVMF_CODE.fd",
           "-drive", f"if=pflash,format=raw,file={vars_copy}",
           *drive,
           "-vga", "std", "-display", "none",
           "-netdev", "hubport,id=n0,hubid=0",   # placa virtio sem rede real (Marco 3)
           "-device", "virtio-net-pci,netdev=n0",
           "-serial", f"unix:{ser_sock},server=on,wait=off",
           "-monitor", f"unix:{mon_sock},server=on,wait=off",
           "-no-reboot"]
    t0 = time.time()
    qemu = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

    def connect(path):
        for _ in range(100):
            try:
                s = socket.socket(socket.AF_UNIX)
                s.connect(path)
                return s
            except OSError:
                time.sleep(0.1)
        raise RuntimeError(f"não conectou em {path}")

    ser = connect(ser_sock)
    mon = connect(mon_sock)
    ser.settimeout(0.5)
    log = bytearray()

    def read_until(marker, timeout):
        end = time.time() + timeout
        while time.time() < end:
            try:
                chunk = ser.recv(4096)
                if chunk:
                    log.extend(chunk)
            except socket.timeout:
                pass
            if marker in log:
                return True
        return False

    ok = read_until(b"# ", 600)   # TCG sem KVM é lento; dá tempo
    boot_s = time.time() - t0
    print(f"shell apareceu: {ok} (em {boot_s:.1f}s de emulação sem KVM)")

    for c in commands:
        mark = len(log)
        ser.sendall(c.encode() + b"\n")
        time.sleep(0.5)
        read_until(b"# ", 30)
        print(f"--- $ {c}")
        print(log[mark:].decode("utf-8", "replace"))

    time.sleep(1)
    ppm = os.path.join(out, "screen.ppm")
    mon.sendall(f"screendump {ppm}\n".encode())
    time.sleep(2)

    if "--poweroff" in os.environ.get("AKKOS_TEST", "--poweroff"):
        ser.sendall(b"poweroff\n")
        try:
            qemu.wait(timeout=60)
            print(f"poweroff: QEMU saiu sozinho (código {qemu.returncode})")
        except subprocess.TimeoutExpired:
            print("poweroff: QEMU NÃO desligou, matando")
            qemu.kill()

    with open(os.path.join(out, "serial.log"), "wb") as f:
        f.write(log)
    try:
        from PIL import Image
        Image.open(ppm).save(os.path.join(out, "screen.png"))
        print("print da tela:", os.path.join(out, "screen.png"))
    except Exception as e:
        print("sem print da tela:", e)


if __name__ == "__main__":
    main()
