#!/bin/sh
# Тесты слоя 8: параметры CLI, main, сценарий установки, меню, статус.
# Запуск: sh test_layer8.sh
HERE=$(cd "$(dirname "$0")" && pwd)
TSI_NO_MAIN=1
. "$HERE/tsi.sh"
SH_UNDER_TEST=${TSI_TEST_SH:-sh}

T=$(mktemp -d /tmp/tsi-test8.XXXXXX)
CONF="$T/tsi.conf"; RUNDIR="$T/run"; LOG_FILE="$RUNDIR/tsi.log"; ROLLBACK_FILE="$RUNDIR/rollback.list"
MOCK_LOG="$T/calls.log"; : >"$MOCK_LOG"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: получено [$2], ожидалось [$3]"; fi; }
rc()  { if [ "$2" -eq "$3" ]; then ok; else bad "$1: rc=$2, ожидалось $3"; fi; }
calls() { tr '\n' ' ' <"$MOCK_LOG" | sed 's/ $//'; }
reset_log() { : >"$MOCK_LOG"; }
log() { echo "$1" >>"$MOCK_LOG"; }

# ---------- последовательный ввод ----------
TTY_SCRIPT="$T/tty.script"; TTY_N=0
_read_tty() {
    ASK_REPLY=""
    [ "$NONINTERACTIVE" = 1 ] && return 2
    TTY_N=$((TTY_N + 1))
    [ "$(wc -l <"$TTY_SCRIPT" | tr -d ' ')" -ge "$TTY_N" ] || return 2
    ASK_REPLY=$(sed -n "${TTY_N}p" "$TTY_SCRIPT")
    return 0
}
feed() { : >"$TTY_SCRIPT"; TTY_N=0; for l in "$@"; do printf '%s\n' "$l" >>"$TTY_SCRIPT"; done; }

tsi_init 2>/dev/null; rc "tsi_init" $? 0; CUR_LANG=ru
reset_state() { rm -f "$CONF"; conf_reset; reset_log; feed; NONINTERACTIVE=0; NETFILTER_FORCE=""; SOURCE_CHOICE=""; CUR_LANG=ru; }

# ================= parse_args =================
pa_ok() { # ожидаемый MODE, netfilter-off, login-server ; аргументы...
    _e_mode=$1; _e_nf=$2; _e_ls=$3; shift 3
    parse_args "$@"; _r=$?
    if [ "$_r" -eq 0 ] && [ "$MODE" = "$_e_mode" ] && [ "$ARG_NETFILTER_OFF" = "$_e_nf" ] && [ "$ARG_LOGIN_SERVER" = "$_e_ls" ]; then ok
    else bad "parse [$*]: rc=$_r MODE=[$MODE] nf=[$ARG_NETFILTER_OFF] ls=[$ARG_LOGIN_SERVER] (ожидалось $_e_mode/$_e_nf/$_e_ls)"; fi
}
pa_bad() { parse_args "$@"; _r=$?; if [ "$_r" -ne 0 ] && [ -n "$PARSE_ERR" ]; then ok; else bad "parse [$*] должен отвергаться (rc=$_r)"; fi; }
pa_ok menu 0 ""
pa_ok status 0 "" --status
pa_ok update 0 "" --update
pa_ok install-official 0 "" --install-official
pa_ok install-lite 0 "" --install-lite
pa_ok install-lite 1 "" --install-lite --netfilter-off
pa_ok install-lite 1 "" --netfilter-off --install-lite
pa_ok install-official 0 "rc.routerich.ru" --install-official --login-server=rc.routerich.ru
pa_ok install-lite 1 "https://rc.x.y" --login-server=https://rc.x.y --netfilter-off --install-lite
pa_ok help 0 "" --help
pa_ok help 0 "" -h
pa_ok version 0 "" --version
pa_ok version 0 "" -V
pa_ok status 0 "" --status --status
pa_bad --bogus
pa_bad --status --update
pa_bad --install-lite --install-official
pa_bad --netfilter-off
pa_bad --login-server=x.y
pa_bad --update --netfilter-off
pa_bad --status --login-server=x.y
pa_bad --install-lite --login-server
pa_bad --install-lite --login-server=
pa_bad --uninstall
pa_bad -y
pa_bad --quiet
pa_bad --install-lite-direct
pa_bad "extra"
parse_args --bogus; eq "parse: PARSE_ERR хранит параметр" "$PARSE_ERR" "--bogus"

# ================= usage / version / main (stubs) =================
# все внешние шаги заменены заглушками, записывающими вызов
_is_root() { return "${STUB_ROOT:-0}"; }
install_self() { log install_self; return "${STUB_SELF:-0}"; }
detect_release() { log detect_release; return 0; }
detect_pkg_mgr() { log detect_pkg_mgr; PKG_MGR=opkg; return 0; }
detect_arch() { log detect_arch; return "${STUB_ARCH:-0}"; }
first_run_language() { log "first_run_language NI=$NONINTERACTIVE"; return 0; }
show_status() { log show_status; return 0; }
update_tailscale() { log "update NI=$NONINTERACTIVE"; return "${STUB_UPDATE:-0}"; }
run_install_flow() { log "install SRC=$SOURCE_CHOICE NI=$NONINTERACTIVE FORCE=$NETFILTER_FORCE"; return "${STUB_INSTALL:-0}"; }
menu_main() { log "menu NI=$NONINTERACTIVE"; return 0; }
STUB_ROOT=0; STUB_SELF=0; STUB_UPDATE=0; STUB_INSTALL=0; STUB_ARCH=0

reset_state; main --help >"$T/o" 2>&1; rc "main --help" $? 0
grep -q -- '--install-lite' "$T/o" && grep -q -- '--netfilter-off' "$T/o" && grep -q -- '--login-server' "$T/o" && ok || bad "help: перечислены параметры"
grep -q -- '--uninstall' "$T/o" && bad "help: нет --uninstall" || ok
grep -q 'только через меню' "$T/o" && ok || bad "help: про удаление и direct"
eq "help: без побочных вызовов" "$(calls)" ""
CUR_LANG=en; conf_set LANG en; main -h >"$T/o" 2>&1; grep -q 'Usage: tsi' "$T/o" && ok || bad "help на английском"; CUR_LANG=ru
reset_state; main --version >"$T/o" 2>&1; rc "main --version" $? 0; eq "version: вывод" "$(cat "$T/o")" "tsi $TSI_VERSION"; eq "version: без вызовов" "$(calls)" ""
reset_state; main --bogus >"$T/o" 2>"$T/e"; rc "main: неверный параметр -> 2" $? 2
grep -q -- '--bogus' "$T/e" && grep -q 'Использование' "$T/e" && ok || bad "main: ошибка и справка в stderr"; eq "main: неверный параметр без вызовов" "$(calls)" ""
reset_state; STUB_ROOT=1; main --status >/dev/null 2>"$T/e"; rc "main: не root -> 1" $? 1; STUB_ROOT=0; eq "main: не root без вызовов" "$(calls)" ""
reset_state; main --status >/dev/null 2>&1; rc "main --status" $? 0
eq "main --status: порядок (без вопроса о языке)" "$(calls)" "install_self detect_release detect_pkg_mgr detect_arch show_status"
reset_state; main --update >/dev/null 2>&1; eq "main --update: неинтерактивно" "$(calls)" "install_self detect_release detect_pkg_mgr detect_arch update NI=1"
reset_state; STUB_UPDATE=2; main --update >/dev/null 2>&1; rc "main --update: код 2 пробрасывается" $? 2; STUB_UPDATE=0
reset_state; main --install-official >/dev/null 2>&1; rc "main --install-official" $? 0
eq "main --install-official: вызовы" "$(calls)" "install_self detect_release detect_pkg_mgr detect_arch install SRC=official NI=1 FORCE="
reset_state; main --install-lite --netfilter-off >/dev/null 2>&1
eq "main --install-lite: источник и NETFILTER_FORCE" "$(calls)" "install_self detect_release detect_pkg_mgr detect_arch install SRC=lite_feed NI=1 FORCE=off"
reset_state; STUB_INSTALL=1; main --install-lite >/dev/null 2>&1; rc "main: код установки пробрасывается" $? 1; STUB_INSTALL=0
reset_state; main --install-lite --login-server=rc.routerich.ru >/dev/null 2>&1; eq "main: login-server в конфиге" "$(conf_get LOGIN_SERVER)" "https://rc.routerich.ru"
reset_state; main --install-lite --login-server='bad;host' >/dev/null 2>"$T/e"; rc "main: плохой login-server -> 2" $? 2; eq "main: плохой login-server не записан" "$(conf_get LOGIN_SERVER)" ""
grep -q 'bad;host' "$T/e" && ok || bad "main: ошибка называет адрес"; nocall_install=$(calls); case "$nocall_install" in *install\ SRC*) bad "main: плохой сервер, установка не запускается" ;; *) ok ;; esac
reset_state; main >/dev/null 2>&1; rc "main: меню" $? 0; eq "main: меню интерактивно" "$(calls)" "install_self first_run_language NI=0 detect_release detect_pkg_mgr detect_arch menu NI=0"
reset_state; STUB_SELF=1; main --status >/dev/null 2>&1; rc "main: install_self отказал -> 1" $? 1; STUB_SELF=0; eq "main: после отказа install_self ничего не выполняется" "$(calls)" "install_self"
reset_state; STUB_ARCH=1; main --status >/dev/null 2>&1; rc "main: неопределённая архитектура не критична" $? 0; STUB_ARCH=0
unset -f _is_root install_self detect_release detect_pkg_mgr detect_arch first_run_language show_status update_tailscale run_install_flow menu_main
. "$HERE/tsi.sh"; RUNDIR="$T/run"; LOG_FILE="$RUNDIR/tsi.log"; ROLLBACK_FILE="$RUNDIR/rollback.list"; CONF="$T/tsi.conf"
_read_tty() { ASK_REPLY=""; [ "$NONINTERACTIVE" = 1 ] && return 2; TTY_N=$((TTY_N + 1)); [ "$(wc -l <"$TTY_SCRIPT" | tr -d ' ')" -ge "$TTY_N" ] || return 2; ASK_REPLY=$(sed -n "${TTY_N}p" "$TTY_SCRIPT"); return 0; }

# ================= first_run_language =================
reset_state; feed 1; first_run_language >/dev/null 2>&1; eq "lang: русский" "$(conf_get LANG)/$CUR_LANG" "ru/ru"
reset_state; feed 2; first_run_language >/dev/null 2>&1; eq "lang: английский" "$(conf_get LANG)/$CUR_LANG" "en/en"
reset_state; conf_set LANG en; i18n_init; feed 1; first_run_language >"$T/o" 2>&1; eq "lang: уже выбран - не спрашиваем" "$(conf_get LANG)" "en"; [ -s "$T/o" ] && bad "lang: молчит" || ok
CUR_LANG=ru
reset_state; NONINTERACTIVE=1; first_run_language >/dev/null 2>&1; eq "lang: неинтерактивно не пишет" "$(conf_get LANG)" ""
reset_state; first_run_language >/dev/null 2>&1; rc "lang: нет ввода" $? 0; eq "lang: нет ввода - не пишем" "$(conf_get LANG)" ""
reset_state; feed 1; first_run_language >"$T/o" 2>&1; grep -q 'Select language' "$T/o" && ok || bad "lang: приглашение двуязычное"

# ================= show_status =================
STUB_PKG=1; STUB_FW=0; STUB_UP=0
pkg_installed() { return "$STUB_PKG"; }
pkg_version() { printf '1.104.1-r1'; }
fw_is_setup() { return "$STUB_FW"; }
pidof() { return "$STUB_UP"; }
PATH_SAVE=$PATH; mkdir -p "$T/tools"; printf '#!/bin/sh\necho "STATUS-OUT $*"\n' >"$T/tools/tailscale"; chmod +x "$T/tools/tailscale"; PATH="$T/tools:$PATH"
reset_state; STUB_PKG=0; STUB_FW=0; STUB_UP=0; CFG_INSTALL_SOURCE=B; CFG_B_SUBMODE=feed; CFG_NETFILTER_MODE=off; CFG_LOGIN_SERVER=https://rc.routerich.ru
show_status >"$T/o" 2>&1; rc "status" $? 0
for k in '1.104.1-r1' 'lite-feed' 'Служба: запущена' 'зона tailscale настроена' 'netfilter: off' 'https://rc.routerich.ru' 'STATUS-OUT status'; do grep -q -- "$k" "$T/o" && ok || bad "status: [$k]"; done
reset_state; STUB_PKG=1; STUB_FW=1; STUB_UP=1; show_status >"$T/o" 2>&1
grep -q 'не установлен' "$T/o" && ok || bad "status: пакет не установлен"; grep -q 'Служба: не запущена' "$T/o" && ok || bad "status: служба не запущена"
grep -q 'STATUS-OUT' "$T/o" && bad "status: tailscale status не вызывается без службы" || ok
grep -q 'не настроена' "$T/o" && ok || bad "status: firewall не настроен"; grep -q 'стандартный' "$T/o" && ok || bad "status: стандартный сервер"
reset_state; CFG_INSTALL_SOURCE=A; STUB_PKG=0; STUB_UP=1; show_status >"$T/o" 2>&1; grep -q 'official' "$T/o" && ok || bad "status: official"
unset -f pkg_installed pkg_version fw_is_setup pidof; PATH=$PATH_SAVE
. "$HERE/tsi.sh"; RUNDIR="$T/run"; LOG_FILE="$RUNDIR/tsi.log"; ROLLBACK_FILE="$RUNDIR/rollback.list"; CONF="$T/tsi.conf"
_read_tty() { ASK_REPLY=""; [ "$NONINTERACTIVE" = 1 ] && return 2; TTY_N=$((TTY_N + 1)); [ "$(wc -l <"$TTY_SCRIPT" | tr -d ' ')" -ge "$TTY_N" ] || return 2; ASK_REPLY=$(sed -n "${TTY_N}p" "$TTY_SCRIPT"); return 0; }

# ================= run_install_flow (заглушки шагов) =================
step() { # имя, переменная кода возврата
    eval "$1() { log $1; return \${STUB_$2:-0}; }"
}
step choose_source CHOOSE; step install_deps DEPS; step check_tun TUN; step decide_netfilter_mode NF; step install_selected SEL
step fw_setup FW; step set_fw_debug_mode FWMODE; step service_enable_start SVC; step register_sysupgrade SYS
step run_tailscale_up_flow UP; step install_luci_ask LUCI
show_post_install() { log show_post_install; return 0; }
rollback_init() { log rollback_init; }
rollback_run() { log rollback_run; }
rollback_clear() { log rollback_clear; }
clear_stubs() { STUB_CHOOSE=0; STUB_DEPS=0; STUB_TUN=0; STUB_NF=0; STUB_SEL=0; STUB_FW=0; STUB_FWMODE=0; STUB_SVC=0; STUB_SYS=0; STUB_UP=0; STUB_LUCI=0; }
clear_stubs
FULL="rollback_init install_deps check_tun decide_netfilter_mode install_selected fw_setup set_fw_debug_mode service_enable_start register_sysupgrade run_tailscale_up_flow show_post_install install_luci_ask rollback_clear"
reset_state; SOURCE_CHOICE=official; run_install_flow >"$T/o" 2>&1; rc "flow: успех" $? 0; eq "flow: порядок шагов" "$(calls)" "$FULL"
grep -q 'Установка завершена.' "$T/o" && ok || bad "flow: итоговое сообщение"
reset_state; run_install_flow >/dev/null 2>&1; eq "flow: без выбора источника вызывает choose_source" "$(calls)" "rollback_init choose_source install_deps check_tun decide_netfilter_mode install_selected fw_setup set_fw_debug_mode service_enable_start register_sysupgrade run_tailscale_up_flow show_post_install install_luci_ask rollback_clear"
reset_state; STUB_CHOOSE=1; run_install_flow >/dev/null 2>&1; rc "flow: choose_source сбой" $? 1; eq "flow: после сбоя choose_source" "$(calls)" "rollback_init choose_source"; clear_stubs
reset_state; SOURCE_CHOICE=official; STUB_DEPS=1; run_install_flow >/dev/null 2>&1; rc "flow: сбой install_deps" $? 1; eq "flow: install_deps -> откат" "$(calls)" "rollback_init install_deps rollback_run"; clear_stubs
reset_state; SOURCE_CHOICE=official; STUB_TUN=1; NONINTERACTIVE=1; run_install_flow >/dev/null 2>"$T/e"; rc "flow: нет TUN неинтерактивно" $? 1
eq "flow: нет TUN неинтерактивно -> откат" "$(calls)" "rollback_init install_deps check_tun rollback_run"; [ -s "$T/e" ] && ok || bad "flow: сообщение о TUN"
reset_state; SOURCE_CHOICE=official; STUB_TUN=1; feed n; run_install_flow >/dev/null 2>&1; rc "flow: нет TUN, отказ продолжить" $? 1; eq "flow: отказ -> откат" "$(calls)" "rollback_init install_deps check_tun rollback_run"
reset_state; SOURCE_CHOICE=official; STUB_TUN=1; feed y; run_install_flow >/dev/null 2>&1; rc "flow: нет TUN, согласие продолжить" $? 0; eq "flow: согласие -> полный путь" "$(calls)" "$FULL"; clear_stubs
reset_state; SOURCE_CHOICE=official; STUB_NF=1; run_install_flow >/dev/null 2>&1; rc "flow: decide_netfilter_mode сбой" $? 1; eq "flow: netfilter -> откат до установки" "$(calls)" "rollback_init install_deps check_tun decide_netfilter_mode rollback_run"; clear_stubs
reset_state; SOURCE_CHOICE=lite_feed; STUB_SEL=2; run_install_flow >/dev/null 2>&1; rc "flow: отказ пользователя (2)" $? 2; eq "flow: отказ -> откат" "$(calls)" "rollback_init install_deps check_tun decide_netfilter_mode install_selected rollback_run"; clear_stubs
reset_state; SOURCE_CHOICE=lite_feed; STUB_SEL=1; run_install_flow >/dev/null 2>&1; rc "flow: сбой установки (1)" $? 1; clear_stubs
# сбои после установки пакета не прерывают сценарий, итог = 1
for st in FW FWMODE SVC SYS UP; do
    reset_state; SOURCE_CHOICE=official; eval "STUB_$st=1"; run_install_flow >"$T/o" 2>"$T/e"; _r=$?
    rc "flow: сбой $st -> итог 1" $_r 1; eq "flow: сбой $st - путь продолжается" "$(calls)" "$FULL"
    grep -q 'предупреждениями' "$T/e" && ok || bad "flow: сбой $st - итоговое предупреждение"; clear_stubs
done
unset -f choose_source install_deps check_tun decide_netfilter_mode install_selected fw_setup set_fw_debug_mode service_enable_start register_sysupgrade run_tailscale_up_flow install_luci_ask show_post_install rollback_init rollback_run rollback_clear
. "$HERE/tsi.sh"; RUNDIR="$T/run"; LOG_FILE="$RUNDIR/tsi.log"; ROLLBACK_FILE="$RUNDIR/rollback.list"; CONF="$T/tsi.conf"
_read_tty() { ASK_REPLY=""; [ "$NONINTERACTIVE" = 1 ] && return 2; TTY_N=$((TTY_N + 1)); [ "$(wc -l <"$TTY_SCRIPT" | tr -d ' ')" -ge "$TTY_N" ] || return 2; ASK_REPLY=$(sed -n "${TTY_N}p" "$TTY_SCRIPT"); return 0; }

# ================= меню =================
menu_install() { log menu_install; }
update_tailscale() { log update_tailscale; }
uninstall_tailscale() { log uninstall_tailscale; return "${STUB_UN:-0}"; }
show_status() { log show_status; }
menu_settings() { log menu_settings; }
STUB_UN=0
reset_state; feed 1 2 4 5 0; menu_main >"$T/o" 2>&1; rc "menu_main" $? 0; eq "menu_main: пункты" "$(calls)" "menu_install update_tailscale show_status menu_settings"
for k in 'Установить Tailscale' 'Обновить Tailscale' 'Удалить Tailscale' 'Статус' 'Настройки' 'Выход'; do grep -q "$k" "$T/o" && ok || bad "menu_main: пункт [$k]"; done
reset_state; feed 3; STUB_UN=0; menu_main >/dev/null 2>&1; rc "menu_main: после удаления выход" $? 0; eq "menu_main: удаление" "$(calls)" "uninstall_tailscale"
reset_state; feed 3 0; STUB_UN=2; menu_main >/dev/null 2>&1; rc "menu_main: отмена удаления -> остаёмся в меню" $? 0; eq "menu_main: отмена" "$(calls)" "uninstall_tailscale"
reset_state; menu_main >/dev/null 2>"$T/e"; rc "menu_main: нет ввода -> 1" $? 1; [ -s "$T/e" ] && ok || bad "menu_main: сообщение об отсутствии ввода"
reset_state; feed 0; menu_main >/dev/null 2>&1; rc "menu_main: выход" $? 0; eq "menu_main: выход без вызовов" "$(calls)" ""
unset -f menu_install update_tailscale uninstall_tailscale show_status menu_settings
. "$HERE/tsi.sh"; RUNDIR="$T/run"; LOG_FILE="$RUNDIR/tsi.log"; ROLLBACK_FILE="$RUNDIR/rollback.list"; CONF="$T/tsi.conf"
_read_tty() { ASK_REPLY=""; [ "$NONINTERACTIVE" = 1 ] && return 2; TTY_N=$((TTY_N + 1)); [ "$(wc -l <"$TTY_SCRIPT" | tr -d ' ')" -ge "$TTY_N" ] || return 2; ASK_REPLY=$(sed -n "${TTY_N}p" "$TTY_SCRIPT"); return 0; }

# ---- настройки ----
choose_login_server() { log choose_login_server; return 0; }
fw_wan_forward_toggle() { log fw_wan_forward_toggle; }
set_fw_debug_mode() { log set_fw_debug_mode; return "${STUB_FWM:-0}"; }
service_restart() { log service_restart; }
install_luci() { log install_luci; }
run_tailscale_up_flow() { log run_tailscale_up_flow; }
show_post_install() { log show_post_install; }
STUB_FWM=0
reset_state; feed 2 4 7 8 9 0; menu_settings >"$T/o" 2>&1; rc "menu_settings" $? 0
eq "menu_settings: пункты" "$(calls)" "choose_login_server fw_wan_forward_toggle install_luci run_tailscale_up_flow show_post_install"
for k in 'Язык интерфейса' 'Сервер Tailscale' 'Режим netfilter' 'Forwarding tailscale' 'Режим firewall' 'Подробный лог' 'Показать конфигурацию' 'LuCI' 'tailscale up' 'Назад'; do grep -q "$k" "$T/o" && ok || bad "menu_settings: пункт [$k]"; done
grep -q 'Вступит\|вступит' "$T/o" && ok || bad "menu_settings: после смены сервера подсказка про tailscale up"
reset_state; conf_set NETFILTER_MODE on; conf_set LOG_VERBOSE 0; feed 7 0; menu_settings >"$T/o" 2>&1; grep -q 'NETFILTER_MODE=on' "$T/o" && ok || bad "menu_settings: просмотр конфигурации"
reset_state; feed 1 2 0; menu_settings >/dev/null 2>&1; eq "settings: язык -> en" "$(conf_get LANG)/$CUR_LANG" "en/en"
reset_state; feed 1 1 0; CUR_LANG=en; conf_set LANG en; menu_settings >/dev/null 2>&1; eq "settings: язык -> ru" "$(conf_get LANG)/$CUR_LANG" "ru/ru"
reset_state; feed 3 1 0; menu_settings >"$T/o" 2>&1; eq "settings: netfilter -> off" "$(conf_get NETFILTER_MODE)" "off"; grep -q 'следующем tailscale up' "$T/o" && ok || bad "settings: напоминание про tailscale up"
reset_state; conf_set NETFILTER_MODE off; feed 3 2 0; menu_settings >/dev/null 2>&1; eq "settings: netfilter -> on" "$(conf_get NETFILTER_MODE)" "on"
reset_state; conf_set NETFILTER_MODE off; feed 3 3 0; menu_settings >/dev/null 2>&1; eq "settings: netfilter назад - без изменений" "$(conf_get NETFILTER_MODE)" "off"
reset_state; feed 6 0; menu_settings >/dev/null 2>&1; eq "settings: verbose включён" "$(conf_get LOG_VERBOSE)" "1"
reset_state; conf_set LOG_VERBOSE 1; feed 6 0; menu_settings >/dev/null 2>&1; eq "settings: verbose выключен" "$(conf_get LOG_VERBOSE)" "0"
reset_state; feed 5 y 0; menu_settings >/dev/null 2>&1; eq "settings: fw_mode + перезапуск" "$(calls)" "set_fw_debug_mode service_restart"
reset_state; feed 5 n 0; menu_settings >/dev/null 2>&1; eq "settings: fw_mode без перезапуска" "$(calls)" "set_fw_debug_mode"
reset_state; STUB_FWM=1; feed 5 0; menu_settings >/dev/null 2>&1; eq "settings: сбой fw_mode - без вопроса о перезапуске" "$(calls)" "set_fw_debug_mode"; STUB_FWM=0
reset_state; menu_settings >/dev/null 2>&1; rc "menu_settings: нет ввода -> 1" $? 1
unset -f choose_login_server fw_wan_forward_toggle set_fw_debug_mode service_restart install_luci run_tailscale_up_flow show_post_install

# ================= запуск файла как скрипта =================
$SH_UNDER_TEST "$HERE/tsi.sh" --version >"$T/o" 2>&1; rc "script --version" $? 0; eq "script --version: вывод" "$(cat "$T/o")" "tsi $TSI_VERSION"
$SH_UNDER_TEST "$HERE/tsi.sh" --help >"$T/o" 2>&1; rc "script --help" $? 0; grep -q 'install-lite' "$T/o" && ok || bad "script --help: вывод"
$SH_UNDER_TEST "$HERE/tsi.sh" --bogus >"$T/o" 2>"$T/e"; rc "script --bogus" $? 2; grep -q 'bogus' "$T/e" && ok || bad "script --bogus: ошибка"
$SH_UNDER_TEST "$HERE/tsi.sh" --install-lite --status >/dev/null 2>&1; rc "script: два режима" $? 2
# через пайп: подсказка двухшагового запуска, ни копий, ни побочных эффектов
if [ "$(id -u)" = 0 ]; then
    cat "$HERE/tsi.sh" | $SH_UNDER_TEST >"$T/o" 2>&1; _r=$?
    rc "script через пайп -> 1" $_r 1; grep -q 'wget -O /tmp/tsi.sh' "$T/o" && ok || bad "script через пайп: подсказка"
    [ -e /usr/bin/tsi ] && bad "script через пайп: /usr/bin/tsi не создаётся" || ok
fi

# ================= i18n и ограничения =================
CUR_LANG=ru; i18n_selfcheck 2>/dev/null; rc "i18n selfcheck" $? 0
keys_of() { sed -n "/^$1() {/,/^}/p" "$HERE/tsi.sh" | sed -n 's/^ *\([A-Z0-9_]*\)) *_S=.*/\1/p' | sort | tr '\n' ' '; }
eq "keys ru==en" "$(keys_of strings_ru)" "$(keys_of strings_en)"
eq "keys == I18N_KEYS" "$(keys_of strings_ru)" "$(for k in $I18N_KEYS; do echo $k; done | sort | tr '\n' ' ')"
sed -n '/^# 10\. CLI, МЕНЮ/,$p' "$HERE/tsi.sh" | grep -v '^[[:space:]]*#' | grep -Eq '(^|[^A-Za-z_-])(opkg|apk) [a-z-]' && bad "слой 8: прямой вызов opkg/apk" || ok
sed -n '/^# 10\. CLI, МЕНЮ/,$p' "$HERE/tsi.sh" | grep -v '^[[:space:]]*#' | grep -q '\beval\b' && bad "слой 8: eval" || ok
grep -v '^[[:space:]]*#' "$HERE/tsi.sh" | grep -q -- '--allow-untrusted' && bad "нигде нет --allow-untrusted" || ok
# нет флагов, которые мы исключили
sed -n '/^parse_args() {/,/^}/p' "$HERE/tsi.sh" | grep -Eq -- '--uninstall|--quiet|-y\)|--install-lite-direct|--lang|--verbose' && bad "parse_args: нет лишних флагов" || ok

rm -rf "$T"
printf 'passed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
