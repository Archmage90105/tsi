#!/bin/sh
# Тесты слоя 5 (сеть и firewall через uci) на эмуляторе uci с рабочей и
# закоммиченной копиями конфигов. Запуск: sh test_layer5.sh
HERE=$(cd "$(dirname "$0")" && pwd)
TSI_NO_MAIN=1
. "$HERE/tsi.sh"

T=$(mktemp -d /tmp/tsi-test5.XXXXXX)
CONF="$T/tsi.conf"; RUNDIR="$T/run"; LOG_FILE="$RUNDIR/tsi.log"
ROLLBACK_FILE="$RUNDIR/rollback.list"; TTY_DEV="$T/tty"; BACKUP_DIR="$RUNDIR/backup"
UCI_CONF_DIR="$T/etc_config"; FW_INIT="$T/init.firewall"; NET_INIT="$T/init.network"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: получено [$2], ожидалось [$3]"; fi; }
rc()  { if [ "$2" -eq "$3" ]; then ok; else bad "$1: rc=$2, ожидалось $3"; fi; }
has() { if grep -Fxq -- "$2" "$MOCK_LOG"; then ok; else bad "$1: нет вызова [$2]"; fi; }
nocall() { if grep -q -- "$2" "$MOCK_LOG"; then bad "$1: лишний вызов [$2]"; else ok; fi; }
cnt() { grep -Fxc -- "$1" "$MOCK_LOG"; }
lineno() { grep -Fxn -- "$1" "$MOCK_LOG" | head -n 1 | cut -d: -f1; }
reset_log() { : >"$MOCK_LOG"; }

# ---------- эмулятор uci ----------
BASEPATH=$PATH
UCI_DIR="$T/uci"; MOCK_LOG="$T/calls.log"
mkdir -p "$T/tools" "$T/fw4bin" "$UCI_DIR" "$UCI_CONF_DIR"
export UCI_DIR MOCK_LOG MOCK_UCI_FAIL_ON MOCK_RELOAD_FAIL MOCK_TS_LINK MOCK_ROUTE
cat >"$T/tools/uci" <<'M'
#!/bin/sh
D=$UCI_DIR
echo "uci $*" >>"$MOCK_LOG"
if [ -n "$MOCK_UCI_FAIL_ON" ]; then case "$*" in *"$MOCK_UCI_FAIL_ON"*) exit 1;; esac; fi
[ "$1" = "-q" ] && shift
cmd=$1; shift
split() { cfg=${1%%.*}; rest=${1#*.}; case "$rest" in *.*) sec=${rest%%.*}; opt=${rest#*.};; *) sec=$rest; opt="";; esac; [ "$rest" = "$1" ] && { sec=""; opt=""; }; }
touch_cfg() { for f in work com pend; do [ -f "$D/$1.$f" ] || : >"$D/$1.$f"; done; }
case "$cmd" in
  show)
    cfg=$1; touch_cfg "$cfg"
    sed -n "s/^\([^.=]*\)\.\([^=]*\)=\(.*\)\$/$cfg.\1.\2='\3'/p" "$D/$cfg.work"
    sed -n "s/^\([^.=]*\)=\(.*\)\$/$cfg.\1=\2/p" "$D/$cfg.work" ;;
  get)
    split "$1"; touch_cfg "$cfg"
    if [ -z "$opt" ]; then line=$(grep -m1 "^$sec=" "$D/$cfg.work") || exit 1; printf '%s\n' "${line#*=}"
    else line=$(grep -m1 "^$sec\.$opt=" "$D/$cfg.work") || exit 1; printf '%s\n' "${line#*=}"; fi ;;
  set|add_list)
    path=${1%%=*}; val=${1#*=}; split "$path"; touch_cfg "$cfg"
    if [ -z "$opt" ]; then grep -v "^$sec=" "$D/$cfg.work" >"$D/tmp"; printf '%s=%s\n' "$sec" "$val" >>"$D/tmp"
    else if [ "$cmd" = set ]; then grep -v "^$sec\.$opt=" "$D/$cfg.work" >"$D/tmp"; else cp "$D/$cfg.work" "$D/tmp"; fi
         printf '%s.%s=%s\n' "$sec" "$opt" "$val" >>"$D/tmp"; fi
    mv "$D/tmp" "$D/$cfg.work"; echo "$cfg.$sec" >>"$D/$cfg.pend" ;;
  delete)
    split "$1"; touch_cfg "$cfg"; before=$(wc -l <"$D/$cfg.work")
    if [ -z "$opt" ]; then grep -v "^$sec[.=]" "$D/$cfg.work" >"$D/tmp"; else grep -v "^$sec\.$opt=" "$D/$cfg.work" >"$D/tmp"; fi
    mv "$D/tmp" "$D/$cfg.work"; after=$(wc -l <"$D/$cfg.work")
    [ "$before" -eq "$after" ] && exit 1
    echo "$cfg.$sec" >>"$D/$cfg.pend" ;;
  revert)
    split "$1"; [ -z "$sec" ] && cfg=$1; touch_cfg "$cfg"
    if [ -z "$sec" ]; then cp "$D/$cfg.com" "$D/$cfg.work"; : >"$D/$cfg.pend"
    else grep -v "^$sec[.=]" "$D/$cfg.work" >"$D/tmp"; grep "^$sec[.=]" "$D/$cfg.com" >>"$D/tmp"; mv "$D/tmp" "$D/$cfg.work"
         grep -v "^$cfg\.$sec\$" "$D/$cfg.pend" >"$D/tmp"; mv "$D/tmp" "$D/$cfg.pend"; fi ;;
  commit)
    cfg=$1; touch_cfg "$cfg"; cp "$D/$cfg.work" "$D/$cfg.com"; : >"$D/$cfg.pend" ;;
  changes)
    for cfg in "$@"; do touch_cfg "$cfg"; sort -u "$D/$cfg.pend"; done ;;
esac
exit 0
M
cat >"$T/tools/ip" <<'M'
#!/bin/sh
echo "ip $*" >>"$MOCK_LOG"
case "$1 $2" in
  "link show") [ "$MOCK_TS_LINK" = none ] && exit 1; exit 0 ;;
  "route get") printf '%s\n' "$MOCK_ROUTE" ;;
esac
exit 0
M
printf '#!/bin/sh\n' >"$T/fw4bin/fw4"
for n in firewall network; do
    printf '#!/bin/sh\necho "%s $1" >>"$MOCK_LOG"\n[ "$1" = "$MOCK_RELOAD_FAIL" ] && exit 1\nexit 0\n' "$n" >"$T/init.$n"
done
chmod +x "$T/tools/"* "$T/fw4bin/fw4" "$T/init.firewall" "$T/init.network"
# в init.<n> аргумент $1 = reload; MOCK_RELOAD_FAIL задаётся как "reload" только для нужного скрипта через имя
for n in firewall network; do
    printf '#!/bin/sh\necho "%s $1" >>"$MOCK_LOG"\n[ "$MOCK_RELOAD_FAIL" = "%s" ] && exit 1\nexit 0\n' "$n" "$n" >"$T/init.$n"
done
ip() { "$T/tools/ip" "$@"; }

setenv() { PATH="$T/tools:$BASEPATH"; [ "$1" = fw4 ] && PATH="$T/fw4bin:$PATH"; }

seed() { # базовые конфиги роутера
    rm -f "$UCI_DIR"/*
    printf 'cfgdef=defaults\ncfglan=zone\ncfglan.name=lan\ncfgwan=zone\ncfgwan.name=wan\ncfgrule=rule\ncfgrule.name=tailscale\n' >"$UCI_DIR/firewall.com"
    printf 'lan=interface\nlan.device=br-lan\n' >"$UCI_DIR/network.com"
    printf 'settings=settings\nsettings.fw_mode=nftables\n' >"$UCI_DIR/tailscale.com"
    for c in firewall network tailscale; do cp "$UCI_DIR/$c.com" "$UCI_DIR/$c.work"; : >"$UCI_DIR/$c.pend"; done
    printf 'config defaults\n' >"$UCI_CONF_DIR/firewall"; printf 'config interface lan\n' >"$UCI_CONF_DIR/network"
    reset_log; rollback_init; rm -rf "$BACKUP_DIR"
    MOCK_UCI_FAIL_ON=""; MOCK_RELOAD_FAIL=""; MOCK_TS_LINK=""; MOCK_ROUTE=""; NONINTERACTIVE=0; : >"$TTY_DEV"
    REL_MAJOR=24.10; REL_VERSION=24.10.2; setenv
}
com() { grep -c "$2" "$UCI_DIR/$1.com"; }   # число строк в закоммиченном конфиге
has_com() { grep -Fxq -- "$2" "$UCI_DIR/$1.com"; }
ours() { cat "$UCI_DIR/firewall.com" "$UCI_DIR/network.com" | grep -c '^tsi_'; }

tsi_init 2>/dev/null; rc "tsi_init" $? 0; CUR_LANG=ru

# ================= _fw_pending_check =================
seed; _fw_pending_check; rc "pending: чисто" $? 0
printf 'cfgx.name=foo\n' >>"$UCI_DIR/firewall.work"; echo firewall.cfgx >>"$UCI_DIR/firewall.pend"
_fw_pending_check; rc "pending: есть изменения" $? 1
PATH="$BASEPATH"; _fw_pending_check; rc "pending: нет uci" $? 2

# ================= _fw_find_foreign =================
seed; _fw_find_foreign; rc "foreign: чисто (rule с name tailscale игнорируется)" $? 1
printf 'cfgzt=zone\ncfgzt.name=tailscale\n' >>"$UCI_DIR/firewall.work"
_fw_find_foreign; rc "foreign zone" $? 0; eq "foreign zone id" "$FW_FOREIGN_ZONE" "cfgzt"
seed; printf 'tailscale=interface\ntailscale.device=tailscale0\nother=interface\nother.ifname=tailscale0\nlan6=interface\nlan6.device=eth1\n' >>"$UCI_DIR/network.work"
_fw_find_foreign; rc "foreign iface" $? 0; eq "foreign iface ids (device и ifname)" "$FW_FOREIGN_IFACE" "tailscale other"
seed; printf 'tsi_zone=zone\ntsi_zone.name=tailscale\n' >>"$UCI_DIR/firewall.work"; printf 'tsi_net=interface\ntsi_net.device=tailscale0\n' >>"$UCI_DIR/network.work"
_fw_find_foreign; rc "foreign: наши секции не считаются чужими" $? 1

# ================= fw_setup: чистая система =================
seed; fw_setup >"$T/o" 2>"$T/e"; rc "fw_setup" $? 0
has_com network "tsi_net=interface" && has_com network "tsi_net.proto=none" && has_com network "tsi_net.device=tailscale0" && ok || bad "setup: network.tsi_net"
for l in tsi_zone=zone tsi_zone.name=tailscale tsi_zone.input=ACCEPT tsi_zone.output=ACCEPT tsi_zone.forward=ACCEPT tsi_zone.masq=1 tsi_zone.mtu_fix=1 tsi_zone.network=tsi_net \
         tsi_fwd_lan_in=forwarding tsi_fwd_lan_in.src=tailscale tsi_fwd_lan_in.dest=lan tsi_fwd_lan_out=forwarding tsi_fwd_lan_out.src=lan tsi_fwd_lan_out.dest=tailscale; do
    has_com firewall "$l" && ok || bad "setup: firewall $l"
done
has_com firewall "tsi_fwd_wan=forwarding" && bad "setup: forwarding в wan не создаётся" || ok
has_com firewall "cfglan.name=lan" && has_com firewall "cfgrule.name=tailscale" && has_com network "lan.device=br-lan" && ok || bad "setup: чужое не тронуто"
eq "setup: pending пуст после commit" "$(cat "$UCI_DIR/firewall.pend" "$UCI_DIR/network.pend" | wc -l | tr -d ' ')" "0"
has "setup: network reload" "network reload"; has "setup: firewall reload" "firewall reload"
[ "$(lineno 'network reload')" -lt "$(lineno 'firewall reload')" ] && ok || bad "setup: network раньше firewall"
[ -f "$BACKUP_DIR/firewall" ] && [ -f "$BACKUP_DIR/network" ] && ok || bad "setup: бэкап конфигов"
grep -Fxq "fw_remove" "$ROLLBACK_FILE" && ok || bad "setup: fw_remove в стеке отката"
[ "$(lineno 'uci -q changes firewall network')" -lt "$(lineno 'uci set network.tsi_net=interface')" ] && ok || bad "setup: проверка uci changes раньше первого uci set"
# повторный запуск: идемпотентность
reset_log; fw_setup >/dev/null 2>&1; rc "setup: повторно" $? 0
nocall "setup: повторно без uci set" "uci set"; nocall "setup: повторно без reload" "reload"

# ================= fw_setup: отказы =================
seed; printf 'cfgx.name=foo\n' >>"$UCI_DIR/firewall.work"; echo firewall.cfgx >>"$UCI_DIR/firewall.pend"
fw_setup >/dev/null 2>"$T/e"; rc "setup: чужие незакоммиченные правки" $? 1; nocall "setup pending: без uci set" "uci set"
seed; printf 'cfgzt=zone\ncfgzt.name=tailscale\n' >>"$UCI_DIR/firewall.com"; cp "$UCI_DIR/firewall.com" "$UCI_DIR/firewall.work"
fw_setup >/dev/null 2>"$T/e"; rc "setup: чужая зона" $? 1
grep -q cfgzt "$T/e" && ok || bad "setup: сообщение называет чужую зону"; eq "setup foreign: наших секций нет" "$(ours)" "0"; nocall "setup foreign: без uci set" "uci set"
seed; PATH="$BASEPATH"; fw_setup >/dev/null 2>&1; rc "setup: нет uci" $? 1
seed; mv "$UCI_CONF_DIR/firewall" "$UCI_CONF_DIR/firewall.x"; BACKUP_DIR="/proc/нет/backup"
fw_setup >/dev/null 2>&1; rc "setup: бэкап не удался -> 1" $? 1; nocall "setup: без бэкапа не меняем" "uci set"
BACKUP_DIR="$RUNDIR/backup"; mv "$UCI_CONF_DIR/firewall.x" "$UCI_CONF_DIR/firewall"
# сбой на середине
seed; MOCK_UCI_FAIL_ON="firewall.tsi_zone.masq"; fw_setup >/dev/null 2>&1; rc "setup: сбой uci set" $? 1
eq "setup: после сбоя наших секций нет (commit)" "$(ours)" "0"
eq "setup: после сбоя нет наших секций (work)" "$(cat "$UCI_DIR/firewall.work" "$UCI_DIR/network.work" | grep -c '^tsi_')" "0"
eq "setup: после сбоя pending пуст" "$(cat "$UCI_DIR/firewall.pend" "$UCI_DIR/network.pend" | wc -l | tr -d ' ')" "0"
has_com firewall "cfglan.name=lan" && ok || bad "setup: после сбоя чужое цело"
# сбой reload
seed; MOCK_RELOAD_FAIL=firewall; fw_setup >/dev/null 2>&1; rc "setup: сбой firewall reload -> 1" $? 1
eq "setup: после сбоя reload наших секций нет" "$(ours)" "0"
# частичное состояние
seed; printf 'tsi_zone=zone\ntsi_zone.name=tailscale\n' >>"$UCI_DIR/firewall.com"; cp "$UCI_DIR/firewall.com" "$UCI_DIR/firewall.work"
fw_setup >/dev/null 2>"$T/e"; rc "setup: частичное состояние пересоздаётся" $? 0
has_com firewall "tsi_fwd_lan_out.dest=tailscale" && ok || bad "setup partial: секции созданы заново"
eq "setup partial: нет дубля зоны" "$(com firewall '^tsi_zone=zone')" "1"

# ================= fw_remove =================
reset_log; fw_remove >/dev/null 2>&1; rc "remove" $? 0
eq "remove: наших секций нет" "$(ours)" "0"
has_com firewall "cfglan.name=lan" && has_com firewall "cfgrule.name=tailscale" && has_com network "lan.device=br-lan" && ok || bad "remove: чужое цело"
has "remove: reload" "firewall reload"
reset_log; fw_remove >/dev/null 2>&1; rc "remove повторно (идемпотентно)" $? 0; nocall "remove повторно: без reload" "reload"
seed; fw_setup >/dev/null 2>&1; fw_wan_forward_on >/dev/null 2>&1
printf 'tsi_route=route\ntsi_route.interface=tsi_net\n' >>"$UCI_DIR/network.work"; cp "$UCI_DIR/network.work" "$UCI_DIR/network.com"
fw_remove >/dev/null 2>&1; eq "remove: включая wan и route" "$(ours)" "0"
# remove снимает незакоммиченные правки наших секций
seed; fw_setup >/dev/null 2>&1; uci set firewall.tsi_zone.masq=0 2>/dev/null || "$T/tools/uci" set firewall.tsi_zone.masq=0
fw_remove >/dev/null 2>&1; eq "remove: pending пуст" "$(cat "$UCI_DIR/firewall.pend" "$UCI_DIR/network.pend" | wc -l | tr -d ' ')" "0"
PATH="$BASEPATH"; fw_remove; rc "remove без uci -> 0" $? 0

# ================= forwarding в wan =================
seed; fw_wan_forward_on >/dev/null 2>&1; rc "wan on без настройки -> 1" $? 1
fw_setup >/dev/null 2>&1; reset_log
fw_wan_forward_on >/dev/null 2>&1; rc "wan on" $? 0
for l in tsi_fwd_wan=forwarding tsi_fwd_wan.src=tailscale tsi_fwd_wan.dest=wan; do has_com firewall "$l" && ok || bad "wan on: $l"; done
has "wan on: только firewall reload" "firewall reload"; nocall "wan on: без network reload" "network reload"
reset_log; fw_wan_forward_on >/dev/null 2>&1; rc "wan on повторно" $? 0; nocall "wan on повторно: без uci set" "uci set"
fw_wan_forward_state; rc "wan state вкл" $? 0
fw_wan_forward_off >/dev/null 2>&1; rc "wan off" $? 0; has_com firewall "tsi_fwd_wan=forwarding" && bad "wan off: секция удалена" || ok
has_com firewall "tsi_fwd_lan_in=forwarding" && ok || bad "wan off: lan-forwarding цел"
fw_wan_forward_off >/dev/null 2>&1; rc "wan off повторно" $? 0
fw_wan_forward_state; rc "wan state выкл" $? 1
# toggle
printf 'y\n' >"$TTY_DEV"; fw_wan_forward_toggle >/dev/null 2>&1; rc "toggle: включить" $? 0; fw_wan_forward_state; rc "toggle: стало вкл" $? 0
printf 'n\n' >"$TTY_DEV"; fw_wan_forward_toggle >/dev/null 2>&1; rc "toggle: отказ -> 2" $? 2; fw_wan_forward_state; rc "toggle: отказ, осталось вкл" $? 0
printf 'y\n' >"$TTY_DEV"; fw_wan_forward_toggle >/dev/null 2>&1; rc "toggle: выключить" $? 0; fw_wan_forward_state; rc "toggle: стало выкл" $? 1
NONINTERACTIVE=1; fw_wan_forward_toggle >/dev/null 2>&1; rc "toggle: non-interactive -> 2" $? 2; NONINTERACTIVE=0
# чужие правки блокируют
printf 'cfgx.name=foo\n' >>"$UCI_DIR/firewall.work"; echo firewall.cfgx >>"$UCI_DIR/firewall.pend"
fw_wan_forward_on >/dev/null 2>&1; rc "wan on: чужие правки -> 1" $? 1
# сбой reload откатывает wan on
seed; fw_setup >/dev/null 2>&1; MOCK_RELOAD_FAIL=firewall; fw_wan_forward_on >/dev/null 2>&1; rc "wan on: сбой reload -> 1" $? 1

# ================= route_check_cgnat =================
seed; fw_setup >/dev/null 2>&1; REL_MAJOR=25.12; reset_log; route_check_cgnat; rc "route: 25.12 no-op" $? 0; nocall "route 25.12: без ip" "^ip "
REL_MAJOR=24.10
PATH="$BASEPATH"; reset_log; route_check_cgnat 2>"$T/e"; rc "route: нет uci -> 0" $? 0
setenv; MOCK_TS_LINK=none; reset_log; route_check_cgnat; rc "route: нет tailscale0" $? 0; nocall "route: нет tailscale0 -> без uci set" "uci set"
MOCK_TS_LINK=""; MOCK_ROUTE="100.64.0.1 dev tailscale0 table 52 src 100.101.102.103"; reset_log
route_check_cgnat; rc "route: уже через tailscale0" $? 0; nocall "route ok: без uci set" "uci set"
MOCK_ROUTE="100.64.0.1 via 192.168.1.1 dev eth0 src 192.168.1.2"; reset_log
route_check_cgnat >"$T/o" 2>&1; rc "route: добавление" $? 0
for l in tsi_route=route tsi_route.interface=tsi_net tsi_route.target=100.64.0.0 tsi_route.netmask=255.192.0.0; do has_com network "$l" && ok || bad "route: $l"; done
has "route: network reload" "network reload"; nocall "route: без firewall reload" "firewall reload"
reset_log; route_check_cgnat >"$T/o" 2>"$T/e"; rc "route: повторно (всё ещё нет маршрута) -> предупреждение" $? 0
[ -s "$T/e" ] && ok || bad "route: предупреждение ROUTE_STILL_MISSING"
eq "route: без дубля" "$(com network '^tsi_route=route')" "1"; nocall "route повторно: без uci set" "uci set"
seed; MOCK_ROUTE="100.64.0.1 via 192.168.1.1 dev eth0"; route_check_cgnat >/dev/null 2>"$T/e"; rc "route: без fw_setup" $? 0
[ -s "$T/e" ] && ok || bad "route: предупреждение без tsi_net"; eq "route: без tsi_net ничего не создано" "$(ours)" "0"
# команда ip отсутствует
seed; fw_setup >/dev/null 2>&1; unset -f ip; setenv; mv "$T/tools/ip" "$T/tools/ip.off"
route_check_cgnat >/dev/null 2>"$T/e"; rc "route: нет ip -> 0" $? 0
# (busybox из Ubuntu имеет встроенный апплет ip, его нельзя скрыть; на OpenWrt такого апплета нет)
if command -v ip >/dev/null 2>&1; then ok; else [ -s "$T/e" ] && ok || bad "route: предупреждение об ip"; fi
mv "$T/tools/ip.off" "$T/tools/ip"; ip() { "$T/tools/ip" "$@"; }

# ================= set_fw_debug_mode =================
seed; setenv fw4; set_fw_debug_mode >/dev/null 2>&1; rc "fwmode: fw4 -> nftables (уже стоит)" $? 0; nocall "fwmode: без изменений" "uci commit tailscale"
seed; setenv; set_fw_debug_mode >/dev/null 2>&1; rc "fwmode: нет fw4 -> iptables" $? 0
has_com tailscale "settings.fw_mode=iptables" && ok || bad "fwmode: записан iptables"; has "fwmode: commit" "uci commit tailscale"
seed; printf 'settings=settings\nsettings.fw_mode=iptables\n' >"$UCI_DIR/tailscale.com"; cp "$UCI_DIR/tailscale.com" "$UCI_DIR/tailscale.work"; setenv fw4
set_fw_debug_mode >/dev/null 2>&1; has_com tailscale "settings.fw_mode=nftables" && ok || bad "fwmode: iptables -> nftables"
seed; : >"$UCI_DIR/tailscale.com"; : >"$UCI_DIR/tailscale.work"; reset_log; set_fw_debug_mode >/dev/null 2>&1; rc "fwmode: нет секции -> no-op" $? 0; nocall "fwmode: нет секции без uci set" "uci set"
seed; setenv; MOCK_UCI_FAIL_ON="tailscale.settings.fw_mode"; set_fw_debug_mode >/dev/null 2>&1; rc "fwmode: сбой записи -> 1" $? 1
PATH="$BASEPATH"; set_fw_debug_mode; rc "fwmode: нет uci -> 0" $? 0

# ================= i18n и ограничения =================
CUR_LANG=ru; i18n_selfcheck 2>/dev/null; rc "i18n selfcheck" $? 0
keys_of() { sed -n "/^$1() {/,/^}/p" "$HERE/tsi.sh" | sed -n 's/^ *\([A-Z0-9_]*\)) *_S=.*/\1/p' | sort | tr '\n' ' '; }
eq "keys ru==en" "$(keys_of strings_ru)" "$(keys_of strings_en)"
eq "keys == I18N_KEYS" "$(keys_of strings_ru)" "$(for k in $I18N_KEYS; do echo $k; done | sort | tr '\n' ' ')"
# в слое 5 нет uci commit/set вне наших секций и нет прямых записей в /etc/config
sed -n '/^# 7\. СЕТЬ И FIREWALL/,$p' "$HERE/tsi.sh" | grep -v '^[[:space:]]*#' | grep -q '/etc/config/' && bad "слой 5: прямая запись в /etc/config" || ok

rm -rf "$T"
printf 'passed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
