#!/bin/sh
# Тесты слоя 6: решение по netfilter, login-server, проверка подсетей,
# tailscale up, инструкции. Запуск: sh test_layer6.sh
HERE=$(cd "$(dirname "$0")" && pwd)
TSI_NO_MAIN=1
. "$HERE/tsi.sh"

T=$(mktemp -d /tmp/tsi-test6.XXXXXX)
CONF="$T/tsi.conf"; RUNDIR="$T/run"; LOG_FILE="$RUNDIR/tsi.log"; ROLLBACK_FILE="$RUNDIR/rollback.list"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: получено [$2], ожидалось [$3]"; fi; }
rc()  { if [ "$2" -eq "$3" ]; then ok; else bad "$1: rc=$2, ожидалось $3"; fi; }
has() { if grep -Fxq -- "$2" "$MOCK_LOG"; then ok; else bad "$1: нет записи [$2]"; fi; }
nocall() { if grep -q -- "$2" "$MOCK_LOG"; then bad "$1: лишний вызов [$2]"; else ok; fi; }
reset_log() { : >"$MOCK_LOG"; }

# ---------- последовательный ввод вместо /dev/tty ----------
TTY_SCRIPT="$T/tty.script"; TTY_N=0
_read_tty() {
    ASK_REPLY=""
    [ "$NONINTERACTIVE" = 1 ] && return 2
    TTY_N=$((TTY_N + 1))
    _rt_line=$(sed -n "${TTY_N}p" "$TTY_SCRIPT")
    [ "$(wc -l <"$TTY_SCRIPT" | tr -d ' ')" -ge "$TTY_N" ] || return 2
    ASK_REPLY=$_rt_line
    return 0
}
feed() { : >"$TTY_SCRIPT"; TTY_N=0; for l in "$@"; do printf '%s\n' "$l" >>"$TTY_SCRIPT"; done; }

# ---------- мок tailscale ----------
BASEPATH=$PATH
MOCK_LOG="$T/calls.log"; mkdir -p "$T/tools"
export MOCK_LOG MOCK_TS_RC
cat >"$T/tools/tailscale" <<'M'
#!/bin/sh
echo "tailscale $*" >>"$MOCK_LOG"
echo "To authenticate, visit:" >&2
echo "" >&2
printf '\thttps://login.tailscale.com/a/abc123\n' >&2
exit ${MOCK_TS_RC:-0}
M
chmod +x "$T/tools/tailscale"
PATH="$T/tools:$BASEPATH"

tsi_init 2>/dev/null; rc "tsi_init" $? 0; CUR_LANG=ru
reset_state() {
    rm -f "$CONF"; conf_reset; reset_log; rollback_init
    TS_ADVERTISE_EXIT_NODE=0; TS_ADVERTISE_ROUTES=""; UP_DONE=0; UP_AUTH_URL=""; UP_CMD=""
    NONINTERACTIVE=0; NETFILTER_FORCE=""; DNS_CONFLICTS=""; MOCK_TS_RC=0; feed
    PATH="$T/tools:$BASEPATH"
}

# ================= routes_validate =================
rv_ok() { routes_validate "$1"; if [ $? -eq 0 ] && [ "$ROUTES_NORMALIZED" = "$2" ]; then ok; else bad "routes ok [$1] -> [$ROUTES_NORMALIZED] err=$ROUTES_ERR"; fi; }
rv_bad() { routes_validate "$1"; if [ $? -ne 0 ] && [ "$ROUTES_ERR" = "$2" ]; then ok; else bad "routes bad [$1]: err=[$ROUTES_ERR], ожидалось [$2]"; fi; }
rv_ok "192.168.1.0/24" "192.168.1.0/24"
rv_ok "192.168.1.0/24,10.0.0.0/8" "192.168.1.0/24,10.0.0.0/8"
rv_ok "  192.168.1.0/24 , 10.0.0.0/8  " "192.168.1.0/24,10.0.0.0/8"
rv_ok "172.16.0.0/12" "172.16.0.0/12"
rv_ok "192.168.1.128/25" "192.168.1.128/25"
rv_ok "10.0.0.1/32" "10.0.0.1/32"
rv_ok "255.255.255.255/32" "255.255.255.255/32"
rv_ok "128.0.0.0/1" "128.0.0.0/1"
rv_bad "" empty
rv_bad "   " empty
rv_bad "0.0.0.0/0" prefix
rv_bad "192.168.1.0/33" prefix
rv_bad "192.168.1.0/024" prefix
rv_bad "192.168.1.5/24" hostbits
rv_bad "192.168.1.130/25" hostbits
rv_bad "10.0.0.1/8" hostbits
rv_bad "256.1.1.0/24" octet
rv_bad "192.168.01.0/24" octet
rv_bad "192.168.1.0000/24" octet
rv_bad "192.168.1/24" format
rv_bad "192.168.1.0" format
rv_bad "192.168.1.0/" format
rv_bad "/24" format
rv_bad "1.2.3.4.5/24" format
rv_bad "1..3.0/24" format
rv_bad "192.168.1.0/2/4" format
rv_bad "a.b.c.d/8" format
rv_bad ",192.168.1.0/24" format
rv_bad "192.168.1.0/24," format
rv_bad "192.168.1.0/24,,10.0.0.0/8" format
rv_bad '192.168.1.0/24;rm -rf /' format
rv_bad '192.168.1.0/24$(id)' format
rv_bad 'fd00::/64' format
rv_bad '192.168.*.0/24' format
rv_bad "192.168.1.0/24,10.0.0.5/8" hostbits
eq "routes: плохой элемент назван" "$ROUTES_BAD_ITEM" "10.0.0.5/8"

# ================= login_server_normalize =================
ln_ok() { eq "server [$1]" "$(login_server_normalize "$1")" "$2"; }
ln_bad() { login_server_normalize "$1" >/dev/null 2>&1; rc "server bad [$1]" $? 1; }
ln_ok "rc.routerich.ru" "https://rc.routerich.ru"
ln_ok "https://rc.routerich.ru" "https://rc.routerich.ru"
ln_ok "https://rc.routerich.ru/" "https://rc.routerich.ru"
ln_ok "  rc.routerich.ru  " "https://rc.routerich.ru"
ln_ok "hs.example.org:8443" "https://hs.example.org:8443"
ln_bad "http://rc.routerich.ru"
ln_bad "ftp://x.y"
ln_bad "rc routerich.ru"
ln_bad 'bad;host'
ln_bad 'x$(id).y'
ln_bad ""
ln_bad "https://"
ln_bad "///"

# ================= choose_login_server =================
reset_state; feed 2 "rc.routerich.ru"; choose_login_server >/dev/null 2>&1; rc "choose server custom" $? 0
eq "server saved" "$(conf_get LOGIN_SERVER)" "https://rc.routerich.ru"
feed 1; choose_login_server >/dev/null 2>&1; rc "choose server standard" $? 0; eq "server reset" "$(conf_get LOGIN_SERVER)" ""
reset_state; feed 2 "bad;host" "http://x.y" "" ; choose_login_server >/dev/null 2>&1; rc "choose server: 3 плохих ввода -> 1" $? 1
eq "server unchanged after failure" "$(conf_get LOGIN_SERVER)" ""
reset_state; feed 2 "bad;host" "rc.routerich.ru"; choose_login_server >/dev/null 2>&1; rc "choose server: со второй попытки" $? 0
eq "server saved 2nd try" "$(conf_get LOGIN_SERVER)" "https://rc.routerich.ru"
reset_state; NONINTERACTIVE=1; choose_login_server >/dev/null 2>&1; rc "choose server non-interactive" $? 1; NONINTERACTIVE=0

# ================= decide_netfilter_mode =================
STUB_RC=1
check_dns_conflicts() { DNS_CONFLICTS=$STUB_LIST; return "$STUB_RC"; }
dn() { decide_netfilter_mode >"$T/o" 2>"$T/e"; }
STUB_RC=0; STUB_LIST="podkop stubby"
reset_state; feed 1; dn; rc "конфликт, пусто, выбор 1" $? 0; eq "-> off" "$(conf_get NETFILTER_MODE)" off
grep -q 'podkop stubby' "$T/o" && ok || bad "netfilter: список конфликтов показан"
reset_state; feed 2; dn; rc "конфликт, пусто, выбор 2" $? 0; eq "-> on" "$(conf_get NETFILTER_MODE)" on
reset_state; conf_set NETFILTER_MODE on; feed 3; dn; rc "конфликт, on, оставить" $? 0; eq "keep on" "$(conf_get NETFILTER_MODE)" on
grep -q 'Текущее значение режима netfilter: on' "$T/o" && ok || bad "netfilter: текущее значение показано"
reset_state; conf_set NETFILTER_MODE on; feed 1; dn; eq "on -> off по выбору" "$(conf_get NETFILTER_MODE)" off
reset_state; conf_set NETFILTER_MODE off; feed 2; dn; eq "off -> on по выбору" "$(conf_get NETFILTER_MODE)" on
reset_state; NONINTERACTIVE=1; dn; rc "конфликт, пусто, неинтерактивно -> ошибка" $? 1
eq "неинтерактивно: ничего не записано" "$(conf_get NETFILTER_MODE)" ""
grep -q 'netfilter-off' "$T/e" && ok || bad "неинтерактивно: подсказка про --netfilter-off"
reset_state; NONINTERACTIVE=1; conf_set NETFILTER_MODE off; dn; rc "конфликт, задано, неинтерактивно -> keep" $? 0; eq "keep off" "$(conf_get NETFILTER_MODE)" off
STUB_RC=1; STUB_LIST=""
reset_state; dn; rc "нет конфликтов, пусто" $? 0; eq "-> on без вопроса" "$(conf_get NETFILTER_MODE)" on
reset_state; conf_set NETFILTER_MODE off; dn; eq "нет конфликтов, off не трогаем" "$(conf_get NETFILTER_MODE)" off
reset_state; NONINTERACTIVE=1; dn; rc "нет конфликтов, неинтерактивно" $? 0; eq "нет конфликтов неинт.: on" "$(conf_get NETFILTER_MODE)" on
STUB_RC=2; reset_state; dn; rc "ошибка check_dns_conflicts -> 1" $? 1; eq "ошибка: ничего не записано" "$(conf_get NETFILTER_MODE)" ""
STUB_RC=0; STUB_LIST="podkop"; reset_state; NETFILTER_FORCE=off; NONINTERACTIVE=1; dn; rc "NETFILTER_FORCE=off" $? 0; eq "force off" "$(conf_get NETFILTER_MODE)" off
STUB_RC=1; STUB_LIST=""; reset_state; NETFILTER_FORCE=off; dn; eq "force off без конфликтов" "$(conf_get NETFILTER_MODE)" off
unset -f check_dns_conflicts

# ================= build_up_cmd / _up_flags =================
reset_state; build_up_cmd; eq "up: без флагов" "$UP_CMD" "tailscale up"
CFG_LOGIN_SERVER=https://rc.routerich.ru; build_up_cmd; eq "up: login-server" "$UP_CMD" "tailscale up --login-server=https://rc.routerich.ru"
CFG_NETFILTER_MODE=off; build_up_cmd; eq "up: +netfilter off" "$UP_CMD" "tailscale up --login-server=https://rc.routerich.ru --netfilter-mode=off"
TS_ADVERTISE_EXIT_NODE=1; TS_ADVERTISE_ROUTES="192.168.1.0/24,10.0.0.0/8"; build_up_cmd
eq "up: все флаги" "$UP_CMD" "tailscale up --login-server=https://rc.routerich.ru --netfilter-mode=off --advertise-exit-node --advertise-routes=192.168.1.0/24,10.0.0.0/8"
CFG_NETFILTER_MODE=on; CFG_LOGIN_SERVER=""; build_up_cmd; eq "up: netfilter on - без флага" "$UP_CMD" "tailscale up --advertise-exit-node --advertise-routes=192.168.1.0/24,10.0.0.0/8"

# ================= run_tailscale_up =================
reset_state; CFG_LOGIN_SERVER=https://rc.routerich.ru; CFG_NETFILTER_MODE=off; TS_ADVERTISE_EXIT_NODE=1; TS_ADVERTISE_ROUTES=" 192.168.1.0/24 , 10.0.0.0/8 "
run_tailscale_up >"$T/o" 2>&1; rc "run up" $? 0
has "up: аргументы одним списком" "tailscale up --login-server=https://rc.routerich.ru --netfilter-mode=off --advertise-exit-node --advertise-routes=192.168.1.0/24,10.0.0.0/8"
eq "up: UP_DONE" "$UP_DONE" 1
eq "up: ссылка извлечена" "$UP_AUTH_URL" "https://login.tailscale.com/a/abc123"
grep -q 'https://login.tailscale.com/a/abc123' "$T/o" && ok || bad "up: ссылка показана пользователю"
grep -q '\[CMD\] \[run_tailscale_up\].*abc123' "$LOG_FILE" && ok || bad "up: вывод записан в лог"
grep -q 'tailscale up --login-server=https://rc.routerich.ru' "$LOG_FILE" && ok || bad "up: команда записана в лог"
reset_state; MOCK_TS_RC=3; run_tailscale_up >/dev/null 2>&1; rc "run up: код возврата пробрасывается" $? 3; eq "up fail: UP_DONE=0" "$UP_DONE" 0
reset_state; PATH="$BASEPATH"; run_tailscale_up >/dev/null 2>&1; rc "run up: нет tailscale" $? 1
reset_state; TS_ADVERTISE_ROUTES='1;2'; run_tailscale_up >/dev/null 2>&1; rc "run up: плохие подсети" $? 1; nocall "run up: плохие подсети без вызова" "tailscale up"
reset_state; TS_ADVERTISE_ROUTES='*'; run_tailscale_up >/dev/null 2>&1; rc "run up: glob в подсетях" $? 1; nocall "run up: glob без вызова" "tailscale up"
reset_state; CFG_LOGIN_SERVER='http://x.y'; run_tailscale_up >/dev/null 2>&1; rc "run up: плохой login-server" $? 1; nocall "run up: плохой сервер без вызова" "tailscale up"
reset_state; run_tailscale_up >/dev/null 2>&1; has "run up: без флагов" "tailscale up"
# каталог с файлами не влияет (glob отключён): подсети валидируются, но проверяем и сборку аргументов
reset_state; mkdir -p "$T/g"; : >"$T/g/a"; ( cd "$T/g" && CFG_LOGIN_SERVER=https://x.y run_tailscale_up >/dev/null 2>&1 ); has "run up: cwd с файлами не влияет" "tailscale up --login-server=https://x.y"

# ================= run_tailscale_up_flow =================
fw_is_setup() { return "$STUB_FW_SETUP"; }
fw_wan_forward_state() { return "$STUB_WAN_STATE"; }
fw_wan_forward_on() { echo "STUB fw_wan_forward_on" >>"$MOCK_LOG"; return 0; }
route_check_cgnat() { echo "STUB route_check_cgnat" >>"$MOCK_LOG"; return 0; }
STUB_FW_SETUP=0; STUB_WAN_STATE=1
# a) всё по умолчанию: без смены сервера, без exit node и подсетей, подтверждение
reset_state; feed n n n y; run_tailscale_up_flow >"$T/o" 2>&1; rc "flow: по умолчанию" $? 0
has "flow: tailscale up без флагов" "tailscale up"; has "flow: route_check после up" "STUB route_check_cgnat"; eq "flow: UP_DONE" "$UP_DONE" 1
nocall "flow: без wan-forward" "STUB fw_wan_forward_on"
# b) exit node + wan forward + подсети
reset_state; feed n y y y 192.168.1.0/24 y; run_tailscale_up_flow >"$T/o" 2>&1; rc "flow: exit node и подсети" $? 0
has "flow: wan forward включён" "STUB fw_wan_forward_on"
has "flow: флаги" "tailscale up --advertise-exit-node --advertise-routes=192.168.1.0/24"
# c) wan forward отклонён
reset_state; feed n y n n y; run_tailscale_up_flow >/dev/null 2>&1; nocall "flow: wan-forward отклонён" "STUB fw_wan_forward_on"; has "flow: exit node всё равно в команде" "tailscale up --advertise-exit-node"
# d) wan forward уже включён - не спрашиваем
STUB_WAN_STATE=0; reset_state; feed n y n y; run_tailscale_up_flow >/dev/null 2>&1; nocall "flow: wan уже включён" "STUB fw_wan_forward_on"; STUB_WAN_STATE=1
# e) firewall не настроен - не предлагаем wan-forward
STUB_FW_SETUP=1; reset_state; feed n y n y; run_tailscale_up_flow >/dev/null 2>&1; nocall "flow: firewall не настроен" "STUB fw_wan_forward_on"; STUB_FW_SETUP=0
# f) подсети: сначала плохой ввод, потом верный
reset_state; feed n n y "192.168.1.5/24" "192.168.1.0/24" y; run_tailscale_up_flow >"$T/o" 2>"$T/e"; has "flow: подсети со 2-й попытки" "tailscale up --advertise-routes=192.168.1.0/24"
grep -q '192.168.1.5/24' "$T/e" && ok || bad "flow: ошибка называет плохую подсеть"
# g) три плохих ввода - подсети не анонсируются
reset_state; feed n n y x y z y; run_tailscale_up_flow >/dev/null 2>&1; has "flow: 3 плохих ввода -> без подсетей" "tailscale up"; nocall "flow: подсети не попали в команду" "advertise-routes"
# h) смена сервера
reset_state; feed y 2 rc.routerich.ru n n y; run_tailscale_up_flow >/dev/null 2>&1
has "flow: свой сервер" "tailscale up --login-server=https://rc.routerich.ru"; eq "flow: сервер в конфиге" "$(conf_get LOGIN_SERVER)" "https://rc.routerich.ru"
# i) отказ от подтверждения
reset_state; feed n n n n; run_tailscale_up_flow >/dev/null 2>&1; rc "flow: отказ" $? 0; nocall "flow: отказ без tailscale" "tailscale up"; nocall "flow: отказ без route_check" "route_check"
# j) сбой tailscale up: код возврата, route_check не вызывается
reset_state; MOCK_TS_RC=2; feed n n n y; run_tailscale_up_flow >/dev/null 2>"$T/e"; rc "flow: сбой up -> код" $? 2
nocall "flow: после сбоя без route_check" "STUB route_check"; eq "flow: после сбоя UP_DONE=0" "$UP_DONE" 0
# k) неинтерактивно
reset_state; NONINTERACTIVE=1; run_tailscale_up_flow >"$T/o" 2>&1; rc "flow: неинтерактивно" $? 0; nocall "flow: неинтерактивно без tailscale" "tailscale up"
grep -q 'Неинтерактивный режим' "$T/o" && ok || bad "flow: сообщение о неинтерактивном режиме"
# l) текущий сервер показывается в вопросе
reset_state; conf_set LOGIN_SERVER https://hs.example.org; feed n n n y; run_tailscale_up_flow >"$T/o" 2>&1; grep -q 'https://hs.example.org' "$T/o" && ok || bad "flow: текущий сервер показан"
unset -f fw_is_setup fw_wan_forward_state fw_wan_forward_on route_check_cgnat

# ================= show_post_install =================
reset_state; UP_DONE=1; UP_AUTH_URL="https://login.tailscale.com/a/abc123"; CFG_NETFILTER_MODE=off
show_post_install >"$T/o" 2>"$T/e"
grep -q 'login.tailscale.com/a/abc123' "$T/o" && ok || bad "post: ссылка авторизации"
grep -q 'advertise-exit-node' "$T/o" && grep -q 'advertise-routes' "$T/o" && ok || bad "post: exit node и подсети"
grep -q 'одобрить' "$T/o" && ok || bad "post: напоминание об одобрении"
grep -q 'netfilter-mode=off' "$T/o" && ok || bad "post: справка про netfilter off"
[ -s "$T/e" ] && bad "post: без предупреждений при off" || ok
reset_state; CFG_NETFILTER_MODE=off; CFG_LOGIN_SERVER=https://rc.routerich.ru; show_post_install >"$T/o" 2>&1
grep -q 'tailscale up --login-server=https://rc.routerich.ru --netfilter-mode=off' "$T/o" && ok || bad "post: команда с login-server и off, если up не выполнялся"
reset_state; CFG_NETFILTER_MODE=on; DNS_CONFLICTS="podkop"; show_post_install >"$T/o" 2>"$T/e"
grep -q 'podkop' "$T/e" && ok || bad "post: предупреждение о DNS-пакетах при on"
reset_state; CFG_NETFILTER_MODE=on; DNS_CONFLICTS=""; show_post_install >"$T/o" 2>"$T/e"; [ -s "$T/e" ] && bad "post: без конфликтов нет предупреждения" || ok
CUR_LANG=en; reset_state; CFG_NETFILTER_MODE=off; show_post_install >"$T/o" 2>&1; grep -q 'What next' "$T/o" && ok || bad "post: английский"; CUR_LANG=ru

# ================= i18n =================
CUR_LANG=ru; i18n_selfcheck 2>/dev/null; rc "i18n selfcheck" $? 0
keys_of() { sed -n "/^$1() {/,/^}/p" "$HERE/tsi.sh" | sed -n 's/^ *\([A-Z0-9_]*\)) *_S=.*/\1/p' | sort | tr '\n' ' '; }
eq "keys ru==en" "$(keys_of strings_ru)" "$(keys_of strings_en)"
eq "keys == I18N_KEYS" "$(keys_of strings_ru)" "$(for k in $I18N_KEYS; do echo $k; done | sort | tr '\n' ' ')"
# в слое 6 нет eval и нет run_ext для tailscale up
sed -n '/^# 8\. TAILSCALE UP/,$p' "$HERE/tsi.sh" | grep -v '^[[:space:]]*#' | grep -q '\beval\b' && bad "слой 6: eval" || ok

rm -rf "$T"
printf 'passed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
