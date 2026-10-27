/*
 * akko-part — particionamento GPT do Akko's OS
 *
 *   akko-part install <disco>   cria GPT novo: 1 = EFI (64 MiB), 2 = dados (resto)
 *   akko-part grow <disco>      após aumentar o disco no Proxmox: move o GPT
 *                               reserva pro fim e estica a última partição
 *   akko-part show <disco>      lista as partições
 *
 * Escrito do zero (CRC32 incluso), sem depender de fdisk/sgdisk.
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/fs.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/random.h>
#include <unistd.h>

#define SECTOR 512ULL
#define NENTRIES 128
#define ENTRY_SIZE 128
#define ENTRIES_SECTORS (NENTRIES * ENTRY_SIZE / SECTOR) /* 32 */
#define MiB (1024ULL * 1024ULL)

struct gpt_header {
    char     signature[8];
    uint32_t revision;
    uint32_t header_size;
    uint32_t header_crc;
    uint32_t reserved;
    uint64_t my_lba;
    uint64_t alt_lba;
    uint64_t first_usable;
    uint64_t last_usable;
    uint8_t  disk_guid[16];
    uint64_t entries_lba;
    uint32_t n_entries;
    uint32_t entry_size;
    uint32_t entries_crc;
} __attribute__((packed));

struct gpt_entry {
    uint8_t  type_guid[16];
    uint8_t  part_guid[16];
    uint64_t first_lba;
    uint64_t last_lba;
    uint64_t attrs;
    uint16_t name[36];
} __attribute__((packed));

/* GUIDs no formato "misto" do GPT (os 3 primeiros campos little-endian) */
static const uint8_t GUID_ESP[16] = {
    0x28, 0x73, 0x2a, 0xc1, 0x1f, 0xf8, 0xd2, 0x11,
    0xba, 0x4b, 0x00, 0xa0, 0xc9, 0x3e, 0xc9, 0x3b };   /* C12A7328-F81F-11D2-BA4B-00A0C93EC93B */
static const uint8_t GUID_LINUX[16] = {
    0xaf, 0x3d, 0xc6, 0x0f, 0x83, 0x84, 0x72, 0x47,
    0x8e, 0x79, 0x3d, 0x69, 0xd8, 0x47, 0x7d, 0xe4 };   /* 0FC63DAF-8483-4772-8E79-3D69D8477DE4 */

static uint32_t crc_table[256];

static void crc_init(void)
{
    for (uint32_t i = 0; i < 256; i++) {
        uint32_t c = i;
        for (int k = 0; k < 8; k++)
            c = c & 1 ? 0xEDB88320u ^ (c >> 1) : c >> 1;
        crc_table[i] = c;
    }
}

static uint32_t crc32(const void *buf, size_t len)
{
    const uint8_t *p = buf;
    uint32_t c = 0xFFFFFFFFu;
    while (len--)
        c = crc_table[(c ^ *p++) & 0xFF] ^ (c >> 8);
    return c ^ 0xFFFFFFFFu;
}

static void die(const char *fmt, const char *arg)
{
    fprintf(stderr, "akko-part: ");
    fprintf(stderr, fmt, arg);
    fprintf(stderr, "\n");
    exit(1);
}

static void random_guid(uint8_t g[16])
{
    if (getrandom(g, 16, 0) != 16)
        die("sem aleatoriedade%s", "");
    g[7] = (g[7] & 0x0F) | 0x40;   /* versão 4 */
    g[8] = (g[8] & 0x3F) | 0x80;   /* variante */
}

static void set_name(struct gpt_entry *e, const char *name)
{
    memset(e->name, 0, sizeof(e->name));
    for (int i = 0; name[i] && i < 36; i++)
        e->name[i] = (uint8_t)name[i];
}

static void pwrite_all(int fd, const void *buf, size_t len, uint64_t off)
{
    if (pwrite(fd, buf, len, off) != (ssize_t)len)
        die("erro de escrita: %s", strerror(errno));
}

static uint64_t disk_sectors(int fd)
{
    uint64_t bytes = 0;
    if (ioctl(fd, BLKGETSIZE64, &bytes) < 0) {
        off_t end = lseek(fd, 0, SEEK_END);   /* arquivo de imagem */
        if (end < 0)
            die("não consegui o tamanho do disco%s", "");
        bytes = end;
    }
    return bytes / SECTOR;
}

/* grava MBR protetor + GPT primário e reserva */
static void write_gpt(int fd, uint64_t nsec, struct gpt_header *h, struct gpt_entry *entries)
{
    uint8_t mbr[512] = { 0 };
    uint8_t *p = mbr + 446;
    p[1] = 0x00; p[2] = 0x02; p[3] = 0x00;     /* CHS início */
    p[4] = 0xEE;                               /* GPT protetor */
    p[5] = 0xFF; p[6] = 0xFF; p[7] = 0xFF;
    uint32_t start = 1, count = nsec - 1 > 0xFFFFFFFFu ? 0xFFFFFFFFu : (uint32_t)(nsec - 1);
    memcpy(p + 8, &start, 4);
    memcpy(p + 12, &count, 4);
    mbr[510] = 0x55;
    mbr[511] = 0xAA;
    pwrite_all(fd, mbr, 512, 0);

    h->first_usable = 2 + ENTRIES_SECTORS;
    h->last_usable = nsec - 2 - ENTRIES_SECTORS;
    h->n_entries = NENTRIES;
    h->entry_size = ENTRY_SIZE;
    h->entries_crc = crc32(entries, NENTRIES * ENTRY_SIZE);

    uint8_t sec[512];
    /* primário */
    h->my_lba = 1;
    h->alt_lba = nsec - 1;
    h->entries_lba = 2;
    h->header_crc = 0;
    h->header_crc = crc32(h, sizeof(*h));
    memset(sec, 0, sizeof(sec));
    memcpy(sec, h, sizeof(*h));
    pwrite_all(fd, sec, 512, SECTOR);
    pwrite_all(fd, entries, NENTRIES * ENTRY_SIZE, 2 * SECTOR);
    /* reserva no fim do disco */
    h->my_lba = nsec - 1;
    h->alt_lba = 1;
    h->entries_lba = nsec - 1 - ENTRIES_SECTORS;
    h->header_crc = 0;
    h->header_crc = crc32(h, sizeof(*h));
    memset(sec, 0, sizeof(sec));
    memcpy(sec, h, sizeof(*h));
    pwrite_all(fd, entries, NENTRIES * ENTRY_SIZE, h->entries_lba * SECTOR);
    pwrite_all(fd, sec, 512, (nsec - 1) * SECTOR);

    fsync(fd);
    ioctl(fd, BLKRRPART);   /* kernel relê a tabela */
}

static int read_gpt(int fd, struct gpt_header *h, struct gpt_entry *entries)
{
    uint8_t sec[512];
    if (pread(fd, sec, 512, SECTOR) != 512)
        return -1;
    memcpy(h, sec, sizeof(*h));
    if (memcmp(h->signature, "EFI PART", 8) != 0)
        return -1;
    uint32_t crc = h->header_crc;
    h->header_crc = 0;
    if (crc32(h, sizeof(*h)) != crc)
        return -1;
    h->header_crc = crc;
    if (pread(fd, entries, NENTRIES * ENTRY_SIZE, h->entries_lba * SECTOR) != NENTRIES * ENTRY_SIZE)
        return -1;
    return 0;
}

static int cmd_install(const char *dev)
{
    int fd = open(dev, O_RDWR | O_CLOEXEC);
    if (fd < 0)
        die("não abri %s", dev);
    uint64_t nsec = disk_sectors(fd);
    uint64_t esp_first = MiB / SECTOR;                     /* alinhado em 1 MiB */
    uint64_t esp_last = esp_first + 64 * MiB / SECTOR - 1;
    uint64_t data_first = esp_last + 1;
    uint64_t data_last = nsec - 2 - ENTRIES_SECTORS;
    data_last -= (data_last + 1) % (MiB / SECTOR);         /* termina alinhado */
    if (data_last <= data_first + 256 * MiB / SECTOR)
        die("disco pequeno demais (mínimo ~512 MiB): %s", dev);

    static struct gpt_entry entries[NENTRIES];
    memset(entries, 0, sizeof(entries));
    memcpy(entries[0].type_guid, GUID_ESP, 16);
    random_guid(entries[0].part_guid);
    entries[0].first_lba = esp_first;
    entries[0].last_lba = esp_last;
    set_name(&entries[0], "AKKOS-EFI");
    memcpy(entries[1].type_guid, GUID_LINUX, 16);
    random_guid(entries[1].part_guid);
    entries[1].first_lba = data_first;
    entries[1].last_lba = data_last;
    set_name(&entries[1], "AKKOS-DATA");

    struct gpt_header h = { 0 };
    memcpy(h.signature, "EFI PART", 8);
    h.revision = 0x00010000;
    h.header_size = 92;
    random_guid(h.disk_guid);

    /* limpa o início (assinaturas antigas) antes de gravar */
    static uint8_t zero[1024 * 1024];
    pwrite_all(fd, zero, sizeof(zero), 0);
    write_gpt(fd, nsec, &h, entries);
    close(fd);
    printf("%s: EFI %llu MiB + dados %llu MiB\n", dev,
           (unsigned long long)((esp_last - esp_first + 1) * SECTOR / MiB),
           (unsigned long long)((data_last - data_first + 1) * SECTOR / MiB));
    return 0;
}

static int cmd_grow(const char *dev)
{
    int fd = open(dev, O_RDWR | O_CLOEXEC);
    if (fd < 0)
        die("não abri %s", dev);
    static struct gpt_entry entries[NENTRIES];
    struct gpt_header h;
    if (read_gpt(fd, &h, entries) < 0)
        die("%s não tem GPT válido", dev);
    uint64_t nsec = disk_sectors(fd);
    int last = -1;
    for (int i = 0; i < NENTRIES; i++)
        if (entries[i].first_lba && (last < 0 || entries[i].last_lba > entries[last].last_lba))
            last = i;
    if (last < 0)
        die("%s sem partições", dev);
    uint64_t new_last = nsec - 2 - ENTRIES_SECTORS;
    new_last -= (new_last + 1) % (MiB / SECTOR);
    if (new_last <= entries[last].last_lba) {
        printf("%s: já ocupa o disco todo\n", dev);
        return 0;
    }
    uint64_t gain = (new_last - entries[last].last_lba) * SECTOR / MiB;
    entries[last].last_lba = new_last;
    write_gpt(fd, nsec, &h, entries);
    close(fd);
    printf("%s: partição %d aumentada em %llu MiB\n", dev, last + 1, (unsigned long long)gain);
    return 0;
}

static int cmd_show(const char *dev)
{
    int fd = open(dev, O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        die("não abri %s", dev);
    static struct gpt_entry entries[NENTRIES];
    struct gpt_header h;
    if (read_gpt(fd, &h, entries) < 0) {
        printf("%s: sem GPT\n", dev);
        return 1;
    }
    printf("%s: %llu MiB\n", dev, (unsigned long long)(disk_sectors(fd) * SECTOR / MiB));
    for (int i = 0; i < NENTRIES; i++) {
        if (!entries[i].first_lba)
            continue;
        char name[37] = { 0 };
        for (int k = 0; k < 36 && entries[i].name[k]; k++)
            name[k] = (char)entries[i].name[k];
        printf("  %d  %-12s %8llu MiB\n", i + 1, name,
               (unsigned long long)((entries[i].last_lba - entries[i].first_lba + 1) * SECTOR / MiB));
    }
    return 0;
}

int main(int argc, char **argv)
{
    crc_init();
    if (argc != 3) {
        fprintf(stderr, "uso: akko-part install|grow|show <disco>\n");
        return 2;
    }
    if (!strcmp(argv[1], "install"))
        return cmd_install(argv[2]);
    if (!strcmp(argv[1], "grow"))
        return cmd_grow(argv[2]);
    if (!strcmp(argv[1], "show"))
        return cmd_show(argv[2]);
    fprintf(stderr, "comando desconhecido: %s\n", argv[1]);
    return 2;
}
