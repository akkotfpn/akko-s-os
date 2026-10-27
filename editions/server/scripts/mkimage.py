#!/usr/bin/env python3
"""
mkimage.py — gera as imagens bootáveis do Akko's OS, sem ferramentas externas.

  akkos.iso  ISO9660 + El Torito (UEFI). É só subir no Proxmox e dar boot.
  akkos.img  Disco bruto GPT com partição EFI (ESP). Pra importar como disco.

Em ambos, o kernel (com o initramfs embutido) vai em \\EFI\\BOOT\\BOOTX64.EFI,
o caminho padrão que todo firmware UEFI procura. Não há bootloader: o próprio
kernel é um executável EFI (EFI stub).

Uso: mkimage.py <kernel bzImage> <saida-dir>
"""

import os
import struct
import sys
import time
import uuid
import zlib

SECTOR = 512


# --------------------------------------------------------------------------
# FAT16
# --------------------------------------------------------------------------

def fat16_image(files, size_bytes, sectors_per_cluster, label=b"AKKOS"):
    """files: {"EFI/BOOT/BOOTX64.EFI": bytes}. Nomes 8.3 em maiúsculas."""
    total = size_bytes // SECTOR
    reserved = 4
    nfats = 2
    root_entries = 512
    root_secs = root_entries * 32 // SECTOR
    cluster_bytes = sectors_per_cluster * SECTOR

    # tamanho da FAT: iterar até estabilizar
    fat_secs = 1
    while True:
        data_secs = total - reserved - nfats * fat_secs - root_secs
        clusters = data_secs // sectors_per_cluster
        need = ((clusters + 2) * 2 + SECTOR - 1) // SECTOR
        if need <= fat_secs:
            break
        fat_secs = need
    assert 4085 <= clusters < 65525, f"FAT16 inválido: {clusters} clusters"

    img = bytearray(size_bytes)
    fat = [0] * (clusters + 2)
    fat[0] = 0xFFF8
    fat[1] = 0xFFFF
    next_free = [2]
    data_start = reserved + nfats * fat_secs + root_secs

    def alloc(data):
        """Grava dados numa cadeia de clusters. Retorna o primeiro cluster."""
        if not data:
            return 0
        n = (len(data) + cluster_bytes - 1) // cluster_bytes
        first = next_free[0]
        assert first + n <= clusters + 2, "imagem FAT pequena demais"
        for i in range(n):
            c = first + i
            fat[c] = c + 1 if i < n - 1 else 0xFFFF
            off = (data_start + (c - 2) * sectors_per_cluster) * SECTOR
            chunk = data[i * cluster_bytes:(i + 1) * cluster_bytes]
            img[off:off + len(chunk)] = chunk
        next_free[0] += n
        return first

    def name83(name):
        base, _, ext = name.upper().partition(".")
        assert len(base) <= 8 and len(ext) <= 3, f"nome não é 8.3: {name}"
        return base.ljust(8).encode() + ext.ljust(3).encode()

    def dirent(name11, attr, cluster, size):
        t = time.localtime()
        ftime = (t.tm_hour << 11) | (t.tm_min << 5) | (t.tm_sec // 2)
        fdate = ((t.tm_year - 1980) << 9) | (t.tm_mon << 5) | t.tm_mday
        return struct.pack("<11sBBBHHHHHHHI", name11, attr, 0, 0, ftime, fdate,
                           fdate, 0, ftime, fdate, cluster, size)

    # árvore de diretórios
    tree = {}
    for path, data in files.items():
        node = tree
        parts = path.split("/")
        for p in parts[:-1]:
            node = node.setdefault(p, {})
        node[parts[-1]] = data

    def write_dir(node, self_cluster, parent_cluster):
        """Escreve um subdiretório (recursivo). Retorna os bytes do diretório."""
        entries = []
        if self_cluster is not None:
            entries.append(dirent(b".          ", 0x10, self_cluster, 0))
            entries.append(dirent(b"..         ", 0x10, parent_cluster, 0))
        for name, child in node.items():
            if isinstance(child, dict):
                # reserva o cluster do subdiretório antes de preencher
                c = alloc(b"\0" * cluster_bytes)
                body = write_dir(child, c, self_cluster or 0)
                assert len(body) <= cluster_bytes
                off = (data_start + (c - 2) * sectors_per_cluster) * SECTOR
                img[off:off + len(body)] = body
                entries.append(dirent(name83(name), 0x10, c, 0))
            else:
                c = alloc(child)
                entries.append(dirent(name83(name), 0x20, c, len(child)))
        return b"".join(entries)

    root = dirent(label.ljust(11)[:11], 0x08, 0, 0) + write_dir(tree, None, 0)
    off = (reserved + nfats * fat_secs) * SECTOR
    img[off:off + len(root)] = root

    fat_bytes = struct.pack(f"<{len(fat)}H", *fat)
    for i in range(nfats):
        off = (reserved + i * fat_secs) * SECTOR
        img[off:off + len(fat_bytes)] = fat_bytes

    # setor de boot (BPB)
    bs = bytearray(SECTOR)
    bs[0:3] = b"\xEB\x3C\x90"
    bs[3:11] = b"AKKOS1.0"
    struct.pack_into("<HBHBHHBHHHII", bs, 11,
                     SECTOR, sectors_per_cluster, reserved, nfats, root_entries,
                     total if total < 65536 else 0, 0xF8, fat_secs, 63, 255, 0,
                     total if total >= 65536 else 0)
    struct.pack_into("<BBBI11s8s", bs, 36, 0x80, 0, 0x29,
                     zlib.crc32(b"akkos") & 0xFFFFFFFF,
                     label.ljust(11)[:11], b"FAT16   ")
    bs[510:512] = b"\x55\xAA"
    img[0:SECTOR] = bs
    return bytes(img)


# --------------------------------------------------------------------------
# Disco GPT com ESP
# --------------------------------------------------------------------------

ESP_TYPE = uuid.UUID("C12A7328-F81F-11D2-BA4B-00A0C93EC93B")


def gpt_disk(esp, disk_bytes):
    nsec = disk_bytes // SECTOR
    first_lba = 2048
    esp_secs = len(esp) // SECTOR
    last_usable = nsec - 34
    assert first_lba + esp_secs - 1 <= last_usable

    img = bytearray(disk_bytes)

    # MBR protetor
    mbr = bytearray(SECTOR)
    struct.pack_into("<B3sB3sII", mbr, 446, 0, b"\x00\x02\x00", 0xEE,
                     b"\xFF\xFF\xFF", 1, min(nsec - 1, 0xFFFFFFFF))
    mbr[510:512] = b"\x55\xAA"
    img[0:SECTOR] = mbr

    # tabela de partições (128 entradas de 128 bytes)
    entries = bytearray(128 * 128)
    name = "Akko's OS EFI".encode("utf-16-le").ljust(72, b"\0")
    struct.pack_into("<16s16sQQQ72s", entries, 0, ESP_TYPE.bytes_le,
                     uuid.uuid4().bytes_le, first_lba,
                     first_lba + esp_secs - 1, 0, name)
    entries_crc = zlib.crc32(entries) & 0xFFFFFFFF
    disk_guid = uuid.uuid4().bytes_le

    def header(my_lba, alt_lba, entries_lba):
        h = bytearray(92)
        struct.pack_into("<8sIIIIQQQQ16sQIII", h, 0, b"EFI PART", 0x00010000, 92,
                         0, 0, my_lba, alt_lba, first_lba, last_usable,
                         disk_guid, entries_lba, 128, 128, entries_crc)
        struct.pack_into("<I", h, 16, zlib.crc32(h) & 0xFFFFFFFF)
        return bytes(h).ljust(SECTOR, b"\0")

    img[1 * SECTOR:2 * SECTOR] = header(1, nsec - 1, 2)
    img[2 * SECTOR:2 * SECTOR + len(entries)] = entries
    img[(nsec - 33) * SECTOR:(nsec - 33) * SECTOR + len(entries)] = entries
    img[(nsec - 1) * SECTOR:nsec * SECTOR] = header(nsec - 1, 1, nsec - 33)

    off = first_lba * SECTOR
    img[off:off + len(esp)] = esp
    return bytes(img)


# --------------------------------------------------------------------------
# ISO9660 + El Torito (só UEFI)
# --------------------------------------------------------------------------

ISO_BLOCK = 2048


def both16(v):
    return struct.pack("<H", v) + struct.pack(">H", v)


def both32(v):
    return struct.pack("<I", v) + struct.pack(">I", v)


def iso_date7():
    t = time.gmtime()
    return bytes([t.tm_year - 1900, t.tm_mon, t.tm_mday, t.tm_hour, t.tm_min, t.tm_sec, 0])


def iso_date17():
    return time.strftime("%Y%m%d%H%M%S", time.gmtime()).encode() + b"00\x00"


def dir_record(lba, size, name, is_dir):
    rec = bytearray(33 + len(name))
    rec[0] = len(rec) + (len(rec) % 2)
    rec[2:10] = both32(lba)
    rec[10:18] = both32(size)
    rec[18:25] = iso_date7()
    rec[25] = 2 if is_dir else 0
    rec[28:32] = both16(1)
    rec[32] = len(name)
    rec[33:] = name
    if len(rec) % 2:
        rec += b"\0"
    return bytes(rec)


def iso_image(efiboot, volume_id=b"AKKOS"):
    assert len(efiboot) % SECTOR == 0
    boot_secs = len(efiboot) // SECTOR
    assert boot_secs <= 0xFFFF, "imagem EFI precisa ter menos de 32 MiB"

    LBA_PVD, LBA_BOOTREC, LBA_TERM = 16, 17, 18
    LBA_LPATH, LBA_MPATH, LBA_ROOT, LBA_CAT, LBA_EFI = 19, 20, 21, 22, 23
    efi_blocks = (len(efiboot) + ISO_BLOCK - 1) // ISO_BLOCK
    total_blocks = LBA_EFI + efi_blocks

    root = (dir_record(LBA_ROOT, ISO_BLOCK, b"\x00", True) +
            dir_record(LBA_ROOT, ISO_BLOCK, b"\x01", True) +
            dir_record(LBA_CAT, ISO_BLOCK, b"BOOT.CAT;1", False) +
            dir_record(LBA_EFI, len(efiboot), b"EFIBOOT.IMG;1", False))

    # tabelas de caminhos (só a raiz)
    lpath = struct.pack("<BBIH", 1, 0, LBA_ROOT, 1) + b"\0\0"
    mpath = struct.pack(">BBIH", 1, 0, LBA_ROOT, 1) + b"\0\0"

    pvd = bytearray(ISO_BLOCK)
    pvd[0] = 1
    pvd[1:6] = b"CD001"
    pvd[6] = 1
    pvd[8:40] = b"AKKOS".ljust(32)
    pvd[40:72] = volume_id.ljust(32)
    pvd[80:88] = both32(total_blocks)
    pvd[120:124] = both16(1)
    pvd[124:128] = both16(1)
    pvd[128:132] = both16(ISO_BLOCK)
    pvd[132:140] = both32(10)
    struct.pack_into("<I", pvd, 140, LBA_LPATH)
    struct.pack_into(">I", pvd, 148, LBA_MPATH)
    pvd[156:190] = dir_record(LBA_ROOT, ISO_BLOCK, b"\x00", True)
    pvd[190:318] = b" " * 128
    pvd[318:446] = b"AKKO'S OS".ljust(128)
    pvd[446:574] = b" " * 128
    pvd[574:702] = b"AKKOS MKIMAGE.PY".ljust(128)
    pvd[702:813] = b" " * 111
    d = iso_date17()
    pvd[813:830] = d
    pvd[830:847] = d
    pvd[847:864] = b"0" * 16 + b"\0"
    pvd[864:881] = b"0" * 16 + b"\0"
    pvd[881] = 1

    bootrec = bytearray(ISO_BLOCK)
    bootrec[0] = 0
    bootrec[1:6] = b"CD001"
    bootrec[6] = 1
    bootrec[7:39] = b"EL TORITO SPECIFICATION".ljust(32, b"\0")
    struct.pack_into("<I", bootrec, 71, LBA_CAT)

    term = bytearray(ISO_BLOCK)
    term[0] = 255
    term[1:6] = b"CD001"
    term[6] = 1

    # catálogo de boot: entrada de validação (plataforma 0xEF = UEFI) + entrada padrão
    val = bytearray(32)
    val[0] = 1
    val[1] = 0xEF
    val[4:28] = b"AKKOS".ljust(24, b"\0")
    val[30] = 0x55
    val[31] = 0xAA
    s = sum(struct.unpack("<16H", bytes(val))) & 0xFFFF
    struct.pack_into("<H", val, 28, (-s) & 0xFFFF)
    entry = struct.pack("<BBHBBHI", 0x88, 0, 0, 0, 0, boot_secs, LBA_EFI).ljust(32, b"\0")
    cat = bytes(val) + entry

    iso = bytearray(total_blocks * ISO_BLOCK)

    def put(lba, data):
        iso[lba * ISO_BLOCK:lba * ISO_BLOCK + len(data)] = data

    put(LBA_PVD, pvd)
    put(LBA_BOOTREC, bootrec)
    put(LBA_TERM, term)
    put(LBA_LPATH, lpath)
    put(LBA_MPATH, mpath)
    put(LBA_ROOT, root)
    put(LBA_CAT, cat)
    put(LBA_EFI, efiboot)
    return bytes(iso)


# --------------------------------------------------------------------------

def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)
    kernel = open(sys.argv[1], "rb").read()
    out = sys.argv[2]
    os.makedirs(out, exist_ok=True)
    MiB = 1024 * 1024
    files = {"EFI/BOOT/BOOTX64.EFI": kernel}

    # ESP da ISO: justa (limite de 32 MiB do El Torito), clusters de 1 KiB
    esp_iso = max(8 * MiB, ((len(kernel) + 2 * MiB) // MiB + 1) * MiB)
    efiboot = fat16_image(files, esp_iso, sectors_per_cluster=2)
    with open(os.path.join(out, "akkos.iso"), "wb") as f:
        f.write(iso_image(efiboot))

    # disco: ESP de 64 MiB (folga pra crescer) num disco de 128 MiB
    esp_disk = fat16_image(files, 64 * MiB, sectors_per_cluster=4)
    with open(os.path.join(out, "akkos.img"), "wb") as f:
        f.write(gpt_disk(esp_disk, 128 * MiB))

    print(f"kernel   {len(kernel) / MiB:.1f} MiB")
    for n in ("akkos.iso", "akkos.img"):
        print(f"{n:9}{os.path.getsize(os.path.join(out, n)) / MiB:.1f} MiB")


if __name__ == "__main__":
    main()
