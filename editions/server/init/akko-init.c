/*
 * akko-init — PID 1 e supervisor de serviços do Akko's OS
 *
 * Como PID 1:
 *   1. monta /proc, /sys, /dev, /run, /tmp
 *   2. roda /etc/akko/boot.sh (disco, usuários, rede base, firewall, raiz ro)
 *   3. inicia os serviços e fica supervisionando
 *   4. recolhe órfãos; desliga/reinicia de forma limpa
 *
 * Serviços: arquivos chave=valor
 *   /etc/akko/services/NN-nome.conf    do sistema (ordem pelo nome)
 *   /data/apps/<nome>/app.conf         seus aplicativos
 *
 *   exec=comando com argumentos        (rodado por /bin/sh -c "exec ...")
 *   user=usuario                       (padrão: root no sistema, "apps" nos apps)
 *   restart=always|on-failure|no       (padrão: always)
 *   enabled=yes|no
 *   tty=/dev/ttyN                      (liga o serviço a um terminal; sem log)
 *   workdir=/caminho
 *   env=CHAVE=valor                    (pode repetir)
 *   port=8080 ou 53/udp                (lido pelo firewall)
 *
 * Saída de cada serviço vai para /var/log/<nome>.log (com rotação).
 *
 * Controle: socket /run/akko/control. O mesmo binário, chamado como
 * "akkoctl", vira o cliente:  akkoctl list | start X | stop X | restart X |
 * reload | poweroff | reboot
 */

#define _GNU_SOURCE
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <glob.h>
#include <grp.h>
#include <linux/input.h>
#include <linux/kd.h>
#include <linux/reboot.h>
#include <poll.h>
#include <pwd.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define CONTROL_SOCK "/run/akko/control"
#define LOG_DIR      "/var/log"
#define LOG_MAX      (512 * 1024)
#define MAX_SERVICES 64
#define MAX_ENV      16

enum restart_policy { R_ALWAYS, R_ONFAIL, R_NO };
enum state { S_STOPPED, S_RUNNING, S_WAITING, S_FAILED, S_DONE };
static const char *state_name[] = { "parado", "rodando", "aguardando", "falhou", "concluido" };

struct service {
    char name[64];
    char conf[300];
    char exec[1024];
    char user[33];
    char tty[64];
    char workdir[256];
    char env[MAX_ENV][256];
    int nenv;
    int restart;
    int enabled;
    int is_app;
    time_t conf_mtime;

    /* estado em execução */
    pid_t pid;
    int state;
    int out_fd;            /* leitura do pipe stdout/stderr */
    int log_fd;
    int at_line_start;
    time_t started;
    time_t next_start;
    time_t kill_at;        /* prazo pro SIGKILL quando parando */
    int stopping;
    int restart_pending;   /* reiniciar assim que terminar */
    int crashes;
    int restarts;
    int last_status;
    int seen;              /* marcação durante reload */
};

static struct service services[MAX_SERVICES];
static int nservices;
static int sigpipe[2] = { -1, -1 };
static volatile sig_atomic_t pending_action;
static int boot_done;

/* ------------------------------------------------------------------ util */

static void kmsg(const char *fmt, ...)
{
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    int fd = open("/dev/kmsg", O_WRONLY | O_CLOEXEC);
    if (fd >= 0) {
        dprintf(fd, "<6>akko-init: %.*s\n", n, buf);
        close(fd);
    }
}

static void mkdir_p(const char *path, mode_t mode)
{
    char tmp[512];
    snprintf(tmp, sizeof(tmp), "%s", path);
    for (char *p = tmp + 1; *p; p++) {
        if (*p == '/') {
            *p = '\0';
            mkdir(tmp, mode);
            *p = '/';
        }
    }
    mkdir(tmp, mode);
}

static void mount_fs(const char *src, const char *dst, const char *type,
                     unsigned long flags, const char *data)
{
    mkdir_p(dst, 0755);
    if (mount(src, dst, type, flags, data) < 0 && errno != EBUSY)
        kmsg("mount %s em %s: %s", type, dst, strerror(errno));
}

static char *trim(char *s)
{
    while (isspace((unsigned char)*s))
        s++;
    char *e = s + strlen(s);
    while (e > s && isspace((unsigned char)e[-1]))
        *--e = '\0';
    return s;
}

static void set_nonblock(int fd)
{
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
}

/* ------------------------------------------------------------ configuração */

static int parse_conf(struct service *s, const char *path, const char *name, int is_app)
{
    FILE *f = fopen(path, "re");
    if (!f)
        return -1;
    struct stat st;
    fstat(fileno(f), &st);

    memset(s->exec, 0, sizeof(s->exec));
    snprintf(s->name, sizeof(s->name), "%s", name);
    snprintf(s->conf, sizeof(s->conf), "%s", path);
    snprintf(s->user, sizeof(s->user), "%s", is_app ? "apps" : "root");
    s->tty[0] = '\0';
    s->workdir[0] = '\0';
    s->nenv = 0;
    s->restart = R_ALWAYS;
    s->enabled = 1;
    s->is_app = is_app;
    s->conf_mtime = st.st_mtime;
    if (is_app) {
        /* apps rodam na própria pasta por padrão */
        char *dir = strdup(path);
        char *slash = strrchr(dir, '/');
        if (slash)
            *slash = '\0';
        snprintf(s->workdir, sizeof(s->workdir), "%s", dir);
        free(dir);
    }

    char line[1100];
    while (fgets(line, sizeof(line), f)) {
        char *l = trim(line);
        if (!*l || *l == '#')
            continue;
        char *eq = strchr(l, '=');
        if (!eq)
            continue;
        *eq = '\0';
        char *k = trim(l), *v = trim(eq + 1);
        if (!strcmp(k, "exec"))
            snprintf(s->exec, sizeof(s->exec), "%s", v);
        else if (!strcmp(k, "user"))
            snprintf(s->user, sizeof(s->user), "%s", v);
        else if (!strcmp(k, "tty"))
            snprintf(s->tty, sizeof(s->tty), "%s", v);
        else if (!strcmp(k, "workdir"))
            snprintf(s->workdir, sizeof(s->workdir), "%s", v);
        else if (!strcmp(k, "env") && s->nenv < MAX_ENV && strchr(v, '='))
            snprintf(s->env[s->nenv++], sizeof(s->env[0]), "%s", v);
        else if (!strcmp(k, "restart"))
            s->restart = !strcmp(v, "no") ? R_NO : !strcmp(v, "on-failure") ? R_ONFAIL : R_ALWAYS;
        else if (!strcmp(k, "enabled"))
            s->enabled = !(strcmp(v, "no") == 0 || strcmp(v, "false") == 0 || strcmp(v, "0") == 0);
    }
    fclose(f);
    return s->exec[0] ? 0 : -1;
}

static struct service *find_service(const char *name)
{
    for (int i = 0; i < nservices; i++)
        if (!strcmp(services[i].name, name))
            return &services[i];
    return NULL;
}

/* ---------------------------------------------------------------- logs */

static void open_log(struct service *s)
{
    if (s->log_fd >= 0)
        return;
    char path[300];
    snprintf(path, sizeof(path), LOG_DIR "/%s.log", s->name);
    s->log_fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0640);
    s->at_line_start = 1;
}

static void rotate_log(struct service *s)
{
    struct stat st;
    if (s->log_fd < 0 || fstat(s->log_fd, &st) < 0 || st.st_size < LOG_MAX)
        return;
    char a[300], b[310];
    snprintf(a, sizeof(a), LOG_DIR "/%s.log", s->name);
    snprintf(b, sizeof(b), "%s.1", a);
    rename(a, b);
    close(s->log_fd);
    s->log_fd = -1;
    open_log(s);
}

static void log_write(struct service *s, const char *buf, size_t n)
{
    open_log(s);
    if (s->log_fd < 0)
        return;
    char out[8192];
    size_t o = 0;
    for (size_t i = 0; i < n; i++) {
        if (s->at_line_start) {
            time_t t = time(NULL);
            struct tm tm;
            localtime_r(&t, &tm);
            o += strftime(out + o, sizeof(out) - o, "%Y-%m-%d %H:%M:%S ", &tm);
            s->at_line_start = 0;
        }
        out[o++] = buf[i];
        if (buf[i] == '\n')
            s->at_line_start = 1;
        if (o > sizeof(out) - 64) {
            write(s->log_fd, out, o);
            o = 0;
        }
    }
    if (o)
        write(s->log_fd, out, o);
    rotate_log(s);
}

static void log_event(struct service *s, const char *fmt, ...)
{
    char msg[300];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(msg, sizeof(msg) - 2, fmt, ap);
    va_end(ap);
    if (!s->at_line_start)
        log_write(s, "\n", 1);
    char line[320];
    int m = snprintf(line, sizeof(line), "[akko-init] %.*s\n", n, msg);
    log_write(s, line, m);
}

/* ------------------------------------------------------------- execução */

static void start_service(struct service *s)
{
    if (s->pid > 0)
        return;
    int pfd[2] = { -1, -1 };
    if (!s->tty[0]) {
        if (pipe2(pfd, O_CLOEXEC) < 0) {
            kmsg("pipe: %s", strerror(errno));
            return;
        }
    }

    struct passwd *pw = getpwnam(s->user);
    if (!pw) {
        open_log(s);
        log_event(s, "usuário '%s' não existe; serviço não iniciado", s->user);
        s->state = S_FAILED;
        if (pfd[0] >= 0) {
            close(pfd[0]);
            close(pfd[1]);
        }
        return;
    }
    uid_t uid = pw->pw_uid;
    gid_t gid = pw->pw_gid;
    char home[256], shell[128], uname[64];
    snprintf(home, sizeof(home), "%s", pw->pw_dir);
    snprintf(shell, sizeof(shell), "%s", pw->pw_shell);
    snprintf(uname, sizeof(uname), "%s", pw->pw_name);

    pid_t pid = fork();
    if (pid < 0) {
        kmsg("fork: %s", strerror(errno));
        return;
    }
    if (pid == 0) {
        sigset_t none;
        sigemptyset(&none);
        sigprocmask(SIG_SETMASK, &none, NULL);
        for (int i = 1; i < NSIG; i++)
            signal(i, SIG_DFL);
        setsid();

        if (s->tty[0]) {
            int fd = open(s->tty, O_RDWR | O_NOCTTY);
            if (fd < 0)
                _exit(126);
            ioctl(fd, TIOCSCTTY, 1);
            dup2(fd, 0);
            dup2(fd, 1);
            dup2(fd, 2);
            if (fd > 2)
                close(fd);
        } else {
            int devnull = open("/dev/null", O_RDONLY);
            dup2(devnull, 0);
            dup2(pfd[1], 1);
            dup2(pfd[1], 2);
            if (devnull > 2)
                close(devnull);
        }

        /* ambiente limpo */
        const char *tz = getenv("TZ");
        char tzbuf[64];
        snprintf(tzbuf, sizeof(tzbuf), "%s", tz ? tz : "");
        clearenv();
        setenv("PATH", uid == 0 ? "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
                                : "/usr/local/bin:/usr/bin:/bin", 1);
        setenv("HOME", home, 1);
        setenv("USER", uname, 1);
        setenv("LOGNAME", uname, 1);
        setenv("SHELL", shell, 1);
        setenv("LANG", "C.UTF-8", 1);
        setenv("TERM", "linux", 1);
        setenv("AKKO_SERVICE", s->name, 1);
        if (tzbuf[0])
            setenv("TZ", tzbuf, 1);
        for (int i = 0; i < s->nenv; i++) {
            char *eq = strchr(s->env[i], '=');
            *eq = '\0';
            setenv(s->env[i], eq + 1, 1);
        }

        umask(022);
        if (uid != 0) {
            if (initgroups(uname, gid) < 0 || setgid(gid) < 0 || setuid(uid) < 0)
                _exit(125);
        }
        if (chdir(s->workdir[0] ? s->workdir : (uid ? home : "/")) < 0)
            chdir("/");

        char cmd[1100];
        snprintf(cmd, sizeof(cmd), "exec %s", s->exec);
        execl("/bin/sh", "sh", "-c", cmd, (char *)NULL);
        _exit(127);
    }

    s->pid = pid;
    s->state = S_RUNNING;
    s->started = time(NULL);
    s->stopping = 0;
    if (pfd[1] >= 0) {
        close(pfd[1]);
        if (s->out_fd >= 0)
            close(s->out_fd);
        s->out_fd = pfd[0];
        set_nonblock(s->out_fd);
        open_log(s);
        log_event(s, "iniciado (pid %d, usuário %s)", pid, s->user);
    }
}

static void stop_service(struct service *s)
{
    if (s->pid <= 0) {
        s->state = S_STOPPED;
        return;
    }
    s->stopping = 1;
    kill(-s->pid, SIGTERM);
    kill(s->pid, SIGTERM);
    s->kill_at = time(NULL) + 5;
}

static void drain_output(struct service *s)
{
    if (s->out_fd < 0)
        return;
    char buf[4096];
    ssize_t n;
    while ((n = read(s->out_fd, buf, sizeof(buf))) > 0)
        log_write(s, buf, n);
    if (n == 0) {   /* fim do pipe */
        close(s->out_fd);
        s->out_fd = -1;
    }
}

static void service_exited(struct service *s, int status)
{
    drain_output(s);
    time_t now = time(NULL);
    int code = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
    s->last_status = code;
    s->pid = 0;

    if (s->out_fd >= 0 || s->log_fd >= 0)
        log_event(s, "terminou (código %d)", code);

    if (s->stopping || pending_action) {
        s->stopping = 0;
        s->kill_at = 0;
        if (s->restart_pending && !pending_action && s->enabled) {
            s->restart_pending = 0;
            s->crashes = 0;
            start_service(s);
        } else {
            s->restart_pending = 0;
            s->state = S_STOPPED;
        }
        return;
    }
    int failed = code != 0;
    if (s->restart == R_NO || (s->restart == R_ONFAIL && !failed)) {
        s->state = failed ? S_FAILED : S_DONE;
        return;
    }
    /* espera progressiva: crashes rápidos seguidos dobram a espera */
    if (now - s->started < 10)
        s->crashes++;
    else
        s->crashes = 0;
    if (s->crashes >= 10) {
        s->state = S_FAILED;
        log_event(s, "desisti após %d falhas seguidas (use: akko service start %s)", s->crashes, s->name);
        return;
    }
    int delay = s->crashes ? 1 << (s->crashes < 6 ? s->crashes : 6) : 1;
    s->state = S_WAITING;
    s->next_start = now + delay;
    s->restarts++;
}

/* ---------------------------------------------------- carregar serviços */

static void load_one(const char *path, const char *name, int is_app)
{
    struct service tmp;
    memset(&tmp, 0, sizeof(tmp));
    if (parse_conf(&tmp, path, name, is_app) < 0)
        return;
    struct service *s = find_service(name);
    if (s) {
        s->seen = 1;
        if (s->conf_mtime == tmp.conf_mtime)
            return;
        /* configuração mudou: atualiza e reinicia se estiver rodando */
        int was_running = s->pid > 0;
        pid_t pid = s->pid;
        int out_fd = s->out_fd, log_fd = s->log_fd;
        memcpy(s->exec, tmp.exec, sizeof(tmp.exec));
        memcpy(s->user, tmp.user, sizeof(tmp.user));
        memcpy(s->tty, tmp.tty, sizeof(tmp.tty));
        memcpy(s->workdir, tmp.workdir, sizeof(tmp.workdir));
        memcpy(s->env, tmp.env, sizeof(tmp.env));
        s->nenv = tmp.nenv;
        s->restart = tmp.restart;
        s->enabled = tmp.enabled;
        s->conf_mtime = tmp.conf_mtime;
        s->pid = pid;
        s->out_fd = out_fd;
        s->log_fd = log_fd;
        if (was_running) {
            stop_service(s);
            s->restart_pending = s->enabled;   /* volta com a config nova */
        } else if (s->enabled && s->state != S_FAILED) {
            start_service(s);
        }
        return;
    }
    if (nservices >= MAX_SERVICES)
        return;
    s = &services[nservices++];
    *s = tmp;
    s->pid = 0;
    s->out_fd = -1;
    s->log_fd = -1;
    s->seen = 1;
    s->state = S_STOPPED;
    if (s->enabled && boot_done)
        start_service(s);
}

static void load_services(void)
{
    for (int i = 0; i < nservices; i++)
        services[i].seen = 0;

    glob_t g;
    if (glob("/etc/akko/services/*.conf", 0, NULL, &g) == 0) {
        for (size_t i = 0; i < g.gl_pathc; i++) {
            const char *base = strrchr(g.gl_pathv[i], '/') + 1;
            char name[64];
            const char *dash = strchr(base, '-');   /* "20-sshd.conf" → "sshd" */
            snprintf(name, sizeof(name), "%s", dash && isdigit((unsigned char)base[0]) ? dash + 1 : base);
            char *dot = strrchr(name, '.');
            if (dot)
                *dot = '\0';
            load_one(g.gl_pathv[i], name, 0);
        }
        globfree(&g);
    }
    if (glob("/data/apps/*/app.conf", 0, NULL, &g) == 0) {
        for (size_t i = 0; i < g.gl_pathc; i++) {
            char dir[300];
            snprintf(dir, sizeof(dir), "%s", g.gl_pathv[i]);
            *strrchr(dir, '/') = '\0';
            const char *name = strrchr(dir, '/') + 1;
            if (find_service(name) && !find_service(name)->is_app)
                continue;   /* não deixa app sobrescrever serviço do sistema */
            load_one(g.gl_pathv[i], name, 1);
        }
        globfree(&g);
    }

    /* serviços cujo arquivo sumiu: para e remove */
    for (int i = 0; i < nservices; i++) {
        if (services[i].seen)
            continue;
        if (services[i].pid > 0) {
            stop_service(&services[i]);
            continue;   /* remove depois que terminar */
        }
        if (services[i].out_fd >= 0)
            close(services[i].out_fd);
        if (services[i].log_fd >= 0)
            close(services[i].log_fd);
        services[i] = services[--nservices];
        i--;
    }
}

/* ------------------------------------------------------------ boot.sh */

static int run_boot_script(void)
{
    if (access("/etc/akko/boot.sh", X_OK) < 0)
        return 0;
    pid_t pid = fork();
    if (pid == 0) {
        int fd = open("/dev/console", O_RDWR);
        if (fd >= 0) {
            dup2(fd, 0);
            dup2(fd, 1);
            dup2(fd, 2);
            if (fd > 2)
                close(fd);
        }
        execl("/bin/sh", "sh", "/etc/akko/boot.sh", (char *)NULL);
        _exit(127);
    }
    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR)
        ;
    return status;
}

static void load_timezone(void)
{
    char buf[64] = "<-03>3";   /* padrão: horário de Brasília */
    FILE *f = fopen("/data/etc/timezone", "re");
    if (f) {
        if (fgets(buf, sizeof(buf), f))
            buf[strcspn(buf, "\r\n")] = '\0';
        fclose(f);
    }
    setenv("TZ", buf, 1);
    tzset();
}

/* --------------------------------------------------- socket de controle */

static int control_fd = -1;

static void setup_control(void)
{
    mkdir_p("/run/akko", 0755);
    unlink(CONTROL_SOCK);
    control_fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    struct sockaddr_un a = { .sun_family = AF_UNIX };
    snprintf(a.sun_path, sizeof(a.sun_path), "%s", CONTROL_SOCK);
    if (bind(control_fd, (struct sockaddr *)&a, sizeof(a)) < 0 || listen(control_fd, 8) < 0) {
        kmsg("socket de controle: %s", strerror(errno));
        close(control_fd);
        control_fd = -1;
        return;
    }
    chmod(CONTROL_SOCK, 0666);   /* qualquer um conecta; permissões checadas por comando */
}

static int peer_is_admin(int fd)
{
    struct ucred cr;
    socklen_t len = sizeof(cr);
    if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cr, &len) < 0)
        return 0;
    return cr.uid == 0;
}

static void handle_control(void)
{
    int fd = accept4(control_fd, NULL, NULL, SOCK_CLOEXEC);
    if (fd < 0)
        return;
    struct timeval tv = { 1, 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    char req[512];
    ssize_t n = read(fd, req, sizeof(req) - 1);
    if (n <= 0) {
        close(fd);
        return;
    }
    req[n] = '\0';
    char *cmd = trim(req);
    char *arg = strchr(cmd, ' ');
    if (arg) {
        *arg++ = '\0';
        arg = trim(arg);
    }
    FILE *out = fdopen(fd, "w");
    if (!out) {
        close(fd);
        return;
    }
    time_t now = time(NULL);

    if (!strcmp(cmd, "list")) {
        for (int i = 0; i < nservices; i++) {
            struct service *s = &services[i];
            fprintf(out, "%s|%s|%d|%ld|%d|%s|%s|%d\n", s->name, state_name[s->state], s->pid,
                    s->pid > 0 ? (long)(now - s->started) : 0L, s->restarts,
                    s->is_app ? "app" : "sistema", s->enabled ? "sim" : "nao", s->last_status);
        }
    } else if (!peer_is_admin(fd)) {
        fprintf(out, "erro: precisa de root (use doas)\n");
    } else if (!strcmp(cmd, "reload")) {
        load_services();
        fprintf(out, "ok: %d serviços\n", nservices);
    } else if (!strcmp(cmd, "poweroff") || !strcmp(cmd, "reboot")) {
        pending_action = !strcmp(cmd, "poweroff") ? RB_POWER_OFF : RB_AUTOBOOT;
        fprintf(out, "ok\n");
    } else if (!strcmp(cmd, "start") || !strcmp(cmd, "stop") || !strcmp(cmd, "restart")) {
        struct service *s = arg ? find_service(arg) : NULL;
        if (!s) {
            fprintf(out, "erro: serviço '%s' não existe\n", arg ? arg : "");
        } else if (!strcmp(cmd, "stop")) {
            stop_service(s);
            fprintf(out, "ok: parando %s\n", s->name);
        } else {
            s->crashes = 0;
            if (!strcmp(cmd, "restart") && s->pid > 0) {
                stop_service(s);
                s->restart_pending = 1;    /* reinicia assim que terminar */
            } else if (s->pid <= 0) {
                start_service(s);
            }
            fprintf(out, "ok: %s %s\n", !strcmp(cmd, "restart") ? "reiniciando" : "iniciando", s->name);
        }
    } else {
        fprintf(out, "erro: comando desconhecido '%s'\n", cmd);
    }
    fclose(out);
}

/* modo cliente: akkoctl <comando> [arg] */
static int client(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "uso: akkoctl list | start X | stop X | restart X | reload | poweroff | reboot\n");
        return 2;
    }
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    struct sockaddr_un a = { .sun_family = AF_UNIX };
    snprintf(a.sun_path, sizeof(a.sun_path), "%s", CONTROL_SOCK);
    if (connect(fd, (struct sockaddr *)&a, sizeof(a)) < 0) {
        fprintf(stderr, "akkoctl: não conectei no akko-init: %s\n", strerror(errno));
        return 1;
    }
    char req[512] = "";
    for (int i = 1; i < argc; i++) {
        strncat(req, argv[i], sizeof(req) - strlen(req) - 2);
        if (i < argc - 1)
            strcat(req, " ");
    }
    strcat(req, "\n");
    write(fd, req, strlen(req));
    shutdown(fd, SHUT_WR);
    char buf[4096];
    ssize_t n;
    int err = 0;
    while ((n = read(fd, buf, sizeof(buf))) > 0) {
        if (!strncmp(buf, "erro", 4))
            err = 1;
        fwrite(buf, 1, n, stdout);
    }
    return err;
}

/* --------------------------------------------------------- desligamento */

static void on_signal(int sig)
{
    switch (sig) {
    case SIGUSR1:
    case SIGUSR2:
        pending_action = RB_POWER_OFF;
        break;
    case SIGTERM:
    case SIGINT:
        pending_action = RB_AUTOBOOT;
        break;
    }
    int saved = errno;
    if (sigpipe[1] >= 0)
        write(sigpipe[1], "x", 1);
    errno = saved;
}

static void reap(void)
{
    pid_t pid;
    int status;
    while ((pid = waitpid(-1, &status, WNOHANG)) > 0) {
        for (int i = 0; i < nservices; i++)
            if (services[i].pid == pid)
                service_exited(&services[i], status);
    }
}

static void shutdown_system(int how)
{
    const char *what = how == RB_POWER_OFF ? "Desligando" : "Reiniciando";
    kmsg("%s", what);
    int con = open("/dev/console", O_WRONLY | O_NOCTTY | O_CLOEXEC);
    if (con >= 0) {
        ioctl(con, KDSETMODE, KD_TEXT);
        dprintf(con, "\n\033[1;95m  %s o Akko's OS...\033[0m\n", what);
        close(con);
    }
    for (int i = nservices - 1; i >= 0; i--)
        stop_service(&services[i]);
    for (int t = 0; t < 50; t++) {   /* até 5 s pros serviços saírem */
        reap();
        int alive = 0;
        for (int i = 0; i < nservices; i++)
            alive |= services[i].pid > 0;
        if (!alive)
            break;
        usleep(100000);
    }
    kill(-1, SIGTERM);
    usleep(300000);
    kill(-1, SIGKILL);
    reap();
    for (int i = 0; i < nservices; i++)
        if (services[i].log_fd >= 0)
            close(services[i].log_fd);
    sync();
    if (umount2("/data", 0) < 0)
        mount(NULL, "/data", NULL, MS_REMOUNT | MS_RDONLY, NULL);
    sync();
    reboot(how);
    for (;;)
        pause();
}

static int open_power_button(void)
{
    DIR *d = opendir("/sys/class/input");
    if (!d)
        return -1;
    struct dirent *e;
    int fd = -1;
    while ((e = readdir(d)) && fd < 0) {
        if (strncmp(e->d_name, "event", 5) != 0)
            continue;
        char path[300], name[128] = "";
        snprintf(path, sizeof(path), "/sys/class/input/%s/device/name", e->d_name);
        FILE *f = fopen(path, "re");
        if (!f)
            continue;
        if (fgets(name, sizeof(name), f) && strstr(name, "Power Button")) {
            snprintf(path, sizeof(path), "/dev/input/%s", e->d_name);
            fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
        }
        fclose(f);
    }
    closedir(d);
    return fd;
}

/* ------------------------------------------------------------------ main */

int main(int argc, char **argv)
{
    if (getpid() != 1)
        return client(argc, argv);

    mount_fs("proc", "/proc", "proc", MS_NOSUID | MS_NODEV | MS_NOEXEC, "hidepid=invisible");
    mount_fs("sysfs", "/sys", "sysfs", MS_NOSUID | MS_NODEV | MS_NOEXEC, NULL);
    mount_fs("devtmpfs", "/dev", "devtmpfs", MS_NOSUID | MS_NOEXEC, "mode=0755");
    mount_fs("devpts", "/dev/pts", "devpts", MS_NOSUID | MS_NOEXEC, "gid=5,mode=620,ptmxmode=666");
    mount_fs("tmpfs", "/dev/shm", "tmpfs", MS_NOSUID | MS_NODEV | MS_NOEXEC, "mode=1777");
    mount_fs("tmpfs", "/run", "tmpfs", MS_NOSUID | MS_NODEV, "mode=0755,size=32m");
    mount_fs("tmpfs", "/tmp", "tmpfs", MS_NOSUID | MS_NODEV, "mode=1777");
    symlink("/proc/self/fd", "/dev/fd");
    symlink("/proc/self/fd/0", "/dev/stdin");
    symlink("/proc/self/fd/1", "/dev/stdout");
    symlink("/proc/self/fd/2", "/dev/stderr");

    setenv("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", 1);
    setenv("HOME", "/root", 1);
    setenv("TERM", "linux", 1);
    setenv("LANG", "C.UTF-8", 1);
    umask(022);

    reboot(LINUX_REBOOT_CMD_CAD_OFF);
    if (pipe2(sigpipe, O_CLOEXEC | O_NONBLOCK) < 0)
        sigpipe[0] = sigpipe[1] = -1;
    struct sigaction sa = { .sa_handler = on_signal, .sa_flags = SA_RESTART };
    sigemptyset(&sa.sa_mask);
    sigaction(SIGUSR1, &sa, NULL);
    sigaction(SIGUSR2, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGCHLD, &sa, NULL);
    signal(SIGHUP, SIG_IGN);
    signal(SIGPIPE, SIG_IGN);

    kmsg("Akko's OS iniciando");
    int st = run_boot_script();
    if (st != 0)
        kmsg("boot.sh terminou com código %d", st);
    load_timezone();

    setup_control();
    load_services();
    boot_done = 1;
    for (int i = 0; i < nservices; i++)
        if (services[i].enabled)
            start_service(&services[i]);

    int pwr = open_power_button();
    time_t last_rotate = time(NULL);

    for (;;) {
        if (pending_action)
            shutdown_system(pending_action);

        struct pollfd p[MAX_SERVICES + 3];
        int idx[MAX_SERVICES + 3];
        int np = 0;
        if (sigpipe[0] >= 0) {
            p[np] = (struct pollfd){ .fd = sigpipe[0], .events = POLLIN };
            idx[np++] = -1;
        }
        if (control_fd >= 0) {
            p[np] = (struct pollfd){ .fd = control_fd, .events = POLLIN };
            idx[np++] = -2;
        }
        if (pwr >= 0) {
            p[np] = (struct pollfd){ .fd = pwr, .events = POLLIN };
            idx[np++] = -3;
        }
        for (int i = 0; i < nservices; i++) {
            if (services[i].out_fd >= 0) {
                p[np] = (struct pollfd){ .fd = services[i].out_fd, .events = POLLIN };
                idx[np++] = i;
            }
        }

        int r = poll(p, np, 1000);
        for (int k = 0; r > 0 && k < np; k++) {
            if (!p[k].revents)
                continue;
            if (idx[k] == -1) {
                char tmp[64];
                while (read(sigpipe[0], tmp, sizeof(tmp)) > 0)
                    ;
            } else if (idx[k] == -2) {
                handle_control();
            } else if (idx[k] == -3) {
                struct input_event ev[16];
                ssize_t n = read(pwr, ev, sizeof(ev));
                for (ssize_t i = 0; i < n / (ssize_t)sizeof(ev[0]); i++)
                    if (ev[i].type == EV_KEY && ev[i].code == KEY_POWER && ev[i].value == 1)
                        pending_action = RB_POWER_OFF;
            } else if (idx[k] < nservices) {
                drain_output(&services[idx[k]]);
            }
        }

        reap();

        time_t now = time(NULL);
        for (int i = 0; i < nservices; i++) {
            struct service *s = &services[i];
            if (s->pid > 0 && s->kill_at && now >= s->kill_at && s->stopping) {
                kill(-s->pid, SIGKILL);
                kill(s->pid, SIGKILL);
                s->kill_at = 0;
            }
            if (s->pid <= 0 && s->state == S_WAITING && now >= s->next_start)
                start_service(s);
        }
        /* serviços removidos do disco que já terminaram */
        for (int i = 0; i < nservices; i++) {
            if (!services[i].seen && services[i].pid <= 0) {
                if (services[i].log_fd >= 0)
                    close(services[i].log_fd);
                services[i] = services[--nservices];
                i--;
            }
        }
        if (now - last_rotate > 60) {
            for (int i = 0; i < nservices; i++)
                rotate_log(&services[i]);
            last_rotate = now;
        }
        if (pwr < 0 && now % 10 == 0)
            pwr = open_power_button();
    }
}
