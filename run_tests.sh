#!/bin/sh
# Запускает все наборы тестов во всех доступных оболочках: dash, bash --posix и
# busybox ash (если есть busybox; можно указать BUSYBOX=/путь/к/busybox).
# Код возврата 0 - всё прошло. Нужны: tar (GNU), sha256sum, sed, grep, tr, od.
cd "$(dirname "$0")" || exit 1
FAILED=0
BUSYBOX=${BUSYBOX:-$(command -v busybox 2>/dev/null)}
BBDIR=""
if [ -n "$BUSYBOX" ] && "$BUSYBOX" ash -c 'exit 0' 2>/dev/null; then
    BBDIR=$(mktemp -d)
    # апплеты busybox имеют приоритет над системными, как на роутере
    for a in sed date wc tr cat rm mv mkdir printf touch ls grep head tail sort od \
             sha256sum cut chmod cp uname seq tar gzip gunzip sleep dirname tee readlink; do
        if "$BUSYBOX" --list 2>/dev/null | grep -qx "$a"; then
            ln -sf "$BUSYBOX" "$BBDIR/$a"
        fi
    done
fi
run() { # метка, команда...
    _label=$1; shift
    _out=$("$@" 2>&1); _rc=$?
    printf '%-18s %-14s %s\n' "$t" "$_label" "$(printf '%s\n' "$_out" | tail -n 1)"
    if [ "$_rc" -ne 0 ]; then
        FAILED=1
        printf '%s\n' "$_out" | grep '^FAIL' | head -20
    fi
}
for t in test_layer*.sh; do
    command -v dash >/dev/null 2>&1 && run dash dash "$t"
    command -v bash >/dev/null 2>&1 && run "bash --posix" bash --posix "$t"
    if [ -n "$BBDIR" ]; then
        run busybox env PATH="$BBDIR:$PATH" TSI_TEST_SH="$BUSYBOX ash" "$BUSYBOX" ash "$t"
    fi
done
[ -n "$BBDIR" ] && rm -rf "$BBDIR"
if [ "$FAILED" -eq 0 ]; then echo "ВСЕ ТЕСТЫ ПРОШЛИ"; else echo "ЕСТЬ ОШИБКИ"; fi
exit "$FAILED"
