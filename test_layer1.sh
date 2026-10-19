#!/bin/sh
# Тесты слоя 1. Запуск: sh test_layer1.sh   (также: bash --posix, busybox ash)
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/tsi.sh"

T=$(mktemp -d /tmp/tsi-test.XXXXXX)
CONF="$T/tsi.conf"
RUNDIR="$T/run"
LOG_FILE="$RUNDIR/tsi.log"
ROLLBACK_FILE="$RUNDIR/rollback.list"
TTY_DEV="$T/tty"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$1"; }
eq()   { if [ "$2" = "$3" ]; then ok; else bad "$1: ожидалось [$3], получено [$2]"; fi; }
rc()   { if [ "$2" -eq "$3" ]; then ok; else bad "$1: rc=$2, ожидалось $3"; fi; }

tsi_init; rc "tsi_init" $? 0
[ -d "$RUNDIR" ] && ok || bad "rundir создан"

# --- i18n
CUR_LANG=ru; eq "msg ru" "$(msg_str RB_EMPTY)" "Откатывать нечего."
CUR_LANG=en; eq "msg en" "$(msg_str RB_EMPTY)" "Nothing to roll back."
eq "missing key" "$(msg_str NO_SUCH_KEY)" "[missing:NO_SUCH_KEY]"
eq "args" "$(msg_str CONF_BAD_KEY FOO)" "Config: key 'FOO' is not supported."
CUR_LANG=ru
i18n_selfcheck 2>/dev/null; rc "selfcheck ok" $? 0
# синхронность ключей в самих функциях (парсим файл)
keys_of() { sed -n "/^$1() {/,/^}/p" "$HERE/tsi.sh" | sed -n 's/^ *\([A-Z0-9_]*\)) *_S=.*/\1/p' | sort | tr '\n' ' '; }
eq "keys ru==en" "$(keys_of strings_ru)" "$(keys_of strings_en)"
eq "keys == I18N_KEYS" "$(keys_of strings_ru)" "$(for k in $I18N_KEYS; do echo $k; done | sort | tr '\n' ' ')"

# --- конфиг
conf_set LANG en; rc "set LANG" $? 0
eq "get LANG" "$(conf_get LANG)" "en"
conf_set LOGIN_SERVER https://rc.routerich.ru; rc "set server" $? 0
conf_set NETFILTER_MODE off; rc "set nf" $? 0
conf_set NETFILTER_MODE maybe 2>/dev/null; rc "bad value rejected" $? 1
eq "value unchanged" "$(conf_get NETFILTER_MODE)" "off"
conf_set FOO bar 2>/dev/null; rc "bad key rejected" $? 1
conf_set LOGIN_SERVER 'https://x.y$(touch /tmp/pwned)' 2>/dev/null; rc "inject rejected" $? 1
conf_set LOGIN_SERVER 'rc.routerich.ru' 2>/dev/null; rc "no scheme rejected" $? 1
conf_set LITE_SHA256_TS abc 2>/dev/null; rc "bad sha rejected" $? 1
H=$(printf 'a%.0s' $(seq 1 64)); conf_set LITE_SHA256_TS "$H"; rc "good sha" $? 0
# перезапись не плодит дубликатов, неизвестные строки сохраняются
printf '# my comment\nFOO=1\n' >>"$CONF"
conf_set LANG ru; conf_set LANG en
eq "no dup" "$(grep -c '^LANG=' "$CONF")" "1"
grep -q '^# my comment$' "$CONF" && grep -q '^FOO=1$' "$CONF" && ok || bad "чужие строки сохранены"
conf_unset LOGIN_SERVER; rc "unset" $? 0
eq "unset mem" "$(conf_get LOGIN_SERVER)" ""
grep -q LOGIN_SERVER "$CONF" && bad "unset file" || ok
# загрузка: мусор, инъекции, CRLF
cat >"$CONF" <<EOT
LANG=ru; touch $T/pwned1
NETFILTER_MODE=on
FOO=bar
garbage line
LOG_VERBOSE=1
INSTALL_SOURCE=B
EOT
printf 'B_SUBMODE=feed\r\n' >>"$CONF"
conf_load 2>/dev/null
eq "load valid" "$CFG_NETFILTER_MODE" "on"
eq "load bad LANG ignored" "$CFG_LANG" ""
eq "load verbose" "$CFG_LOG_VERBOSE" "1"
eq "load CRLF" "$CFG_B_SUBMODE" "feed"
[ -e "$T/pwned1" ] && bad "инъекция выполнилась" || ok
CFG_LANG=$(conf_get LANG); eq "env LANG untouched" "${LANG:-unset}" "${LANG:-unset}"
conf_reset; eq "reset verbose" "$CFG_LOG_VERBOSE" "0"
conf_show | grep -q . && ok || bad "show"

# --- откат (LIFO, кавычки, пробелы)
OUT="$T/out"; : >"$OUT"
rb_note() { printf '%s\n' "$1" >>"$OUT"; }
rollback_init
rollback_push rb_note "first"
rollback_push rb_note "it's second; \$(touch $T/pwned2)"
rollback_push rb_note "third  spaced"
rollback_push 'bad name;x' "a" 2>/dev/null; rc "bad entry name" $? 1
rollback_run >/dev/null 2>&1; rc "rollback_run" $? 0
eq "LIFO 1" "$(sed -n 1p "$OUT")" "third  spaced"
eq "LIFO 2" "$(sed -n 2p "$OUT")" "it's second; \$(touch $T/pwned2)"
eq "LIFO 3" "$(sed -n 3p "$OUT")" "first"
[ -e "$T/pwned2" ] && bad "инъекция в откате" || ok
[ -s "$ROLLBACK_FILE" ] && bad "стек очищен" || ok
rb_fail() { return 1; }
rollback_init; rollback_push rb_fail; rollback_push rb_note x
rollback_run >/dev/null 2>&1; rc "rollback fail propagated" $? 1

# --- ввод
printf 'д\n' >"$TTY_DEV";  ask_yn RB_EMPTY >/dev/null; rc "yn да" $? 0
printf 'n\n' >"$TTY_DEV";  ask_yn RB_EMPTY >/dev/null; rc "yn n" $? 1
printf '\n'  >"$TTY_DEV";  ask_yn RB_EMPTY >/dev/null; rc "yn enter=нет" $? 1
printf '7\n9\n2\n' >"$TTY_DEV"
# один read на вызов читает первую строку файла; для повторов используем fifo-подобный набор
exec_choice() { ask_choice RB_EMPTY "1 2 3" >/dev/null; }
printf '2\n' >"$TTY_DEV"; exec_choice; rc "choice ok" $? 0; eq "choice val" "$ASK_REPLY" "2"
printf 'yes\n' >"$TTY_DEV"; ask_typed_yes RB_EMPTY >/dev/null; rc "typed yes" $? 0
printf 'Yes\n' >"$TTY_DEV"; ask_typed_yes RB_EMPTY >/dev/null; rc "typed Yes отклонён" $? 1
printf 'y\n'   >"$TTY_DEV"; ask_typed_yes RB_EMPTY >/dev/null; rc "typed y отклонён" $? 1
NONINTERACTIVE=1; printf 'yes\n' >"$TTY_DEV"
ask_typed_yes RB_EMPTY >/dev/null; rc "noninteractive typed_yes=2" $? 2
ask_yn RB_EMPTY >/dev/null; rc "noninteractive yn=2" $? 2
NONINTERACTIVE=0
TTY_DEV="$T/нет-такого"; ask_yn RB_EMPTY >/dev/null 2>"$T/e"; rc "нет tty=2" $? 2
[ -s "$T/e" ] && bad "нет tty: лишний вывод ошибок shell" || ok
TTY_DEV="$T/tty"

# --- лог и run_ext
grep -Eq '^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8}\] \[INFO\] \[tsi_init\] ' "$LOG_FILE" && ok || bad "формат лога"
CFG_LOG_VERBOSE=0
run_ext sh -c 'echo out; echo errline >&2; exit 3' 2>"$T/se"; rc "run_ext rc" $? 3
[ -s "$T/se" ] && bad "run_ext не должен дублировать при verbose=0" || ok
grep -q '\[CMD\] \[run_ext\] errline' "$LOG_FILE" && ok || bad "run_ext лог"
CFG_LOG_VERBOSE=1
run_ext sh -c 'echo dup' 2>"$T/se"
grep -q dup "$T/se" && ok || bad "run_ext verbose дубль в stderr"
CFG_LOG_VERBOSE=0
# die: код возврата и вывод
( die test_fn ERR_ABORT ) 2>/dev/null; rc "die exit code" $? 1
# log_trim
LOG_MAX_BYTES=10; log_info t "xxxxxxxxxxxxxxxxxxxxxxxx"; log_trim
[ -s "$LOG_FILE" ] && bad "log_trim" || ok
# shq
eq "shq" "$(eval "printf '%s' $(shq "a'b c\"d")")" "a'b c\"d"

rm -rf "$T"
printf 'passed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
