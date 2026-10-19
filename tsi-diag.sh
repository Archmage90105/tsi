#!/bin/sh
# Сбор диагностики для отчёта о тесте: запускать на роутере после прогона tsi.
# Ничего не меняет в системе. Вывод можно сохранить: sh tsi-diag.sh > /tmp/diag.txt
# Секретов не печатает (ключи авторизации в вывод не попадают), но проверьте
# вывод перед отправкой: в нём есть имена узлов и адреса вашей сети.
sec() { printf '\n===== %s =====\n' "$1"; }
sec "система"
cat /etc/openwrt_release 2>/dev/null
uname -a
command -v opkg >/dev/null 2>&1 && { echo "менеджер: opkg"; opkg print-architecture; }
command -v apk >/dev/null 2>&1 && { echo "менеджер: apk"; cat /etc/apk/arch 2>/dev/null; }
sec "tsi"
tsi --version 2>&1
tsi --status 2>&1
sec "конфиг скрипта"
cat /etc/tailscale-installer.conf 2>&1
cat /etc/tailscale-installer.feeds 2>&1
sec "пакеты"
if command -v opkg >/dev/null 2>&1; then
    opkg status tailscale 2>&1 | grep -E '^(Package|Version|Maintainer|Status):'
    opkg list-installed 2>/dev/null | grep -E '^(tailscale|luci-app-tailscale|kmod-tun|usign|ip-full|ip-tiny) '
    cat /etc/opkg/customfeeds.conf 2>&1; ls /etc/opkg/keys 2>&1
fi
if command -v apk >/dev/null 2>&1; then
    apk list -I tailscale 2>&1
    apk list -I 2>/dev/null | grep -E '^(luci-app-tailscale|kmod-tun|ip-full|ip-tiny)'
    grep -E 'tailscale|tsi' /etc/apk/world 2>&1
    cat /etc/apk/repositories.d/customfeeds.list 2>&1; ls /etc/apk/keys 2>&1
fi
sec "uci: firewall и сеть (секции tsi_*), незакоммиченные правки"
uci show firewall 2>&1 | grep -E 'tsi_|name=.tailscale'
uci show network 2>&1 | grep -E 'tsi_|tailscale0'
uci show tailscale 2>&1
echo "uci changes:"; uci changes firewall network tailscale 2>&1
sec "служба и сеть"
pidof tailscaled 2>&1; /etc/init.d/tailscale status 2>&1
ip link show tailscale0 2>&1
ip route get 100.64.0.1 2>&1
sec "sysupgrade.conf (наши строки)"
grep -E 'tsi|tailscale' /etc/sysupgrade.conf 2>&1
sec "лог tsi (последние 120 строк)"
tail -n 120 /tmp/tsi/tsi.log 2>&1
sec "logread (tailscale, последние 60 строк)"
logread 2>/dev/null | grep -i tailscale | tail -n 60
