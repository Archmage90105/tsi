#!/bin/sh
# Тесты слоя 4 (установка) на моках.
# Запуск: sh test_layer4.sh   (TSI_TEST_SH="busybox ash" - чем запускать драйверы)
HERE=$(cd "$(dirname "$0")" && pwd)
TSI_NO_MAIN=1
export TSI_NO_MAIN
. "$HERE/tsi.sh"
SH_UNDER_TEST=${TSI_TEST_SH:-sh}
GTAR=/usr/bin/tar

T=$(mktemp -d /tmp/tsi-test4.XXXXXX)
CONF="$T/tsi.conf"; RUNDIR="$T/run"; LOG_FILE="$RUNDIR/tsi.log"
ROLLBACK_FILE="$RUNDIR/rollback.list"; TTY_DEV="$T/tty"
OPKG_FEEDS="$T/opkg/customfeeds.conf"; OPKG_KEYDIR="$T/opkg/keys"
APK_FEEDS="$T/apk/repositories.d/customfeeds.list"; APK_KEYDIR="$T/apk/keys"
APK_ARCH_FILE="$T/apk_arch"; FEEDS_LEDGER="$T/feeds.ledger"
SELF_DEST="$T/bin/tsi"; INIT_SCRIPT="$T/init.tailscale"; SYSUPGRADE_CONF="$T/sysupgrade.conf"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: получено [$2], ожидалось [$3]"; fi; }
rc()  { if [ "$2" -eq "$3" ]; then ok; else bad "$1: rc=$2, ожидалось $3"; fi; }
has() { if grep -Fxq -- "$2" "$MOCK_LOG"; then ok; else bad "$1: нет вызова [$2]"; fi; }
hasnt() { if grep -Fxq -- "$2" "$MOCK_LOG"; then bad "$1: лишний вызов [$2]"; else ok; fi; }
nocall() { if grep -q -- "$2" "$MOCK_LOG"; then bad "$1: лишний вызов [$2]"; else ok; fi; }
lineno() { grep -Fxn -- "$1" "$MOCK_LOG" | head -n 1 | cut -d: -f1; }
reset_log() { : >"$MOCK_LOG"; }

# ---------- моки ----------
BASEPATH=$PATH
mkdir -p "$T/tools" "$T/usignbin" "$T/m_opkg" "$T/m_apk" "$T/fix"
MOCK_LOG="$T/calls.log"; FIX="$T/fix"; MOCK_LISTS="$T/lists"
export MOCK_LOG FIX MOCK_LISTS MOCK_INSTALLED MOCK_AVAILABLE MOCK_MAINT MOCK_ARCH_LINES MOCK_UPDATE_FAIL MOCK_INSTALL_FAIL MOCK_SIM_FAIL MOCK_STATE
cat >"$T/m_opkg/opkg" <<'M'
#!/bin/sh
echo "opkg $*" >>"$MOCK_LOG"
case "$1" in
  update) [ -n "$MOCK_UPDATE_FAIL" ] && exit 1; : >"$MOCK_LISTS" ;;
  info) [ -f "$MOCK_LISTS" ] || exit 0; case " $MOCK_AVAILABLE " in *" $2 "*) echo "Package: $2";; esac ;;
  status) case " $MOCK_INSTALLED " in *" $2 "*) printf 'Package: %s\nVersion: 1.2.3-1\n' "$2"; [ -n "$MOCK_MAINT" ] && echo "Maintainer: $MOCK_MAINT"; echo 'Status: install ok installed';; esac ;;
  list-installed) case " $MOCK_INSTALLED " in *" $2 "*) echo "$2 - 1.2.3-1";; esac ;;
  print-architecture) printf '%b\n' "$MOCK_ARCH_LINES" ;;
  install) [ -n "$MOCK_INSTALL_FAIL" ] && exit 1 ;;
esac
exit 0
M
cat >"$T/m_apk/apk" <<'M'
#!/bin/sh
echo "apk $*" >>"$MOCK_LOG"
case "$1" in
  update) [ -n "$MOCK_UPDATE_FAIL" ] && exit 1; : >"$MOCK_LISTS" ;;
  info) case " $MOCK_INSTALLED " in *" $3 "*) exit 0;; *) exit 1;; esac ;;
  list) case " $MOCK_INSTALLED " in *" $3 "*) echo "$3-1.2.3-r0 x86_64 {$3} (BSD-3-Clause) [installed]";; esac ;;
  search) [ -f "$MOCK_LISTS" ] || exit 0; case " $MOCK_AVAILABLE " in *" $3 "*) echo "$3-1.2.3-r0";; esac ;;
  add) [ -n "$MOCK_INSTALL_FAIL" ] && exit 1 ;;
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
export MOCK_INIT_FAIL
setpath() { # opkg|apk [nousign]
    _sp="$T/m_$1:$T/tools"
    [ "$2" = nousign ] || _sp="$_sp:$T/usignbin"
    PATH="$_sp:$BASEPATH"
}
fresh() { # чистое состояние окружения
    rm -rf "$T/opkg" "$T/apk" "$FEEDS_LEDGER" "$CONF" "$T/bin" "$LISTS" "$MOCK_LISTS" "$SYSUPGRADE_CONF" "$APK_ARCH_FILE"
    reset_log; rollback_init
    MOCK_INSTALLED=""; MOCK_AVAILABLE=""; MOCK_MAINT=""; MOCK_UPDATE_FAIL=""; MOCK_INSTALL_FAIL=""; MOCK_INIT_FAIL=""
    MOCK_ARCH_LINES='arch all 1\narch noarch 1\narch mipsel_24kc 10'
    NONINTERACTIVE=0; : >"$TTY_DEV"; conf_reset
}

# ---------- фикстуры ----------
A53=$(printf 'A%.0s' $(seq 1 53))
FB="$FIX/gunanovo.github.io/openwrt-tailscale"; RB="$FIX/raw.githubusercontent.com/gunanovo/openwrt-tailscale/refs/heads/feed"
mkdir -p "$FB/mipsel_24kc" "$FB/aarch64_cortex-a53" "$RB/mipsel_24kc"
printf 'untrusted comment: usign public key\nRWQ%s\n' "$A53" >"$FB/key-build.pub"
printf -- '-----BEGIN PUBLIC KEY-----\nMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE\n-----END PUBLIC KEY-----\n' >"$FB/key-build.rsa.pub"
# NEW: те же ключи по raw-пути (там их ждёт текущий код)
cp "$FB/key-build.pub"      "$RB/key-build.pub"
cp "$FB/key-build.rsa.pub"  "$RB/key-build.rsa.pub"
printf 'index-bytes' >"$FB/mipsel_24kc/Packages.gz"
printf 'index-bytes' >"$FB/aarch64_cortex-a53/packages.adb"
mkelf() { printf "\\177ELF\\00$2\\00$3\\001\\000\\000\\000\\000\\000\\000\\000\\000\\000\\002\\000$4" >"$1"; }
mkipk() { # OUT ELFCLASS ELFDATA MACHBYTES
    _d="$T/ipkbuild"; rm -rf "$_d"; mkdir -p "$_d/data/usr/sbin" "$_d/data/etc/init.d" "$_d/ctl"
    mkelf "$_d/data/usr/sbin/tailscaled" "$2" "$3" "$4"; head -c 300 /dev/zero >>"$_d/data/usr/sbin/tailscaled"
    ln -s tailscaled "$_d/data/usr/sbin/tailscale"
    printf '#!/bin/sh /etc/rc.common\n' >"$_d/data/etc/init.d/tailscale"
    printf 'Package: tailscale\nVersion: 1.104.1-r1\nMaintainer: GuNan <x@y.z>\n' >"$_d/ctl/control"
    $GTAR -czf "$_d/data.tar.gz" -C "$_d/data" .; $GTAR -czf "$_d/control.tar.gz" -C "$_d/ctl" .
    printf '2.0\n' >"$_d/debian-binary"
    $GTAR -czf "$1" -C "$_d" ./debian-binary ./data.tar.gz ./control.tar.gz
}
IPK="$RB/mipsel_24kc/tailscale-1.104.1-r1.ipk"
mkipk "$IPK" 1 1 '\010\000'      # mipsle
set -- $(sha256sum "$IPK"); IPK_SHA=$1
printf '1.104.1-r1\n' >"$RB/mipsel_24kc/version"
printf '%s\n' "$IPK_SHA" >"$RB/mipsel_24kc/ipk.sha256"

tsi_init 2>/dev/null; rc "tsi_init" $? 0
CUR_LANG=ru; REL_MAJOR=24.10; REL_ARCH=mipsel_24kc; TS_ARCH=mipsle

# ================= install_self =================
mkdrv() { # TSI_URL-значение, SELF_DEST-значение
    cat >"$T/drv.sh" <<EOD
. "$HERE/tsi.sh"
RUNDIR="$RUNDIR"
$1
SELF_DEST="$2"
install_self
echo "rc=\$?"
EOD
}
rm -rf "$T/bin"; mkdrv 'TSI_URL=https://example.org/tsi.sh' "$T/bin/tsi"
$SH_UNDER_TEST "$T/drv.sh" >"$T/o" 2>"$T/e"; eq "self: rc" "$(tail -n 1 "$T/o")" "rc=0"
[ -x "$T/bin/tsi" ] && ok || bad "self: копия создана и исполняема"
cmp -s "$T/bin/tsi" "$T/drv.sh" && ok || bad "self: копия совпадает с исходником"
mkdrv '' "$T/drv.sh"; : >"$T/before"; $SH_UNDER_TEST "$T/drv.sh" >"$T/o" 2>&1; eq "self: no-op когда уже на месте" "$(tail -n 1 "$T/o")" "rc=0"
mkdrv 'TSI_URL=https://example.org/tsi.sh' "$T/bin2/tsi"; rm -rf "$T/bin2"
cat "$T/drv.sh" | $SH_UNDER_TEST >"$T/o" 2>"$T/e"; PRC=$?
eq "self: пайп -> rc=1" "$(tail -n 1 "$T/o" | grep '^rc=')" "rc=1"
grep -q 'wget -O /tmp/tsi.sh https://example.org/tsi.sh && sh /tmp/tsi.sh' "$T/o" && ok || bad "self: подсказка с URL"
grep -q 'ОШИБКА' "$T/o" && grep -q 'ERROR' "$T/o" && ok || bad "self: подсказка двуязычная"
[ -e "$T/bin2" ] && bad "self: при пайпе ничего не копируется" || ok
mkdrv '' "$T/bin3/tsi"; cat "$T/drv.sh" | $SH_UNDER_TEST >"$T/o" 2>&1
grep -q '<URL>' "$T/o" && ok || bad "self: плейсхолдер даёт общую подсказку"
mkdrv '' "/proc/нет-такого/tsi"; $SH_UNDER_TEST "$T/drv.sh" >"$T/o" 2>"$T/e"
eq "self: нет записи -> rc 0" "$(tail -n 1 "$T/o")" "rc=0"; [ -s "$T/e" ] && ok || bad "self: предупреждение при отсутствии записи"

# ================= pkg_arch / feed_arch =================
PKG_MGR=opkg; setpath opkg
MOCK_ARCH_LINES='arch all 1\narch noarch 1\narch aarch64_cortex-a53 10'; eq "pkg_arch opkg" "$(pkg_arch)" "aarch64_cortex-a53"
MOCK_ARCH_LINES='arch all 1\narch noarch 1'; eq "pkg_arch opkg (только служебные -> последняя)" "$(pkg_arch)" "noarch"
MOCK_ARCH_LINES='garbage'; eq "pkg_arch мусор" "$(pkg_arch)" ""
MOCK_ARCH_LINES='arch all 1\narch mipsel_24kc 10'
eq "feed_arch opkg" "$(feed_arch)" "mipsel_24kc"
PKG_MGR=apk; printf 'aarch64_cortex-a53\n' >"$APK_ARCH_FILE"; eq "feed_arch apk" "$(feed_arch)" "aarch64_cortex-a53"
printf 'x;y\n' >"$APK_ARCH_FILE"; REL_ARCH=mips_24kc; eq "feed_arch: недопустимые символы -> fallback" "$(feed_arch 2>/dev/null)" "mips_24kc"
rm -f "$APK_ARCH_FILE"; feed_arch 2>"$T/e" >/dev/null; [ -s "$T/e" ] && ok || bad "feed_arch fallback предупреждает"
REL_ARCH=""; feed_arch >/dev/null 2>&1; rc "feed_arch: ничего нет -> 1" $? 1
REL_ARCH=mipsel_24kc

# ================= feed_precheck =================
PKG_MGR=opkg; setpath opkg
feed_precheck mipsel_24kc; rc "precheck opkg есть" $? 0
feed_precheck riscv64_generic; rc "precheck opkg нет индекса" $? 1
PKG_MGR=apk; setpath apk
feed_precheck aarch64_cortex-a53; rc "precheck apk есть" $? 0
feed_precheck mipsel_24kc; rc "precheck apk нет packages.adb" $? 1

# ================= install_deps =================
_ssl_ok() { return 1; }
PKG_MGR=opkg; setpath opkg nousign; fresh
MOCK_AVAILABLE="usign libustream-openssl kmod-tun ca-bundle"
install_deps >/dev/null 2>&1; rc "deps opkg" $? 0
has "deps: установка с учётом списков" "opkg install kmod-tun ca-bundle libustream-openssl usign"
[ "$(lineno 'opkg update')" -lt "$(lineno 'opkg install kmod-tun ca-bundle libustream-openssl usign')" ] && ok || bad "deps: pkg_update раньше проверки доступности"
fresh; MOCK_INSTALLED="kmod-tun ca-bundle"; setpath opkg; : >"$T/usignbin/.x"
_ssl_ok() { return 0; }
install_deps >/dev/null 2>&1; rc "deps: всё есть" $? 0
nocall "deps: всё есть -> без update" "opkg update"; nocall "deps: всё есть -> без install" "opkg install"
_ssl_ok() { return 1; }
fresh; MOCK_INSTALL_FAIL=1; MOCK_AVAILABLE="libustream-openssl"; MOCK_INSTALLED="kmod-tun ca-bundle"; setpath opkg
install_deps >/dev/null 2>&1; rc "deps: сбой установки -> 1" $? 1
PKG_MGR=apk; setpath apk; fresh; MOCK_AVAILABLE="libustream-mbedtls"; MOCK_INSTALLED=""
install_deps >/dev/null 2>&1; rc "deps apk" $? 0
has "deps apk: apk add" "apk add kmod-tun ca-bundle libustream-mbedtls"
nocall "deps apk: usign не нужен" "usign"
_ssl_ok() { ls /usr/lib/libustream*.so* /lib/libustream*.so* >/dev/null 2>&1; }

# ================= pkg_field / pkg_install_file =================
PKG_MGR=opkg; setpath opkg; fresh; MOCK_INSTALLED="tailscale"; MOCK_MAINT="GuNan <x@y.z>"
eq "pkg_field" "$(pkg_field tailscale Maintainer)" "GuNan <x@y.z>"
pkg_field tailscale 'Bad;Field' >/dev/null; rc "pkg_field плохое поле" $? 1
PKG_MGR=apk; pkg_field tailscale Maintainer >/dev/null; rc "pkg_field apk -> 1" $? 1
: >"$T/x.ipk"; PKG_MGR=apk; pkg_install_file "$T/x.ipk" 2>/dev/null; rc "install_file apk запрещён" $? 1
PKG_MGR=opkg; setpath opkg; reset_log
pkg_install_file "$T/x.txt" 2>/dev/null; rc "install_file не .ipk" $? 1
pkg_install_file "$T/x.ipk"; rc "install_file" $? 0; has "install_file call" "opkg install $T/x.ipk"
nocall "install_file: без allow-untrusted" "allow-untrusted"

# ================= choose_source =================
PKG_MGR=opkg; setpath opkg; REL_MAJOR=24.10; fresh
printf '2\n' >"$TTY_DEV"; choose_source >"$T/o" 2>&1; rc "choose 2" $? 0; eq "choice lite_feed" "$SOURCE_CHOICE" lite_feed
grep -q 'прямое скачивание' "$T/o" && ok || bad "choose: на 24.10+opkg direct показан"
printf '3\n' >"$TTY_DEV"; choose_source >/dev/null 2>&1; eq "choice lite_direct" "$SOURCE_CHOICE" lite_direct
printf '1\n' >"$TTY_DEV"; choose_source >/dev/null 2>&1; eq "choice official" "$SOURCE_CHOICE" official
[ -s "$CONF" ] && grep -q INSTALL_SOURCE "$CONF" && bad "choose: в конфиг не пишет" || ok
PKG_MGR=apk; REL_MAJOR=25.12; printf '1\n' >"$TTY_DEV"; choose_source >"$T/o" 2>&1
grep -q 'прямое скачивание' "$T/o" && bad "choose: на apk/25.12 direct скрыт" || ok
PKG_MGR=opkg; REL_MAJOR=""; printf '1\n' >"$TTY_DEV"; choose_source >"$T/o" 2>&1
grep -q 'прямое скачивание' "$T/o" && bad "choose: SNAPSHOT/opkg direct скрыт" || ok
REL_MAJOR=24.10
NONINTERACTIVE=1; choose_source >/dev/null 2>&1; rc "choose non-interactive" $? 1; NONINTERACTIVE=0
SOURCE_CHOICE=""; install_selected 2>/dev/null; rc "install_selected без выбора" $? 1

# ================= install_official =================
PKG_MGR=opkg; setpath opkg; fresh; MOCK_AVAILABLE="tailscale tailscaled"
install_official >/dev/null 2>&1; rc "official" $? 0
has "official: оба пакета" "opkg install tailscale tailscaled"
eq "official: INSTALL_SOURCE" "$(conf_get INSTALL_SOURCE)" A; eq "official: B_SUBMODE пуст" "$(conf_get B_SUBMODE)" ""
fresh; MOCK_AVAILABLE="tailscale"; install_official >/dev/null 2>&1; has "official: только tailscale" "opkg install tailscale"
fresh; MOCK_AVAILABLE="tailscale"; MOCK_INSTALL_FAIL=1; install_official >/dev/null 2>&1; rc "official: сбой" $? 1
[ -s "$CONF" ] && grep -q INSTALL_SOURCE "$CONF" && bad "official: при сбое конфиг не пишется" || ok
fresh; conf_set B_SUBMODE direct; MOCK_AVAILABLE="tailscale"; install_official >/dev/null 2>&1
eq "official: сбрасывает B_SUBMODE" "$(conf_get B_SUBMODE)" ""

# ================= install_lite_feed =================
PKG_MGR=opkg; setpath opkg; fresh; MOCK_AVAILABLE="tailscale"; MOCK_INSTALLED="tailscale"; MOCK_MAINT="GuNan <x@y.z>"
printf 'y\n' >"$TTY_DEV"; install_lite_feed >"$T/o" 2>"$T/e"; rc "lite_feed opkg" $? 0
grep -Fxq 'src/gz tsi_lite https://gunanovo.github.io/openwrt-tailscale/mipsel_24kc' "$OPKG_FEEDS" && ok || bad "lite_feed: строка фида"
[ -f "$OPKG_KEYDIR/0123456789abcdef" ] && ok || bad "lite_feed: ключ импортирован"
has "lite_feed: install" "opkg install tailscale"; has "lite_feed: hold" "opkg flag hold tailscale"
eq "lite_feed: INSTALL_SOURCE" "$(conf_get INSTALL_SOURCE)" B; eq "lite_feed: B_SUBMODE" "$(conf_get B_SUBMODE)" feed
[ -s "$T/e" ] && bad "lite_feed: без предупреждений при верном Maintainer" || ok
fresh; MOCK_AVAILABLE="tailscale"; MOCK_INSTALLED="tailscale"; MOCK_MAINT="OpenWrt Community"; printf 'y\n' >"$TTY_DEV"
install_lite_feed >/dev/null 2>"$T/e"; rc "lite_feed: чужой Maintainer -> предупреждение, не ошибка" $? 0
[ -s "$T/e" ] && ok || bad "lite_feed: предупреждение о происхождении"
fresh; MOCK_ARCH_LINES='arch all 1\narch riscv64_generic 10'; printf 'y\n' >"$TTY_DEV"
install_lite_feed >/dev/null 2>&1; rc "lite_feed: архитектура не в фиде" $? 1
[ -e "$OPKG_FEEDS" ] && bad "lite_feed: фид не добавлен при неподдержке" || ok
[ -s "$CONF" ] && grep -q INSTALL_SOURCE "$CONF" && bad "lite_feed: конфиг не пишется" || ok
fresh; printf 'n\n' >"$TTY_DEV"; install_lite_feed >/dev/null 2>&1; rc "lite_feed: отказ -> 2" $? 2
nocall "lite_feed: при отказе без install" "opkg install"
[ -s "$CONF" ] && grep -q INSTALL_SOURCE "$CONF" && bad "lite_feed: отказ, конфиг не пишется" || ok
fresh; MOCK_AVAILABLE="tailscale"; MOCK_INSTALL_FAIL=1; printf 'y\n' >"$TTY_DEV"; install_lite_feed >/dev/null 2>&1
rc "lite_feed: сбой install -> 1" $? 1
[ -s "$CONF" ] && grep -q INSTALL_SOURCE "$CONF" && bad "lite_feed: сбой, конфиг не пишется" || ok
# apk
PKG_MGR=apk; setpath apk; fresh; MOCK_INSTALLED="tailscale"; printf 'aarch64_cortex-a53\n' >"$APK_ARCH_FILE"; printf 'y\n' >"$TTY_DEV"
install_lite_feed >/dev/null 2>&1; rc "lite_feed apk" $? 0
eq "lite_feed apk: строки фида" "$(tail -n 2 "$APK_FEEDS" | tr '\n' ' ')" "# tsi:lite https://gunanovo.github.io/openwrt-tailscale/aarch64_cortex-a53/packages.adb "
[ -f "$APK_KEYDIR/tsi-lite.pub" ] && ok || bad "lite_feed apk: ключ"
has "lite_feed apk: add" "apk add tailscale"; has "lite_feed apk: пин" "apk add tailscale=1.2.3-r0"
nocall "lite_feed apk: без allow-untrusted" "allow-untrusted"

# ================= install_lite_direct =================
dfresh() { PKG_MGR=opkg; setpath opkg; fresh; REL_MAJOR=24.10; TS_ARCH=mipsle; printf 'yes\n' >"$TTY_DEV"; MOCK_INSTALLED="tailscale"; MOCK_ARCH_LINES='arch all 1\narch mipsel_24kc 10'; }
dfresh; install_lite_direct >/dev/null 2>"$T/e"; rc "direct ok" $? 0
has "direct: install файла" "opkg install $RUNDIR/tailscale-1.104.1-r1.ipk"; has "direct: hold" "opkg flag hold tailscale"
eq "direct: LITE_VERSION" "$(conf_get LITE_VERSION)" "1.104.1-r1"
eq "direct: INSTALL_SOURCE/B_SUBMODE" "$(conf_get INSTALL_SOURCE)/$(conf_get B_SUBMODE)" "B/direct"
[ -e "$RUNDIR/tailscale-1.104.1-r1.ipk" ] && bad "direct: .ipk удалён после установки" || ok
grep -q 'ipk.sha256' "$MOCK_LOG" && ok || bad "direct: запрошен ipk.sha256 (а не <пакет>.ipk.sha256)"
nocall "direct: без несуществующего имени sha" "ipk.ipk.sha256"
[ -s "$T/e" ] && bad "direct: без предупреждений в штатном случае" || ok
# sha: заглавные буквы
mv "$RB/mipsel_24kc/ipk.sha256" "$T/sha.bak"; printf '%s\n' "$IPK_SHA" | tr 'a-f' 'A-F' >"$RB/mipsel_24kc/ipk.sha256"
dfresh; install_lite_direct >/dev/null 2>&1; rc "direct: sha в верхнем регистре" $? 0
# sha неверный
printf '%064d\n' 0 >"$RB/mipsel_24kc/ipk.sha256"
dfresh; install_lite_direct >/dev/null 2>&1; rc "direct: неверный sha -> 1" $? 1
nocall "direct: при неверном sha без install" "opkg install"
[ -e "$RUNDIR/tailscale-1.104.1-r1.ipk" ] && bad "direct: .ipk удалён после sha-ошибки" || ok
# sha отсутствует
rm -f "$RB/mipsel_24kc/ipk.sha256"
dfresh; install_lite_direct >/dev/null 2>"$T/e"; rc "direct: sha недоступен -> установка с предупреждением" $? 0; [ -s "$T/e" ] && ok || bad "direct: предупреждение о sha"
mv "$T/sha.bak" "$RB/mipsel_24kc/ipk.sha256"
# архитектура
dfresh; TS_ARCH=arm64; install_lite_direct >/dev/null 2>&1; rc "direct: чужая архитектура -> 1" $? 1
nocall "direct: чужая арх. без install" "opkg install"
dfresh; TS_ARCH=""; install_lite_direct >/dev/null 2>"$T/e"; rc "direct: TS_ARCH пуст -> предупреждение" $? 0; [ -s "$T/e" ] && ok || bad "direct: предупреждение при пустом TS_ARCH"
# отказ и режимы
dfresh; printf 'Yes\n' >"$TTY_DEV"; install_lite_direct >/dev/null 2>&1; rc "direct: 'Yes' не принимается -> 2" $? 2
nocall "direct: отказ без сети" "uclient-fetch"
dfresh; NONINTERACTIVE=1; install_lite_direct >/dev/null 2>&1; rc "direct: noninteractive -> 2" $? 2
dfresh; PKG_MGR=apk; install_lite_direct >/dev/null 2>&1; rc "direct: apk -> 1" $? 1
dfresh; REL_MAJOR=25.12; install_lite_direct >/dev/null 2>&1; rc "direct: 25.12 -> 1" $? 1
dfresh; MOCK_ARCH_LINES='arch all 1\narch nonexist_arch 10'; install_lite_direct >/dev/null 2>&1; rc "direct: нет version для арх. -> 1" $? 1
printf 'bad;version\n' >"$RB/mipsel_24kc/version"; dfresh; install_lite_direct >/dev/null 2>&1; rc "direct: плохая version -> 1" $? 1
printf '1.104.1-r1\n' >"$RB/mipsel_24kc/version"
dfresh; MOCK_INSTALL_FAIL=1; install_lite_direct >/dev/null 2>&1; rc "direct: сбой opkg install -> 1" $? 1
[ -s "$CONF" ] && grep -q INSTALL_SOURCE "$CONF" && bad "direct: сбой, конфиг не пишется" || ok
# ELF на бинарнике другой архитектуры внутри ipk: BE mips
mkipk "$IPK" 1 2 '\000\010'; set -- $(sha256sum "$IPK"); printf '%s\n' "$1" >"$RB/mipsel_24kc/ipk.sha256"
dfresh; TS_ARCH=mipsle; install_lite_direct >/dev/null 2>&1; rc "direct: mips BE в пакете, на устройстве mipsle -> 1" $? 1
dfresh; TS_ARCH=mips; install_lite_direct >/dev/null 2>&1; rc "direct: mips BE совпадает" $? 0

# ================= service_enable_start =================
sleep() { :; }
pidof() { return 0; }
fresh; service_enable_start >/dev/null 2>"$T/e"; rc "service ok" $? 0
has "service: enable" "init enable"; has "service: start" "init start"
[ "$(lineno 'init enable')" -lt "$(lineno 'init start')" ] && ok || bad "service: enable раньше start"
pidof() { return 1; }
fresh; service_enable_start >/dev/null 2>"$T/e"; rc "service: не запущен -> предупреждение, 0" $? 0; [ -s "$T/e" ] && ok || bad "service: предупреждение"
pidof() { return 0; }
fresh; MOCK_INIT_FAIL=enable; service_enable_start >/dev/null 2>&1; rc "service: enable fail" $? 1
fresh; MOCK_INIT_FAIL=start; service_enable_start >/dev/null 2>&1; rc "service: start fail" $? 1
INIT_SCRIPT="$T/нет"; service_enable_start >/dev/null 2>&1; rc "service: нет init" $? 1
INIT_SCRIPT="$T/init.tailscale"
unset -f sleep pidof

# ================= register_sysupgrade =================
PKG_MGR=opkg; fresh; printf '/etc/my/own\n' >"$SYSUPGRADE_CONF"
register_sysupgrade >/dev/null 2>&1; rc "sysupgrade" $? 0
for p in /usr/bin/tsi /etc/tailscale-installer.conf /etc/tailscale-installer.feeds /etc/config/tailscale /etc/tailscale/ /var/lib/tailscale/ /etc/my/own; do
    grep -Fxq "$p" "$SYSUPGRADE_CONF" && ok || bad "sysupgrade: $p"
done
N1=$(wc -l <"$SYSUPGRADE_CONF"); register_sysupgrade >/dev/null 2>&1; eq "sysupgrade идемпотентен" "$(wc -l <"$SYSUPGRADE_CONF")" "$N1"
printf 'lite|https://x|0123456789abcdef\nbad|https://x|../evil\n' >"$FEEDS_LEDGER"
register_sysupgrade >/dev/null 2>&1
grep -Fxq "$OPKG_FEEDS" "$SYSUPGRADE_CONF" && ok || bad "sysupgrade: файл фидов из учёта"
grep -Fxq "$OPKG_KEYDIR/0123456789abcdef" "$SYSUPGRADE_CONF" && ok || bad "sysupgrade: ключ из учёта"
grep -q 'evil' "$SYSUPGRADE_CONF" && bad "sysupgrade: небезопасный id пропущен" || ok
rm -f "$SYSUPGRADE_CONF"; fresh; rm -f "$SYSUPGRADE_CONF"; register_sysupgrade >/dev/null 2>&1; rc "sysupgrade: файла не было" $? 0
SYSUPGRADE_CONF="/proc/нет/sysupgrade.conf"; register_sysupgrade >/dev/null 2>&1; rc "sysupgrade: нет записи -> 1" $? 1
SYSUPGRADE_CONF="$T/sysupgrade.conf"

# ================= i18n =================
CUR_LANG=ru; i18n_selfcheck 2>/dev/null; rc "i18n selfcheck" $? 0
keys_of() { sed -n "/^$1() {/,/^}/p" "$HERE/tsi.sh" | sed -n 's/^ *\([A-Z0-9_]*\)) *_S=.*/\1/p' | sort | tr '\n' ' '; }
eq "keys ru==en" "$(keys_of strings_ru)" "$(keys_of strings_en)"
eq "keys == I18N_KEYS" "$(keys_of strings_ru)" "$(for k in $I18N_KEYS; do echo $k; done | sort | tr '\n' ' ')"
grep -v '^[[:space:]]*#' "$HERE/tsi.sh" | grep -q -- '--allow-untrusted' && bad "в коде не должно быть --allow-untrusted" || ok
# слой 4 не вызывает opkg/apk напрямую (только через пакетный слой)
sed -n '/^# 6\. УСТАНОВКА/,$p' "$HERE/tsi.sh" | grep -v '^[[:space:]]*#' | grep -Eq '(^|[^A-Za-z_-])(opkg|apk) [a-z-]' && bad "слой 4: прямой вызов opkg/apk" || ok

rm -rf "$T"
printf 'passed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
