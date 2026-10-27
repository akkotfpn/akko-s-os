/*
 * akko-user — contas pela linha de comando
 *
 *   akko-user setup             assistente de primeira conta (texto)
 *   akko-user add <nome> [--admin]
 *   akko-user passwd <nome>
 *   akko-user del <nome>
 *   akko-user list
 *   akko-user count             nº de contas de pessoas (uid >= 1000)
 */

#define _GNU_SOURCE
#include "akko-auth.h"

#include <grp.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>

static void read_line(const char *prompt, char *buf, size_t len, int hidden)
{
    struct termios old, t;
    int tty = isatty(0);
    fputs(prompt, stdout);
    fflush(stdout);
    if (hidden && tty) {
        tcgetattr(0, &old);
        t = old;
        t.c_lflag &= ~ECHO;
        tcsetattr(0, TCSANOW, &t);
    }
    if (!fgets(buf, len, stdin))
        buf[0] = '\0';
    buf[strcspn(buf, "\r\n")] = '\0';
    if (hidden && tty) {
        tcsetattr(0, TCSANOW, &old);
        fputs("\n", stdout);
    }
}

static int ask_password(char *out, size_t len)
{
    char again[256];
    for (int tries = 0; tries < 3; tries++) {
        read_line("Senha: ", out, len, 1);
        read_line("Repita a senha: ", again, sizeof(again), 1);
        if (strcmp(out, again) != 0) {
            puts("As senhas não conferem. De novo.");
            continue;
        }
        if (strlen(out) < 6) {
            puts("Use pelo menos 6 caracteres.");
            continue;
        }
        return 0;
    }
    return -1;
}

static int is_admin(const char *user)
{
    struct group *g = getgrnam("wheel");
    if (!g)
        return 0;
    for (char **m = g->gr_mem; *m; m++)
        if (!strcmp(*m, user))
            return 1;
    return 0;
}

static int setup(void)
{
    if (akko_auth_count_humans() > 0) {
        puts("Já existe conta criada.");
        return 0;
    }
    puts("\n\033[1;96m  Bem-vindo ao Akko's OS!\033[0m");
    puts("  Vamos criar a sua conta de administrador.\n");
    char user[64], pass[256];
    for (;;) {
        read_line("Nome de usuário (ex.: akko): ", user, sizeof(user), 0);
        if (akko_auth_valid_name(user))
            break;
        puts("Use só letras minúsculas, números, - ou _, começando com letra.");
    }
    if (ask_password(pass, sizeof(pass)) < 0)
        return 1;
    if (akko_auth_add_user(user, user, pass, 1) < 0) {
        printf("Erro: %s\n", akko_auth_error);
        return 1;
    }
    memset(pass, 0, sizeof(pass));
    printf("\nConta \033[1m%s\033[0m criada (administrador: use \033[1mdoas\033[0m para comandos de root).\n\n", user);
    return 0;
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "uso: akko-user setup | add <nome> [--admin] | passwd <nome> | del <nome> | list | count\n");
        return 2;
    }
    const char *cmd = argv[1];

    if (!strcmp(cmd, "count")) {
        printf("%d\n", akko_auth_count_humans());
        return 0;
    }
    if (!strcmp(cmd, "list")) {
        FILE *f = fopen("/etc/passwd", "re");
        struct passwd *pw;
        while (f && (pw = fgetpwent(f)))
            if (pw->pw_uid >= AKKO_UID_MIN && pw->pw_uid < 60000)
                printf("%-16s uid=%-6u %s\n", pw->pw_name, pw->pw_uid, is_admin(pw->pw_name) ? "admin" : "");
        if (f)
            fclose(f);
        return 0;
    }
    if (getuid() != 0) {
        fprintf(stderr, "akko-user: precisa de root (use doas)\n");
        return 1;
    }
    if (!strcmp(cmd, "setup"))
        return setup();

    if (argc < 3) {
        fprintf(stderr, "faltou o nome do usuário\n");
        return 2;
    }
    const char *user = argv[2];
    char pass[256];

    if (!strcmp(cmd, "add")) {
        int admin = argc > 3 && !strcmp(argv[3], "--admin");
        if (!akko_auth_valid_name(user)) {
            fprintf(stderr, "nome inválido\n");
            return 1;
        }
        if (ask_password(pass, sizeof(pass)) < 0)
            return 1;
        if (akko_auth_add_user(user, user, pass, admin) < 0) {
            fprintf(stderr, "erro: %s\n", akko_auth_error);
            return 1;
        }
        printf("usuário %s criado%s\n", user, admin ? " (admin)" : "");
        return 0;
    }
    if (!strcmp(cmd, "passwd")) {
        if (ask_password(pass, sizeof(pass)) < 0)
            return 1;
        if (akko_auth_set_password(user, pass) < 0) {
            fprintf(stderr, "erro: %s\n", akko_auth_error);
            return 1;
        }
        puts("senha alterada");
        return 0;
    }
    if (!strcmp(cmd, "del")) {
        if (akko_auth_del_user(user) < 0) {
            fprintf(stderr, "erro: %s\n", akko_auth_error);
            return 1;
        }
        printf("usuário %s removido (a pasta /home/%s foi mantida)\n", user, user);
        return 0;
    }
    if (!strcmp(cmd, "check")) {   /* uso interno/testes: senha pela entrada padrão */
        read_line("", pass, sizeof(pass), 1);
        int r = akko_auth_check(user, pass);
        puts(r == 0 ? "ok" : akko_auth_error);
        return r == 0 ? 0 : 1;
    }
    fprintf(stderr, "comando desconhecido: %s\n", cmd);
    return 2;
}
