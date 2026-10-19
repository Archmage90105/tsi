#!/bin/sh
# Тесты слоя 7: обновление, LuCI, удаление. Моки opkg/apk со состоянием.
# Запуск: sh test_layer7.sh
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/tsi.sh"
GTAR=/usr/bin/tar

T=$(mktemp -d /tmp/tsi-test7.XXXXXX)
CONF="$T/tsi.conf"; RUNDIR="$T/run"; LOG_FILE="$RUNDIR/tsi.log"; ROLLBACK_FILE="$RUNDIR/rollback.list"
OPKG_FEEDS="$T/opkg/customfeeds.conf"; OPKG_KEYDIR="$T/opkg/keys"
APK_FEEDS="$T/apk/repositories.d/customfeeds.list"; APK_KEYDIR="$T/apk/keys"
APK_ARCH_FILE="$T/apk_arch"; FEEDS_LEDGER="$T/feeds.ledger"
SELF_DEST="$T/bin/tsi"; INIT_SCRIPT="$T/init.tailscale"; SYSUPGRADE_CONF="$T/sysupgrade.conf"
TS_UCI_CONF="$T/etc/config/tailscale"; TS_STATE_DIR="$T/etc/tailscale"; TS_VAR_DIR="$T/var/lib/tailscale"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: получено [$2], ожидалось [$3]"; fi; }
rc()  { if [ "$2" -eq "$3" ]; then ok; else bad "$1: rc=$2, ожидалось $3"; fi; }
has() { if grep -Fxq -- "$2" "$MOCK_LOG"; then ok; else bad "$1: нет вызова [$2]"; fi; }
nocall() { if grep -q -- "$2" "$MOCK_LOG"; then bad "$1: лишний вызов [$2]"; else ok; fi; }
lineno() { grep -Fxn -- "$1" "$MOCK_LOG" | head -n 1 | cut -d: -f1; }
before() { a=$(lineno "$2"); b=$(lineno "$3"); if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then ok; else bad "$1: порядок [$2]($a) раньше [$3]($b)"; fi; }
reset_log() { : >"$MOCK_LOG"; }
fexists() { [ -e "$1" ]; }

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

# ---------- моки ----------
BASEPATH=$PATH
MOCK_LOG="$T/calls.log"; S="$T/state"; FIX="$T/fix"
mkdir -p "$T/tools" "$T/usignbin" "$T/m_opkg" "$T/m_apk" "$S" "$FIX"
export MOCK_ARCH_LINES MOCK_LOG S FIX MOCK_AVAILABLE MOCK_AVAILABLE_AFTER_FEED MOCK_FEEDS_FILE MOCK_MAINT MOCK_UPDATE_FAIL MOCK_INSTALL_FAIL MOCK_UPGRADE_FAIL MOCK_UPGRADE_TO MOCK_REMOVE_FAIL MOCK_FLAG_FAIL MOCK_INIT_FAIL
cat >"$T/m_opkg/opkg" <<'M'
#!/bin/sh
echo "opkg $*" >>"$MOCK_LOG"
avail() { case " $MOCK_AVAILABLE " in *" $1 "*) return 0;; esac
          case " $MOCK_AVAILABLE_AFTER_FEED " in *" $1 "*) grep -q tsi_ "$MOCK_FEEDS_FILE" 2>/dev/null && return 0;; esac; return 1; }
case "$1" in
  update) [ -n "$MOCK_UPDATE_FAIL" ] && exit 1; : >"$S/lists" ;;
  info) [ -f "$S/lists" ] || exit 0; avail "$2" && echo "Package: $2" ;;
  status) [ -f "$S/inst.$2" ] && { printf 'Package: %s\nVersion: %s\n' "$2" "$(cat "$S/inst.$2")"; [ -n "$MOCK_MAINT" ] && echo "Maintainer: $MOCK_MAINT"; echo 'Status: install ok installed'; } ;;
  list-installed) [ -f "$S/inst.$2" ] && echo "$2 - $(cat "$S/inst.$2")" ;;
  print-architecture) printf '%b\n' "$MOCK_ARCH_LINES" ;;
  install) [ -n "$MOCK_INSTALL_FAIL" ] && exit 1
     shift; for a in "$@"; do case "$a" in
        *.ipk) b=${a##*/}; v=${b#tailscale-}; echo "${v%.ipk}" >"$S/inst.tailscale" ;;
        -*) ;; *) [ -f "$S/inst.$a" ] || echo "1.0-1" >"$S/inst.$a" ;; esac; done ;;
  upgrade) [ -n "$MOCK_UPGRADE_FAIL" ] && exit 1; [ -n "$MOCK_UPGRADE_TO" ] && echo "$MOCK_UPGRADE_TO" >"$S/inst.$2" ;;
  remove) case " $MOCK_REMOVE_FAIL " in *" $2 "*) exit 1;; esac; rm -f "$S/inst.$2" ;;
  flag) [ "$MOCK_FLAG_FAIL" = "$2" ] && exit 1 ;;
esac
exit 0
M
cat >"$T/m_apk/apk" <<'M'
#!/bin/sh
echo "apk $*" >>"$MOCK_LOG"
avail() { case " $MOCK_AVAILABLE " in *" $1 "*) return 0;; esac
          case " $MOCK_AVAILABLE_AFTER_FEED " in *" $1 "*) grep -q 'tsi:' "$MOCK_FEEDS_FILE" 2>/dev/null && return 0;; esac; return 1; }
case "$1" in
  update) [ -n "$MOCK_UPDATE_FAIL" ] && exit 1; : >"$S/lists" ;;
  info) [ -f "$S/inst.$3" ] && exit 0; exit 1 ;;
  list) [ -f "$S/inst.$3" ] && echo "$3-$(cat "$S/inst.$3") x86_64 {$3} (BSD-3-Clause) [installed]" ;;
  search) [ -f "$S/lists" ] || exit 0; avail "$3" && echo "$3-1.0-r0" ;;
  add) [ -n "$MOCK_INSTALL_FAIL" ] && exit 1
     if [ "$2" = "-u" ]; then [ -n "$MOCK_UPGRADE_FAIL" ] && exit 1; [ -n "$MOCK_UPGRADE_TO" ] && echo "$MOCK_UPGRADE_TO" >"$S/inst.$3"; exit 0; fi
     shift; for a in "$@"; do n=${a%%=*}; [ -f "$S/inst.$n" ] || echo "1.0-r0" >"$S/inst.$n"; done ;;
  del) case " $MOCK_REMOVE_FAIL " in *" $2 "*) exit 1;; esac; rm -f "$S/inst.$2" ;;
  upgrade) ;;
esac
exit 0
M
cat >"$T/usignbin/usign" <<'M'
#!/bin/sh
[ "$1" = "-F" ] && echo 0123456789abcdef
M
cat >"$T/tools/uclient-fetch" <<'M'
#!/bin/sh
echo "uclient-fetch $*" >>"$MOCK_LOG"
dest=""; url=""
while [ $# -gt 0 ]; do case "$1" in -O) dest=$2; shift 2;; -q) shift;; *) url=$1; shift;; esac; done
f="$FIX/${url#https://}"
[ -f "$f" ] || exit 1
cp "$f" "$dest"
M
cat >"$T/init.tailscale" <<'M'
#!/bin/sh
echo "init $1" >>"$MOCK_LOG"
[ "$1" = "$MOCK_INIT_FAIL" ] && exit 1
exit 0
M
chmod +x "$T"/m_*/* "$T/usignbin/usign" "$T/tools/"* "$T/init.tailscale"
setpath() { PATH="$T/m_$1:$T/tools:$T/usignbin:$BASEPATH"; }

# ---------- фикстуры ----------
A53=$(printf 'A%.0s' $(seq 1 53))
LB="$FIX/tokisaki-galaxy.github.io/luci-app-tailscale-community/all"; mkdir -p "$LB"
printf 'untrusted comment: usign public key\nRWQ%s' "$A53" >"$LB/key-build.pub"
printf -- '-----BEGIN PUBLIC KEY-----\nMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE\n-----END PUBLIC KEY-----\n' >"$LB/public-key.pem"
RB="$FIX/raw.githubusercontent.com/gunanovo/openwrt-tailscale/refs/heads/feed/mipsel_24kc"; mkdir -p "$RB"
mkelf() { printf "\\177ELF\\00$2\\00$3\\001\\000\\000\\000\\000\\000\\000\\000\\000\\000\\002\\000$4" >"$1"; }
mkipk() { # OUT
    _d="$T/ipkbuild"; rm -rf "$_d"; mkdir -p "$_d/data/usr/sbin" "$_d/ctl"
    mkelf "$_d/data/usr/sbin/tailscaled" 1 1 '\010\000'; head -c 300 /dev/zero >>"$_d/data/usr/sbin/tailscaled"
    printf 'Package: tailscale\n' >"$_d/ctl/control"
    $GTAR -czf "$_d/data.tar.gz" -C "$_d/data" .; $GTAR -czf "$_d/control.tar.gz" -C "$_d/ctl" .
    printf '2.0\n' >"$_d/debian-binary"; $GTAR -czf "$1" -C "$_d" ./debian-binary ./data.tar.gz ./control.tar.gz
}
mkipk "$RB/tailscale-1.105.0-r1.ipk"; set -- $(sha256sum "$RB/tailscale-1.105.0-r1.ipk"); printf '%s\n' "$1" >"$RB/ipk.sha256"
printf '1.105.0-r1\n' >"$RB/version"

tsi_init 2>/dev/null; rc "tsi_init" $? 0; CUR_LANG=ru; TS_ARCH=mipsle; REL_MAJOR=24.10

fresh() { # PKGMGR
    PKG_MGR=$1; setpath "$1"
    rm -rf "$S" "$T/opkg" "$T/apk" "$T/bin" "$T/etc" "$T/var" "$FEEDS_LEDGER" "$CONF" "$SYSUPGRADE_CONF"; mkdir -p "$S"
    reset_log; rollback_init; conf_reset; feed
    MOCK_AVAILABLE=""; MOCK_AVAILABLE_AFTER_FEED=""; MOCK_MAINT="GuNan <x@y.z>"; MOCK_UPDATE_FAIL=""; MOCK_INSTALL_FAIL=""
    MOCK_UPGRADE_FAIL=""; MOCK_UPGRADE_TO=""; MOCK_REMOVE_FAIL=""; MOCK_FLAG_FAIL=""; MOCK_INIT_FAIL=""
    if [ "$1" = opkg ]; then MOCK_FEEDS_FILE="$OPKG_FEEDS"; else MOCK_FEEDS_FILE="$APK_FEEDS"; fi
    NONINTERACTIVE=0; REL_MAJOR=24.10; [ "$1" = apk ] && REL_MAJOR=25.12
    MOCK_ARCH_LINES=""; printf 'mipsel_24kc\n' >"$APK_ARCH_FILE"
}
inst() { echo "$2" >"$S/inst.$1"; }      # inst PKG VERSION

# ================= service_restart =================
fresh opkg; service_restart >/dev/null 2>&1; rc "restart" $? 0; has "restart call" "init restart"
MOCK_INIT_FAIL=restart; service_restart >/dev/null 2>&1; rc "restart fail" $? 1; MOCK_INIT_FAIL=""
INIT_SCRIPT="$T/нет"; service_restart >/dev/null 2>&1; rc "restart: нет init" $? 1; INIT_SCRIPT="$T/init.tailscale"

# ================= update_official =================
fresh opkg; inst tailscale 1.0-1; MOCK_UPGRADE_TO=1.1-1
update_official >"$T/o" 2>&1; rc "official: обновление" $? 0
has "official: update" "opkg update"; has "official: upgrade" "opkg upgrade tailscale"; has "official: restart" "init restart"
grep -q '1.0-1 -> 1.1-1' "$T/o" && ok || bad "official: сообщение о версиях"
nocall "official: без hold" "flag"
fresh opkg; inst tailscale 1.0-1; update_official >"$T/o" 2>&1; rc "official: без обновлений" $? 0; nocall "official: без restart" "init restart"
grep -q 'Обновлений нет' "$T/o" && ok || bad "official: сообщение 'обновлений нет'"
fresh opkg; update_official >/dev/null 2>&1; rc "official: не установлен" $? 1; nocall "official: не установлен без update" "opkg update"
fresh opkg; inst tailscale 1.0-1; MOCK_UPDATE_FAIL=1; update_official >/dev/null 2>&1; rc "official: сбой update" $? 1; nocall "official: после сбоя update без upgrade" "opkg upgrade"
fresh opkg; inst tailscale 1.0-1; MOCK_UPGRADE_FAIL=1; update_official >/dev/null 2>&1; rc "official: сбой upgrade" $? 1; nocall "official: после сбоя без restart" "init restart"
fresh apk; inst tailscale 1.0-r0; MOCK_UPGRADE_TO=1.1-r0; update_official >/dev/null 2>&1; rc "official apk" $? 0; has "official apk: add -u" "apk add -u tailscale"

# ================= update_lite_feed =================
fresh opkg; inst tailscale 1.0-1; MOCK_UPGRADE_TO=1.1-1
update_lite_feed >"$T/o" 2>"$T/e"; rc "lite_feed: обновление" $? 0
before "lite_feed: unhold раньше update" "opkg flag unhold tailscale" "opkg update"
before "lite_feed: update раньше upgrade" "opkg update" "opkg upgrade tailscale"
before "lite_feed: upgrade раньше hold" "opkg upgrade tailscale" "opkg flag hold tailscale"
before "lite_feed: hold раньше restart" "opkg flag hold tailscale" "init restart"
[ -s "$T/e" ] && bad "lite_feed: без предупреждений при верном Maintainer" || ok
fresh opkg; inst tailscale 1.0-1; MOCK_UPGRADE_FAIL=1; update_lite_feed >/dev/null 2>&1; rc "lite_feed: сбой upgrade" $? 1
has "lite_feed: hold возвращён после сбоя upgrade" "opkg flag hold tailscale"; nocall "lite_feed: сбой -> без restart" "init restart"
fresh opkg; inst tailscale 1.0-1; MOCK_UPDATE_FAIL=1; update_lite_feed >/dev/null 2>&1; rc "lite_feed: сбой update" $? 1
has "lite_feed: hold возвращён после сбоя update" "opkg flag hold tailscale"; nocall "lite_feed: сбой update без upgrade" "opkg upgrade"
fresh opkg; inst tailscale 1.0-1; MOCK_FLAG_FAIL=unhold; update_lite_feed >/dev/null 2>&1; rc "lite_feed: unhold не удался" $? 1; nocall "lite_feed: без unhold нет upgrade" "opkg upgrade"
fresh opkg; inst tailscale 1.0-1; update_lite_feed >"$T/o" 2>&1; rc "lite_feed: нет новой версии" $? 0; nocall "lite_feed: нет новой версии без restart" "init restart"; has "lite_feed: hold и без обновления" "opkg flag hold tailscale"
fresh opkg; inst tailscale 1.0-1; MOCK_MAINT="OpenWrt Community"; MOCK_UPGRADE_TO=1.1-1; update_lite_feed >/dev/null 2>"$T/e"; rc "lite_feed: чужой Maintainer" $? 0; [ -s "$T/e" ] && ok || bad "lite_feed: предупреждение о происхождении"
fresh opkg; update_lite_feed >/dev/null 2>&1; rc "lite_feed: не установлен" $? 1
fresh apk; inst tailscale 1.0-r0; MOCK_UPGRADE_TO=1.1-r0; update_lite_feed >/dev/null 2>&1; rc "lite_feed apk" $? 0
before "lite_feed apk: unpin раньше upgrade" "apk add tailscale" "apk add -u tailscale"
before "lite_feed apk: upgrade раньше пина новой версии" "apk add -u tailscale" "apk add tailscale=1.1-r0"
before "lite_feed apk: пин раньше restart" "apk add tailscale=1.1-r0" "init restart"

# ================= update_lite_direct =================
dfresh() { fresh opkg; MOCK_ARCH_LINES='arch all 1\narch mipsel_24kc 10'; inst tailscale 1.104.1-r1; feed yes; }
dfresh; inst tailscale 1.105.0-r1; feed; update_lite_direct >"$T/o" 2>&1; rc "direct upd: та же версия" $? 0
nocall "direct upd: та же версия без install" "opkg install"; nocall "direct upd: без unhold" "flag unhold"
grep -q 'Обновлений нет' "$T/o" && ok || bad "direct upd: 'обновлений нет'"
dfresh; update_lite_direct >"$T/o" 2>"$T/e"; rc "direct upd: новая версия" $? 0
before "direct upd: unhold раньше install" "opkg flag unhold tailscale" "opkg install $RUNDIR/tailscale-1.105.0-r1.ipk"
before "direct upd: install раньше hold" "opkg install $RUNDIR/tailscale-1.105.0-r1.ipk" "opkg flag hold tailscale"
before "direct upd: hold раньше restart" "opkg flag hold tailscale" "init restart"
eq "direct upd: LITE_VERSION" "$(conf_get LITE_VERSION)" "1.105.0-r1"
grep -q '1.104.1-r1 -> 1.105.0-r1' "$T/o" && ok || bad "direct upd: сообщение о версиях"
[ -e "$RUNDIR/tailscale-1.105.0-r1.ipk" ] && bad "direct upd: .ipk удалён" || ok
dfresh; feed no; update_lite_direct >/dev/null 2>&1; rc "direct upd: отказ" $? 2; nocall "direct upd: отказ без unhold" "flag unhold"; nocall "direct upd: отказ без install" "opkg install"
dfresh; feed Yes; update_lite_direct >/dev/null 2>&1; rc "direct upd: 'Yes' не принимается" $? 2
dfresh; NONINTERACTIVE=1; update_lite_direct >"$T/o" 2>&1; rc "direct upd: неинтерактивно" $? 2; nocall "direct upd: неинтерактивно без install" "opkg install"
grep -q 'только через меню' "$T/o" && ok || bad "direct upd: подсказка про меню"
dfresh; MOCK_INSTALL_FAIL=1; update_lite_direct >/dev/null 2>&1; rc "direct upd: сбой install" $? 1
has "direct upd: hold возвращён после сбоя" "opkg flag hold tailscale"; eq "direct upd: сбой, LITE_VERSION не менялась" "$(conf_get LITE_VERSION)" ""; nocall "direct upd: сбой без restart" "init restart"
mv "$RB/ipk.sha256" "$T/sha.bak"; printf '%064d\n' 0 >"$RB/ipk.sha256"
dfresh; update_lite_direct >/dev/null 2>&1; rc "direct upd: неверный sha" $? 1; has "direct upd: hold возвращён после sha-ошибки" "opkg flag hold tailscale"; nocall "direct upd: sha-ошибка без install" "opkg install"
mv "$T/sha.bak" "$RB/ipk.sha256"
dfresh; mv "$RB/version" "$T/ver.bak"; update_lite_direct >/dev/null 2>&1; rc "direct upd: version недоступен" $? 1; mv "$T/ver.bak" "$RB/version"; nocall "direct upd: без version нет unhold" "flag unhold"
dfresh; PKG_MGR=apk; update_lite_direct >/dev/null 2>&1; rc "direct upd: apk -> 1" $? 1
dfresh; REL_MAJOR=25.12; update_lite_direct >/dev/null 2>&1; rc "direct upd: 25.12 -> 1" $? 1
fresh opkg; MOCK_ARCH_LINES='arch all 1\narch mipsel_24kc 10'; update_lite_direct >/dev/null 2>&1; rc "direct upd: не установлен" $? 1

# ================= update_tailscale =================
update_official() { echo "STUB official" >>"$MOCK_LOG"; return 0; }
update_lite_feed() { echo "STUB feed" >>"$MOCK_LOG"; return 0; }
update_lite_direct() { echo "STUB direct" >>"$MOCK_LOG"; return 0; }
fresh opkg; CFG_INSTALL_SOURCE=A; update_tailscale; has "dispatch A" "STUB official"
reset_log; CFG_INSTALL_SOURCE=B; CFG_B_SUBMODE=feed; update_tailscale; has "dispatch B/feed" "STUB feed"
reset_log; CFG_B_SUBMODE=direct; update_tailscale; has "dispatch B/direct" "STUB direct"
reset_log; CFG_B_SUBMODE=""; update_tailscale 2>/dev/null; rc "dispatch B без подрежима" $? 1
CFG_INSTALL_SOURCE=""; update_tailscale 2>/dev/null; rc "dispatch без источника" $? 1; [ -s "$MOCK_LOG" ] && bad "dispatch: лишние вызовы" || ok
unset -f update_official update_lite_feed update_lite_direct
. "$HERE/tsi.sh"; RUNDIR="$T/run"; LOG_FILE="$RUNDIR/tsi.log"; ROLLBACK_FILE="$RUNDIR/rollback.list"; CONF="$T/tsi.conf"
_read_tty() { ASK_REPLY=""; [ "$NONINTERACTIVE" = 1 ] && return 2; TTY_N=$((TTY_N + 1)); [ "$(wc -l <"$TTY_SCRIPT" | tr -d ' ')" -ge "$TTY_N" ] || return 2; ASK_REPLY=$(sed -n "${TTY_N}p" "$TTY_SCRIPT"); return 0; }
OPKG_FEEDS="$T/opkg/customfeeds.conf"; OPKG_KEYDIR="$T/opkg/keys"; APK_FEEDS="$T/apk/repositories.d/customfeeds.list"; APK_KEYDIR="$T/apk/keys"
APK_ARCH_FILE="$T/apk_arch"; FEEDS_LEDGER="$T/feeds.ledger"; SELF_DEST="$T/bin/tsi"; INIT_SCRIPT="$T/init.tailscale"; SYSUPGRADE_CONF="$T/sysupgrade.conf"
TS_UCI_CONF="$T/etc/config/tailscale"; TS_STATE_DIR="$T/etc/tailscale"; TS_VAR_DIR="$T/var/lib/tailscale"; TS_ARCH=mipsle; CUR_LANG=ru

# ================= install_luci =================
LUCI=luci-app-tailscale-community
fresh opkg; install_luci >/dev/null 2>&1; rc "luci: нет luci-base" $? 0; nocall "luci: нет luci-base без вызовов установки" "opkg install"
fresh opkg; inst luci-base 1.0-1; inst $LUCI 4.3.0-r1; install_luci >/dev/null 2>&1; rc "luci: уже установлен" $? 0; nocall "luci: уже установлен без install" "opkg install"
fresh opkg; inst luci-base 1.0-1; MOCK_AVAILABLE="$LUCI"; install_luci >/dev/null 2>&1; rc "luci: из официального фида" $? 0
has "luci: install" "opkg install $LUCI"; [ -e "$OPKG_FEEDS" ] && bad "luci: чужой фид не добавляется" || ok
fresh opkg; inst luci-base 1.0-1; MOCK_AVAILABLE_AFTER_FEED="$LUCI"; feed y; install_luci >"$T/o" 2>&1; rc "luci: через фид Tokisaki (opkg)" $? 0
grep -Fxq 'src/gz tsi_luci https://tokisaki-galaxy.github.io/luci-app-tailscale-community/all' "$OPKG_FEEDS" && ok || bad "luci: строка фида"
[ -f "$OPKG_KEYDIR/0123456789abcdef" ] && ok || bad "luci: ключ импортирован"
has "luci: install после фида" "opkg install $LUCI"; feed_exists luci && ok || bad "luci: учёт фида"
fresh opkg; inst luci-base 1.0-1; MOCK_AVAILABLE_AFTER_FEED="$LUCI"; feed n; install_luci >"$T/o" 2>&1; rc "luci: фид отклонён" $? 0
nocall "luci: отклонён без install" "opkg install"; [ -e "$OPKG_FEEDS" ] && bad "luci: отклонён, фид не добавлен" || ok
fresh opkg; inst luci-base 1.0-1; MOCK_AVAILABLE_AFTER_FEED="$LUCI"; NONINTERACTIVE=1; install_luci >/dev/null 2>&1; rc "luci: неинтерактивно, фид пропущен" $? 0; nocall "luci: неинтерактивно без install" "opkg install"
fresh opkg; inst luci-base 1.0-1; MOCK_AVAILABLE_AFTER_FEED="$LUCI"; mv "$LB/key-build.pub" "$T/kb"; feed y; install_luci >/dev/null 2>&1; rc "luci: ключ не скачался" $? 1; mv "$T/kb" "$LB/key-build.pub"
fresh opkg; inst luci-base 1.0-1; feed y; install_luci >"$T/o" 2>&1; rc "luci: после фида пакета всё равно нет" $? 0; nocall "luci: нет пакета без install" "opkg install $LUCI"
grep -q 'недоступен' "$T/o" && ok || bad "luci: справка о недоступности"
fresh opkg; inst luci-base 1.0-1; MOCK_AVAILABLE="$LUCI"; MOCK_INSTALL_FAIL=1; install_luci >/dev/null 2>&1; rc "luci: сбой install" $? 1
fresh apk; inst luci-base 1.0-r0; MOCK_AVAILABLE="$LUCI"; install_luci >/dev/null 2>&1; rc "luci apk: из официального" $? 0; has "luci apk: add" "apk add $LUCI"
fresh apk; inst luci-base 1.0-r0; MOCK_AVAILABLE_AFTER_FEED="$LUCI"; feed y; install_luci >/dev/null 2>&1; rc "luci apk: через фид" $? 0
eq "luci apk: строки фида" "$(tail -n 2 "$APK_FEEDS" | tr '\n' ' ')" "# tsi:luci https://tokisaki-galaxy.github.io/luci-app-tailscale-community/all/packages.adb "
[ -f "$APK_KEYDIR/tsi-luci.pub" ] && ok || bad "luci apk: ключ public-key.pem"
# install_luci_ask
fresh opkg; inst luci-base 1.0-1; MOCK_AVAILABLE="$LUCI"; feed y; install_luci_ask >/dev/null 2>&1; has "luci_ask: да" "opkg install $LUCI"
fresh opkg; inst luci-base 1.0-1; MOCK_AVAILABLE="$LUCI"; feed n; install_luci_ask >/dev/null 2>&1; nocall "luci_ask: нет" "opkg install"
fresh opkg; inst luci-base 1.0-1; MOCK_AVAILABLE="$LUCI"; NONINTERACTIVE=1; install_luci_ask >/dev/null 2>&1; rc "luci_ask: неинтерактивно" $? 0; [ -s "$MOCK_LOG" ] && bad "luci_ask: неинтерактивно без вызовов" || ok

# ================= _safe_rm / _sysupgrade_unregister =================
_safe_rm ""; rc "safe_rm: пусто" $? 1; _safe_rm "/"; rc "safe_rm: /" $? 1; _safe_rm "relative/x"; rc "safe_rm: относительный" $? 1
_safe_rm "$T/нет-такого"; rc "safe_rm: нет пути" $? 0
mkdir -p "$T/del/sub"; : >"$T/del/sub/f"; _safe_rm "$T/del"; fexists "$T/del" && bad "safe_rm: каталог удалён" || ok
printf '/a\n/ab\n/a/b\nx/a\n/a\n' >"$SYSUPGRADE_CONF"; _sysupgrade_unregister /a /zzz
eq "unregister: точные совпадения" "$(tr '\n' ' ' <"$SYSUPGRADE_CONF")" "/ab /a/b x/a "
rm -f "$SYSUPGRADE_CONF"; _sysupgrade_unregister /a; rc "unregister: файла нет" $? 0

# ================= uninstall_tailscale =================
STUB_FW_OURS=0
_uci_ok() { return 0; }
_fw_any_ours() { return "$STUB_FW_OURS"; }
fw_remove() { echo "STUB fw_remove" >>"$MOCK_LOG"; }
mkun() { # PKGMGR
    fresh "$1"; STUB_FW_OURS=0
    inst tailscale 1.104.1-r1; inst $LUCI 4.3.0-r1
    mkdir -p "$T/etc/config" "$T/etc/tailscale" "$T/var/lib/tailscale" "$T/bin" "$T/opkg/keys" "$T/apk/repositories.d" "$T/apk/keys"
    : >"$TS_UCI_CONF"; echo state >"$TS_STATE_DIR/tailscaled.state"; echo x >"$TS_VAR_DIR/x"; echo script >"$SELF_DEST"
    printf 'INSTALL_SOURCE=B\nB_SUBMODE=feed\n' >"$CONF"; conf_load
    if [ "$1" = opkg ]; then
        printf 'src/gz custom https://user/feed\nsrc/gz tsi_lite https://x/lite\nsrc/gz tsi_luci https://x/luci\n' >"$OPKG_FEEDS"
        printf 'lite|https://x/lite|aaaaaaaaaaaaaaaa\nluci|https://x/luci|bbbbbbbbbbbbbbbb\n' >"$FEEDS_LEDGER"
        : >"$OPKG_KEYDIR/aaaaaaaaaaaaaaaa"; : >"$OPKG_KEYDIR/bbbbbbbbbbbbbbbb"
    else
        printf 'https://user/p.adb\n# tsi:lite\nhttps://x/lite\n# tsi:luci\nhttps://x/luci\n' >"$APK_FEEDS"
        printf 'lite|https://x/lite|tsi-lite.pub\nluci|https://x/luci|tsi-luci.pub\n' >"$FEEDS_LEDGER"
        : >"$APK_KEYDIR/tsi-lite.pub"; : >"$APK_KEYDIR/tsi-luci.pub"
    fi
    printf '/etc/my/own\n' >"$SYSUPGRADE_CONF"
    for p in $SYSUPGRADE_BASE_PATHS; do printf '%s\n' "$p" >>"$SYSUPGRADE_CONF"; done
    _sysupgrade_feed_paths >>"$SYSUPGRADE_CONF"
}
mkun opkg; feed yes n; uninstall_tailscale >"$T/o" 2>"$T/e"; rc "uninstall opkg" $? 0
has "un: stop" "init stop"; has "un: disable" "init disable"; has "un: fw_remove" "STUB fw_remove"
before "un: служба раньше firewall" "init disable" "STUB fw_remove"
before "un: LuCI удалён раньше tailscale" "opkg remove $LUCI" "opkg remove tailscale"
before "un: unhold раньше remove" "opkg flag unhold tailscale" "opkg remove tailscale"
before "un: firewall раньше пакета" "STUB fw_remove" "opkg remove tailscale"
fexists "$TS_UCI_CONF" && bad "un: /etc/config/tailscale удалён" || ok
fexists "$TS_STATE_DIR" && bad "un: /etc/tailscale удалён" || ok
fexists "$TS_VAR_DIR" && bad "un: /var/lib/tailscale удалён" || ok
fexists "$SELF_DEST" && bad "un: алиас удалён" || ok
fexists "$CONF" && ok || bad "un: конфиг скрипта оставлен по умолчанию"
fexists "$FEEDS_LEDGER" && bad "un: пустой учёт фидов удалён" || ok
grep -q 'tsi_' "$OPKG_FEEDS" && bad "un: фиды удалены" || ok
grep -Fxq 'src/gz custom https://user/feed' "$OPKG_FEEDS" && ok || bad "un: чужой фид цел"
fexists "$OPKG_KEYDIR/aaaaaaaaaaaaaaaa" || fexists "$OPKG_KEYDIR/bbbbbbbbbbbbbbbb" && bad "un: ключи фидов удалены" || ok
eq "un: sysupgrade - только чужая строка" "$(cat "$SYSUPGRADE_CONF")" "/etc/my/own"
grep -q 'Удалено:' "$T/o" && grep -q 'package' "$T/o" && grep -q 'service' "$T/o" && ok || bad "un: итоговый отчёт"
grep -q 'Оставлено: script-config' "$T/o" && ok || bad "un: в отчёте оставленная конфигурация"
mkun opkg; feed yes y; uninstall_tailscale >"$T/o" 2>&1; fexists "$CONF" && bad "un: конфиг скрипта удалён по согласию" || ok
grep -q 'Оставлено' "$T/o" && bad "un: нечего оставлять" || ok
mkun opkg; feed no; uninstall_tailscale >/dev/null 2>&1; rc "un: отказ" $? 2
[ -s "$MOCK_LOG" ] && bad "un: отказ без вызовов" || ok; fexists "$TS_STATE_DIR" && fexists "$SELF_DEST" && ok || bad "un: отказ ничего не трогает"
mkun opkg; feed Yes; uninstall_tailscale >/dev/null 2>&1; rc "un: 'Yes' не принимается" $? 2; fexists "$TS_STATE_DIR" && ok || bad "un: 'Yes' ничего не трогает"
mkun opkg; NONINTERACTIVE=1; uninstall_tailscale >/dev/null 2>&1; rc "un: неинтерактивно" $? 2; fexists "$TS_STATE_DIR" && ok || bad "un: неинтерактивно ничего не трогает"
# сбой удаления пакета
mkun opkg; MOCK_REMOVE_FAIL=tailscale; feed yes n; uninstall_tailscale >"$T/o" 2>"$T/e"; rc "un: сбой remove tailscale" $? 0
fexists "$TS_STATE_DIR" && fexists "$TS_UCI_CONF" && ok || bad "un: при сбое состояние и конфиг оставлены"
fexists "$SELF_DEST" && ok || bad "un: при сбое алиас оставлен"; grep -Fxq "/usr/bin/tsi" "$SYSUPGRADE_CONF" && ok || bad "un: при сбое записи sysupgrade оставлены"
grep -q 'Оставлено: .*package' "$T/o" && ok || bad "un: в отчёте оставленный пакет"; [ -s "$T/e" ] && ok || bad "un: предупреждение о пакете"
# direct-режим (нет фидов)
mkun opkg; rm -f "$FEEDS_LEDGER" "$OPKG_FEEDS"; printf 'INSTALL_SOURCE=B\nB_SUBMODE=direct\n' >"$CONF"; conf_load; rm -f "$S/inst.$LUCI"
feed yes n; uninstall_tailscale >/dev/null 2>&1; rc "un: direct" $? 0; nocall "un: direct без удаления luci" "opkg remove $LUCI"; fexists "$TS_STATE_DIR" && bad "un: direct, состояние удалено" || ok
# нет firewall-секций
mkun opkg; STUB_FW_OURS=1; feed yes n; uninstall_tailscale >/dev/null 2>&1; nocall "un: без наших секций нет fw_remove" "STUB fw_remove"
# пакет уже удалён
mkun opkg; rm -f "$S/inst.tailscale" "$S/inst.$LUCI"; feed yes n; uninstall_tailscale >/dev/null 2>&1; rc "un: пакета уже нет" $? 0; nocall "un: пакета нет без remove" "opkg remove"
fexists "$TS_STATE_DIR" && bad "un: пакета нет, остатки убраны" || ok
# apk
mkun apk; feed yes n; uninstall_tailscale >/dev/null 2>&1; rc "uninstall apk" $? 0
has "un apk: del luci" "apk del $LUCI"; has "un apk: del tailscale" "apk del tailscale"; nocall "un apk: без flag unhold" "flag"
before "un apk: luci раньше tailscale" "apk del $LUCI" "apk del tailscale"
grep -Fxq 'https://user/p.adb' "$APK_FEEDS" && ok || bad "un apk: чужой репозиторий цел"; grep -q 'tsi:' "$APK_FEEDS" && bad "un apk: наши записи удалены" || ok
fexists "$APK_KEYDIR/tsi-lite.pub" && bad "un apk: ключи удалены" || ok

# ================= i18n =================
CUR_LANG=ru; i18n_selfcheck 2>/dev/null; rc "i18n selfcheck" $? 0
keys_of() { sed -n "/^$1() {/,/^}/p" "$HERE/tsi.sh" | sed -n 's/^ *\([A-Z0-9_]*\)) *_S=.*/\1/p' | sort | tr '\n' ' '; }
eq "keys ru==en" "$(keys_of strings_ru)" "$(keys_of strings_en)"
eq "keys == I18N_KEYS" "$(keys_of strings_ru)" "$(for k in $I18N_KEYS; do echo $k; done | sort | tr '\n' ' ')"
sed -n '/^# 9\. ОБНОВЛЕНИЕ/,$p' "$HERE/tsi.sh" | grep -v '^[[:space:]]*#' | grep -Eq '(^|[^A-Za-z_-])(opkg|apk) [a-z-]' && bad "слой 7: прямой вызов opkg/apk" || ok
eq "слой 7: rm -rf только внутри _safe_rm" "$(sed -n '/^# 9\. ОБНОВЛЕНИЕ/,$p' "$HERE/tsi.sh" | grep -v '^[[:space:]]*#' | grep -c 'rm -rf')" "1"

rm -rf "$T"
printf 'passed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
