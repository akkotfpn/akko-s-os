/*
 * akko-auth — gerencia /etc/passwd, /etc/shadow e /etc/group.
 *
 * No Akko's OS esses arquivos são links para /data/etc (o disco persistente),
 * porque a raiz do sistema é somente leitura. As escritas são atômicas:
 * grava um arquivo temporário ao lado e troca com rename(), sob um flock.
 */

#define _GNU_SOURCE
#include "akko-auth.h"

#include <crypt.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pwd.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/random.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

char akko_auth_error[160];

#define PASSWD "/etc/passwd"
#define SHADOW "/etc/shadow"
#define GROUP  "/etc/group"

static int fail(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(akko_auth_error, sizeof(akko_auth_error), fmt, ap);
    va_end(ap);
    return -1;
}

/* ---------------- leitura/escrita de arquivos inteiros ---------------- */

static char *slurp(const char *path)
{
    FILE *f = fopen(path, "re");
    if (!f)
        return strdup("");
    char *buf = NULL;
    size_t cap = 0, len = 0;
    char tmp[4096];
    size_t n;
    while ((n = fread(tmp, 1, sizeof(tmp), f)) > 0) {
        if (len + n + 1 > cap) {
            cap = (len + n + 1) * 2;
            buf = realloc(buf, cap);
        }
        memcpy(buf + len, tmp, n);
        len += n;
    }
    fclose(f);
    if (!buf)
        return strdup("");
    buf[len] = '\0';
    return buf;
}

static int write_atomic(const char *link, const char *content, mode_t mode)
{
    char real[PATH_MAX];
    if (!realpath(link, real)) {
        /* o destino do link ainda não existe: segue o link manualmente */
        ssize_t n = readlink(link, real, sizeof(real) - 1);
        if (n < 0)
            snprintf(real, sizeof(real), "%s", link);
        else
            real[n] = '\0';
    }
    char tmp[PATH_MAX + 8];
    snprintf(tmp, sizeof(tmp), "%s.new", real);
    int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, mode);
    if (fd < 0)
        return fail("não consegui gravar %s: %s", tmp, strerror(errno));
    size_t len = strlen(content);
    if (write(fd, content, len) != (ssize_t)len || fsync(fd) < 0) {
        close(fd);
        unlink(tmp);
        return fail("erro gravando %s", tmp);
    }
    fchmod(fd, mode);
    close(fd);
    if (rename(tmp, real) < 0)
        return fail("erro trocando %s: %s", real, strerror(errno));
    return 0;
}

static int lock_fd = -1;

static int lock(void)
{
    lock_fd = open("/data/etc/.auth.lock", O_RDWR | O_CREAT | O_CLOEXEC, 0600);
    if (lock_fd >= 0)
        flock(lock_fd, LOCK_EX);
    return 0;
}

static void unlock(void)
{
    if (lock_fd >= 0) {
        flock(lock_fd, LOCK_UN);
        close(lock_fd);
        lock_fd = -1;
    }
}

/* procura a linha "nome:..." num arquivo estilo passwd; devolve ponteiro ou NULL */
static char *find_line(char *buf, const char *name)
{
    size_t n = strlen(name);
    for (char *p = buf; p && *p;) {
        if (!strncmp(p, name, n) && p[n] == ':')
            return p;
        p = strchr(p, '\n');
        if (p)
            p++;
    }
    return NULL;
}

/* substitui (ou remove, se repl == NULL) a linha de "name" */
static char *replace_line(const char *buf, const char *name, const char *repl)
{
    char *copy = strdup(buf);
    char *line = find_line(copy, name);
    size_t need = strlen(buf) + (repl ? strlen(repl) : 0) + 2;
    char *out = malloc(need);
    out[0] = '\0';
    if (!line) {
        strcpy(out, buf);
        if (repl) {
            if (*out && out[strlen(out) - 1] != '\n')
                strcat(out, "\n");
            strcat(out, repl);
            strcat(out, "\n");
        }
    } else {
        char *end = strchr(line, '\n');
        *line = '\0';
        strcpy(out, copy);
        if (repl) {
            strcat(out, repl);
            strcat(out, "\n");
        }
        if (end)
            strcat(out, end + 1);
    }
    free(copy);
    return out;
}

/* ---------------- senhas ---------------- */

static char *hash_password(const char *pass)
{
    static const char abc[] =
        "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
    unsigned char rnd[16];
    if (getrandom(rnd, sizeof(rnd), 0) != sizeof(rnd))
        return NULL;
    char salt[32] = "$6$";
    for (int i = 0; i < 16; i++)
        salt[3 + i] = abc[rnd[i] % 64];
    salt[19] = '$';
    salt[20] = '\0';
    char *h = crypt(pass, salt);
    return h && h[0] == '$' ? strdup(h) : NULL;
}

int akko_auth_valid_name(const char *u)
{
    size_t n = strlen(u);
    if (n < 1 || n > 32)
        return 0;
    if (!(islower((unsigned char)u[0]) || u[0] == '_'))
        return 0;
    for (size_t i = 1; i < n; i++)
        if (!(islower((unsigned char)u[i]) || isdigit((unsigned char)u[i]) || u[i] == '_' || u[i] == '-'))
            return 0;
    static const char *reserved[] = { "root", "nobody", "apps", "sshd", "wheel", "tty", NULL };
    for (int i = 0; reserved[i]; i++)
        if (!strcmp(u, reserved[i]))
            return 0;
    return 1;
}

int akko_auth_check(const char *user, const char *pass)
{
    if (!user || !*user || !pass)
        return fail("usuário ou senha vazios");
    char *buf = slurp(SHADOW);
    char *line = find_line(buf, user);
    int ret = fail("usuário ou senha incorretos");
    if (line) {
        char *h = strchr(line, ':') + 1;
        char *end = strchr(h, ':');
        if (end) {
            *end = '\0';
            if (h[0] == '$') {
                char *c = crypt(pass, h);
                /* comparação em tempo constante */
                size_t a = strlen(h), b = c ? strlen(c) : 0;
                int diff = (a != b) | !c;
                for (size_t i = 0; c && i < a && i < b; i++)
                    diff |= h[i] ^ c[i];
                if (!diff)
                    ret = 0;
            }
        }
    } else {
        /* gasta o mesmo tempo mesmo sem usuário (evita descobrir nomes) */
        crypt(pass, "$6$akkosdummysalt$");
    }
    free(buf);
    if (ret < 0)
        sleep(1);   /* atrasa tentativas de força bruta */
    return ret;
}

int akko_auth_count_humans(void)
{
    int n = 0;
    FILE *f = fopen(PASSWD, "re");
    if (!f)
        return 0;
    struct passwd *pw;
    while ((pw = fgetpwent(f)))
        if (pw->pw_uid >= AKKO_UID_MIN && pw->pw_uid < 60000)
            n++;
    fclose(f);
    return n;
}

static unsigned next_id(void)
{
    unsigned id = AKKO_UID_MIN;
    FILE *f = fopen(PASSWD, "re");
    if (f) {
        struct passwd *pw;
        while ((pw = fgetpwent(f)))
            if (pw->pw_uid >= id && pw->pw_uid < 60000)
                id = pw->pw_uid + 1;
        fclose(f);
    }
    char *g = slurp(GROUP);
    for (;;) {   /* garante gid livre também */
        char pat[32];
        snprintf(pat, sizeof(pat), ":x:%u:", id);
        if (!strstr(g, pat))
            break;
        id++;
    }
    free(g);
    return id;
}

static int add_to_group(const char *group, const char *user)
{
    char *g = slurp(GROUP);
    char *line = find_line(g, group);
    int ret = 0;
    if (line) {
        char *end = strchr(line, '\n');
        size_t len = end ? (size_t)(end - line) : strlen(line);
        char cur[512];
        snprintf(cur, sizeof(cur), "%.*s", (int)len, line);
        char repl[600];
        snprintf(repl, sizeof(repl), "%s%s%s", cur, cur[strlen(cur) - 1] == ':' ? "" : ",", user);
        char *out = replace_line(g, group, repl);
        ret = write_atomic(GROUP, out, 0644);
        free(out);
    }
    free(g);
    return ret;
}

static void mkdir_home(const char *path, uid_t uid, gid_t gid)
{
    mkdir(path, 0700);
    chown(path, uid, gid);
    chmod(path, 0700);
}

int akko_auth_add_user(const char *user, const char *fullname, const char *pass, int admin)
{
    if (!akko_auth_valid_name(user))
        return fail("nome inválido: use letras minúsculas, números, - ou _ (até 32)");
    if (!pass || strlen(pass) < 6)
        return fail("a senha precisa ter pelo menos 6 caracteres");
    if (fullname && (strchr(fullname, ':') || strchr(fullname, '\n')))
        return fail("nome completo não pode ter ':'");

    lock();
    char *pw = slurp(PASSWD);
    if (find_line(pw, user)) {
        free(pw);
        unlock();
        return fail("o usuário '%s' já existe", user);
    }
    char *h = hash_password(pass);
    if (!h) {
        free(pw);
        unlock();
        return fail("falha ao gerar o hash da senha");
    }
    unsigned id = next_id();
    char line[512];

    snprintf(line, sizeof(line), "%s:x:%u:%u:%s:/home/%s:/bin/sh", user, id, id,
             fullname ? fullname : "", user);
    char *out = replace_line(pw, user, line);
    int ret = write_atomic(PASSWD, out, 0644);
    free(out);
    free(pw);

    if (ret == 0) {
        char *sh = slurp(SHADOW);
        snprintf(line, sizeof(line), "%s:%s:%ld:0:99999:7:::", user, h, (long)(time(NULL) / 86400));
        out = replace_line(sh, user, line);
        ret = write_atomic(SHADOW, out, 0600);
        free(out);
        free(sh);
    }
    if (ret == 0) {
        char *g = slurp(GROUP);
        snprintf(line, sizeof(line), "%s:x:%u:", user, id);
        out = replace_line(g, user, line);
        ret = write_atomic(GROUP, out, 0644);
        free(out);
        free(g);
    }
    if (ret == 0 && admin)
        ret = add_to_group("wheel", user);
    free(h);
    unlock();

    if (ret == 0) {
        char home[300];
        snprintf(home, sizeof(home), "/home/%s", user);
        mkdir_home(home, id, id);
    }
    return ret;
}

int akko_auth_set_password(const char *user, const char *pass)
{
    if (!pass || strlen(pass) < 6)
        return fail("a senha precisa ter pelo menos 6 caracteres");
    lock();
    char *sh = slurp(SHADOW);
    char *line = find_line(sh, user);
    if (!line) {
        free(sh);
        unlock();
        return fail("usuário '%s' não existe", user);
    }
    char *h = hash_password(pass);
    char repl[512];
    snprintf(repl, sizeof(repl), "%s:%s:%ld:0:99999:7:::", user, h ? h : "!", (long)(time(NULL) / 86400));
    char *out = replace_line(sh, user, repl);
    int ret = h ? write_atomic(SHADOW, out, 0600) : fail("falha no hash");
    free(out);
    free(sh);
    free(h);
    unlock();
    return ret;
}

int akko_auth_del_user(const char *user)
{
    if (!strcmp(user, "root"))
        return fail("não dá pra remover o root");
    lock();
    const char *files[] = { PASSWD, SHADOW, GROUP };
    mode_t modes[] = { 0644, 0600, 0644 };
    int ret = 0;
    for (int i = 0; i < 3 && ret == 0; i++) {
        char *b = slurp(files[i]);
        char *out = replace_line(b, user, NULL);
        ret = write_atomic(files[i], out, modes[i]);
        free(out);
        free(b);
    }
    /* tira dos grupos suplementares (ex.: wheel) */
    if (ret == 0) {
        char *g = slurp(GROUP);
        char *res = calloc(1, strlen(g) + 2);
        for (char *l = strtok(g, "\n"); l; l = strtok(NULL, "\n")) {
            char *members = strrchr(l, ':');
            strncat(res, l, members ? (size_t)(members - l + 1) : strlen(l));
            if (members) {
                int first = 1;
                char *save;
                for (char *m = strtok_r(members + 1, ",", &save); m; m = strtok_r(NULL, ",", &save)) {
                    if (!strcmp(m, user))
                        continue;
                    if (!first)
                        strcat(res, ",");
                    strcat(res, m);
                    first = 0;
                }
            }
            strcat(res, "\n");
        }
        ret = write_atomic(GROUP, res, 0644);
        free(res);
        free(g);
    }
    unlock();
    return ret;
}
