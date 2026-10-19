#!/bin/sh
# Тесты слоёв 2-3 (определение системы, пакетный слой, репозитории) на моках.
# Запуск: sh test_layer23.sh   (также: bash --posix, busybox ash)
HERE=$(cd "$(dirname "$0")" && pwd)
TSI_NO_MAIN=1
. "$HERE/tsi.sh"

T=$(mktemp -d /tmp/tsi-test23.XXXXXX)
CONF="$T/tsi.conf"; RUNDIR="$T/run"; LOG_FILE="$RUNDIR/tsi.log"
ROLLBACK_FILE="$RUNDIR/rollback.list"; TTY_DEV="$T/tty"
OPENWRT_RELEASE="$T/openwrt_release"
OPKG_FEEDS="$T/opkg/customfeeds.conf"; OPKG_KEYDIR="$T/opkg/keys"
APK_FEEDS="$T/apk/repositories.d/customfeeds.list"; APK_KEYDIR="$T/apk/keys"
FEEDS_LEDGER="$T/feeds.ledger"
INITD_DIR="$T/initd"; TUN_DEV="/dev/null"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: получено [$2], ожидалось [$3]"; fi; }
rc()  { if [ "$2" -eq "$3" ]; then ok; else bad "$1: rc=$2, ожидалось $3"; fi; }
has() { if grep -Fxq -- "$2" "$MOCK_LOG"; then ok; else bad "$1: нет вызова [$2]"; fi; }
hasnt() { if grep -Fxq -- "$2" "$MOCK_LOG"; then bad "$1: лишний вызов [$2]"; else ok; fi; }
reset_log() { : >"$MOCK_LOG"; }

# ---------- моки ----------
BASEPATH=$PATH
mkdir -p "$T/tools" "$T/usignbin" "$T/m_opkg" "$T/m_apk" "$T/m_both" "$T/m_none" "$T/fix" "$T/initd"
MOCK_LOG="$T/calls.log"; FIX="$T/fix"
export MOCK_LOG FIX MOCK_INSTALLED MOCK_UPDATE_FAIL MOCK_SIM_FAIL MOCK_IP MOCK_UCI_OUT

cat >"$T/m_opkg/opkg" <<'M'
#!/bin/sh
echo "opkg $*" >>"$MOCK_LOG"
case "$1" in
  status) case " $MOCK_INSTALLED " in *" $2 "*) printf 'Package: %s\nVersion: 1.2.3-1\nStatus: install ok installed\n' "$2";; esac ;;
  list-installed) case " $MOCK_INSTALLED " in *" $2 "*) echo "$2 - 1.2.3-1";; esac ;;
  info) [ "$2" = tailscale ] && echo "Package: tailscale" ;;
  update) [ -n "$MOCK_UPDATE_FAIL" ] && exit 1 ;;
esac
exit 0
M
cat >"$T/m_apk/apk" <<'M'
#!/bin/sh
echo "apk $*" >>"$MOCK_LOG"
case "$1" in
  info) case " $MOCK_INSTALLED " in *" $3 "*) exit 0;; *) exit 1;; esac ;;
  list) case " $MOCK_INSTALLED " in *" $3 "*) echo "$3-1.2.3-r0 x86_64 {$3} (BSD-3-Clause) [installed]";; esac ;;
  search) [ "$3" = tailscale ] && echo "tailscale-1.2.3-r0" ;;
  upgrade) [ -n "$MOCK_SIM_FAIL" ] && exit 1 ;;
  update) [ -n "$MOCK_UPDATE_FAIL" ] && exit 1 ;;
esac
exit 0
M
cp "$T/m_opkg/opkg" "$T/m_both/opkg"; cp "$T/m_apk/apk" "$T/m_both/apk"
cat >"$T/usignbin/usign" <<'M'
#!/bin/sh
echo "usign $*" >>"$MOCK_LOG"
[ "$1" = "-F" ] && echo 0123456789abcdef
M
cat >"$T/tools/ip" <<'M'
#!/bin/sh
echo "ip $*" >>"$MOCK_LOG"
if [ "$1" = tuntap ] && [ "$MOCK_IP" = fail ]; then echo 'Object "tuntap" is unknown' >&2; exit 1; fi
exit 0
M
cat >"$T/tools/uci" <<'M'
#!/bin/sh
[ "$1 $2 $3" = "-q show dhcp" ] && printf '%s\n' "$MOCK_UCI_OUT"
exit 0
M
cat >"$T/tools/uclient-fetch" <<'M'
#!/bin/sh
echo "uclient-fetch $*" >>"$MOCK_LOG"
dest=""; url=""
while [ $# -gt 0 ]; do case "$1" in -O) dest=$2; shift 2;; -q) shift;; *) url=$1; shift;; esac; done
f="$FIX/$(basename "$url")"
[ -f "$f" ] || exit 1
cp "$f" "$dest"
M
chmod +x "$T"/m_*/* "$T/usignbin/usign" "$T/tools/"*
setpath() { # mgr(opkg|apk|both|none) [nousign]
    _sp="$T/m_$1:$T/tools"
    [ "$2" = nousign ] || _sp="$_sp:$T/usignbin"
    PATH="$_sp:$BASEPATH"
}

# ---------- фикстуры ----------
A53=$(printf 'A%.0s' $(seq 1 53))
printf 'untrusted comment: usign public key\nRWQ%s\n' "$A53" >"$FIX/usign.pub"
printf 'untrusted comment: usign public key\r\nRWQ%s\r\n' "$A53" >"$FIX/usign_crlf.pub"
printf -- '-----BEGIN PUBLIC KEY-----\nMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE\n-----END PUBLIC KEY-----\n' >"$FIX/pem.pub"
printf '067a9a7db1770bb0\n' >"$FIX/idonly.pub"
printf 'hello world\n' >"$FIX/garbage.pub"
head -c 5000 /dev/zero | tr '\0' 'A' >"$FIX/big.pub"
printf 'untrusted comment: x\nRW%s\nextra\n' "$A53" >"$FIX/usign_extra.pub"

mkrelease() { # VERSION ARCH
    printf "DISTRIB_ID='OpenWrt'\nDISTRIB_RELEASE='%s'\nDISTRIB_REVISION='r1'\nDISTRIB_TARGET='ath79/generic'\nDISTRIB_ARCH='%s'\nDISTRIB_DESCRIPTION='OpenWrt %s'\n" "$1" "$2" "$1" >"$OPENWRT_RELEASE"
}

tsi_init 2>/dev/null; rc "tsi_init" $? 0
CUR_LANG=ru

# ================= detect_release =================
mkrelease 24.10.2 mips_24kc; detect_release
eq "ver" "$REL_VERSION" "24.10.2"; eq "major" "$REL_MAJOR" "24.10"
eq "arch" "$REL_ARCH" "mips_24kc"; eq "target" "$REL_TARGET" "ath79/generic"
mkrelease 25.12.0-rc1 aarch64_cortex-a53; detect_release
eq "major rc" "$REL_MAJOR" "25.12"
mkrelease SNAPSHOT x86_64; detect_release
eq "snapshot major" "$REL_MAJOR" ""
rel_ge 25 12; rc "snapshot ge 25.12" $? 0
mkrelease 24.10.2 x; detect_release
rel_ge 24 10; rc "24.10 ge 24.10" $? 0
rel_ge 25 12; rc "24.10 !ge 25.12" $? 1
REL_MAJOR=25.12; rel_ge 25 12; rc "25.12 ge" $? 0
REL_MAJOR=26.2; rel_ge 25 12; rc "26.2 ge 25.12" $? 0
REL_MAJOR=23.05; rel_ge 24 10; rc "23.05 !ge 24.10" $? 1
OPENWRT_RELEASE="$T/нет"; detect_release 2>/dev/null; rc "нет файла" $? 1
OPENWRT_RELEASE="$T/openwrt_release"

# ================= detect_pkg_mgr =================
mkrelease 24.10.2 x; detect_release
setpath opkg; detect_pkg_mgr; eq "opkg only" "$PKG_MGR" opkg
mkrelease 25.12.0 x; detect_release
setpath apk;  detect_pkg_mgr; eq "apk only" "$PKG_MGR" apk
setpath both; detect_pkg_mgr; eq "both+25.12 -> apk" "$PKG_MGR" apk
mkrelease 24.10.2 x; detect_release
setpath both; detect_pkg_mgr; eq "both+24.10 -> opkg" "$PKG_MGR" opkg
setpath none; detect_pkg_mgr 2>/dev/null; rc "none" $? 1
setpath apk; detect_pkg_mgr 2>"$T/err"; eq "mismatch still apk" "$PKG_MGR" apk
[ -s "$T/err" ] && ok || bad "предупреждение о несоответствии версии и менеджера"
mkrelease 23.05.5 x; detect_release; setpath opkg
detect_pkg_mgr 2>"$T/err"; [ -s "$T/err" ] && ok || bad "предупреждение о неподдерживаемой версии"

# ================= архитектура =================
chk_d() { eq "distrib $1" "$(_arch_from_distrib "$1")" "$2"; }
chk_d x86_64 amd64; chk_d i386_pentium4 386; chk_d aarch64_cortex-a53 arm64
chk_d arm_cortex-a7_neon-vfpv4 arm; chk_d mips_24kc mips; chk_d mipsel_24kc mipsle
chk_d mips64_octeonplus mips64; chk_d mips64el_x mips64le
chk_d riscv64_riscv64 riscv64; chk_d loongarch64_generic loong64
_arch_from_distrib foo_bar >/dev/null; rc "distrib unknown" $? 1
chk_u() { eq "uname $1" "$(_arch_from_uname "$1")" "$2"; }
chk_u x86_64 amd64; chk_u i686 386; chk_u aarch64 arm64; chk_u armv7l arm; chk_u riscv64 riscv64
_arch_from_uname mips >/dev/null; rc "uname mips -> ELF" $? 1
mkelf() { printf "\\177ELF\\00$2\\00$3\\001\\000\\000\\000\\000\\000\\000\\000\\000\\000\\002\\000$4" >"$1"; }
chk_e() { mkelf "$T/elf" "$2" "$3" "$4"; eq "elf $1" "$(_arch_from_elf "$T/elf")" "$1"; }
chk_e mipsle 1 1 '\010\000'; chk_e mips 1 2 '\000\010'
chk_e mips64 2 2 '\000\010'; chk_e mips64le 2 1 '\010\000'
chk_e arm64 2 1 '\267\000'; chk_e amd64 2 1 '\076\000'; chk_e arm 1 1 '\050\000'
chk_e riscv64 2 1 '\363\000'; chk_e loong64 2 1 '\002\001'; chk_e 386 1 1 '\003\000'
printf 'not an elf at all, just text here' >"$T/elf"; _arch_from_elf "$T/elf" >/dev/null; rc "elf garbage" $? 1
printf 'ab' >"$T/elf"; _arch_from_elf "$T/elf" >/dev/null; rc "elf short" $? 1
# detect_arch: приоритеты
REL_ARCH=mipsel_24kc; detect_arch; eq "detect distrib" "$TS_ARCH" mipsle
REL_ARCH=""; _uname_m() { echo aarch64; }; detect_arch; eq "detect uname" "$TS_ARCH" arm64
_uname_m() { echo mips; }; mkelf "$T/elf" 1 2 '\000\010'; ELF_PROBE_FILES="$T/нет $T/elf"
detect_arch; eq "detect elf" "$TS_ARCH" mips
ELF_PROBE_FILES="$T/нет"; detect_arch 2>/dev/null; rc "detect unknown" $? 1

# ================= TUN =================
# busybox ash в сборке Ubuntu запускает свой апплет ip в обход PATH, поэтому мок
# подключаем функцией (на OpenWrt апплета ip в busybox нет - это только тесты).
ip() { "$T/tools/ip" "$@"; }
setpath opkg; reset_log
MOCK_IP=ok; check_tun >/dev/null; rc "tun ip" $? 0
eq "tun avail" "$TUN_AVAILABLE/$TUN_PROBE" "1/ip"
has "tun add" "ip tuntap add dev tsiprobe0 mode tun"; has "tun del" "ip link del dev tsiprobe0"
MOCK_IP=fail; TUN_DEV=/dev/null; check_tun >/dev/null 2>&1; rc "tun device" $? 0
eq "tun device probe" "$TUN_AVAILABLE/$TUN_PROBE" "1/device"
TUN_DEV="$T/нет"; check_tun >/dev/null 2>&1; rc "tun none" $? 1
eq "tun none state" "$TUN_AVAILABLE/$TUN_PROBE" "0/none"
TUN_DEV=/dev/null; MOCK_IP=ok
unset -f ip

# ================= DNS-конфликты =================
PKG_MGR=opkg; setpath opkg
MOCK_INSTALLED="tailscale podkop stubby"; check_dns_conflicts; rc "dns found" $? 0
eq "dns list" "$DNS_CONFLICTS" "podkop stubby"
: >"$INITD_DIR/forkop"; chmod +x "$INITD_DIR/forkop"
MOCK_INSTALLED="tailscale"; check_dns_conflicts; eq "dns initd" "$DNS_CONFLICTS" "forkop"
rm -f "$INITD_DIR/forkop"
MOCK_INSTALLED="dnsmasq-full"; MOCK_UCI_OUT="dhcp.cfg01.domain='lan'"
check_dns_conflicts; rc "dnsmasq-full plain" $? 1; eq "dnsmasq-full plain list" "$DNS_CONFLICTS" ""
MOCK_UCI_OUT="dhcp.cfg01.nftset='/example.com/4#inet#fw4#vpn_domains'"
check_dns_conflicts; eq "dnsmasq-full custom" "$DNS_CONFLICTS" "dnsmasq-full"
MOCK_INSTALLED=""; MOCK_UCI_OUT=""; check_dns_conflicts; rc "dns none" $? 1

# ================= пакетный слой =================
for MGR in opkg apk; do
    PKG_MGR=$MGR; setpath $MGR; MOCK_INSTALLED="tailscale"; MOCK_UPDATE_FAIL=""; MOCK_SIM_FAIL=""
    if [ $MGR = opkg ]; then INST="install"; REM="remove"; V="1.2.3-1"; else INST="add"; REM="del"; V="1.2.3-r0"; fi
    reset_log
    pkg_update; rc "$MGR update" $? 0; has "$MGR update call" "$MGR update"
    pkg_install kmod-tun ca-bundle; rc "$MGR install" $? 0; has "$MGR install call" "$MGR $INST kmod-tun ca-bundle"
    pkg_remove tailscale; rc "$MGR remove" $? 0; has "$MGR remove call" "$MGR $REM tailscale"
    reset_log; pkg_install 'a;b' 2>/dev/null; rc "$MGR bad name" $? 1; [ -s "$MOCK_LOG" ] && bad "$MGR bad name: не должно быть вызова" || ok
    pkg_installed tailscale; rc "$MGR installed" $? 0
    pkg_installed podkop; rc "$MGR not installed" $? 1
    pkg_installed 'x;y'; rc "$MGR installed bad name" $? 1
    pkg_available tailscale; rc "$MGR available" $? 0
    pkg_available nothere; rc "$MGR unavailable" $? 1
    eq "$MGR version" "$(pkg_version tailscale)" "$V"
    pkg_version podkop >/dev/null; rc "$MGR version none" $? 1
    MOCK_UPDATE_FAIL=1; pkg_update 2>/dev/null; rc "$MGR update fail" $? 1; MOCK_UPDATE_FAIL=""
    reset_log; pkg_upgrade_pkg tailscale; rc "$MGR upgrade" $? 0
    if [ $MGR = opkg ]; then has "opkg upgrade call" "opkg upgrade tailscale"; else has "apk upgrade call" "apk add -u tailscale"; fi
done
# hold / unhold
PKG_MGR=opkg; setpath opkg; reset_log
pkg_hold tailscale; rc "opkg hold" $? 0; has "opkg hold call" "opkg flag hold tailscale"
pkg_unhold tailscale; rc "opkg unhold" $? 0; has "opkg unhold call" "opkg flag unhold tailscale"
PKG_MGR=apk; setpath apk; MOCK_INSTALLED="tailscale"; reset_log
pkg_hold tailscale; rc "apk hold" $? 0
has "apk hold pin" "apk add tailscale=1.2.3-r0"; has "apk hold sim" "apk upgrade --simulate"
reset_log; MOCK_SIM_FAIL=1; pkg_hold tailscale 2>/dev/null; rc "apk hold sim fail" $? 1
eq "apk hold reverted" "$(tail -n 1 "$MOCK_LOG")" "apk add tailscale"
MOCK_SIM_FAIL=""; MOCK_INSTALLED=""; pkg_hold tailscale 2>/dev/null; rc "apk hold not installed" $? 1
MOCK_INSTALLED="tailscale"; reset_log
pkg_unhold tailscale; rc "apk unhold" $? 0; has "apk unhold call" "apk add tailscale"
PKG_MGR=""; reset_log
pkg_update 2>/dev/null; rc "no mgr update" $? 1
pkg_install x 2>/dev/null; rc "no mgr install" $? 1
pkg_installed tailscale; rc "no mgr installed" $? 1
[ -s "$MOCK_LOG" ] && bad "без менеджера не должно быть вызовов" || ok

# ================= проверка ключей =================
PKG_MGR=opkg
key_validate "$FIX/usign.pub"; rc "usign ok" $? 0
key_validate "$FIX/pem.pub"; rc "opkg rejects pem" $? 1; eq "opkg pem err" "$KEY_ERR" usign
key_validate "$FIX/idonly.pub"; rc "opkg id-only" $? 1; eq "id_only err" "$KEY_ERR" id_only
key_validate "$FIX/garbage.pub"; rc "opkg garbage" $? 1
key_validate "$FIX/usign_extra.pub"; rc "usign 3 lines" $? 1
PKG_MGR=apk
key_validate "$FIX/pem.pub"; rc "pem ok" $? 0
key_validate "$FIX/usign.pub"; rc "apk rejects usign" $? 1; eq "apk usign err" "$KEY_ERR" pem
key_validate "$FIX/idonly.pub"; rc "apk id-only" $? 1; eq "apk id_only err" "$KEY_ERR" id_only
printf -- '-----BEGIN PUBLIC KEY-----\n-----END PUBLIC KEY-----\n' >"$T/k"; key_validate "$T/k"; rc "pem empty body" $? 1
printf -- '-----BEGIN PUBLIC KEY-----\nAB CD;rm\n-----END PUBLIC KEY-----\n' >"$T/k"; key_validate "$T/k"; rc "pem bad chars" $? 1

# ================= feed_add / feed_remove =================
URL=https://example.org/feed; KURL_U=https://example.org/key/usign.pub; KURL_P=https://example.org/key/pem.pub
fresh() { rm -rf "$T/opkg" "$T/apk" "$FEEDS_LEDGER"; reset_log; rollback_init; MOCK_UPDATE_FAIL=""; NONINTERACTIVE=0; : >"$TTY_DEV"; }
fp() { set -- $(sha256sum "$1"); printf '%s' "$1"; }

# --- opkg
PKG_MGR=opkg; setpath opkg
fresh; mkdir -p "$T/opkg"; printf 'src/gz custom https://user/feed\n' >"$OPKG_FEEDS"
printf 'y\n' >"$TTY_DEV"; feed_add gnu "$URL" "$KURL_U" >"$T/out" 2>&1; rc "opkg add" $? 0
grep -Fxq 'src/gz tsi_gnu https://example.org/feed' "$OPKG_FEEDS" && ok || bad "opkg feed line"
grep -Fxq 'src/gz custom https://user/feed' "$OPKG_FEEDS" && ok || bad "opkg чужая строка сохранена"
[ -f "$OPKG_KEYDIR/0123456789abcdef" ] && ok || bad "opkg key placed by fingerprint"
eq "ledger" "$(cat "$FEEDS_LEDGER")" "gnu|$URL|0123456789abcdef"
has "opkg updated after" "opkg update"
grep -q "$(fp "$FIX/usign.pub")" "$T/out" && ok || bad "подтверждение показывает sha256 ключа"
grep -q "$URL" "$T/out" && grep -q "$KURL_U" "$T/out" && ok || bad "подтверждение показывает URL"
grep -Fxq "feed_remove 'gnu'" "$ROLLBACK_FILE" && ok || bad "запись отката feed_remove"
reset_log; feed_add gnu "$URL" "$KURL_U" >/dev/null 2>&1; rc "opkg add idempotent" $? 0
[ -s "$MOCK_LOG" ] && bad "повторное добавление не должно ходить в сеть/менеджер" || ok
feed_remove gnu >/dev/null 2>&1; rc "opkg remove" $? 0
grep -q tsi_gnu "$OPKG_FEEDS" && bad "opkg feed line removed" || ok
[ -f "$OPKG_KEYDIR/0123456789abcdef" ] && bad "opkg key removed" || ok
[ -s "$FEEDS_LEDGER" ] && bad "ledger cleaned" || ok
grep -Fxq 'src/gz custom https://user/feed' "$OPKG_FEEDS" && ok || bad "после remove чужая строка цела"
feed_remove gnu >/dev/null 2>&1; rc "remove idempotent" $? 0

fresh; printf 'n\n' >"$TTY_DEV"; feed_add gnu "$URL" "$KURL_U" >/dev/null 2>&1; rc "opkg declined" $? 2
[ -e "$OPKG_FEEDS" ] && bad "declined: файл фида не создан" || ok
hasnt "declined: нет update" "opkg update"
fresh; NONINTERACTIVE=1; feed_add gnu "$URL" "$KURL_U" >/dev/null 2>&1; rc "noninteractive" $? 2
[ -s "$MOCK_LOG" ] && bad "noninteractive: без обращений" || ok
fresh; : >"$T/empty"; TTY_DEV="$T/нет-tty"; feed_add gnu "$URL" "$KURL_U" >/dev/null 2>&1; rc "no tty" $? 2; TTY_DEV="$T/tty"
fresh; printf 'y\n' >"$TTY_DEV"; feed_add gnu "$URL" https://example.org/key/idonly.pub >/dev/null 2>"$T/err"; rc "id-only key" $? 1
[ -e "$OPKG_FEEDS" ] && bad "id-only: фид не добавлен" || ok
[ -d "$OPKG_KEYDIR" ] && bad "id-only: ключ не импортирован" || ok
fresh; printf 'y\n' >"$TTY_DEV"; feed_add gnu "$URL" https://example.org/key/garbage.pub >/dev/null 2>&1; rc "garbage key" $? 1
fresh; printf 'y\n' >"$TTY_DEV"; feed_add gnu "$URL" https://example.org/key/big.pub >/dev/null 2>&1; rc "oversize key" $? 1
fresh; printf 'y\n' >"$TTY_DEV"; feed_add gnu "$URL" https://example.org/key/missing.pub >/dev/null 2>&1; rc "fetch fail" $? 1
fresh; printf 'y\n' >"$TTY_DEV"; feed_add gnu "$URL" https://example.org/key/pem.pub >/dev/null 2>&1; rc "opkg rejects pem key" $? 1
fresh; printf 'y\n' >"$TTY_DEV"; feed_add gnu "$URL" https://example.org/key/usign_crlf.pub >/dev/null 2>&1; rc "crlf key accepted" $? 0
fresh; feed_add gnu http://example.org/feed "$KURL_U" >/dev/null 2>&1; rc "http url rejected" $? 1
fresh; feed_add Gnu "$URL" "$KURL_U" >/dev/null 2>&1; rc "bad name rejected" $? 1
fresh; feed_add gnu 'https://x.y/$(id)' "$KURL_U" >/dev/null 2>&1; rc "url injection rejected" $? 1
fresh; printf 'y\n' >"$TTY_DEV"; MOCK_UPDATE_FAIL=1
feed_add gnu "$URL" "$KURL_U" >/dev/null 2>&1; rc "update fail -> error" $? 1
grep -q tsi_gnu "$OPKG_FEEDS" 2>/dev/null && bad "update fail: фид откатан" || ok
[ -f "$OPKG_KEYDIR/0123456789abcdef" ] && bad "update fail: ключ откатан" || ok
[ -s "$FEEDS_LEDGER" ] && bad "update fail: ledger откатан" || ok
MOCK_UPDATE_FAIL=""
setpath opkg nousign; fresh; printf 'y\n' >"$TTY_DEV"
feed_add gnu "$URL" "$KURL_U" >/dev/null 2>&1; rc "no usign" $? 1
[ -e "$OPKG_FEEDS" ] && bad "no usign: фид не добавлен" || ok

# --- apk
PKG_MGR=apk; setpath apk
fresh; mkdir -p "$T/apk/repositories.d"; printf 'https://user/packages.adb\n' >"$APK_FEEDS"
printf 'y\n' >"$TTY_DEV"; feed_add gnu https://example.org/packages.adb "$KURL_P" >/dev/null 2>&1; rc "apk add" $? 0
eq "apk feed lines" "$(tail -n 2 "$APK_FEEDS" | tr '\n' ' ')" "# tsi:gnu https://example.org/packages.adb "
[ -f "$APK_KEYDIR/tsi-gnu.pub" ] && ok || bad "apk key placed"
cmp -s "$APK_KEYDIR/tsi-gnu.pub" "$FIX/pem.pub" && ok || bad "apk key content"
has "apk updated" "apk update"
grep -q -- '--allow-untrusted' "$MOCK_LOG" && bad "--allow-untrusted не используется" || ok
feed_remove gnu >/dev/null 2>&1; rc "apk remove" $? 0
eq "apk only foreign line remains" "$(cat "$APK_FEEDS")" "https://user/packages.adb"
[ -f "$APK_KEYDIR/tsi-gnu.pub" ] && bad "apk key removed" || ok
fresh; printf 'y\n' >"$TTY_DEV"; feed_add gnu https://example.org/packages.adb "$KURL_U" >/dev/null 2>&1; rc "apk rejects usign key" $? 1
fresh; printf 'y\n' >"$TTY_DEV"; feed_add gnu https://example.org/packages.adb https://example.org/key/idonly.pub >/dev/null 2>&1; rc "apk id-only" $? 1

# ---------- общий прогон: ни один вызов не использует --allow-untrusted ----------
grep -q -- '--allow-untrusted' "$MOCK_LOG" && bad "allow-untrusted в логе" || ok
# i18n: все новые ключи в обоих языках
CUR_LANG=ru; i18n_selfcheck 2>/dev/null; rc "i18n selfcheck" $? 0
keys_of() { sed -n "/^$1() {/,/^}/p" "$HERE/tsi.sh" | sed -n 's/^ *\([A-Z0-9_]*\)) *_S=.*/\1/p' | sort | tr '\n' ' '; }
eq "keys ru==en" "$(keys_of strings_ru)" "$(keys_of strings_en)"
eq "keys == I18N_KEYS" "$(keys_of strings_ru)" "$(for k in $I18N_KEYS; do echo $k; done | sort | tr '\n' ' ')"

rm -rf "$T"
printf 'passed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
