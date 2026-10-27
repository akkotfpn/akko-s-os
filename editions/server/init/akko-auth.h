/* akko-auth — contas de usuário do Akko's OS (passwd/shadow/group) */
#ifndef AKKO_AUTH_H
#define AKKO_AUTH_H

#define AKKO_UID_MIN 1000

/* 0 = ok; <0 = erro (mensagem em akko_auth_error) */
int akko_auth_check(const char *user, const char *pass);
int akko_auth_add_user(const char *user, const char *fullname, const char *pass, int admin);
int akko_auth_set_password(const char *user, const char *pass);
int akko_auth_del_user(const char *user);
int akko_auth_count_humans(void);          /* usuários com uid >= 1000 */
int akko_auth_valid_name(const char *user);

extern char akko_auth_error[160];

#endif
