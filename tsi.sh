#!/bin/sh
# tsi.sh - установщик Tailscale для OpenWrt 24.10 (opkg) и 25.12+ (apk)
#
# СЛОЙ 1: константы, ядро (лог, i18n, ввод, стек отката), конфиг.
# СЛОИ 2-3: определение системы, пакетный слой (opkg/apk), репозитории.
# СЛОЙ 4: установка (self, deps, источники, служба, sysupgrade).
# СЛОЙ 5: сеть и firewall через uci (секции tsi_*), маршрут CGNAT, fw_mode.
# СЛОЙ 6: решение по netfilter, login-server, tailscale up, инструкции.
# СЛОЙ 7: обновление, LuCI, удаление.
# СЛОЙ 8: CLI, меню, main (точка входа в конце файла).
#
# Правила кода (busybox ash):
#   - без set -e, ошибки проверяются явно (if ! cmd; then ...)
#   - без массивов, без [[ ]], без local (переменные с префиксом функции)
#   - printf вместо echo -e
#   - die/exit нельзя вызывать внутри $(...): выйдет только подоболочка

# ======================================================================
# 1. КОНСТАНТЫ И ГЛОБАЛЬНОЕ СОСТОЯНИЕ
# ======================================================================

TSI_VERSION="0.7.0"

CONF="/etc/tailscale-installer.conf"
SYSUPGRADE_CONF="/etc/sysupgrade.conf"

# Рабочий каталог (права 700): лог, стек отката, бэкапы.
RUNDIR="/tmp/tsi"
LOG_FILE="$RUNDIR/tsi.log"
ROLLBACK_FILE="$RUNDIR/rollback.list"
BACKUP_DIR="$RUNDIR/backup"
LOG_MAX_BYTES=262144

# Имена секций uci, создаваемых скриптом (только они удаляются при откате).
UCI_NET_IFACE="tsi_net"
UCI_FW_ZONE="tsi_zone"
UCI_FW_FWD_LAN_IN="tsi_fwd_lan_in"
UCI_FW_FWD_LAN_OUT="tsi_fwd_lan_out"
UCI_FW_FWD_WAN="tsi_fwd_wan"
UCI_NET_ROUTE="tsi_route"

# Белый список ключей конфига. В памяти значения лежат в CFG_<КЛЮЧ>
# (префикс нужен, чтобы не затереть системную переменную LANG).
CONF_KEYS="LANG INSTALL_SOURCE B_SUBMODE LOGIN_SERVER NETFILTER_MODE LITE_VERSION LOG_VERBOSE"

CUR_LANG="ru"           # язык интерфейса: ru | en
NONINTERACTIVE=0        # 1 - вопросы пользователю не задаются
TTY_DEV="/dev/tty"      # откуда читаем ввод (при wget | sh stdin занят скриптом)
ASK_REPLY=""            # результат ask_choice / ask_text
EXIT_FAIL=1             # код возврата при критической ошибке

CR=$(printf '\r')

# ======================================================================
# 2. ЯДРО
# ======================================================================

# ---- 2.1 Лог ---------------------------------------------------------
# Формат: [YYYY-MM-DD HH:MM:SS] [LEVEL] [func] message

_log_raw() { # LEVEL FUNC MESSAGE
    [ -n "$LOG_FILE" ] || return 0
    printf '[%s] [%s] [%s] %s\n' "$(date '+%F %T')" "$1" "$2" "$3" \
        >>"$LOG_FILE" 2>/dev/null
    return 0
}
log_dbg()  { _log_raw DEBUG "$1" "$2"; }
log_info() { _log_raw INFO  "$1" "$2"; }
log_warn() { _log_raw WARN  "$1" "$2"; }
log_err()  { _log_raw ERROR "$1" "$2"; }

log_trim() {
    [ -f "$LOG_FILE" ] || return 0
    _lt_size=$(wc -c <"$LOG_FILE" 2>/dev/null)
    [ -n "$_lt_size" ] || return 0
    if [ "$_lt_size" -gt "$LOG_MAX_BYTES" ]; then
        : >"$LOG_FILE"
    fi
    return 0
}

# Запуск внешней команды: вывод целиком уходит в лог (уровень CMD),
# при LOG_VERBOSE=1 дополнительно дублируется в stderr.
# Только для внешних команд (opkg/apk/uci/tailscale), не для наших сообщений.
run_ext() {
    log_dbg run_ext "$*"
    _re_tmp="$RUNDIR/run.$$"
    "$@" >"$_re_tmp" 2>&1
    _re_rc=$?
    if [ -s "$_re_tmp" ]; then
        while IFS= read -r _re_line; do
            _log_raw CMD run_ext "$_re_line"
        done <"$_re_tmp"
        if [ "$CFG_LOG_VERBOSE" = 1 ]; then
            cat "$_re_tmp" >&2
        fi
    fi
    rm -f "$_re_tmp"
    log_dbg run_ext "rc=$_re_rc"
    return "$_re_rc"
}

# ---- 2.2 i18n --------------------------------------------------------
# Строки лежат в двух функциях; ключ -> формат printf в переменной _S.
# Источник истины по набору ключей - I18N_KEYS (проверяет i18n_selfcheck).

I18N_KEYS="PFX_WARN PFX_ERR ERR_ABORT PROMPT_YN PROMPT_CHOICE PROMPT_TYPE_YES ERR_BAD_CHOICE ERR_NO_INPUT RB_START RB_EMPTY RB_STEP_FAIL RB_DONE RB_BAD_ENTRY CONF_BAD_KEY CONF_BAD_VALUE CONF_BAD_LINE CONF_WRITE_FAIL CONF_EMPTY I18N_MISSING INIT_RUNDIR_FAIL DETECT_NO_RELEASE DETECT_NO_PKGMGR DETECT_MGR_MISMATCH DETECT_UNSUPPORTED ARCH_UNKNOWN TUN_OK TUN_DEVICE_ONLY TUN_FAIL PKG_NO_MGR PKG_BAD_NAME PKG_UPDATE_FAIL PKG_INSTALL_FAIL PKG_REMOVE_FAIL PKG_HOLD_FAIL PKG_UNHOLD_FAIL FEED_NAME_BAD FEED_URL_BAD FEED_REMOVE_NO_UPDATE FEED_NONINTERACTIVE FEED_EXISTS FEED_FETCH_FAIL FEED_KEY_ID_ONLY FEED_KEY_INVALID FEED_KEYTOOL_MISSING FEED_CONFIRM FEED_DECLINED FEED_ADDED FEED_REMOVED FEED_WRITE_FAIL FEED_UPDATE_FAIL INSTALL_DEPS_TITLE INSTALL_DEPS_OK INSTALL_DEPS_FAIL FEED_ARCH_UNAVAILABLE FEED_ARCH_FALLBACK CHOOSE_SOURCE_TITLE CHOOSE_SOURCE_OFFICIAL CHOOSE_SOURCE_LITE_FEED CHOOSE_SOURCE_LITE_DIRECT CHOOSE_SOURCE_PROMPT INSTALL_OFFICIAL_TITLE INSTALL_OFFICIAL_OK INSTALL_OFFICIAL_FAIL INSTALL_LITE_FEED_TITLE INSTALL_LITE_FEED_OK INSTALL_LITE_FEED_FAIL INSTALL_LITE_ORIGIN_WARN INSTALL_LITE_DIRECT_TITLE INSTALL_LITE_DIRECT_CONFIRM INSTALL_LITE_DIRECT_DECLINED INSTALL_LITE_DIRECT_WRONG_MGR INSTALL_LITE_DIRECT_WRONG_VER INSTALL_LITE_DIRECT_FETCH_FAIL INSTALL_LITE_DIRECT_NO_SHA INSTALL_LITE_DIRECT_SHA_MISMATCH INSTALL_LITE_DIRECT_ARCH_MISMATCH INSTALL_LITE_DIRECT_ARCH_UNKNOWN INSTALL_LITE_DIRECT_INSTALL_FAIL INSTALL_LITE_DIRECT_OK SERVICE_NO_INIT SERVICE_ENABLE_FAIL SERVICE_START_FAIL SERVICE_START_OK SERVICE_NOT_RUNNING SYSUPGRADE_FAIL SYSUPGRADE_UPDATED FW_NO_UCI FW_PENDING FW_FOREIGN FW_PARTIAL FW_ALREADY FW_SETUP_OK FW_SETUP_FAIL FW_BACKUP_FAIL FW_RELOAD_FAIL FW_REMOVED FW_NOT_SETUP FW_WAN_ALREADY FW_WAN_ALREADY_OFF FW_WAN_ON_OK FW_WAN_OFF_OK FW_WAN_ASK_ON FW_WAN_ASK_OFF ROUTE_NO_IP ROUTE_STILL_MISSING ROUTE_NO_IFACE ROUTE_ADDED FW_MODE_SET FW_MODE_FAIL NF_CONFLICT_INFO NF_CURRENT NF_CHOICE_OFF NF_CHOICE_ON NF_CHOICE_KEEP NF_PROMPT NF_SET_OFF NF_SET_ON NF_NEEDS_CHOICE LS_CHOICE_STD LS_CHOICE_CUSTOM LS_PROMPT LS_INPUT LS_BAD LS_SET LS_RESET LS_ASK_CHANGE LS_STANDARD LS_CHANGE_FAILED UP_NO_BIN UP_ASK_EXIT UP_ASK_ROUTES UP_ASK_ROUTES_INPUT UP_ROUTES_BAD UP_CMD_CONFIRM UP_RUNNING UP_OK UP_FAIL UP_SKIPPED UP_NONINTERACTIVE POST_TITLE POST_DONE POST_UP_NOT_DONE POST_AUTH_URL POST_EXIT POST_ROUTES POST_APPROVE POST_ALL_FLAGS POST_NF_OFF POST_DNS_WARN POST_AGAIN UPD_START UPD_NOT_INSTALLED UPD_NO_SOURCE UPD_NONE UPD_CURRENT UPD_OK UPD_FAIL UPD_DIRECT_MENU_ONLY SERVICE_RESTART_OK SERVICE_RESTART_FAIL LUCI_ASK LUCI_NO_BASE LUCI_ALREADY LUCI_UNAVAILABLE LUCI_FEED_DECLINED LUCI_INSTALLING LUCI_OK LUCI_FAIL UN_CONFIRM UN_CANCELLED UN_ASK_CONF UN_PKG_KEPT UN_REPORT_TITLE UN_REPORT_REMOVED UN_REPORT_KEPT UN_NOTE_DEPS UN_DONE FEED_PIN_BAD FEED_PIN_MISMATCH FEED_PIN_FATAL LANG_FIRST_TITLE USAGE_ERR USAGE_TEXT MENU_TITLE MENU_INSTALL MENU_UPDATE MENU_UNINSTALL MENU_STATUS MENU_SETTINGS MENU_EXIT MENU_PROMPT SET_TITLE SET_LANG SET_SERVER SET_NETFILTER SET_WAN SET_FWMODE SET_VERBOSE SET_CONFIG SET_LUCI SET_UP SET_BACK SET_LANG_SET SET_NF_EXPLAIN SET_NF_BACK SET_RERUN_UP SET_VERBOSE_ON SET_VERBOSE_OFF SET_RESTART_ASK INSTALL_TUN_ABORT INSTALL_TUN_ASK INSTALL_DONE INSTALL_DONE_WARN ST_TITLE ST_NOT_INSTALLED ST_VERSION ST_SOURCE ST_SERVICE_RUNNING ST_SERVICE_STOPPED ST_FW_OK ST_FW_NO ST_NF ST_SERVER ST_TS_STATUS"

strings_ru() {
    case "$1" in
        PFX_WARN)         _S="Внимание: " ;;
        PFX_ERR)          _S="Ошибка: " ;;
        ERR_ABORT)        _S="Работа прервана." ;;
        PROMPT_YN)        _S="[д/Н]" ;;
        PROMPT_CHOICE)    _S="Ваш выбор [%s]: " ;;
        PROMPT_TYPE_YES)  _S="Для подтверждения введите слово yes (всё остальное - отмена): " ;;
        ERR_BAD_CHOICE)   _S="Неверный ввод, попробуйте ещё раз." ;;
        ERR_NO_INPUT)     _S="Интерактивный ввод недоступен." ;;
        RB_START)         _S="Откат выполненных изменений..." ;;
        RB_EMPTY)         _S="Откатывать нечего." ;;
        RB_STEP_FAIL)     _S="Не удалось выполнить шаг отката: %s" ;;
        RB_DONE)          _S="Откат завершён." ;;
        RB_BAD_ENTRY)     _S="Недопустимая запись отката: %s" ;;
        CONF_BAD_KEY)     _S="Конфиг: ключ '%s' не поддерживается." ;;
        CONF_BAD_VALUE)   _S="Конфиг: недопустимое значение для %s." ;;
        CONF_BAD_LINE)    _S="Конфиг: строка %s пропущена (неверный формат)." ;;
        CONF_WRITE_FAIL)  _S="Не удалось записать конфиг %s." ;;
        CONF_EMPTY)       _S="Конфиг пуст." ;;
        I18N_MISSING)     _S="Нет перевода (%s) для ключа %s." ;;
        INIT_RUNDIR_FAIL) _S="Не удалось создать рабочий каталог %s." ;;
        DETECT_NO_RELEASE)    _S="Не найден файл %s - это точно OpenWrt?" ;;
        DETECT_NO_PKGMGR)     _S="Не найден ни opkg, ни apk." ;;
        DETECT_MGR_MISMATCH)  _S="Для OpenWrt %s обычно используется другой пакетный менеджер, чем найденный (%s)." ;;
        DETECT_UNSUPPORTED)   _S="Версия OpenWrt %s не входит в поддерживаемые (24.10 и 25.12+), продолжаем на свой риск." ;;
        ARCH_UNKNOWN)         _S="Не удалось определить архитектуру (DISTRIB_ARCH=%s, uname -m=%s)." ;;
        TUN_OK)               _S="TUN доступен (создание интерфейса проверено)." ;;
        TUN_DEVICE_ONLY)      _S="Создать TUN-интерфейс через ip не удалось, но устройство %s есть: проверка неполная." ;;
        TUN_FAIL)             _S="TUN недоступен. Установите kmod-tun или используйте --tun=userspace-networking." ;;
        PKG_NO_MGR)           _S="Пакетный менеджер не определён." ;;
        PKG_BAD_NAME)         _S="Недопустимое имя пакета: %s" ;;
        PKG_UPDATE_FAIL)      _S="Не удалось обновить списки пакетов." ;;
        PKG_INSTALL_FAIL)     _S="Не удалось установить или обновить: %s" ;;
        PKG_REMOVE_FAIL)      _S="Не удалось удалить: %s" ;;
        PKG_HOLD_FAIL)        _S="Не удалось зафиксировать версию пакета %s." ;;
        PKG_UNHOLD_FAIL)      _S="Не удалось снять фиксацию версии пакета %s." ;;
        FEED_NAME_BAD)        _S="Недопустимое имя репозитория (разрешены a-z, 0-9 и _)." ;;
        FEED_URL_BAD)         _S="Недопустимый адрес: %s (нужен https:// и только символы A-Z a-z 0-9 . _ : / ~ + -)." ;;
        FEED_REMOVE_NO_UPDATE) _S="Репозиторий %s удалён, но обновить списки пакетов не удалось." ;;
        FEED_NONINTERACTIVE)  _S="Добавление репозитория требует подтверждения и пропущено (неинтерактивный режим)." ;;
        FEED_EXISTS)          _S="Репозиторий %s уже добавлен." ;;
        FEED_FETCH_FAIL)      _S="Не удалось скачать: %s" ;;
        FEED_KEY_ID_ONLY)     _S="Файл ключа содержит только идентификатор, а не публичный ключ. Репозиторий не добавлен. Импортируйте ключ вручную или укажите корректный источник." ;;
        FEED_KEY_INVALID)     _S="Файл ключа имеет неверный формат (%s). Репозиторий не добавлен." ;;
        FEED_KEYTOOL_MISSING) _S="Не найден usign: невозможно импортировать ключ для opkg." ;;
        FEED_CONFIRM)         _S="Будет добавлен сторонний репозиторий пакетов:\n  имя:      %s\n  адрес:    %s\n  ключ:     %s\n  sha256 ключа: %s\nДобавить?" ;;
        FEED_DECLINED)        _S="Репозиторий не добавлен." ;;
        FEED_ADDED)           _S="Репозиторий %s добавлен, ключ импортирован." ;;
        FEED_REMOVED)         _S="Репозиторий %s удалён." ;;
        FEED_WRITE_FAIL)      _S="Не удалось записать %s." ;;
        FEED_UPDATE_FAIL)     _S="Не удалось обновить индекс нового репозитория (проверьте адрес и подпись), репозиторий удалён." ;;
        INSTALL_DEPS_TITLE)                _S="Установка зависимостей: %s" ;;
        INSTALL_DEPS_OK)                   _S="Зависимости установлены." ;;
        INSTALL_DEPS_FAIL)                 _S="Не удалось установить зависимости: %s" ;;
        FEED_ARCH_UNAVAILABLE)             _S="Архитектура устройства не поддерживается фидом (или фид недоступен). Выберите другой источник." ;;
        FEED_ARCH_FALLBACK)                _S="Не удалось определить архитектуру пакетным менеджером, используем DISTRIB_ARCH=%s." ;;
        CHOOSE_SOURCE_TITLE)               _S="Выберите источник установки Tailscale:" ;;
        CHOOSE_SOURCE_OFFICIAL)            _S="  1) Официальный пакет OpenWrt (стабильно, версия может быть старой)" ;;
        CHOOSE_SOURCE_LITE_FEED)           _S="  2) Lite-версия (GuNanOvO) через подписанный фид (рекомендуется)" ;;
        CHOOSE_SOURCE_LITE_DIRECT)         _S="  3) Lite-версия (GuNanOvO), прямое скачивание .ipk (небезопасно)" ;;
        CHOOSE_SOURCE_PROMPT)              _S="Источник " ;;
        INSTALL_OFFICIAL_TITLE)            _S="Установка официального пакета..." ;;
        INSTALL_OFFICIAL_OK)               _S="Официальный пакет установлен." ;;
        INSTALL_OFFICIAL_FAIL)             _S="Не удалось установить официальный пакет (%s)." ;;
        INSTALL_LITE_FEED_TITLE)           _S="Установка Lite-версии через фид..." ;;
        INSTALL_LITE_FEED_OK)              _S="Lite-версия установлена через фид." ;;
        INSTALL_LITE_FEED_FAIL)            _S="Не удалось установить Lite-версию через фид." ;;
        INSTALL_LITE_ORIGIN_WARN)          _S="Установленный пакет tailscale, похоже, не из фида Lite (в официальном фиде версия выше). Проверьте opkg info tailscale." ;;
        INSTALL_LITE_DIRECT_TITLE)         _S="Установка Lite-версии прямым скачиванием .ipk." ;;
        INSTALL_LITE_DIRECT_CONFIRM)       _S="ВНИМАНИЕ: этот путь небезопасен. Файл .ipk не проверяется подписью фида (только хэш от битой загрузки). Менеджер установит его без проверки подписи." ;;
        INSTALL_LITE_DIRECT_DECLINED)      _S="Установка отменена." ;;
        INSTALL_LITE_DIRECT_WRONG_MGR)     _S="Прямое скачивание поддерживается только для opkg (24.10)." ;;
        INSTALL_LITE_DIRECT_WRONG_VER)     _S="На OpenWrt 25.12+ используйте подписанный фид (вариант 2)." ;;
        INSTALL_LITE_DIRECT_FETCH_FAIL)    _S="Не удалось скачать: %s" ;;
        INSTALL_LITE_DIRECT_NO_SHA)        _S="Файл ipk.sha256 недоступен, проверка хэша не выполнена." ;;
        INSTALL_LITE_DIRECT_SHA_MISMATCH)  _S="SHA256 пакета не совпадает с ipk.sha256. Установка прервана." ;;
        INSTALL_LITE_DIRECT_ARCH_MISMATCH) _S="Архитектура пакета (%s) не совпадает с архитектурой устройства (%s)." ;;
        INSTALL_LITE_DIRECT_ARCH_UNKNOWN)  _S="Не удалось определить архитектуру пакета, проверка ELF пропущена." ;;
        INSTALL_LITE_DIRECT_INSTALL_FAIL)  _S="opkg install не удался." ;;
        INSTALL_LITE_DIRECT_OK)            _S="Lite-версия установлена прямым скачиванием." ;;
        SERVICE_NO_INIT)                   _S="Не найден /etc/init.d/tailscale." ;;
        SERVICE_ENABLE_FAIL)               _S="Не удалось включить автозапуск." ;;
        SERVICE_START_FAIL)                _S="Не удалось запустить службу." ;;
        SERVICE_START_OK)                  _S="Служба tailscale запущена, автозапуск включён." ;;
        SERVICE_NOT_RUNNING)               _S="Служба запущена, но tailscaled не обнаружен. Проверьте logread." ;;
        SYSUPGRADE_FAIL)                   _S="Не удалось записать %s." ;;
        SYSUPGRADE_UPDATED)                _S="Список сохраняемых при sysupgrade файлов обновлён." ;;
        FW_NO_UCI)                         _S="Не найден uci: настройка firewall невозможна." ;;
        FW_PENDING)                        _S="В конфигурации network/firewall есть незакоммиченные изменения (uci changes). Закоммитьте или отмените их и повторите." ;;
        FW_FOREIGN)                        _S="Найдены чужие настройки Tailscale. Зоны firewall: %s; интерфейсы network: %s. Свои секции не создаём, разберитесь вручную (uci show firewall, uci show network)." ;;
        FW_PARTIAL)                        _S="Найдены остатки прежней настройки (секции tsi_*), создаём заново." ;;
        FW_ALREADY)                        _S="Firewall и сеть для Tailscale уже настроены." ;;
        FW_SETUP_OK)                       _S="Firewall и сеть настроены: зона tailscale, forwarding tailscale <-> lan." ;;
        FW_SETUP_FAIL)                     _S="Не удалось настроить firewall/сеть, внесённые изменения откатаны." ;;
        FW_BACKUP_FAIL)                    _S="Не удалось сохранить резервную копию конфигов в %s." ;;
        FW_RELOAD_FAIL)                    _S="Не удалось перечитать конфигурацию сети/firewall." ;;
        FW_REMOVED)                        _S="Секции Tailscale удалены из network и firewall." ;;
        FW_NOT_SETUP)                      _S="Сначала настройте firewall (зона tailscale отсутствует)." ;;
        FW_WAN_ALREADY)                    _S="Forwarding tailscale -> wan уже включён." ;;
        FW_WAN_ALREADY_OFF)                _S="Forwarding tailscale -> wan уже выключен." ;;
        FW_WAN_ON_OK)                      _S="Forwarding tailscale -> wan включён (нужен для exit node)." ;;
        FW_WAN_OFF_OK)                     _S="Forwarding tailscale -> wan выключен." ;;
        FW_WAN_ASK_ON)                     _S="Включить forwarding tailscale -> wan? Он нужен для exit node: трафик пиров сможет выходить в интернет через этот роутер." ;;
        FW_WAN_ASK_OFF)                    _S="Forwarding tailscale -> wan включён. Выключить?" ;;
        ROUTE_NO_IP)                       _S="Команда ip недоступна, проверка маршрута 100.64.0.0/10 пропущена." ;;
        ROUTE_STILL_MISSING)               _S="Маршрут 100.64.0.0/10 уже добавлен, но трафик к адресам Tailscale идёт не через tailscale0. Проверьте: ip route get 100.64.0.1" ;;
        ROUTE_NO_IFACE)                    _S="Маршрут 100.64.0.0/10 не добавлен: нет интерфейса tsi_net (сначала настройте firewall)." ;;
        ROUTE_ADDED)                       _S="Маршрут %s добавлен через uci (секция tsi_route)." ;;
        FW_MODE_SET)                       _S="Режим firewall для tailscaled: %s." ;;
        FW_MODE_FAIL)                      _S="Не удалось записать fw_mode в /etc/config/tailscale." ;;
        NF_CONFLICT_INFO)                  _S="Найдены пакеты, способные конфликтовать с управлением netfilter в Tailscale: %s.\nTailscale 1.98+ меняет net.ipv4.conf.all.src_valid_mark и правила netfilter, из-за чего схемы TPROXY (podkop, forkop, nikki) могут перестать пропускать трафик клиентов LAN." ;;
        NF_CURRENT)                        _S="Текущее значение режима netfilter: %s" ;;
        NF_CHOICE_OFF)                     _S="  1) Отключить управление netfilter в Tailscale (--netfilter-mode=off), рекомендуется" ;;
        NF_CHOICE_ON)                      _S="  2) Оставить управление у Tailscale (на свой риск)" ;;
        NF_CHOICE_KEEP)                    _S="  3) Оставить текущее значение (%s)" ;;
        NF_PROMPT)                         _S="Режим netfilter " ;;
        NF_SET_OFF)                        _S="Выбрано: --netfilter-mode=off. Правила firewall настраивает этот скрипт через uci." ;;
        NF_SET_ON)                         _S="Выбрано: управление netfilter остаётся у Tailscale." ;;
        NF_NEEDS_CHOICE)                   _S="Найдены конфликтующие пакеты (%s), а режим netfilter не выбран. В неинтерактивном режиме укажите его явно (--netfilter-off)." ;;
        LS_CHOICE_STD)                     _S="  1) Стандартный сервер Tailscale" ;;
        LS_CHOICE_CUSTOM)                  _S="  2) Свой сервер (например, headscale)" ;;
        LS_PROMPT)                         _S="Сервер " ;;
        LS_INPUT)                          _S="Адрес сервера без https:// (например, rc.routerich.ru): " ;;
        LS_BAD)                            _S="Недопустимый адрес сервера: %s" ;;
        LS_SET)                            _S="Сервер установлен: %s" ;;
        LS_RESET)                          _S="Будет использоваться стандартный сервер Tailscale." ;;
        LS_ASK_CHANGE)                     _S="Сервер Tailscale: %s. Изменить?" ;;
        LS_STANDARD)                       _S="стандартный" ;;
        LS_CHANGE_FAILED)                  _S="Не удалось изменить сервер, остаётся прежний." ;;
        UP_NO_BIN)                         _S="Команда tailscale не найдена." ;;
        UP_ASK_EXIT)                       _S="Использовать этот роутер как exit node (--advertise-exit-node)?" ;;
        UP_ASK_ROUTES)                     _S="Анонсировать подсети (--advertise-routes), например LAN этого роутера?" ;;
        UP_ASK_ROUTES_INPUT)               _S="Подсети через запятую (например, 192.168.1.0/24): " ;;
        UP_ROUTES_BAD)                     _S="Недопустимая подсеть '%s' (%s). Ожидается A.B.C.D/N без битов хоста, например 192.168.1.0/24." ;;
        UP_CMD_CONFIRM)                    _S="Будет выполнена команда:\n  %s\nВыполнить?" ;;
        UP_RUNNING)                        _S="Запускаем tailscale up. Если потребуется авторизация, откройте показанную ссылку в браузере." ;;
        UP_OK)                             _S="tailscale up выполнен." ;;
        UP_FAIL)                           _S="tailscale up завершился с ошибкой (код %s). Установка сохранена, команду можно повторить вручную или через меню." ;;
        UP_SKIPPED)                        _S="tailscale up пропущен." ;;
        UP_NONINTERACTIVE)                 _S="Неинтерактивный режим: tailscale up не запускается (нужна авторизация)." ;;
        POST_TITLE)                        _S="=== Что дальше ===" ;;
        POST_DONE)                         _S="Tailscale установлен, служба запущена, firewall настроен." ;;
        POST_UP_NOT_DONE)                  _S="Подключите роутер к сети командой:\n  %s" ;;
        POST_AUTH_URL)                     _S="Если авторизация не завершена, откройте: %s" ;;
        POST_EXIT)                         _S="Exit node: добавьте --advertise-exit-node и включите forwarding tailscale -> wan (пункт меню)." ;;
        POST_ROUTES)                       _S="Subnet routing: добавьте --advertise-routes=192.168.1.0/24 (подставьте вашу подсеть)." ;;
        POST_APPROVE)                      _S="Exit node и маршруты нужно одобрить в админ-панели Tailscale (или своего сервера), пока этого не сделано, они не работают." ;;
        POST_ALL_FLAGS)                    _S="При повторном tailscale up указывайте все нестандартные флаги сразу, иначе команда откажется выполняться; tsi соберёт их сам." ;;
        POST_NF_OFF)                       _S="Режим --netfilter-mode=off: Tailscale не управляет правилами netfilter, их настраивает этот скрипт (uci, зона tailscale). Это нужно, чтобы не ломать podkop/forkop." ;;
        POST_DNS_WARN)                     _S="Обнаружены %s, а режим --netfilter-mode=off не выбран: Tailscale может нарушить работу LAN-клиентов. Выберите режим off в меню настроек и повторите tailscale up." ;;
        POST_AGAIN)                        _S="Изменить настройки позже: запустите tsi." ;;
        UPD_START)                         _S="Проверяем обновления Tailscale..." ;;
        UPD_NOT_INSTALLED)                 _S="Tailscale не установлен." ;;
        UPD_NO_SOURCE)                     _S="Источник установки неизвестен (INSTALL_SOURCE не задан в конфиге). Запустите установку." ;;
        UPD_NONE)                          _S="Обновлений нет: установлена версия %s." ;;
        UPD_CURRENT)                       _S="Установлена версия %s, доступна %s." ;;
        UPD_OK)                            _S="Tailscale обновлён: %s -> %s." ;;
        UPD_FAIL)                          _S="Не удалось обновить Tailscale." ;;
        UPD_DIRECT_MENU_ONLY)              _S="Обновление этой установки (прямое скачивание) доступно только через меню: нужно подтверждение." ;;
        SERVICE_RESTART_OK)                _S="Служба tailscale перезапущена." ;;
        SERVICE_RESTART_FAIL)              _S="Не удалось перезапустить службу tailscale." ;;
        LUCI_ASK)                          _S="Установить веб-интерфейс LuCI для Tailscale (luci-app-tailscale-community)?" ;;
        LUCI_NO_BASE)                      _S="LuCI на этом роутере не установлен (нет luci-base), веб-интерфейс Tailscale пропущен." ;;
        LUCI_ALREADY)                      _S="Веб-интерфейс LuCI для Tailscale уже установлен." ;;
        LUCI_UNAVAILABLE)                  _S="luci-app-tailscale-community недоступен для вашей системы. Установите его вручную: github.com/Tokisaki-Galaxy/luci-app-tailscale-community" ;;
        LUCI_FEED_DECLINED)                _S="Фид LuCI-приложения не добавлен, веб-интерфейс не установлен." ;;
        LUCI_INSTALLING)                   _S="Установка luci-app-tailscale-community..." ;;
        LUCI_OK)                           _S="Веб-интерфейс LuCI для Tailscale установлен." ;;
        LUCI_FAIL)                         _S="Не удалось установить luci-app-tailscale-community." ;;
        UN_CONFIRM)                        _S="ВНИМАНИЕ: Tailscale будет удалён вместе с состоянием авторизации (/etc/tailscale): роутер пропадёт из вашей сети, потребуется повторный вход. Будут удалены служба, правила firewall, пакеты и фиды, добавленные этим скриптом." ;;
        UN_CANCELLED)                      _S="Удаление отменено." ;;
        UN_ASK_CONF)                       _S="Удалить также конфигурацию скрипта (%s и учёт фидов)?" ;;
        UN_PKG_KEPT)                       _S="Пакет tailscale удалить не удалось, его файлы и состояние оставлены." ;;
        UN_REPORT_TITLE)                   _S="=== Итог удаления ===" ;;
        UN_REPORT_REMOVED)                 _S="Удалено: %s" ;;
        UN_REPORT_KEPT)                    _S="Оставлено: %s" ;;
        UN_NOTE_DEPS)                      _S="Зависимости (kmod-tun, ca-bundle и др.) не удалялись: ими могут пользоваться другие пакеты." ;;
        UN_DONE)                           _S="Удаление завершено." ;;
        FEED_PIN_BAD)                      _S="Внутренняя ошибка: неверный зафиксированный хэш ключа репозитория." ;;
        FEED_PIN_MISMATCH)                 _S="Ключ репозитория отличается от зафиксированного в скрипте (sha256 %s). Возможна смена ключа автором репозитория; проверьте хэш перед подтверждением." ;;
        FEED_PIN_FATAL)                    _S="Ключ репозитория не совпал с зафиксированным в скрипте (sha256 %s): возможна смена ключа автором или подмена. В неинтерактивном режиме репозиторий не добавлен." ;;
        LANG_FIRST_TITLE)                  _S="Выберите язык / Select language:\n  1) Русский\n  2) English" ;;
        USAGE_ERR)                         _S="Неверный параметр: %s" ;;
        USAGE_TEXT)                        _S="Использование: tsi [параметр]\n\n  (без параметров)        меню\n  --status                статус\n  --update                обновить Tailscale (без вопросов)\n  --install-official      установить официальный пакет (без вопросов)\n  --install-lite          установить Lite через подписанный фид (без вопросов)\n  --netfilter-off         с --install-*: отключить управление netfilter в Tailscale\n  --login-server=АДРЕС    с --install-*: свой сервер (например, rc.example.com)\n  -h, --help              эта справка\n  -V, --version           версия\n\nУдаление и прямое скачивание доступны только через меню.\n--install-lite проверяет ключ фида по хэшу, зафиксированному в скрипте: если автор сменит ключ, обновите tsi.\nКоды возврата: 0 успех, 1 ошибка, 2 не выполнено (отказ, нужно подтверждение, неверные параметры)." ;;
        MENU_TITLE)                        _S="=== Установщик Tailscale для OpenWrt (tsi) ===" ;;
        MENU_INSTALL)                      _S="  1) Установить Tailscale" ;;
        MENU_UPDATE)                       _S="  2) Обновить Tailscale" ;;
        MENU_UNINSTALL)                    _S="  3) Удалить Tailscale" ;;
        MENU_STATUS)                       _S="  4) Статус" ;;
        MENU_SETTINGS)                     _S="  5) Настройки" ;;
        MENU_EXIT)                         _S="  0) Выход" ;;
        MENU_PROMPT)                       _S="" ;;
        SET_TITLE)                         _S="=== Настройки ===" ;;
        SET_LANG)                          _S="  1) Язык интерфейса" ;;
        SET_SERVER)                        _S="  2) Сервер Tailscale (сменить или сбросить)" ;;
        SET_NETFILTER)                     _S="  3) Режим netfilter" ;;
        SET_WAN)                           _S="  4) Forwarding tailscale -> wan (для exit node)" ;;
        SET_FWMODE)                        _S="  5) Режим firewall для tailscaled (nftables/iptables)" ;;
        SET_VERBOSE)                       _S="  6) Подробный лог (вкл/выкл)" ;;
        SET_CONFIG)                        _S="  7) Показать конфигурацию" ;;
        SET_LUCI)                          _S="  8) Установить веб-интерфейс LuCI" ;;
        SET_UP)                            _S="  9) Exit node, подсети и tailscale up" ;;
        SET_BACK)                          _S="  0) Назад" ;;
        SET_LANG_SET)                      _S="Язык интерфейса: %s" ;;
        SET_NF_EXPLAIN)                    _S="Режим off: Tailscale не меняет правила netfilter и sysctl (нужно рядом с podkop/forkop), правила firewall настраивает этот скрипт. Режим on: управление у Tailscale." ;;
        SET_NF_BACK)                       _S="  3) Назад" ;;
        SET_RERUN_UP)                      _S="Изменение вступит в силу при следующем tailscale up (пункт настроек «Exit node, подсети и tailscale up»)." ;;
        SET_VERBOSE_ON)                    _S="Подробный лог включён." ;;
        SET_VERBOSE_OFF)                   _S="Подробный лог выключен." ;;
        SET_RESTART_ASK)                   _S="Перезапустить службу tailscale сейчас?" ;;
        INSTALL_TUN_ABORT)                 _S="Без TUN Tailscale не заработает. Установите kmod-tun и повторите. Установка прервана." ;;
        INSTALL_TUN_ASK)                   _S="TUN недоступен, Tailscale может не запуститься. Продолжить установку?" ;;
        INSTALL_DONE)                      _S="Установка завершена." ;;
        INSTALL_DONE_WARN)                 _S="Установка завершена с предупреждениями, см. сообщения выше и лог %s." ;;
        ST_TITLE)                          _S="=== Статус Tailscale ===" ;;
        ST_NOT_INSTALLED)                  _S="Пакет tailscale не установлен." ;;
        ST_VERSION)                        _S="Версия: %s" ;;
        ST_SOURCE)                         _S="Источник установки: %s" ;;
        ST_SERVICE_RUNNING)                _S="Служба: запущена" ;;
        ST_SERVICE_STOPPED)                _S="Служба: не запущена" ;;
        ST_FW_OK)                          _S="Firewall: зона tailscale настроена" ;;
        ST_FW_NO)                          _S="Firewall: зона tailscale не настроена" ;;
        ST_NF)                             _S="Режим netfilter: %s" ;;
        ST_SERVER)                         _S="Сервер: %s" ;;
        ST_TS_STATUS)                      _S="--- tailscale status ---" ;;
        *) return 1 ;;
    esac
    return 0
}

strings_en() {
    case "$1" in
        PFX_WARN)         _S="Warning: " ;;
        PFX_ERR)          _S="Error: " ;;
        ERR_ABORT)        _S="Aborted." ;;
        PROMPT_YN)        _S="[y/N]" ;;
        PROMPT_CHOICE)    _S="Your choice [%s]: " ;;
        PROMPT_TYPE_YES)  _S="Type yes to confirm (anything else cancels): " ;;
        ERR_BAD_CHOICE)   _S="Invalid input, please try again." ;;
        ERR_NO_INPUT)     _S="Interactive input is not available." ;;
        RB_START)         _S="Rolling back changes..." ;;
        RB_EMPTY)         _S="Nothing to roll back." ;;
        RB_STEP_FAIL)     _S="Rollback step failed: %s" ;;
        RB_DONE)          _S="Rollback finished." ;;
        RB_BAD_ENTRY)     _S="Invalid rollback entry: %s" ;;
        CONF_BAD_KEY)     _S="Config: key '%s' is not supported." ;;
        CONF_BAD_VALUE)   _S="Config: invalid value for %s." ;;
        CONF_BAD_LINE)    _S="Config: line %s skipped (bad format)." ;;
        CONF_WRITE_FAIL)  _S="Failed to write config %s." ;;
        CONF_EMPTY)       _S="Config is empty." ;;
        I18N_MISSING)     _S="Missing translation (%s) for key %s." ;;
        INIT_RUNDIR_FAIL) _S="Failed to create working directory %s." ;;
        DETECT_NO_RELEASE)    _S="File %s not found - is this really OpenWrt?" ;;
        DETECT_NO_PKGMGR)     _S="Neither opkg nor apk was found." ;;
        DETECT_MGR_MISMATCH)  _S="OpenWrt %s usually uses a different package manager than the one found (%s)." ;;
        DETECT_UNSUPPORTED)   _S="OpenWrt %s is not a supported version (24.10 and 25.12+), continuing at your own risk." ;;
        ARCH_UNKNOWN)         _S="Could not determine architecture (DISTRIB_ARCH=%s, uname -m=%s)." ;;
        TUN_OK)               _S="TUN is available (interface creation verified)." ;;
        TUN_DEVICE_ONLY)      _S="Could not create a TUN interface via ip, but device %s exists: the check is incomplete." ;;
        TUN_FAIL)             _S="TUN is not available. Install kmod-tun or use --tun=userspace-networking." ;;
        PKG_NO_MGR)           _S="Package manager is not detected." ;;
        PKG_BAD_NAME)         _S="Invalid package name: %s" ;;
        PKG_UPDATE_FAIL)      _S="Failed to update package lists." ;;
        PKG_INSTALL_FAIL)     _S="Failed to install or upgrade: %s" ;;
        PKG_REMOVE_FAIL)      _S="Failed to remove: %s" ;;
        PKG_HOLD_FAIL)        _S="Failed to pin the version of package %s." ;;
        PKG_UNHOLD_FAIL)      _S="Failed to unpin the version of package %s." ;;
        FEED_NAME_BAD)        _S="Invalid repository name (only a-z, 0-9 and _ are allowed)." ;;
        FEED_URL_BAD)         _S="Invalid address: %s (https:// and only A-Z a-z 0-9 . _ : / ~ + - are allowed)." ;;
        FEED_REMOVE_NO_UPDATE) _S="Repository %s removed, but refreshing package lists failed." ;;
        FEED_NONINTERACTIVE)  _S="Adding a repository requires confirmation and was skipped (non-interactive mode)." ;;
        FEED_EXISTS)          _S="Repository %s is already added." ;;
        FEED_FETCH_FAIL)      _S="Failed to download: %s" ;;
        FEED_KEY_ID_ONLY)     _S="The key file contains only a key ID, not the public key itself. Repository not added. Import the key manually or specify a correct source." ;;
        FEED_KEY_INVALID)     _S="The key file has an invalid format (%s). Repository not added." ;;
        FEED_KEYTOOL_MISSING) _S="usign not found: cannot import the key for opkg." ;;
        FEED_CONFIRM)         _S="A third-party package repository will be added:\n  name:     %s\n  URL:      %s\n  key:      %s\n  key sha256: %s\nAdd it?" ;;
        FEED_DECLINED)        _S="Repository not added." ;;
        FEED_ADDED)           _S="Repository %s added, key imported." ;;
        FEED_REMOVED)         _S="Repository %s removed." ;;
        FEED_WRITE_FAIL)      _S="Failed to write %s." ;;
        FEED_UPDATE_FAIL)     _S="Failed to refresh the new repository index (check URL and signature), repository removed." ;;
        INSTALL_DEPS_TITLE)                _S="Installing dependencies: %s" ;;
        INSTALL_DEPS_OK)                   _S="Dependencies installed." ;;
        INSTALL_DEPS_FAIL)                 _S="Failed to install dependencies: %s" ;;
        FEED_ARCH_UNAVAILABLE)             _S="Device architecture is not supported by this feed (or the feed is unreachable). Choose another source." ;;
        FEED_ARCH_FALLBACK)                _S="Could not determine arch via package manager, using DISTRIB_ARCH=%s." ;;
        CHOOSE_SOURCE_TITLE)               _S="Choose Tailscale installation source:" ;;
        CHOOSE_SOURCE_OFFICIAL)            _S="  1) Official OpenWrt package (stable, version may be old)" ;;
        CHOOSE_SOURCE_LITE_FEED)           _S="  2) Lite (GuNanOvO) via signed feed (recommended)" ;;
        CHOOSE_SOURCE_LITE_DIRECT)         _S="  3) Lite (GuNanOvO) direct .ipk download (unsafe)" ;;
        CHOOSE_SOURCE_PROMPT)              _S="Source " ;;
        INSTALL_OFFICIAL_TITLE)            _S="Installing official package..." ;;
        INSTALL_OFFICIAL_OK)               _S="Official package installed." ;;
        INSTALL_OFFICIAL_FAIL)             _S="Failed to install official package (%s)." ;;
        INSTALL_LITE_FEED_TITLE)           _S="Installing Lite via feed..." ;;
        INSTALL_LITE_FEED_OK)              _S="Lite installed via feed." ;;
        INSTALL_LITE_FEED_FAIL)            _S="Failed to install Lite via feed." ;;
        INSTALL_LITE_ORIGIN_WARN)          _S="The installed tailscale package does not look like the Lite build (the official feed may have a higher version). Check opkg info tailscale." ;;
        INSTALL_LITE_DIRECT_TITLE)         _S="Installing Lite via direct .ipk download." ;;
        INSTALL_LITE_DIRECT_CONFIRM)       _S="WARNING: this path is unsafe. The .ipk is not verified by feed signature (only a same-origin checksum). The package manager installs it without signature verification." ;;
        INSTALL_LITE_DIRECT_DECLINED)      _S="Installation cancelled." ;;
        INSTALL_LITE_DIRECT_WRONG_MGR)     _S="Direct download is supported only with opkg (24.10)." ;;
        INSTALL_LITE_DIRECT_WRONG_VER)     _S="On OpenWrt 25.12+, use the signed feed (option 2)." ;;
        INSTALL_LITE_DIRECT_FETCH_FAIL)    _S="Failed to download: %s" ;;
        INSTALL_LITE_DIRECT_NO_SHA)        _S="ipk.sha256 is unavailable, hash check skipped." ;;
        INSTALL_LITE_DIRECT_SHA_MISMATCH)  _S="Package SHA256 does not match ipk.sha256. Installation aborted." ;;
        INSTALL_LITE_DIRECT_ARCH_MISMATCH) _S="Package arch (%s) does not match device arch (%s)." ;;
        INSTALL_LITE_DIRECT_ARCH_UNKNOWN)  _S="Could not determine package arch, ELF check skipped." ;;
        INSTALL_LITE_DIRECT_INSTALL_FAIL)  _S="opkg install failed." ;;
        INSTALL_LITE_DIRECT_OK)            _S="Lite installed via direct download." ;;
        SERVICE_NO_INIT)                   _S="/etc/init.d/tailscale not found." ;;
        SERVICE_ENABLE_FAIL)               _S="Failed to enable autostart." ;;
        SERVICE_START_FAIL)                _S="Failed to start the service." ;;
        SERVICE_START_OK)                  _S="tailscale service started, autostart enabled." ;;
        SERVICE_NOT_RUNNING)               _S="Service started but tailscaled not detected. Check logread." ;;
        SYSUPGRADE_FAIL)                   _S="Failed to write %s." ;;
        SYSUPGRADE_UPDATED)                _S="Sysupgrade keep-list updated." ;;
        FW_NO_UCI)                         _S="uci not found: cannot configure the firewall." ;;
        FW_PENDING)                        _S="There are uncommitted changes in network/firewall (uci changes). Commit or revert them and try again." ;;
        FW_FOREIGN)                        _S="Foreign Tailscale configuration found. Firewall zones: %s; network interfaces: %s. Not creating our own sections, please sort it out manually (uci show firewall, uci show network)." ;;
        FW_PARTIAL)                        _S="Leftovers of a previous setup (tsi_* sections) found, recreating." ;;
        FW_ALREADY)                        _S="Firewall and network for Tailscale are already configured." ;;
        FW_SETUP_OK)                       _S="Firewall and network configured: zone tailscale, forwarding tailscale <-> lan." ;;
        FW_SETUP_FAIL)                     _S="Failed to configure firewall/network, changes rolled back." ;;
        FW_BACKUP_FAIL)                    _S="Failed to back up configs to %s." ;;
        FW_RELOAD_FAIL)                    _S="Failed to reload network/firewall configuration." ;;
        FW_REMOVED)                        _S="Tailscale sections removed from network and firewall." ;;
        FW_NOT_SETUP)                      _S="Configure the firewall first (zone tailscale is missing)." ;;
        FW_WAN_ALREADY)                    _S="Forwarding tailscale -> wan is already enabled." ;;
        FW_WAN_ALREADY_OFF)                _S="Forwarding tailscale -> wan is already disabled." ;;
        FW_WAN_ON_OK)                      _S="Forwarding tailscale -> wan enabled (required for exit node)." ;;
        FW_WAN_OFF_OK)                     _S="Forwarding tailscale -> wan disabled." ;;
        FW_WAN_ASK_ON)                     _S="Enable forwarding tailscale -> wan? It is required for an exit node: peer traffic will be able to reach the internet through this router." ;;
        FW_WAN_ASK_OFF)                    _S="Forwarding tailscale -> wan is enabled. Disable it?" ;;
        ROUTE_NO_IP)                       _S="The ip command is unavailable, 100.64.0.0/10 route check skipped." ;;
        ROUTE_STILL_MISSING)               _S="The 100.64.0.0/10 route is already added, but traffic to Tailscale addresses does not go via tailscale0. Check: ip route get 100.64.0.1" ;;
        ROUTE_NO_IFACE)                    _S="The 100.64.0.0/10 route was not added: interface tsi_net is missing (configure the firewall first)." ;;
        ROUTE_ADDED)                       _S="Route %s added via uci (section tsi_route)." ;;
        FW_MODE_SET)                       _S="Firewall mode for tailscaled: %s." ;;
        FW_MODE_FAIL)                      _S="Failed to write fw_mode to /etc/config/tailscale." ;;
        NF_CONFLICT_INFO)                  _S="Packages that may conflict with Tailscale's netfilter management were found: %s.\nTailscale 1.98+ changes net.ipv4.conf.all.src_valid_mark and netfilter rules, which can stop TPROXY setups (podkop, forkop, nikki) from passing LAN client traffic." ;;
        NF_CURRENT)                        _S="Current netfilter mode: %s" ;;
        NF_CHOICE_OFF)                     _S="  1) Disable Tailscale netfilter management (--netfilter-mode=off), recommended" ;;
        NF_CHOICE_ON)                      _S="  2) Leave netfilter to Tailscale (at your own risk)" ;;
        NF_CHOICE_KEEP)                    _S="  3) Keep the current value (%s)" ;;
        NF_PROMPT)                         _S="Netfilter mode " ;;
        NF_SET_OFF)                        _S="Selected: --netfilter-mode=off. This script configures firewall rules via uci." ;;
        NF_SET_ON)                         _S="Selected: netfilter stays managed by Tailscale." ;;
        NF_NEEDS_CHOICE)                   _S="Conflicting packages were found (%s) and no netfilter mode is selected. In non-interactive mode specify it explicitly (--netfilter-off)." ;;
        LS_CHOICE_STD)                     _S="  1) Standard Tailscale server" ;;
        LS_CHOICE_CUSTOM)                  _S="  2) Custom server (e.g. headscale)" ;;
        LS_PROMPT)                         _S="Server " ;;
        LS_INPUT)                          _S="Server address without https:// (e.g. rc.routerich.ru): " ;;
        LS_BAD)                            _S="Invalid server address: %s" ;;
        LS_SET)                            _S="Server set: %s" ;;
        LS_RESET)                          _S="The standard Tailscale server will be used." ;;
        LS_ASK_CHANGE)                     _S="Tailscale server: %s. Change it?" ;;
        LS_STANDARD)                       _S="standard" ;;
        LS_CHANGE_FAILED)                  _S="Could not change the server, the previous one is kept." ;;
        UP_NO_BIN)                         _S="The tailscale command was not found." ;;
        UP_ASK_EXIT)                       _S="Use this router as an exit node (--advertise-exit-node)?" ;;
        UP_ASK_ROUTES)                     _S="Advertise subnets (--advertise-routes), e.g. this router's LAN?" ;;
        UP_ASK_ROUTES_INPUT)               _S="Subnets, comma-separated (e.g. 192.168.1.0/24): " ;;
        UP_ROUTES_BAD)                     _S="Invalid subnet '%s' (%s). Expected A.B.C.D/N without host bits, e.g. 192.168.1.0/24." ;;
        UP_CMD_CONFIRM)                    _S="The following command will be run:\n  %s\nRun it?" ;;
        UP_RUNNING)                        _S="Running tailscale up. If authentication is required, open the shown link in a browser." ;;
        UP_OK)                             _S="tailscale up completed." ;;
        UP_FAIL)                           _S="tailscale up failed (code %s). The installation is kept; repeat the command manually or via the menu." ;;
        UP_SKIPPED)                        _S="tailscale up skipped." ;;
        UP_NONINTERACTIVE)                 _S="Non-interactive mode: tailscale up is not run (authentication is needed)." ;;
        POST_TITLE)                        _S="=== What next ===" ;;
        POST_DONE)                         _S="Tailscale is installed, the service is running, the firewall is configured." ;;
        POST_UP_NOT_DONE)                  _S="Connect the router to your network with:\n  %s" ;;
        POST_AUTH_URL)                     _S="If authentication is not finished, open: %s" ;;
        POST_EXIT)                         _S="Exit node: add --advertise-exit-node and enable forwarding tailscale -> wan (menu item)." ;;
        POST_ROUTES)                       _S="Subnet routing: add --advertise-routes=192.168.1.0/24 (use your subnet)." ;;
        POST_APPROVE)                      _S="Exit node and routes must be approved in the Tailscale admin console (or your own server), they do not work until then." ;;
        POST_ALL_FLAGS)                    _S="When running tailscale up again, give all non-default flags at once or the command refuses to run; tsi builds them for you." ;;
        POST_NF_OFF)                       _S="--netfilter-mode=off: Tailscale does not manage netfilter rules, this script configures them (uci, zone tailscale). This avoids breaking podkop/forkop." ;;
        POST_DNS_WARN)                     _S="%s detected while --netfilter-mode=off is not selected: Tailscale may break LAN clients. Choose off in the settings menu and run tailscale up again." ;;
        POST_AGAIN)                        _S="To change settings later, run tsi." ;;
        UPD_START)                         _S="Checking for Tailscale updates..." ;;
        UPD_NOT_INSTALLED)                 _S="Tailscale is not installed." ;;
        UPD_NO_SOURCE)                     _S="Installation source is unknown (INSTALL_SOURCE is not set in the config). Run the installation." ;;
        UPD_NONE)                          _S="No updates: version %s is installed." ;;
        UPD_CURRENT)                       _S="Installed version %s, available %s." ;;
        UPD_OK)                            _S="Tailscale updated: %s -> %s." ;;
        UPD_FAIL)                          _S="Failed to update Tailscale." ;;
        UPD_DIRECT_MENU_ONLY)              _S="Updating this installation (direct download) is available only from the menu: confirmation is required." ;;
        SERVICE_RESTART_OK)                _S="The tailscale service was restarted." ;;
        SERVICE_RESTART_FAIL)              _S="Failed to restart the tailscale service." ;;
        LUCI_ASK)                          _S="Install the LuCI web interface for Tailscale (luci-app-tailscale-community)?" ;;
        LUCI_NO_BASE)                      _S="LuCI is not installed on this router (no luci-base), the Tailscale web interface was skipped." ;;
        LUCI_ALREADY)                      _S="The LuCI web interface for Tailscale is already installed." ;;
        LUCI_UNAVAILABLE)                  _S="luci-app-tailscale-community is not available for your system. Install it manually: github.com/Tokisaki-Galaxy/luci-app-tailscale-community" ;;
        LUCI_FEED_DECLINED)                _S="The LuCI app feed was not added, the web interface was not installed." ;;
        LUCI_INSTALLING)                   _S="Installing luci-app-tailscale-community..." ;;
        LUCI_OK)                           _S="The LuCI web interface for Tailscale is installed." ;;
        LUCI_FAIL)                         _S="Failed to install luci-app-tailscale-community." ;;
        UN_CONFIRM)                        _S="WARNING: Tailscale will be removed together with its authentication state (/etc/tailscale): the router will disappear from your network and must log in again. The service, firewall rules, packages and feeds added by this script will be removed." ;;
        UN_CANCELLED)                      _S="Removal cancelled." ;;
        UN_ASK_CONF)                       _S="Also remove the script configuration (%s and the feed records)?" ;;
        UN_PKG_KEPT)                       _S="Could not remove the tailscale package, its files and state were kept." ;;
        UN_REPORT_TITLE)                   _S="=== Removal summary ===" ;;
        UN_REPORT_REMOVED)                 _S="Removed: %s" ;;
        UN_REPORT_KEPT)                    _S="Kept: %s" ;;
        UN_NOTE_DEPS)                      _S="Dependencies (kmod-tun, ca-bundle, ...) were not removed: other packages may use them." ;;
        UN_DONE)                           _S="Removal finished." ;;
        FEED_PIN_BAD)                      _S="Internal error: invalid pinned repository key hash." ;;
        FEED_PIN_MISMATCH)                 _S="The repository key differs from the one pinned in the script (sha256 %s). The author may have rotated the key; verify the hash before confirming." ;;
        FEED_PIN_FATAL)                    _S="The repository key does not match the one pinned in the script (sha256 %s): the author may have rotated the key, or it was tampered with. In non-interactive mode the repository was not added." ;;
        LANG_FIRST_TITLE)                  _S="Выберите язык / Select language:\n  1) Русский\n  2) English" ;;
        USAGE_ERR)                         _S="Invalid option: %s" ;;
        USAGE_TEXT)                        _S="Usage: tsi [option]\n\n  (no options)            menu\n  --status                status\n  --update                update Tailscale (no questions)\n  --install-official      install the official package (no questions)\n  --install-lite          install Lite via the signed feed (no questions)\n  --netfilter-off         with --install-*: disable Tailscale netfilter management\n  --login-server=ADDRESS  with --install-*: custom server (e.g. rc.example.com)\n  -h, --help              this help\n  -V, --version           version\n\nRemoval and direct download are available from the menu only.\n--install-lite verifies the feed key against a hash pinned in the script: if the author rotates the key, update tsi.\nExit codes: 0 success, 1 error, 2 not performed (declined, confirmation needed, bad options)." ;;
        MENU_TITLE)                        _S="=== Tailscale installer for OpenWrt (tsi) ===" ;;
        MENU_INSTALL)                      _S="  1) Install Tailscale" ;;
        MENU_UPDATE)                       _S="  2) Update Tailscale" ;;
        MENU_UNINSTALL)                    _S="  3) Uninstall Tailscale" ;;
        MENU_STATUS)                       _S="  4) Status" ;;
        MENU_SETTINGS)                     _S="  5) Settings" ;;
        MENU_EXIT)                         _S="  0) Exit" ;;
        MENU_PROMPT)                       _S="" ;;
        SET_TITLE)                         _S="=== Settings ===" ;;
        SET_LANG)                          _S="  1) Interface language" ;;
        SET_SERVER)                        _S="  2) Tailscale server (change or reset)" ;;
        SET_NETFILTER)                     _S="  3) Netfilter mode" ;;
        SET_WAN)                           _S="  4) Forwarding tailscale -> wan (for exit node)" ;;
        SET_FWMODE)                        _S="  5) Firewall mode for tailscaled (nftables/iptables)" ;;
        SET_VERBOSE)                       _S="  6) Verbose log (on/off)" ;;
        SET_CONFIG)                        _S="  7) Show configuration" ;;
        SET_LUCI)                          _S="  8) Install the LuCI web interface" ;;
        SET_UP)                            _S="  9) Exit node, subnets and tailscale up" ;;
        SET_BACK)                          _S="  0) Back" ;;
        SET_LANG_SET)                      _S="Interface language: %s" ;;
        SET_NF_EXPLAIN)                    _S="Mode off: Tailscale does not change netfilter rules or sysctl (needed next to podkop/forkop), this script configures the firewall rules. Mode on: Tailscale manages them." ;;
        SET_NF_BACK)                       _S="  3) Back" ;;
        SET_RERUN_UP)                      _S="The change takes effect on the next tailscale up (settings item 'Exit node, subnets and tailscale up')." ;;
        SET_VERBOSE_ON)                    _S="Verbose log enabled." ;;
        SET_VERBOSE_OFF)                   _S="Verbose log disabled." ;;
        SET_RESTART_ASK)                   _S="Restart the tailscale service now?" ;;
        INSTALL_TUN_ABORT)                 _S="Tailscale will not work without TUN. Install kmod-tun and try again. Installation aborted." ;;
        INSTALL_TUN_ASK)                   _S="TUN is unavailable, Tailscale may fail to start. Continue the installation?" ;;
        INSTALL_DONE)                      _S="Installation finished." ;;
        INSTALL_DONE_WARN)                 _S="Installation finished with warnings, see the messages above and the log %s." ;;
        ST_TITLE)                          _S="=== Tailscale status ===" ;;
        ST_NOT_INSTALLED)                  _S="The tailscale package is not installed." ;;
        ST_VERSION)                        _S="Version: %s" ;;
        ST_SOURCE)                         _S="Installation source: %s" ;;
        ST_SERVICE_RUNNING)                _S="Service: running" ;;
        ST_SERVICE_STOPPED)                _S="Service: not running" ;;
        ST_FW_OK)                          _S="Firewall: zone tailscale is configured" ;;
        ST_FW_NO)                          _S="Firewall: zone tailscale is not configured" ;;
        ST_NF)                             _S="Netfilter mode: %s" ;;
        ST_SERVER)                         _S="Server: %s" ;;
        ST_TS_STATUS)                      _S="--- tailscale status ---" ;;
        *) return 1 ;;
    esac
    return 0
}

i18n_set_lang() { # ru|en
    case "$1" in
        en) CUR_LANG="en" ;;
        *)  CUR_LANG="ru" ;;
    esac
}

i18n_init() {
    i18n_set_lang "$CFG_LANG"
}

# Текст по ключу, без перевода строки. Неизвестный ключ -> [missing:KEY].
msg_str() { # KEY [args...]
    _ms_key=$1
    shift
    _S=""
    if [ "$CUR_LANG" = "en" ]; then
        strings_en "$_ms_key"
        _ms_rc=$?
    else
        strings_ru "$_ms_key"
        _ms_rc=$?
    fi
    if [ "$_ms_rc" -ne 0 ]; then
        printf '[missing:%s]' "$_ms_key"
        return 0
    fi
    # shellcheck disable=SC2059
    printf "$_S" "$@"
}

msg() { # KEY [args...]
    msg_str "$@"
    printf '\n'
}

i18n_selfcheck() {
    _ic_bad=0
    for _ic_k in $I18N_KEYS; do
        if ! strings_ru "$_ic_k"; then
            warn i18n_selfcheck I18N_MISSING ru "$_ic_k"
            _ic_bad=1
        fi
        if ! strings_en "$_ic_k"; then
            warn i18n_selfcheck I18N_MISSING en "$_ic_k"
            _ic_bad=1
        fi
    done
    return "$_ic_bad"
}

# ---- 2.3 Вывод пользователю (+ лог) -----------------------------------
# Первый аргумент - имя функции-вызывателя (для лога), далее KEY [args].

say() { # FUNC KEY [args...]
    _sy_fn=$1
    shift
    _sy_txt=$(msg_str "$@")
    printf '%s\n' "$_sy_txt"
    log_info "$_sy_fn" "$_sy_txt"
}

warn() { # FUNC KEY [args...]
    _wn_fn=$1
    shift
    _wn_txt=$(msg_str "$@")
    printf '%s%s\n' "$(msg_str PFX_WARN)" "$_wn_txt" >&2
    log_warn "$_wn_fn" "$_wn_txt"
}

err() { # FUNC KEY [args...]
    _er_fn=$1
    shift
    _er_txt=$(msg_str "$@")
    printf '%s%s\n' "$(msg_str PFX_ERR)" "$_er_txt" >&2
    log_err "$_er_fn" "$_er_txt"
}

die() { # FUNC KEY [args...]
    err "$@"
    exit "$EXIT_FAIL"
}

# Критическая ошибка с откатом изменений текущего запуска.
die_rb() { # FUNC KEY [args...]
    err "$@"
    rollback_run
    exit "$EXIT_FAIL"
}

# ---- 2.4 Ввод пользователя ---------------------------------------------
# Читаем из TTY_DEV (а не из stdin) - иначе при wget | sh мы съедим сам скрипт.
# Коды возврата ask_*: 0 - ок/да, 1 - нет, 2 - ввод недоступен
# (неинтерактивный режим или нет терминала). Автоматического "yes" нет нигде.

_read_tty() {
    ASK_REPLY=""
    [ "$NONINTERACTIVE" = 1 ] && return 2
    { IFS= read -r ASK_REPLY <"$TTY_DEV"; } 2>/dev/null || return 2
    ASK_REPLY=${ASK_REPLY%"$CR"}
    return 0
}

ask_text() { # KEY [args...]  -> ASK_REPLY
    printf '%s' "$(msg_str "$@")"
    _read_tty
}

ask_yn() { # KEY [args...]  (по умолчанию - нет)
    printf '%s %s ' "$(msg_str "$@")" "$(msg_str PROMPT_YN)"
    _read_tty || return 2
    case "$ASK_REPLY" in
        y|Y|yes|Yes|YES|д|Д|да|Да|ДА) return 0 ;;
        *) return 1 ;;
    esac
}

# Выбор из списка допустимых значений ("1 2 3"). Повторяет вопрос до верного
# ввода; EOF/нет терминала -> 2. Результат в ASK_REPLY.
ask_choice() { # KEY "valid values"
    _ac_key=$1
    _ac_valid=$2
    _ac_show=$(printf '%s' "$_ac_valid" | tr ' ' '/')
    while :; do
        printf '%s' "$(msg_str "$_ac_key")"
        printf '%s' "$(msg_str PROMPT_CHOICE "$_ac_show")"
        _read_tty || return 2
        for _ac_v in $_ac_valid; do
            if [ "$ASK_REPLY" = "$_ac_v" ]; then
                return 0
            fi
        done
        msg ERR_BAD_CHOICE
    done
}

# Подтверждение небезопасных действий: только точное слово "yes", только вручную.
ask_typed_yes() { # KEY [args...]
    printf '%s\n' "$(msg_str "$@")"
    printf '%s' "$(msg_str PROMPT_TYPE_YES)"
    _read_tty || return 2
    [ "$ASK_REPLY" = "yes" ]
}

# ---- 2.5 Стек отката ---------------------------------------------------
# Одна запись = одна строка: "имя_функции_или_команды 'арг1' 'арг2'".
# Сложные действия оборачиваются в функцию. Выполнение - в обратном порядке
# (LIFO), вызывается вручную (rollback_run / die_rb), не через trap.

shq() { # безопасное квотирование аргумента для eval
    _sq=$(printf '%s\n' "$1" | sed "s/'/'\\\\''/g")
    printf "'%s'" "$_sq"
}

rollback_init() {
    : >"$ROLLBACK_FILE"
}

rollback_clear() {
    : >"$ROLLBACK_FILE"
}

rollback_push() { # name [args...]
    _rp_name=$1
    shift
    case "$_rp_name" in
        ''|*[!A-Za-z0-9_./-]*)
            err rollback_push RB_BAD_ENTRY "$_rp_name"
            return 1
            ;;
    esac
    _rp_line=$_rp_name
    for _rp_a in "$@"; do
        case "$_rp_a" in
            *'
'*)
                err rollback_push RB_BAD_ENTRY "$_rp_name"
                return 1
                ;;
        esac
        _rp_line="$_rp_line $(shq "$_rp_a")"
    done
    if ! printf '%s\n' "$_rp_line" >>"$ROLLBACK_FILE"; then
        return 1
    fi
    log_dbg rollback_push "$_rp_line"
    return 0
}

rollback_run() {
    if [ ! -s "$ROLLBACK_FILE" ]; then
        say rollback_run RB_EMPTY
        return 0
    fi
    say rollback_run RB_START
    _rb_rev="$RUNDIR/rollback.rev"
    if ! sed '1!G;h;$!d' "$ROLLBACK_FILE" >"$_rb_rev"; then
        return 1
    fi
    _rb_fail=0
    while IFS= read -r _rb_line; do
        [ -n "$_rb_line" ] || continue
        log_info rollback_run "exec: $_rb_line"
        if ! eval "$_rb_line" </dev/null; then
            warn rollback_run RB_STEP_FAIL "$_rb_line"
            _rb_fail=1
        fi
    done <"$_rb_rev"
    rm -f "$_rb_rev"
    : >"$ROLLBACK_FILE"
    say rollback_run RB_DONE
    return "$_rb_fail"
}

# ======================================================================
# 3. КОНФИГ (/etc/tailscale-installer.conf, KEY=VALUE)
# ======================================================================
# Файл никогда не исполняется (нет source/eval над его содержимым):
# построчный разбор, ключ - по белому списку, значение - по валидатору.

conf_key_ok() { # KEY
    case "$1" in
        ''|*[!A-Z0-9_]*) return 1 ;;
    esac
    case " $CONF_KEYS " in
        *" $1 "*) return 0 ;;
    esac
    return 1
}

conf_validate() { # KEY VALUE
    _cv_v=$2
    case "$1" in
        LANG)
            case "$_cv_v" in ''|ru|en) return 0 ;; esac
            ;;
        INSTALL_SOURCE)
            case "$_cv_v" in ''|A|B) return 0 ;; esac
            ;;
        B_SUBMODE)
            case "$_cv_v" in ''|feed|direct) return 0 ;; esac
            ;;
        NETFILTER_MODE)
            case "$_cv_v" in ''|on|off) return 0 ;; esac
            ;;
        LOG_VERBOSE)
            case "$_cv_v" in ''|0|1) return 0 ;; esac
            ;;
        LOGIN_SERVER)
            [ -z "$_cv_v" ] && return 0
            case "$_cv_v" in https://*) ;; *) return 1 ;; esac
            _cv_r=${_cv_v#https://}
            case "$_cv_r" in
                ''|*[!A-Za-z0-9._:/~-]*) return 1 ;;
                [!A-Za-z0-9]*|*//*) return 1 ;;
            esac
            return 0
            ;;
        LITE_VERSION)
            case "$_cv_v" in
                *[!A-Za-z0-9._+-]*) return 1 ;;
            esac
            return 0
            ;;
    esac
    return 1
}

conf_reset() { # значения по умолчанию в памяти
    for _cr_k in $CONF_KEYS; do
        eval "CFG_$_cr_k=''"
    done
    CFG_LOG_VERBOSE=0
}

conf_load() {
    conf_reset
    [ -f "$CONF" ] || return 0
    _cl_n=0
    while IFS= read -r _cl_line || [ -n "$_cl_line" ]; do
        _cl_n=$((_cl_n + 1))
        _cl_line=${_cl_line%"$CR"}
        case "$_cl_line" in
            ''|'#'*) continue ;;
            *=*) ;;
            *)
                warn conf_load CONF_BAD_LINE "$_cl_n"
                continue
                ;;
        esac
        _cl_k=${_cl_line%%=*}
        _cl_v=${_cl_line#*=}
        if ! conf_key_ok "$_cl_k"; then
            warn conf_load CONF_BAD_KEY "$_cl_k"
            continue
        fi
        if ! conf_validate "$_cl_k" "$_cl_v"; then
            warn conf_load CONF_BAD_VALUE "$_cl_k"
            continue
        fi
        eval "CFG_$_cl_k=\$_cl_v"
    done <"$CONF"
    return 0
}

conf_get() { # KEY -> stdout
    conf_key_ok "$1" || return 1
    eval "printf '%s' \"\$CFG_$1\""
}

# Атомарная перезапись: временный файл рядом с конфигом + mv.
# Прочие строки (комментарии, неизвестные ключи) сохраняются как есть.
_conf_rewrite() { # KEY set|unset [VALUE]
    _cw_k=$1
    _cw_mode=$2
    _cw_v=$3
    _cw_tmp="${CONF}.tmp.$$"
    _cw_found=0
    {
        if [ -f "$CONF" ]; then
            while IFS= read -r _cw_line || [ -n "$_cw_line" ]; do
                _cw_line=${_cw_line%"$CR"}
                case "$_cw_line" in
                    "$_cw_k="*)
                        if [ "$_cw_mode" = set ] && [ "$_cw_found" -eq 0 ]; then
                            printf '%s=%s\n' "$_cw_k" "$_cw_v"
                            _cw_found=1
                        fi
                        ;;
                    *)
                        printf '%s\n' "$_cw_line"
                        ;;
                esac
            done <"$CONF"
        fi
        if [ "$_cw_mode" = set ] && [ "$_cw_found" -eq 0 ]; then
            printf '%s=%s\n' "$_cw_k" "$_cw_v"
        fi
    } >"$_cw_tmp" 2>/dev/null
    if [ $? -ne 0 ] || ! mv "$_cw_tmp" "$CONF" 2>/dev/null; then
        rm -f "$_cw_tmp"
        err conf_write CONF_WRITE_FAIL "$CONF"
        return 1
    fi
    return 0
}

conf_set() { # KEY VALUE
    if ! conf_key_ok "$1"; then
        err conf_set CONF_BAD_KEY "$1"
        return 1
    fi
    if ! conf_validate "$1" "$2"; then
        err conf_set CONF_BAD_VALUE "$1"
        return 1
    fi
    _conf_rewrite "$1" set "$2" || return 1
    eval "CFG_$1=\$2"
    log_dbg conf_set "$1=$2"
    return 0
}

conf_unset() { # KEY
    if ! conf_key_ok "$1"; then
        err conf_unset CONF_BAD_KEY "$1"
        return 1
    fi
    _conf_rewrite "$1" unset || return 1
    eval "CFG_$1=''"
    [ "$1" = LOG_VERBOSE ] && CFG_LOG_VERBOSE=0
    log_dbg conf_unset "$1"
    return 0
}

conf_show() { # для пункта меню "Просмотр конфигурации"
    _cs_any=0
    for _cs_k in $CONF_KEYS; do
        eval "_cs_val=\$CFG_$_cs_k"
        if [ -n "$_cs_val" ]; then
            printf '%s=%s\n' "$_cs_k" "$_cs_val"
            _cs_any=1
        fi
    done
    if [ "$_cs_any" -eq 0 ]; then
        msg CONF_EMPTY
    fi
}

conf_delete_file() { # шаг 5 удаления (подтверждение - на стороне вызывающего)
    rm -f "$CONF"
}

# ======================================================================
# ИНИЦИАЛИЗАЦИЯ СЛОЯ 1
# ======================================================================

tsi_init() {
    _ti_umask=$(umask)
    umask 077
    mkdir -p "$RUNDIR" 2>/dev/null
    umask "$_ti_umask"
    if [ ! -d "$RUNDIR" ] || [ -L "$RUNDIR" ]; then
        printf '%s%s\n' "$(msg_str PFX_ERR)" "$(msg_str INIT_RUNDIR_FAIL "$RUNDIR")" >&2
        return 1
    fi
    log_trim
    conf_load
    i18n_init
    if [ "$CFG_LOG_VERBOSE" = 1 ]; then
        i18n_selfcheck
    fi
    log_info tsi_init "tsi $TSI_VERSION started"
    return 0
}

# ===================== КОНЕЦ СЛОЯ 1 ===================================

# ======================================================================
# 4. ОПРЕДЕЛЕНИЕ СИСТЕМЫ
# ======================================================================

OPENWRT_RELEASE="/etc/openwrt_release"
TUN_DEV="/dev/net/tun"
INITD_DIR="/etc/init.d"
ELF_PROBE_FILES="/bin/busybox /bin/sh /sbin/init"
DNS_PKG_CANDIDATES="podkop forkop nikki https-dns-proxy stubby dnscrypt-proxy"

# Результаты определения (глобальные переменные)
REL_VERSION=""      # DISTRIB_RELEASE: 24.10.2, 25.12.0-rc1, SNAPSHOT
REL_MAJOR=""        # 24.10 / 25.12 (пусто для SNAPSHOT)
REL_ARCH=""         # DISTRIB_ARCH: aarch64_cortex-a53, mipsel_24kc, ...
REL_TARGET=""       # DISTRIB_TARGET: ath79/generic, ...
PKG_MGR=""          # opkg | apk
TS_ARCH=""          # Go-арх. (amd64 arm64 arm 386 mips...): ожидаемая архитектура бинарника
                    # для сверки с ELF; для путей фида НЕ используется (там feed_arch)
TUN_AVAILABLE=0     # 1 - TUN создать можно
TUN_PROBE="none"    # ip | device | none (чем подтверждено)
DNS_CONFLICTS=""    # пробел-разделённый список, в конфиг НЕ пишется

# DISTRIB_X='value' (или "value", или без кавычек) -> value. Файл не исполняем.
_rel_field() { # KEY
    [ -r "$OPENWRT_RELEASE" ] || return 1
    sed -n "s/^$1=['\"]\{0,1\}\([^'\"]*\)['\"]\{0,1\}[[:space:]]*\$/\1/p" \
        "$OPENWRT_RELEASE" | head -n 1
}

# 0, если версия >= MAJOR.MINOR; SNAPSHOT (REL_MAJOR пуст) считаем новой.
rel_ge() { # MAJOR MINOR
    [ -n "$REL_MAJOR" ] || return 0
    _rg_maj=${REL_MAJOR%%.*}
    _rg_min=${REL_MAJOR#*.}
    [ "$_rg_maj" -gt "$1" ] && return 0
    [ "$_rg_maj" -eq "$1" ] && [ "$_rg_min" -ge "$2" ] && return 0
    return 1
}

detect_release() {
    if [ ! -r "$OPENWRT_RELEASE" ]; then
        err detect_release DETECT_NO_RELEASE "$OPENWRT_RELEASE"
        return 1
    fi
    REL_VERSION=$(_rel_field DISTRIB_RELEASE)
    REL_ARCH=$(_rel_field DISTRIB_ARCH)
    REL_TARGET=$(_rel_field DISTRIB_TARGET)
    REL_MAJOR=""
    case "$REL_VERSION" in
        [0-9]*.[0-9]*)
            _dr_maj=${REL_VERSION%%.*}
            _dr_rest=${REL_VERSION#*.}
            _dr_min=${_dr_rest%%[!0-9]*}
            REL_MAJOR="$_dr_maj.$_dr_min"
            ;;
    esac
    log_info detect_release "version=$REL_VERSION major=$REL_MAJOR arch=$REL_ARCH target=$REL_TARGET"
    return 0
}

# Менеджер определяем по наличию инструмента; версия - только для сверки.
detect_pkg_mgr() {
    _dp_apk=0
    _dp_opkg=0
    command -v apk >/dev/null 2>&1 && _dp_apk=1
    command -v opkg >/dev/null 2>&1 && _dp_opkg=1
    if [ "$_dp_apk" -eq 1 ] && [ "$_dp_opkg" -eq 0 ]; then
        PKG_MGR=apk
    elif [ "$_dp_opkg" -eq 1 ] && [ "$_dp_apk" -eq 0 ]; then
        PKG_MGR=opkg
    elif [ "$_dp_apk" -eq 1 ] && [ "$_dp_opkg" -eq 1 ]; then
        if rel_ge 25 12; then PKG_MGR=apk; else PKG_MGR=opkg; fi
    else
        err detect_pkg_mgr DETECT_NO_PKGMGR
        return 1
    fi
    if [ -n "$REL_MAJOR" ]; then
        if rel_ge 25 12; then _dp_expect=apk; else _dp_expect=opkg; fi
        if [ "$_dp_expect" != "$PKG_MGR" ]; then
            warn detect_pkg_mgr DETECT_MGR_MISMATCH "$REL_VERSION" "$PKG_MGR"
        fi
        if ! rel_ge 24 10; then
            warn detect_pkg_mgr DETECT_UNSUPPORTED "$REL_VERSION"
        fi
    fi
    log_info detect_pkg_mgr "PKG_MGR=$PKG_MGR"
    return 0
}

# ---- архитектура: DISTRIB_ARCH -> uname -m -> ELF ------------------------

_uname_m() { uname -m; }

_arch_from_distrib() { # DISTRIB_ARCH -> TS_ARCH
    case "$1" in
        x86_64*)                     echo amd64 ;;
        i386*|i686*|x86)             echo 386 ;;
        aarch64*)                    echo arm64 ;;
        arm_*|arm)                   echo arm ;;
        mips64el*)                   echo mips64le ;;
        mips64*)                     echo mips64 ;;
        mipsel_*|mipsel)             echo mipsle ;;
        mips_*|mips)                 echo mips ;;
        riscv64*)                    echo riscv64 ;;
        loongarch64*)                echo loong64 ;;
        *) return 1 ;;
    esac
}

# uname -m не различает порядок байтов у mips - их оставляем ELF-анализу.
_arch_from_uname() { # uname -m -> TS_ARCH
    case "$1" in
        x86_64)             echo amd64 ;;
        i[3-6]86)           echo 386 ;;
        aarch64|arm64)      echo arm64 ;;
        arm*)               echo arm ;;
        riscv64)            echo riscv64 ;;
        loongarch64)        echo loong64 ;;
        *) return 1 ;;
    esac
}

# Разбор заголовка ELF: магия, класс (32/64), порядок байтов, e_machine.
_arch_from_elf() { # FILE -> TS_ARCH
    [ -r "$1" ] || return 1
    # shellcheck disable=SC2046
    set -- $(od -An -tx1 -N20 "$1" 2>/dev/null)
    [ $# -ge 20 ] || return 1
    _ae_magic="$1$2$3$4"
    _ae_class=$5
    _ae_data=$6
    shift 18
    [ "$_ae_magic" = "7f454c46" ] || return 1
    if [ "$_ae_data" = "01" ]; then
        _ae_mach="$2$1"
        _ae_le=1
    else
        _ae_mach="$1$2"
        _ae_le=0
    fi
    case "$_ae_mach" in
        003e) [ "$_ae_class" = "02" ] || return 1; echo amd64 ;;
        0003) [ "$_ae_class" = "01" ] || return 1; echo 386 ;;
        00b7) [ "$_ae_class" = "02" ] || return 1; echo arm64 ;;
        0028) [ "$_ae_class" = "01" ] || return 1; echo arm ;;
        00f3) [ "$_ae_class" = "02" ] || return 1; echo riscv64 ;;
        0102) [ "$_ae_class" = "02" ] || return 1; echo loong64 ;;
        0008)
            if [ "$_ae_class" = "02" ]; then
                if [ "$_ae_le" -eq 1 ]; then echo mips64le; else echo mips64; fi
            else
                if [ "$_ae_le" -eq 1 ]; then echo mipsle; else echo mips; fi
            fi
            ;;
        *) return 1 ;;
    esac
}

detect_arch() {
    TS_ARCH=""
    _da_src=""
    _da_um=$(_uname_m)
    if _da_r=$(_arch_from_distrib "$REL_ARCH"); then
        TS_ARCH=$_da_r
        _da_src=distrib
    elif _da_r=$(_arch_from_uname "$_da_um"); then
        TS_ARCH=$_da_r
        _da_src="uname"
    else
        for _da_f in $ELF_PROBE_FILES; do
            if _da_r=$(_arch_from_elf "$_da_f"); then
                TS_ARCH=$_da_r
                _da_src="elf:$_da_f"
                break
            fi
        done
    fi
    if [ -z "$TS_ARCH" ]; then
        err detect_arch ARCH_UNKNOWN "$REL_ARCH" "$_da_um"
        return 1
    fi
    log_info detect_arch "TS_ARCH=$TS_ARCH source=$_da_src"
    return 0
}

# ---- TUN -----------------------------------------------------------------
# Реальная проверка: создаём и удаляем интерфейс. Если ip без tuntap (ip-tiny)
# или создание не вышло, но устройство TUN_DEV есть - считаем доступным, но
# с предупреждением (проверка неполная).

# TUN_AVAILABLE и TUN_PROBE читаются тестами и диагностикой, не самим скриптом
# shellcheck disable=SC2034
check_tun() {
    TUN_AVAILABLE=0
    TUN_PROBE=none
    _ct_if="tsiprobe0"
    if command -v ip >/dev/null 2>&1; then
        if run_ext ip tuntap add dev "$_ct_if" mode tun; then
            run_ext ip link del dev "$_ct_if"
            TUN_AVAILABLE=1
            TUN_PROBE=ip
            say check_tun TUN_OK
            return 0
        fi
    fi
    if [ -c "$TUN_DEV" ]; then
        TUN_AVAILABLE=1
        TUN_PROBE=device
        warn check_tun TUN_DEVICE_ONLY "$TUN_DEV"
        return 0
    fi
    warn check_tun TUN_FAIL
    return 1
}

# ---- DNS-пакеты, конфликтующие с управлением netfilter -----------------------
# Возврат: 0 - конфликты найдены (список в DNS_CONFLICTS), 1 - не найдены,
# 2 - ошибка (пакетный менеджер не определён: вызывать только после
# detect_pkg_mgr). Код 2 нельзя трактовать как "конфликтов нет".
# dnsmasq-full считается конфликтным только при "кастомных настройках":
# в uci dhcp есть nftset/ipset (так маршрутизируют podkop и подобные).

_dnsmasq_customized() {
    command -v uci >/dev/null 2>&1 || return 1
    uci -q show dhcp 2>/dev/null | grep -Eq '\.(nftset|ipset)='
}

check_dns_conflicts() {
    DNS_CONFLICTS=""
    _pm_check check_dns_conflicts || return 2
    for _dc_p in $DNS_PKG_CANDIDATES; do
        if pkg_installed "$_dc_p" || [ -x "$INITD_DIR/$_dc_p" ]; then
            DNS_CONFLICTS="$DNS_CONFLICTS $_dc_p"
        fi
    done
    if pkg_installed dnsmasq-full && _dnsmasq_customized; then
        DNS_CONFLICTS="$DNS_CONFLICTS dnsmasq-full"
    fi
    DNS_CONFLICTS=${DNS_CONFLICTS# }
    log_info check_dns_conflicts "DNS_CONFLICTS=[$DNS_CONFLICTS]"
    [ -n "$DNS_CONFLICTS" ]
}

# ======================================================================
# 5. ПАКЕТНЫЙ СЛОЙ (opkg / apk за единым API)
# ======================================================================
# Только здесь разрешены прямые вызовы opkg/apk. Флаг --allow-untrusted
# не используется нигде.

OPKG_FEEDS="/etc/opkg/customfeeds.conf"
OPKG_KEYDIR="/etc/opkg/keys"
APK_FEEDS="/etc/apk/repositories.d/customfeeds.list"
APK_KEYDIR="/etc/apk/keys"
APK_ARCH_FILE="/etc/apk/arch"
FEEDS_LEDGER="/etc/tailscale-installer.feeds"   # строки NAME|URL|KEYID
KEY_MAX_BYTES=4096

_pm_check() { # FUNC
    case "$PKG_MGR" in
        opkg|apk) return 0 ;;
    esac
    err "$1" PKG_NO_MGR
    return 1
}

_pkg_name_ok() {
    case "$1" in
        ''|*[!A-Za-z0-9._+-]*) return 1 ;;
    esac
    return 0
}

pkg_update() {
    _pm_check pkg_update || return 1
    case "$PKG_MGR" in
        opkg) run_ext opkg update ;;
        apk)  run_ext apk update ;;
    esac
    _pu_rc=$?
    if [ "$_pu_rc" -ne 0 ]; then
        err pkg_update PKG_UPDATE_FAIL
    fi
    return "$_pu_rc"
}

pkg_install() { # PKG...
    _pm_check pkg_install || return 1
    [ $# -gt 0 ] || return 1
    for _pi_p in "$@"; do
        if ! _pkg_name_ok "$_pi_p"; then
            err pkg_install PKG_BAD_NAME "$_pi_p"
            return 1
        fi
    done
    case "$PKG_MGR" in
        opkg) run_ext opkg install "$@" ;;
        apk)  run_ext apk add "$@" ;;
    esac
    _pi_rc=$?
    if [ "$_pi_rc" -ne 0 ]; then
        err pkg_install PKG_INSTALL_FAIL "$*"
    fi
    return "$_pi_rc"
}

pkg_remove() { # PKG...
    _pm_check pkg_remove || return 1
    [ $# -gt 0 ] || return 1
    for _pr_p in "$@"; do
        if ! _pkg_name_ok "$_pr_p"; then
            err pkg_remove PKG_BAD_NAME "$_pr_p"
            return 1
        fi
    done
    case "$PKG_MGR" in
        opkg) run_ext opkg remove "$@" ;;
        apk)  run_ext apk del "$@" ;;
    esac
    _pr_rc=$?
    if [ "$_pr_rc" -ne 0 ]; then
        err pkg_remove PKG_REMOVE_FAIL "$*"
    fi
    return "$_pr_rc"
}

pkg_installed() { # PKG  (тихая проверка, без сообщений)
    _pkg_name_ok "$1" || return 1
    case "$PKG_MGR" in
        opkg) opkg status "$1" 2>/dev/null | grep -q '^Status:.* installed$' ;;
        apk)  apk info -e "$1" >/dev/null 2>&1 ;;
        *)    return 1 ;;
    esac
}

pkg_available() { # PKG  (есть в фидах)
    _pkg_name_ok "$1" || return 1
    case "$PKG_MGR" in
        opkg) opkg info "$1" 2>/dev/null | grep -q '^Package: ' ;;
        apk)  apk search -e "$1" 2>/dev/null | grep -q . ;;
        *)    return 1 ;;
    esac
}

pkg_version() { # PKG -> версия установленного пакета (stdout)
    _pkg_name_ok "$1" || return 1
    _pv_name=$1
    case "$PKG_MGR" in
        opkg)
            _pv_v=$(opkg list-installed "$_pv_name" 2>/dev/null | sed -n "s/^$_pv_name - //p" | head -n 1)
            ;;
        apk)
            _pv_line=$(apk list -I "$_pv_name" 2>/dev/null | head -n 1)
            _pv_first=${_pv_line%% *}
            case "$_pv_first" in
                "$_pv_name"-[0-9]*) _pv_v=${_pv_first#"$_pv_name"-} ;;
                *) _pv_v="" ;;
            esac
            ;;
        *) return 1 ;;
    esac
    [ -n "$_pv_v" ] || return 1
    printf '%s' "$_pv_v"
}

# Архитектура устройства от пакетного менеджера (как в командах автора фида):
#  opkg: последняя строка "arch NAME PRIO" вывода print-architecture
#  apk:  первая строка /etc/apk/arch
pkg_arch() {
    case "$PKG_MGR" in
        opkg)
            opkg print-architecture 2>/dev/null \
                | sed -n 's/^arch \([^ ][^ ]*\) [0-9][0-9]*\r\{0,1\}$/\1/p' | tail -n 1
            ;;
        apk)
            [ -r "$APK_ARCH_FILE" ] || return 1
            head -n 1 "$APK_ARCH_FILE" 2>/dev/null | tr -d ' \r\n'
            ;;
        *) return 1 ;;
    esac
}

# Поле установленного пакета (пока только opkg; для apk возврат 1).
pkg_field() { # PKG FIELD
    _pkg_name_ok "$1" || return 1
    case "$2" in ''|*[!A-Za-z0-9-]*) return 1 ;; esac
    case "$PKG_MGR" in
        opkg)
            _pf_v=$(opkg status "$1" 2>/dev/null | sed -n "s/^$2: //p" | head -n 1)
            [ -n "$_pf_v" ] || return 1
            printf '%s' "$_pf_v"
            ;;
        *) return 1 ;;
    esac
}

# Установка локального .ipk (только opkg). Для apk не поддерживается:
# локальный .apk без подписи ставится лишь с --allow-untrusted, а он запрещён.
pkg_install_file() { # FILE.ipk
    _pm_check pkg_install_file || return 1
    [ "$PKG_MGR" = opkg ] || return 1
    case "$1" in
        *.ipk) ;;
        *) err pkg_install_file PKG_BAD_NAME "$1"; return 1 ;;
    esac
    [ -f "$1" ] || return 1
    run_ext opkg install "$1"
    _pif_rc=$?
    if [ "$_pif_rc" -ne 0 ]; then
        err pkg_install_file PKG_INSTALL_FAIL "$1"
    fi
    return "$_pif_rc"
}

# Защита от перезаписи пакета чужим фидом/апгрейдом.
#  opkg: флаг hold.
#  apk:  версионное ограничение в world через "apk add имя=версия"
#        (без ручной правки /etc/apk/world). Проверка "apk upgrade --simulate"
#        выполняется ДО и ПОСЛЕ: ограничение откатывается только если замер
#        до пина был чистым, а после пина упал (иначе чужие проблемы в системе,
#        например сломанная зависимость стороннего пакета, давали бы ложный
#        откат). Если замер до пина уже падает - проверка пропускается и это
#        пишется в лог. Семантика --simulate в apk-tools 3 проверяется на роутере.
pkg_hold() { # PKG
    _pm_check pkg_hold || return 1
    _pkg_name_ok "$1" || { err pkg_hold PKG_BAD_NAME "$1"; return 1; }
    case "$PKG_MGR" in
        opkg)
            if ! run_ext opkg flag hold "$1"; then
                err pkg_hold PKG_HOLD_FAIL "$1"
                return 1
            fi
            ;;
        apk)
            if ! _ph_ver=$(pkg_version "$1"); then
                err pkg_hold PKG_HOLD_FAIL "$1"
                return 1
            fi
            run_ext apk upgrade --simulate
            _ph_base=$?
            if ! run_ext apk add "$1=$_ph_ver"; then
                run_ext apk add "$1"
                err pkg_hold PKG_HOLD_FAIL "$1"
                return 1
            fi
            if [ "$_ph_base" -eq 0 ]; then
                if ! run_ext apk upgrade --simulate; then
                    run_ext apk add "$1"
                    err pkg_hold PKG_HOLD_FAIL "$1"
                    return 1
                fi
            else
                log_warn pkg_hold "baseline 'apk upgrade --simulate' failed (rc=$_ph_base), verification skipped"
            fi
            ;;
    esac
    return 0
}

pkg_unhold() { # PKG
    _pm_check pkg_unhold || return 1
    _pkg_name_ok "$1" || { err pkg_unhold PKG_BAD_NAME "$1"; return 1; }
    case "$PKG_MGR" in
        opkg) run_ext opkg flag unhold "$1" ;;
        apk)  run_ext apk add "$1" ;;
    esac
    _pu2_rc=$?
    if [ "$_pu2_rc" -ne 0 ]; then
        err pkg_unhold PKG_UNHOLD_FAIL "$1"
    fi
    return "$_pu2_rc"
}

pkg_upgrade_pkg() { # PKG
    _pm_check pkg_upgrade_pkg || return 1
    _pkg_name_ok "$1" || { err pkg_upgrade_pkg PKG_BAD_NAME "$1"; return 1; }
    case "$PKG_MGR" in
        opkg) run_ext opkg upgrade "$1" ;;
        apk)  run_ext apk add -u "$1" ;;
    esac
    _pg_rc=$?
    if [ "$_pg_rc" -ne 0 ]; then
        err pkg_upgrade_pkg PKG_INSTALL_FAIL "$1"
    fi
    return "$_pg_rc"
}

# ---- загрузка файлов ---------------------------------------------------------

fetch_file() { # URL DEST
    if command -v uclient-fetch >/dev/null 2>&1; then
        run_ext uclient-fetch -q -O "$2" "$1"
    elif command -v wget >/dev/null 2>&1; then
        run_ext wget -q -O "$2" "$1"
    else
        return 127
    fi
}

# ---- проверка публичного ключа ---------------------------------------------------
# opkg: ключ usign - строка "untrusted comment: ..." и 56 символов base64 ("RW...").
# apk:  PEM "-----BEGIN PUBLIC KEY-----" ... "-----END PUBLIC KEY-----".
# Файл только с идентификатором ключа (16 hex) - не ключ: отдельная причина.
# Результат причины - в KEY_ERR (id_only | usign | pem).

KEY_ERR=""

_key_is_id_only() { # FILE
    _ki_c=$(tr -d ' \t\r\n' <"$1")
    [ "${#_ki_c}" -eq 16 ] || return 1
    case "$_ki_c" in *[!0-9a-fA-F]*) return 1 ;; esac
    return 0
}

_key_check_usign() { # FILE
    _ku_l1=$(sed -n 1p "$1")
    _ku_l2=$(sed -n 2p "$1")
    _ku_l3=$(sed -n 3p "$1")
    case "$_ku_l1" in 'untrusted comment:'*) ;; *) return 1 ;; esac
    [ -z "$_ku_l3" ] || return 1
    [ "${#_ku_l2}" -eq 56 ] || return 1
    case "$_ku_l2" in RW*) ;; *) return 1 ;; esac
    case "$_ku_l2" in *[!A-Za-z0-9+/]*) return 1 ;; esac
    return 0
}

_key_check_pem() { # FILE
    _kp_first=$(sed -n 1p "$1")
    _kp_last=$(sed -n '$p' "$1")
    [ "$_kp_first" = "-----BEGIN PUBLIC KEY-----" ] || return 1
    [ "$_kp_last" = "-----END PUBLIC KEY-----" ] || return 1
    _kp_body=$(sed '1d;$d' "$1")
    [ -n "$_kp_body" ] || return 1
    [ -z "$(printf '%s\n' "$_kp_body" | tr -d 'A-Za-z0-9+/=\n')" ] || return 1
    return 0
}

key_validate() { # FILE (CR уже убраны)
    KEY_ERR=""
    if _key_is_id_only "$1"; then
        KEY_ERR=id_only
        return 1
    fi
    case "$PKG_MGR" in
        opkg)
            if _key_check_usign "$1"; then return 0; fi
            KEY_ERR=usign
            ;;
        apk)
            if _key_check_pem "$1"; then return 0; fi
            KEY_ERR=pem
            ;;
    esac
    return 1
}

# ---- репозитории -----------------------------------------------------------------
# Все записи помечены именем (opkg: src/gz tsi_<имя>; apk: комментарий
# "# tsi:<имя>" перед URL), чужие записи не затрагиваются.

_feed_name_ok() {
    case "$1" in
        ''|*[!a-z0-9_]*) return 1 ;;
    esac
    return 0
}

_feed_url_ok() {
    case "$1" in https://*) ;; *) return 1 ;; esac
    _fu_r=${1#https://}
    case "$_fu_r" in
        ''|*[!A-Za-z0-9._:/~+-]*) return 1 ;;
    esac
    return 0
}

_feed_files() { # -> FEEDS_FILE KEYDIR
    case "$PKG_MGR" in
        opkg) _FEEDS_FILE="$OPKG_FEEDS"; _FEEDS_KEYDIR="$OPKG_KEYDIR" ;;
        apk)  _FEEDS_FILE="$APK_FEEDS";  _FEEDS_KEYDIR="$APK_KEYDIR" ;;
    esac
}

# Переписывает файл без записей имени NAME. KIND: opkg | apk | ledger.
_feed_file_drop() { # FILE NAME KIND
    [ -f "$1" ] || return 0
    _fd_tmp="$1.tmp.$$"
    _fd_skip=0
    {
        while IFS= read -r _fd_line || [ -n "$_fd_line" ]; do
            if [ "$_fd_skip" -eq 1 ]; then
                _fd_skip=0
                continue
            fi
            case "$3" in
                opkg)
                    case "$_fd_line" in "src/gz tsi_$2 "*) continue ;; esac
                    ;;
                apk)
                    if [ "$_fd_line" = "# tsi:$2" ]; then
                        _fd_skip=1
                        continue
                    fi
                    ;;
                ledger)
                    case "$_fd_line" in "$2|"*) continue ;; esac
                    ;;
            esac
            printf '%s\n' "$_fd_line"
        done <"$1"
    } >"$_fd_tmp" 2>/dev/null
    if [ $? -ne 0 ] || ! mv "$_fd_tmp" "$1" 2>/dev/null; then
        rm -f "$_fd_tmp"
        err _feed_file_drop FEED_WRITE_FAIL "$1"
        return 1
    fi
    return 0
}

_ledger_keyid() { # NAME -> keyid
    [ -f "$FEEDS_LEDGER" ] || return 1
    while IFS= read -r _lk_line || [ -n "$_lk_line" ]; do
        case "$_lk_line" in
            "$1|"*)
                printf '%s' "${_lk_line##*|}"
                return 0
                ;;
        esac
    done <"$FEEDS_LEDGER"
    return 1
}

feed_exists() { # NAME
    _ledger_keyid "$1" >/dev/null 2>&1
}

# Добавление стороннего репозитория. Подтверждение ВСТРОЕНО сюда: вызвать
# без подтверждения пользователя нельзя (неинтерактивно -> возврат 2).
# Правило подтверждений: фид (подпись проверяет менеджер) = ask_yn;
# небезопасный direct (файл без проверки подписи) = ask_typed_yes.
# Необязательный 4-й аргумент - sha256 ключа, зафиксированный в скрипте. Он
# позволяет добавить фид БЕЗ вопроса в неинтерактивном режиме, но только если
# скачанный ключ ему равен; несовпадение в неинтерактивном режиме - отказ
# (возможна смена ключа автором или подмена), в интерактивном - предупреждение
# и обычное подтверждение.
# Возврат: 0 - добавлен (или уже был), 1 - ошибка, 2 - отказ / нет ввода.
feed_add() { # NAME URL KEY_URL [PIN_SHA256]
    _fa_name=$1
    _fa_url=$2
    _fa_keyurl=$3
    _fa_pin=$4
    _pm_check feed_add || return 1
    if ! _feed_name_ok "$_fa_name"; then
        err feed_add FEED_NAME_BAD
        return 1
    fi
    if ! _feed_url_ok "$_fa_url"; then
        err feed_add FEED_URL_BAD "$_fa_url"
        return 1
    fi
    if ! _feed_url_ok "$_fa_keyurl"; then
        err feed_add FEED_URL_BAD "$_fa_keyurl"
        return 1
    fi
    if feed_exists "$_fa_name"; then
        say feed_add FEED_EXISTS "$_fa_name"
        return 0
    fi
    if [ -n "$_fa_pin" ]; then
        case "$_fa_pin" in
            *[!0-9a-f]*) err feed_add FEED_PIN_BAD; return 1 ;;
        esac
        [ "${#_fa_pin}" -eq 64 ] || { err feed_add FEED_PIN_BAD; return 1; }
    fi
    if [ "$NONINTERACTIVE" = 1 ] && [ -z "$_fa_pin" ]; then
        warn feed_add FEED_NONINTERACTIVE
        return 2
    fi

    _fa_raw="$RUNDIR/feedkey.$$"
    _fa_key="$RUNDIR/feedkey.$$.n"
    if ! fetch_file "$_fa_keyurl" "$_fa_raw"; then
        rm -f "$_fa_raw" "$_fa_key"
        err feed_add FEED_FETCH_FAIL "$_fa_keyurl"
        return 1
    fi
    _fa_size=$(wc -c <"$_fa_raw" 2>/dev/null)
    if [ -z "$_fa_size" ] || [ "$_fa_size" -eq 0 ] || [ "$_fa_size" -gt "$KEY_MAX_BYTES" ]; then
        rm -f "$_fa_raw" "$_fa_key"
        err feed_add FEED_KEY_INVALID "size"
        return 1
    fi
    tr -d '\r' <"$_fa_raw" >"$_fa_key"
    rm -f "$_fa_raw"
    if ! key_validate "$_fa_key"; then
        rm -f "$_fa_key"
        if [ "$KEY_ERR" = id_only ]; then
            err feed_add FEED_KEY_ID_ONLY
        else
            err feed_add FEED_KEY_INVALID "$KEY_ERR"
        fi
        return 1
    fi

    # shellcheck disable=SC2046
    set -- $(sha256sum "$_fa_key")
    _fa_fp=$1
    _fa_pinned=0
    if [ -n "$_fa_pin" ]; then
        if [ "$_fa_fp" = "$_fa_pin" ]; then
            _fa_pinned=1
        elif [ "$NONINTERACTIVE" = 1 ]; then
            rm -f "$_fa_key"
            err feed_add FEED_PIN_FATAL "$_fa_fp"
            return 1
        else
            warn feed_add FEED_PIN_MISMATCH "$_fa_fp"
        fi
    fi
    if [ "$NONINTERACTIVE" = 1 ] && [ "$_fa_pinned" -eq 1 ]; then
        log_info feed_add "key matches the pinned sha256, confirmation skipped"
    else
        ask_yn FEED_CONFIRM "$_fa_name" "$_fa_url" "$_fa_keyurl" "$_fa_fp"
        _fa_ans=$?
        if [ "$_fa_ans" -ne 0 ]; then
            rm -f "$_fa_key"
            say feed_add FEED_DECLINED
            return 2
        fi
    fi

    # Импорт ключа
    _feed_files
    mkdir -p "$_FEEDS_KEYDIR" 2>/dev/null
    case "$PKG_MGR" in
        opkg)
            if ! command -v usign >/dev/null 2>&1; then
                rm -f "$_fa_key"
                err feed_add FEED_KEYTOOL_MISSING
                return 1
            fi
            if ! _fa_id=$(usign -F -p "$_fa_key") || [ -z "$_fa_id" ]; then
                rm -f "$_fa_key"
                err feed_add FEED_KEY_INVALID "usign"
                return 1
            fi
            case "$_fa_id" in *[!0-9a-fA-F]*)
                rm -f "$_fa_key"
                err feed_add FEED_KEY_INVALID "usign"
                return 1
                ;;
            esac
            ;;
        apk)
            _fa_id="tsi-$_fa_name.pub"
            ;;
    esac
    rollback_push feed_remove "$_fa_name"
    if ! cp "$_fa_key" "$_FEEDS_KEYDIR/$_fa_id" 2>/dev/null; then
        rm -f "$_fa_key"
        err feed_add FEED_WRITE_FAIL "$_FEEDS_KEYDIR/$_fa_id"
        feed_remove "$_fa_name"
        return 1
    fi
    chmod 644 "$_FEEDS_KEYDIR/$_fa_id" 2>/dev/null
    rm -f "$_fa_key"

    # Запись репозитория и учёта
    mkdir -p "$(dirname "$_FEEDS_FILE")" 2>/dev/null
    case "$PKG_MGR" in
        opkg) printf 'src/gz tsi_%s %s\n' "$_fa_name" "$_fa_url" >>"$_FEEDS_FILE" ;;
        apk)  printf '# tsi:%s\n%s\n' "$_fa_name" "$_fa_url" >>"$_FEEDS_FILE" ;;
    esac
    if [ $? -ne 0 ] \
       || ! printf '%s|%s|%s\n' "$_fa_name" "$_fa_url" "$_fa_id" >>"$FEEDS_LEDGER"; then
        err feed_add FEED_WRITE_FAIL "$_FEEDS_FILE"
        feed_remove "$_fa_name"
        return 1
    fi

    if ! pkg_update; then
        err feed_add FEED_UPDATE_FAIL
        feed_remove "$_fa_name"
        return 1
    fi
    say feed_add FEED_ADDED "$_fa_name"
    return 0
}

# Идемпотентно: можно вызывать при частично созданном состоянии (откат).
feed_remove() { # NAME
    _fr_name=$1
    _pm_check feed_remove || return 1
    _feed_name_ok "$_fr_name" || { err feed_remove FEED_NAME_BAD; return 1; }
    _feed_files
    _fr_id=$(_ledger_keyid "$_fr_name")
    if [ -z "$_fr_id" ] && [ "$PKG_MGR" = apk ]; then
        _fr_id="tsi-$_fr_name.pub"
    fi
    case "$_fr_id" in
        ''|*[!A-Za-z0-9._-]*) ;;
        *) rm -f "$_FEEDS_KEYDIR/$_fr_id" ;;
    esac
    _feed_file_drop "$_FEEDS_FILE" "$_fr_name" "$PKG_MGR"
    _feed_file_drop "$FEEDS_LEDGER" "$_fr_name" ledger
    # Сбой обновления индекса не должен ломать откат: предупреждаем, возвращаем 0.
    if pkg_update 2>/dev/null; then
        say feed_remove FEED_REMOVED "$_fr_name"
    else
        warn feed_remove FEED_REMOVE_NO_UPDATE "$_fr_name"
    fi
    return 0
}

# ===================== КОНЕЦ СЛОЁВ 2-3 ==================================

# ======================================================================
# 6. УСТАНОВКА
# ======================================================================
# Порядок вызовов в main() фиксируется здесь (нарушение даёт ложные результаты):
#   install_self                 (до tsi_init, i18n ещё нет)
#   tsi_init -> detect_release -> detect_pkg_mgr -> detect_arch
#   choose_source
#   install_deps                 (ставит kmod-tun, ca-bundle, ...)
#   check_tun                    (ТОЛЬКО после install_deps, иначе ложный минус)
#   check_dns_conflicts          (rc 2 = ошибка, не "нет конфликтов")
#     -> при конфликтах предложить NETFILTER_MODE=off (применяется в слое 8)
#   install_selected             (install_official | install_lite_feed | install_lite_direct)
#   service_enable_start -> register_sysupgrade

# Подписанный фид GuNanOvO (GitHub Pages) и ветка feed (direct). Правятся здесь.
LITE_FEED_BASE="https://gunanovo.github.io/openwrt-tailscale"
LITE_RAW_BASE="https://raw.githubusercontent.com/gunanovo/openwrt-tailscale/refs/heads/feed"
# Ключи фидов скачиваются с raw.githubusercontent.com из тех же веток, по
# которым посчитаны зафиксированные sha256 (без зависимости от Pages).
# Хэши - sha256 файла ключа без символов CR. При смене ключа автором
# неинтерактивная установка откажет (fail closed) до обновления значений.
LITE_KEY_URL_OPKG="${LITE_RAW_BASE}/key-build.pub"
LITE_KEY_URL_APK="${LITE_RAW_BASE}/key-build.rsa.pub"
LITE_KEY_SHA256_OPKG="f5ca65c0fa07c24bd5f6b003ccf928cd9e98f33acf8f9474d535a7c4752c1f80"
LITE_KEY_SHA256_APK="83dae13616cd902b79a84ede91417952a59d9c35e2cd216b05b3ea45eba83dd5"
# Плейсхолдер: подставить реальный URL публикации скрипта.
TSI_URL="_https://raw.githubusercontent.com/Archmage90105/tsi/refs/tags/v0.7.0/tsi.sh
SELF_DEST="/usr/bin/tsi"
INIT_SCRIPT="/etc/init.d/tailscale"
SYSUPGRADE_BASE_PATHS="/usr/bin/tsi /etc/tailscale-installer.conf /etc/tailscale-installer.feeds /etc/config/tailscale /etc/tailscale/ /var/lib/tailscale/"

SOURCE_CHOICE=""    # official | lite_feed | lite_direct (результат choose_source)

# ---- 6.1 install_self ---------------------------------------------------
# Копия себя в постоянное место. Запуск - двухшаговый:
#   wget -O /tmp/tsi.sh <URL> && sh /tmp/tsi.sh
# При пайпе (wget | sh) $0 - интерпретатор, файла нет: копировать нечего,
# выводим подсказку и выходим с кодом 1. Сообщения двуязычные (до i18n).

_is_pipe_run() {
    [ -z "$0" ] && return 0
    [ -f "$0" ] || return 0
    case "$0" in
        /bin/sh|/bin/ash|/bin/dash|/bin/bash|/usr/bin/sh|/usr/bin/bash|*/busybox)
            return 0
            ;;
    esac
    return 1
}

_self_hint_cmd() {
    if [ "$TSI_URL" = "__PLACEHOLDER__" ]; then
        printf '  wget -O /tmp/tsi.sh <URL> && sh /tmp/tsi.sh\n'
    else
        printf '  wget -O /tmp/tsi.sh %s && sh /tmp/tsi.sh\n' "$TSI_URL"
    fi
}

# Абсолютный нормализованный путь (относительный $0, симлинки каталога и
# самого файла): readlink -f, если есть, иначе cd + pwd -P (симлинк самого
# файла в этом варианте не разворачивается).
_abs_path() { # FILE
    if _ap_r=$(readlink -f "$1" 2>/dev/null) && [ -n "$_ap_r" ]; then
        printf '%s' "$_ap_r"
        return 0
    fi
    _ap_d=$(cd "$(dirname "$1")" 2>/dev/null && pwd -P) || return 1
    printf '%s/%s' "${_ap_d%/}" "$(basename "$1")"
}

install_self() {
    if _is_pipe_run; then
        printf '\nERROR: this script must be saved to a file first.\n'
        printf 'It cannot copy itself when run as a pipe (wget ... | sh).\nRun it like this:\n'
        _self_hint_cmd
        printf '\nОШИБКА: этот скрипт нужно сначала сохранить в файл.\n'
        printf 'Он не может скопировать себя при запуске через пайп.\nЗапустите так:\n'
        _self_hint_cmd
        printf '\n'
        return 1
    fi
    _is_me=$(_abs_path "$0")
    _is_dst=$(_abs_path "$SELF_DEST")
    if [ -n "$_is_me" ] && [ "$_is_me" = "$_is_dst" ]; then
        return 0
    fi
    _is_dir=$(dirname "$SELF_DEST")
    if [ ! -d "$_is_dir" ]; then
        mkdir -p "$_is_dir" 2>/dev/null
    fi
    if [ ! -w "$_is_dir" ]; then
        printf 'Warning: cannot write to %s, tsi alias not created.\n' "$_is_dir" >&2
        printf 'Внимание: нет записи в %s, алиас tsi не создан.\n' "$_is_dir" >&2
        return 0
    fi
    if cp "$0" "$SELF_DEST" 2>/dev/null; then
        chmod 755 "$SELF_DEST" 2>/dev/null
    else
        printf 'Warning: failed to copy self to %s.\n' "$SELF_DEST" >&2
        printf 'Внимание: не удалось скопировать себя в %s.\n' "$SELF_DEST" >&2
    fi
    return 0
}

# ---- 6.2 install_deps ---------------------------------------------------
# Списки пакетов нужны уже для проверки доступности (pkg_available), поэтому
# pkg_update выполняется ДО неё, но только если чего-то не хватает.
# usign нужен для feed_add на opkg.

_ssl_ok() {
    ls /usr/lib/libustream*.so* /lib/libustream*.so* >/dev/null 2>&1
}

install_deps() {
    _id_need=""
    for _id_p in kmod-tun ca-bundle; do
        if ! pkg_installed "$_id_p"; then
            _id_need="$_id_need $_id_p"
        fi
    done
    _id_fetch=0
    if ! command -v uclient-fetch >/dev/null 2>&1 \
       && ! command -v wget >/dev/null 2>&1; then
        _id_fetch=1
    fi
    _id_ssl=0
    _ssl_ok || _id_ssl=1
    _id_usign=0
    if [ "$PKG_MGR" = opkg ] && ! command -v usign >/dev/null 2>&1; then
        _id_usign=1
    fi
    if [ -z "$_id_need" ] && [ "$_id_fetch" -eq 0 ] && [ "$_id_ssl" -eq 0 ] \
       && [ "$_id_usign" -eq 0 ]; then
        return 0
    fi

    pkg_update || return 1
    if [ "$_id_fetch" -eq 1 ]; then
        _id_need="$_id_need uclient-fetch"
    fi
    if [ "$_id_ssl" -eq 1 ]; then
        for _id_p in libustream-openssl libustream-wolfssl libustream-mbedtls; do
            if pkg_available "$_id_p"; then
                _id_need="$_id_need $_id_p"
                break
            fi
        done
    fi
    if [ "$_id_usign" -eq 1 ] && pkg_available usign; then
        _id_need="$_id_need usign"
    fi
    _id_need=${_id_need# }
    [ -n "$_id_need" ] || return 0

    say install_deps INSTALL_DEPS_TITLE "$_id_need"
    if ! pkg_install $_id_need; then
        err install_deps INSTALL_DEPS_FAIL "$_id_need"
        return 1
    fi
    say install_deps INSTALL_DEPS_OK
    return 0
}

# ---- 6.3 feed_arch / feed_precheck ---------------------------------------
# Архитектура для путей фида - от пакетного менеджера (pkg_arch), как в
# командах автора фида; fallback - DISTRIB_ARCH с предупреждением.
# Значение уходит в URL: допускаются только A-Za-z0-9._-

feed_arch() {
    _fa_a=$(pkg_arch)
    case "$_fa_a" in
        ''|*[!A-Za-z0-9._-]*) _fa_a="" ;;
    esac
    if [ -z "$_fa_a" ] && [ -n "$REL_ARCH" ]; then
        case "$REL_ARCH" in
            *[!A-Za-z0-9._-]*) ;;
            *)
                _fa_a=$REL_ARCH
                warn feed_arch FEED_ARCH_FALLBACK "$_fa_a"
                ;;
        esac
    fi
    printf '%s' "$_fa_a"
    [ -n "$_fa_a" ]
}

# Индекс фида для архитектуры и текущего менеджера (у riscv64_generic нет
# индекса opkg, у mips_4kec и riscv64_riscv64 нет индекса apk).
feed_precheck() { # ARCH
    _fp_arch=$1
    case "$PKG_MGR" in
        opkg) _fp_url="${LITE_FEED_BASE}/${_fp_arch}/Packages.gz" ;;
        apk)  _fp_url="${LITE_FEED_BASE}/${_fp_arch}/packages.adb" ;;
        *)    return 1 ;;
    esac
    _fp_tmp="$RUNDIR/feedprecheck.$$"
    if ! fetch_file "$_fp_url" "$_fp_tmp"; then
        rm -f "$_fp_tmp"
        return 1
    fi
    _fp_size=$(wc -c <"$_fp_tmp" 2>/dev/null)
    rm -f "$_fp_tmp"
    [ -n "$_fp_size" ] && [ "$_fp_size" -gt 0 ]
}

# ---- 6.4 choose_source / install_selected --------------------------------
# choose_source только выбирает (SOURCE_CHOICE). В конфиг выбор попадает
# после УСПЕШНОЙ установки (_source_save), чтобы конфиг не врал о том,
# чего на роутере нет. direct предлагается только на 24.10 + opkg.

choose_source() {
    _cs_valid="1 2"
    if [ "$PKG_MGR" = opkg ] && ! rel_ge 25 12; then
        _cs_valid="1 2 3"
    fi
    msg CHOOSE_SOURCE_TITLE
    msg CHOOSE_SOURCE_OFFICIAL
    msg CHOOSE_SOURCE_LITE_FEED
    if [ "$_cs_valid" = "1 2 3" ]; then
        msg CHOOSE_SOURCE_LITE_DIRECT
    fi
    SOURCE_CHOICE=""
    ask_choice CHOOSE_SOURCE_PROMPT "$_cs_valid" || return 1
    case "$ASK_REPLY" in
        1) SOURCE_CHOICE=official ;;
        2) SOURCE_CHOICE=lite_feed ;;
        3) SOURCE_CHOICE=lite_direct ;;
    esac
    log_info choose_source "SOURCE_CHOICE=$SOURCE_CHOICE"
    return 0
}

_source_save() { # A|B [feed|direct]
    conf_set INSTALL_SOURCE "$1" || return 1
    if [ -n "$2" ]; then
        conf_set B_SUBMODE "$2" || return 1
    else
        conf_unset B_SUBMODE || return 1
    fi
    return 0
}

install_selected() {
    case "$SOURCE_CHOICE" in
        official)    install_official ;;
        lite_feed)   install_lite_feed ;;
        lite_direct) install_lite_direct ;;
        *)           return 1 ;;
    esac
}

# ---- 6.5 install_official -------------------------------------------------
install_official() {
    say install_official INSTALL_OFFICIAL_TITLE
    pkg_update || return 1
    _io_pkgs="tailscale"
    if pkg_available tailscaled; then
        _io_pkgs="tailscale tailscaled"
    fi
    if ! pkg_install $_io_pkgs; then
        err install_official INSTALL_OFFICIAL_FAIL "$_io_pkgs"
        return 1
    fi
    _source_save A "" || return 1
    say install_official INSTALL_OFFICIAL_OK
    return 0
}

# ---- 6.6 install_lite_feed --------------------------------------------------
# Если одноимённый пакет есть и в официальном фиде, менеджер выбирает по
# версии, а не по фиду. Поэтому после установки сверяем происхождение
# (поле Maintainer, пока только opkg) и предупреждаем.
_lite_origin_check() {
    _lo_m=$(pkg_field tailscale Maintainer) || return 0
    case "$_lo_m" in
        GuNan*) return 0 ;;
    esac
    warn install_lite_feed INSTALL_LITE_ORIGIN_WARN
    return 0
}

install_lite_feed() {
    say install_lite_feed INSTALL_LITE_FEED_TITLE
    _lf_arch=$(feed_arch)
    if [ -z "$_lf_arch" ] || ! feed_precheck "$_lf_arch"; then
        err install_lite_feed FEED_ARCH_UNAVAILABLE
        return 1
    fi
    case "$PKG_MGR" in
        opkg)
            _lf_url="${LITE_FEED_BASE}/${_lf_arch}"
            _lf_keyurl="$LITE_KEY_URL_OPKG"
            _lf_pin="$LITE_KEY_SHA256_OPKG"
            ;;
        apk)
            _lf_url="${LITE_FEED_BASE}/${_lf_arch}/packages.adb"
            _lf_keyurl="$LITE_KEY_URL_APK"
            _lf_pin="$LITE_KEY_SHA256_APK"
            ;;
        *)
            err install_lite_feed PKG_NO_MGR
            return 1
            ;;
    esac
    feed_add lite "$_lf_url" "$_lf_keyurl" "$_lf_pin"
    _lf_rc=$?
    if [ "$_lf_rc" -ne 0 ]; then
        return "$_lf_rc"
    fi
    pkg_update || return 1
    if ! pkg_install tailscale; then
        err install_lite_feed INSTALL_LITE_FEED_FAIL
        return 1
    fi
    _lite_origin_check
    if ! pkg_hold tailscale; then
        warn install_lite_feed PKG_HOLD_FAIL tailscale
    fi
    _source_save B feed || return 1
    say install_lite_feed INSTALL_LITE_FEED_OK
    return 0
}

# ---- 6.7 install_lite_direct ------------------------------------------------
# Только opkg (24.10). Пакет ставится через менеджер (pkg_install_file):
# регистрируется в базе, hold/remove/pkg_version работают штатно, init-скрипт
# и /etc/config/tailscale лежат внутри .ipk. Хэш - из ipk.sha256 (имя файла
# фиксированное, лежит в каталоге архитектуры): защита от битой загрузки,
# не от компрометации источника. Подпись пакета здесь НЕ проверяется,
# поэтому подтверждение - ввод слова yes.

# Архитектура бинарника в .ipk: читаем только первые 64 байта потоком
# (без распаковки в ОЗУ).
_ipk_binary_arch() { # FILE.ipk
    _ib_hdr="$RUNDIR/elfhdr.$$"
    tar -xzOf "$1" ./data.tar.gz 2>/dev/null \
        | tar -xzO -f - ./usr/sbin/tailscaled 2>/dev/null \
        | head -c 64 >"$_ib_hdr"
    _ib_r=$(_arch_from_elf "$_ib_hdr")
    rm -f "$_ib_hdr"
    [ -n "$_ib_r" ] || return 1
    printf '%s' "$_ib_r"
}

# Версия из ветки feed (stdout, формат 1.104.1-r1). При ошибке сообщения
# уже показаны, возврат 1.
_lite_direct_version() { # ARCH
    _lv_base="${LITE_RAW_BASE}/$1"
    _lv_tmp="$RUNDIR/litever.$$"
    if ! fetch_file "$_lv_base/version" "$_lv_tmp"; then
        rm -f "$_lv_tmp"
        err _lite_direct_version INSTALL_LITE_DIRECT_FETCH_FAIL "$_lv_base/version"
        return 1
    fi
    _lv_ver=$(head -n 1 "$_lv_tmp" | tr -d ' \r\n')
    rm -f "$_lv_tmp"
    case "$_lv_ver" in
        ''|*[!0-9A-Za-z._-]*)
            err _lite_direct_version INSTALL_LITE_DIRECT_FETCH_FAIL "version"
            return 1
            ;;
    esac
    log_info _lite_direct_version "version=$_lv_ver"
    printf '%s' "$_lv_ver"
}

# Скачать .ipk, сверить хэш (ipk.sha256 из того же каталога) и ELF-архитектуру,
# установить файл через менеджер. hold здесь не трогается (это делает вызывающий).
_lite_direct_install_pkg() { # ARCH VER
    _ld_base="${LITE_RAW_BASE}/$1"
    _ld_ver=$2
    _ld_ipk="$RUNDIR/tailscale-${_ld_ver}.ipk"
    _ld_sha="$RUNDIR/ipk.sha256"
    if ! fetch_file "$_ld_base/tailscale-${_ld_ver}.ipk" "$_ld_ipk"; then
        rm -f "$_ld_ipk"
        err _lite_direct_install_pkg INSTALL_LITE_DIRECT_FETCH_FAIL "$_ld_base/tailscale-${_ld_ver}.ipk"
        return 1
    fi

    if fetch_file "$_ld_base/ipk.sha256" "$_ld_sha"; then
        _ld_exp=$(head -n 1 "$_ld_sha" | tr -d ' \r\n' | tr 'A-F' 'a-f')
        rm -f "$_ld_sha"
        # shellcheck disable=SC2046
        set -- $(sha256sum "$_ld_ipk")
        if [ -z "$_ld_exp" ] || [ "$_ld_exp" != "$1" ]; then
            rm -f "$_ld_ipk"
            err _lite_direct_install_pkg INSTALL_LITE_DIRECT_SHA_MISMATCH
            return 1
        fi
    else
        rm -f "$_ld_sha"
        warn _lite_direct_install_pkg INSTALL_LITE_DIRECT_NO_SHA
    fi

    _ld_bin=$(_ipk_binary_arch "$_ld_ipk")
    if [ -z "$_ld_bin" ] || [ -z "$TS_ARCH" ]; then
        warn _lite_direct_install_pkg INSTALL_LITE_DIRECT_ARCH_UNKNOWN
    elif [ "$_ld_bin" != "$TS_ARCH" ]; then
        rm -f "$_ld_ipk"
        err _lite_direct_install_pkg INSTALL_LITE_DIRECT_ARCH_MISMATCH "$_ld_bin" "$TS_ARCH"
        return 1
    fi

    if ! pkg_install_file "$_ld_ipk"; then
        rm -f "$_ld_ipk"
        err _lite_direct_install_pkg INSTALL_LITE_DIRECT_INSTALL_FAIL
        return 1
    fi
    rm -f "$_ld_ipk"
    return 0
}

install_lite_direct() {
    if [ "$PKG_MGR" != opkg ]; then
        err install_lite_direct INSTALL_LITE_DIRECT_WRONG_MGR
        return 1
    fi
    if rel_ge 25 12; then
        err install_lite_direct INSTALL_LITE_DIRECT_WRONG_VER
        return 1
    fi
    say install_lite_direct INSTALL_LITE_DIRECT_TITLE
    ask_typed_yes INSTALL_LITE_DIRECT_CONFIRM
    if [ $? -ne 0 ]; then
        say install_lite_direct INSTALL_LITE_DIRECT_DECLINED
        return 2
    fi

    _ldi_arch=$(feed_arch)
    if [ -z "$_ldi_arch" ]; then
        err install_lite_direct FEED_ARCH_UNAVAILABLE
        return 1
    fi
    _ldi_ver=$(_lite_direct_version "$_ldi_arch") || return 1
    _lite_direct_install_pkg "$_ldi_arch" "$_ldi_ver" || return 1
    if ! pkg_hold tailscale; then
        warn install_lite_direct PKG_HOLD_FAIL tailscale
    fi
    conf_set LITE_VERSION "$_ldi_ver" || true
    _source_save B direct || return 1
    say install_lite_direct INSTALL_LITE_DIRECT_OK
    return 0
}

# ---- 6.8 service_enable_start -----------------------------------------------
service_enable_start() {
    if [ ! -x "$INIT_SCRIPT" ]; then
        err service_enable_start SERVICE_NO_INIT
        return 1
    fi
    if ! run_ext "$INIT_SCRIPT" enable; then
        err service_enable_start SERVICE_ENABLE_FAIL
        return 1
    fi
    if ! run_ext "$INIT_SCRIPT" start; then
        err service_enable_start SERVICE_START_FAIL
        return 1
    fi
    _ss_tries=0
    while [ "$_ss_tries" -lt 5 ]; do
        if pidof tailscaled >/dev/null 2>&1; then
            say service_enable_start SERVICE_START_OK
            return 0
        fi
        _ss_tries=$((_ss_tries + 1))
        sleep 1
    done
    warn service_enable_start SERVICE_NOT_RUNNING
    return 0
}

# ---- 6.9 register_sysupgrade ------------------------------------------------
# Базовые пути плюс файл фидов и ключи, записанные в учёте фидов: иначе после
# sysupgrade запись о фиде в учёте останется, а ключа не будет.
_sysupgrade_feed_paths() {
    [ -s "$FEEDS_LEDGER" ] || return 0
    case "$PKG_MGR" in opkg|apk) ;; *) return 0 ;; esac
    _feed_files
    printf '%s\n' "$_FEEDS_FILE"
    while IFS= read -r _sf_line || [ -n "$_sf_line" ]; do
        _sf_id=${_sf_line##*|}
        case "$_sf_id" in
            ''|*[!A-Za-z0-9._-]*) ;;
            *) printf '%s/%s\n' "$_FEEDS_KEYDIR" "$_sf_id" ;;
        esac
    done <"$FEEDS_LEDGER"
}

register_sysupgrade() {
    if [ ! -f "$SYSUPGRADE_CONF" ] && ! touch "$SYSUPGRADE_CONF" 2>/dev/null; then
        err register_sysupgrade SYSUPGRADE_FAIL "$SYSUPGRADE_CONF"
        return 1
    fi
    _rs_all="$(for _rs_b in $SYSUPGRADE_BASE_PATHS; do printf '%s\n' "$_rs_b"; done)
$(_sysupgrade_feed_paths)"
    _rs_tmp="$RUNDIR/rs.list.$$"
    printf '%s\n' "$_rs_all" >"$_rs_tmp"
    while IFS= read -r _rs_p || [ -n "$_rs_p" ]; do
        [ -n "$_rs_p" ] || continue
        if ! grep -Fxq "$_rs_p" "$SYSUPGRADE_CONF" 2>/dev/null; then
            if ! printf '%s\n' "$_rs_p" >>"$SYSUPGRADE_CONF" 2>/dev/null; then
                rm -f "$_rs_tmp"
                err register_sysupgrade SYSUPGRADE_FAIL "$SYSUPGRADE_CONF"
                return 1
            fi
        fi
    done <"$_rs_tmp"
    rm -f "$_rs_tmp"
    say register_sysupgrade SYSUPGRADE_UPDATED
    return 0
}

# ===================== КОНЕЦ СЛОЯ 4 ====================================

# ======================================================================
# 7. СЕТЬ И FIREWALL (только через uci, только именованные секции tsi_*)
# ======================================================================
# Модель: интерфейс network.tsi_net (proto none, device tailscale0), зона
# firewall.tsi_zone (name 'tailscale', ACCEPT/ACCEPT/ACCEPT, masq, mtu_fix),
# forwarding tailscale<->lan. Forwarding tailscale->wan (exit node) создаётся
# ОТДЕЛЬНО (fw_wan_forward_on). Чужие секции не трогаем: чужую зону/интерфейс
# ищем по содержимому, а не по id. Откат - удаление секций tsi_* по имени,
# файл целиком не восстанавливается (бэкап в BACKUP_DIR - только страховка).
# Известное ограничение: uci commit фиксирует весь конфиг, поэтому перед
# изменениями проверяем, что чужих незакоммиченных правок нет (fw_remove при
# откате такую проверку не делает).

TS_ZONE_NAME="tailscale"
TS_DEVICE="tailscale0"
FW_INIT="/etc/init.d/firewall"
NET_INIT="/etc/init.d/network"
UCI_CONF_DIR="/etc/config"
CGNAT_TARGET="100.64.0.0"
CGNAT_NETMASK="255.192.0.0"
CGNAT_PROBE="100.64.0.1"
FW_FOREIGN_ZONE=""      # id чужих зон с name 'tailscale' (результат _fw_find_foreign)
FW_FOREIGN_IFACE=""     # id чужих интерфейсов с device tailscale0

_uci_ok() {
    command -v uci >/dev/null 2>&1
}

# 0 - чисто, 1 - есть незакоммиченные изменения, 2 - uci недоступен.
_fw_pending_check() {
    _uci_ok || return 2
    _fwp_ch=$(uci -q changes firewall network 2>/dev/null)
    [ -z "$_fwp_ch" ]
}

# Возврат: 0 - чужие зона/интерфейс найдены (id в FW_FOREIGN_*), 1 - нет.
# Зона считается чужой, если у секции типа zone name='tailscale'; интерфейс -
# если у секции типа interface device (или ifname) 'tailscale0'. Секции
# других типов (например, rule с name 'tailscale') игнорируются.
_fw_find_foreign() {
    FW_FOREIGN_ZONE=""
    FW_FOREIGN_IFACE=""
    _uci_ok || return 1
    _fwf_ids=$(uci -q show firewall 2>/dev/null \
        | sed -n "s/^firewall\\.\\([^.=]*\\)\\.name='$TS_ZONE_NAME'\$/\\1/p")
    for _fwf_id in $_fwf_ids; do
        [ "$_fwf_id" = "$UCI_FW_ZONE" ] && continue
        if [ "$(uci -q get "firewall.$_fwf_id" 2>/dev/null)" = "zone" ]; then
            FW_FOREIGN_ZONE="$FW_FOREIGN_ZONE $_fwf_id"
        fi
    done
    _fwf_ids=$(uci -q show network 2>/dev/null \
        | sed -n "s/^network\\.\\([^.=]*\\)\\.\\(device\\|ifname\\)='$TS_DEVICE'\$/\\1/p")
    for _fwf_id in $_fwf_ids; do
        [ "$_fwf_id" = "$UCI_NET_IFACE" ] && continue
        if [ "$(uci -q get "network.$_fwf_id" 2>/dev/null)" = "interface" ]; then
            FW_FOREIGN_IFACE="$FW_FOREIGN_IFACE $_fwf_id"
        fi
    done
    FW_FOREIGN_ZONE=${FW_FOREIGN_ZONE# }
    FW_FOREIGN_IFACE=${FW_FOREIGN_IFACE# }
    [ -n "$FW_FOREIGN_ZONE$FW_FOREIGN_IFACE" ]
}

_fw_backup() {
    mkdir -p "$BACKUP_DIR" 2>/dev/null || return 1
    for _fwb_c in firewall network; do
        if [ -f "$UCI_CONF_DIR/$_fwb_c" ]; then
            cp "$UCI_CONF_DIR/$_fwb_c" "$BACKUP_DIR/$_fwb_c" 2>/dev/null || return 1
        fi
    done
    return 0
}

_fw_backend() { # nftables | iptables
    if command -v fw4 >/dev/null 2>&1; then
        echo nftables
    else
        echo iptables
    fi
}

# Перечитать правила: сначала network, затем firewall; отсутствующий
# init-скрипт (урезанная сборка) пропускается. Режим: fw-only | net-only.
_fw_reload() { # [fw-only|net-only]
    _fwl_rc=0
    if [ "$1" != "fw-only" ] && [ -x "$NET_INIT" ]; then
        run_ext "$NET_INIT" reload || _fwl_rc=1
    fi
    if [ "$1" != "net-only" ] && [ -x "$FW_INIT" ]; then
        run_ext "$FW_INIT" reload || _fwl_rc=1
    fi
    return "$_fwl_rc"
}

_uci_exists() { # PATH
    uci -q get "$1" >/dev/null 2>&1
}

# Все четыре обязательные секции на месте.
fw_is_setup() {
    _uci_ok || return 1
    for _fws_s in "network.$UCI_NET_IFACE" "firewall.$UCI_FW_ZONE" \
                  "firewall.$UCI_FW_FWD_LAN_IN" "firewall.$UCI_FW_FWD_LAN_OUT"; do
        _uci_exists "$_fws_s" || return 1
    done
    return 0
}

# Есть ли хоть одна наша секция (в том числе wan и route).
_fw_any_ours() {
    for _fwo_s in "network.$UCI_NET_IFACE" "network.$UCI_NET_ROUTE" \
                  "firewall.$UCI_FW_ZONE" "firewall.$UCI_FW_FWD_LAN_IN" \
                  "firewall.$UCI_FW_FWD_LAN_OUT" "firewall.$UCI_FW_FWD_WAN"; do
        _uci_exists "$_fwo_s" && return 0
    done
    return 1
}

_fw_create_sections() {
    run_ext uci set "network.$UCI_NET_IFACE=interface" \
    && run_ext uci set "network.$UCI_NET_IFACE.proto=none" \
    && run_ext uci set "network.$UCI_NET_IFACE.device=$TS_DEVICE" \
    && run_ext uci set "firewall.$UCI_FW_ZONE=zone" \
    && run_ext uci set "firewall.$UCI_FW_ZONE.name=$TS_ZONE_NAME" \
    && run_ext uci set "firewall.$UCI_FW_ZONE.input=ACCEPT" \
    && run_ext uci set "firewall.$UCI_FW_ZONE.output=ACCEPT" \
    && run_ext uci set "firewall.$UCI_FW_ZONE.forward=ACCEPT" \
    && run_ext uci set "firewall.$UCI_FW_ZONE.masq=1" \
    && run_ext uci set "firewall.$UCI_FW_ZONE.mtu_fix=1" \
    && run_ext uci add_list "firewall.$UCI_FW_ZONE.network=$UCI_NET_IFACE" \
    && run_ext uci set "firewall.$UCI_FW_FWD_LAN_IN=forwarding" \
    && run_ext uci set "firewall.$UCI_FW_FWD_LAN_IN.src=$TS_ZONE_NAME" \
    && run_ext uci set "firewall.$UCI_FW_FWD_LAN_IN.dest=lan" \
    && run_ext uci set "firewall.$UCI_FW_FWD_LAN_OUT=forwarding" \
    && run_ext uci set "firewall.$UCI_FW_FWD_LAN_OUT.src=lan" \
    && run_ext uci set "firewall.$UCI_FW_FWD_LAN_OUT.dest=$TS_ZONE_NAME"
}

# Фиксация network+firewall и перечитывание. Сбой commit или reload - ошибка.
_fw_apply() {
    run_ext uci commit network || return 1
    run_ext uci commit firewall || return 1
    if ! _fw_reload; then
        err _fw_apply FW_RELOAD_FAIL
        return 1
    fi
    return 0
}

# Идемпотентно: можно вызывать при любом (в том числе частичном) состоянии.
# Сначала снимает незакоммиченные правки НАШИХ секций, затем удаляет их.
fw_remove() {
    _uci_ok || return 0
    _fwr_any=0
    for _fwr_s in "network.$UCI_NET_IFACE" "network.$UCI_NET_ROUTE" \
                  "firewall.$UCI_FW_ZONE" "firewall.$UCI_FW_FWD_LAN_IN" \
                  "firewall.$UCI_FW_FWD_LAN_OUT" "firewall.$UCI_FW_FWD_WAN"; do
        uci -q revert "$_fwr_s" >/dev/null 2>&1
        if _uci_exists "$_fwr_s"; then
            if uci -q delete "$_fwr_s" >/dev/null 2>&1; then
                _fwr_any=1
            fi
        fi
    done
    if [ "$_fwr_any" -eq 1 ]; then
        run_ext uci commit network
        run_ext uci commit firewall
        _fw_reload || warn fw_remove FW_RELOAD_FAIL
        say fw_remove FW_REMOVED
    fi
    return 0
}

# Основная настройка: интерфейс, зона, forwarding tailscale<->lan, masq.
# Возврат: 0 - готово (или уже было), 1 - ошибка/отказ.
fw_setup() {
    if ! _uci_ok; then
        err fw_setup FW_NO_UCI
        return 1
    fi
    if fw_is_setup; then
        say fw_setup FW_ALREADY
        return 0
    fi
    _fw_pending_check
    if [ $? -ne 0 ]; then
        err fw_setup FW_PENDING
        return 1
    fi
    if _fw_find_foreign; then
        err fw_setup FW_FOREIGN "${FW_FOREIGN_ZONE:--}" "${FW_FOREIGN_IFACE:--}"
        return 1
    fi
    if _fw_any_ours; then
        warn fw_setup FW_PARTIAL
        fw_remove
    fi
    if ! _fw_backup; then
        err fw_setup FW_BACKUP_FAIL "$BACKUP_DIR"
        return 1
    fi
    rollback_push fw_remove
    if ! _fw_create_sections; then
        err fw_setup FW_SETUP_FAIL
        fw_remove
        return 1
    fi
    if ! _fw_apply; then
        err fw_setup FW_SETUP_FAIL
        fw_remove
        return 1
    fi
    say fw_setup FW_SETUP_OK
    return 0
}

# ---- forwarding tailscale -> wan (нужен для exit node) --------------------

fw_wan_forward_state() { # 0 - включён
    _uci_exists "firewall.$UCI_FW_FWD_WAN"
}

fw_wan_forward_on() {
    _uci_ok || { err fw_wan_forward_on FW_NO_UCI; return 1; }
    if ! fw_is_setup; then
        err fw_wan_forward_on FW_NOT_SETUP
        return 1
    fi
    if fw_wan_forward_state; then
        say fw_wan_forward_on FW_WAN_ALREADY
        return 0
    fi
    _fw_pending_check
    if [ $? -ne 0 ]; then
        err fw_wan_forward_on FW_PENDING
        return 1
    fi
    if ! run_ext uci set "firewall.$UCI_FW_FWD_WAN=forwarding" \
       || ! run_ext uci set "firewall.$UCI_FW_FWD_WAN.src=$TS_ZONE_NAME" \
       || ! run_ext uci set "firewall.$UCI_FW_FWD_WAN.dest=wan" \
       || ! run_ext uci commit firewall \
       || ! _fw_reload fw-only; then
        uci -q revert "firewall.$UCI_FW_FWD_WAN" >/dev/null 2>&1
        err fw_wan_forward_on FW_SETUP_FAIL
        return 1
    fi
    say fw_wan_forward_on FW_WAN_ON_OK
    return 0
}

fw_wan_forward_off() {
    _uci_ok || { err fw_wan_forward_off FW_NO_UCI; return 1; }
    if ! fw_wan_forward_state; then
        say fw_wan_forward_off FW_WAN_ALREADY_OFF
        return 0
    fi
    _fw_pending_check
    if [ $? -ne 0 ]; then
        err fw_wan_forward_off FW_PENDING
        return 1
    fi
    if ! run_ext uci delete "firewall.$UCI_FW_FWD_WAN" \
       || ! run_ext uci commit firewall \
       || ! _fw_reload fw-only; then
        err fw_wan_forward_off FW_SETUP_FAIL
        return 1
    fi
    say fw_wan_forward_off FW_WAN_OFF_OK
    return 0
}

# Интерактивный пункт меню: показывает состояние и предлагает переключить.
fw_wan_forward_toggle() {
    if ! fw_is_setup; then
        err fw_wan_forward_toggle FW_NOT_SETUP
        return 1
    fi
    if fw_wan_forward_state; then
        ask_yn FW_WAN_ASK_OFF
        [ $? -eq 0 ] || return 2
        fw_wan_forward_off
    else
        ask_yn FW_WAN_ASK_ON
        [ $? -eq 0 ] || return 2
        fw_wan_forward_on
    fi
}

# ---- маршрут 100.64.0.0/10 (баг на 24.10) --------------------------------
# Только 24.10, только после tailscale up, только при существующем
# tailscale0. Проверка: ip route get 100.64.0.1 должен идти через tailscale0.
# Иначе - постоянный маршрут через uci (network.tsi_route), а не ip route.
route_check_cgnat() {
    if rel_ge 25 12; then
        log_info route_check_cgnat "skipped on $REL_VERSION"
        return 0
    fi
    _uci_ok || return 0
    if ! command -v ip >/dev/null 2>&1; then
        warn route_check_cgnat ROUTE_NO_IP
        return 0
    fi
    if ! ip link show "$TS_DEVICE" >/dev/null 2>&1; then
        log_info route_check_cgnat "$TS_DEVICE not found, skipped"
        return 0
    fi
    _rt_out=$(ip route get "$CGNAT_PROBE" 2>/dev/null)
    case "$_rt_out" in
        *" dev $TS_DEVICE "*|*" dev $TS_DEVICE")
            log_info route_check_cgnat "route via $TS_DEVICE ok"
            return 0
            ;;
    esac
    if _uci_exists "network.$UCI_NET_ROUTE"; then
        warn route_check_cgnat ROUTE_STILL_MISSING
        return 0
    fi
    if ! fw_is_setup; then
        warn route_check_cgnat ROUTE_NO_IFACE
        return 0
    fi
    _fw_pending_check
    if [ $? -ne 0 ]; then
        warn route_check_cgnat FW_PENDING
        return 0
    fi
    if ! run_ext uci set "network.$UCI_NET_ROUTE=route" \
       || ! run_ext uci set "network.$UCI_NET_ROUTE.interface=$UCI_NET_IFACE" \
       || ! run_ext uci set "network.$UCI_NET_ROUTE.target=$CGNAT_TARGET" \
       || ! run_ext uci set "network.$UCI_NET_ROUTE.netmask=$CGNAT_NETMASK" \
       || ! run_ext uci commit network; then
        uci -q revert "network.$UCI_NET_ROUTE" >/dev/null 2>&1
        err route_check_cgnat FW_SETUP_FAIL
        return 1
    fi
    _fw_reload net-only || warn route_check_cgnat FW_RELOAD_FAIL
    say route_check_cgnat ROUTE_ADDED "$CGNAT_TARGET/10"
    return 0
}

# ---- режим firewall-бэкенда для tailscaled -------------------------------
# init-скрипт (оба пакета) читает tailscale.settings.fw_mode и сам кладёт
# значение в TS_DEBUG_FIREWALL_MODE. fw4 есть -> nftables, иначе iptables.
# Нет секции settings - no-op. Перезапуск службы - на стороне вызывающего.
set_fw_debug_mode() {
    _uci_ok || return 0
    if [ "$(uci -q get tailscale.settings 2>/dev/null)" != "settings" ]; then
        log_info set_fw_debug_mode "tailscale.settings not found, skipped"
        return 0
    fi
    _sd_want=$(_fw_backend)
    _sd_cur=$(uci -q get tailscale.settings.fw_mode 2>/dev/null)
    if [ "$_sd_cur" = "$_sd_want" ]; then
        return 0
    fi
    if ! run_ext uci set "tailscale.settings.fw_mode=$_sd_want" \
       || ! run_ext uci commit tailscale; then
        err set_fw_debug_mode FW_MODE_FAIL
        return 1
    fi
    say set_fw_debug_mode FW_MODE_SET "$_sd_want"
    return 0
}

# ===================== КОНЕЦ СЛОЯ 5 ====================================

# ======================================================================
# 8. TAILSCALE UP, РЕЖИМ NETFILTER, ИНСТРУКЦИИ
# ======================================================================
# Порядок в main() при установке:
#   install_self -> tsi_init -> detect_release -> detect_pkg_mgr -> detect_arch
#   -> choose_source -> install_deps -> check_tun
#   -> decide_netfilter_mode            (до установки: это свойство системы)
#   -> install_selected -> fw_setup -> set_fw_debug_mode
#   -> service_enable_start -> register_sysupgrade
#   -> run_tailscale_up_flow            (внутри: tailscale up, затем
#                                        route_check_cgnat - только ПОСЛЕ up)
#   -> show_post_install -> (по желанию) install_luci
# TS_ADVERTISE_* живут только в памяти текущего запуска: tailscale up запоминает
# их сам, а при повторном вызове команда собирается из полного набора значений.

TS_ADVERTISE_EXIT_NODE=0
TS_ADVERTISE_ROUTES=""
UP_CMD=""               # строка для показа пользователю (build_up_cmd)
UP_DONE=0               # 1 - tailscale up завершился успешно
UP_AUTH_URL=""          # ссылка авторизации из вывода tailscale up
NETFILTER_FORCE=""      # off | on - из флага командной строки (слой 9)

# ---- 8.1 решение по NETFILTER_MODE ------------------------------------------
# Вызывается ДО установки. Конфликты (podkop, forkop, ...) -> спрашиваем
# (рекомендуется off); нет конфликтов и значение не задано -> on без вопроса;
# уже заданное значение молча не меняем. Неинтерактивно при конфликтах без
# заданного режима - ошибка, а не молчаливое "on".
decide_netfilter_mode() {
    if [ -n "$NETFILTER_FORCE" ]; then
        conf_set NETFILTER_MODE "$NETFILTER_FORCE" || return 1
        return 0
    fi
    check_dns_conflicts
    _dn_rc=$?
    case "$_dn_rc" in
        0)
            say decide_netfilter_mode NF_CONFLICT_INFO "$DNS_CONFLICTS"
            _dn_valid="1 2"
            if [ -n "$CFG_NETFILTER_MODE" ]; then
                say decide_netfilter_mode NF_CURRENT "$CFG_NETFILTER_MODE"
                _dn_valid="1 2 3"
            fi
            msg NF_CHOICE_OFF
            msg NF_CHOICE_ON
            if [ "$_dn_valid" = "1 2 3" ]; then
                msg NF_CHOICE_KEEP "$CFG_NETFILTER_MODE"
            fi
            ask_choice NF_PROMPT "$_dn_valid"
            if [ $? -ne 0 ]; then
                if [ -n "$CFG_NETFILTER_MODE" ]; then
                    return 0
                fi
                err decide_netfilter_mode NF_NEEDS_CHOICE "$DNS_CONFLICTS"
                return 1
            fi
            case "$ASK_REPLY" in
                1) conf_set NETFILTER_MODE off || return 1; say decide_netfilter_mode NF_SET_OFF ;;
                2) conf_set NETFILTER_MODE on || return 1; say decide_netfilter_mode NF_SET_ON ;;
                3) : ;;
            esac
            ;;
        1)
            if [ -z "$CFG_NETFILTER_MODE" ]; then
                conf_set NETFILTER_MODE on || return 1
            fi
            ;;
        *)
            err decide_netfilter_mode PKG_NO_MGR
            return 1
            ;;
    esac
    return 0
}

# ---- 8.2 сервер (login-server) ---------------------------------------------
# Пользователь вводит адрес без схемы (rc.routerich.ru), https:// подставляем
# сами; http:// и другие схемы отвергаются. Результат - в stdout.
login_server_normalize() { # INPUT
    _ls_v=$(printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    case "$_ls_v" in
        *[[:space:]]*) return 1 ;;
        https://*) _ls_h=${_ls_v#https://} ;;
        *://*) return 1 ;;
        *) _ls_h=$_ls_v ;;
    esac
    _ls_h=${_ls_h%/}
    [ -n "$_ls_h" ] || return 1
    _ls_full="https://$_ls_h"
    conf_validate LOGIN_SERVER "$_ls_full" || return 1
    printf '%s' "$_ls_full"
}

# Интерактивно: стандартный сервер (сброс) или свой. До 3 попыток ввода.
choose_login_server() {
    msg LS_CHOICE_STD
    msg LS_CHOICE_CUSTOM
    ask_choice LS_PROMPT "1 2" || return 1
    if [ "$ASK_REPLY" = "1" ]; then
        conf_unset LOGIN_SERVER || return 1
        say choose_login_server LS_RESET
        return 0
    fi
    _cl_try=0
    while [ "$_cl_try" -lt 3 ]; do
        ask_text LS_INPUT || return 1
        if _cl_url=$(login_server_normalize "$ASK_REPLY"); then
            conf_set LOGIN_SERVER "$_cl_url" || return 1
            say choose_login_server LS_SET "$_cl_url"
            return 0
        fi
        err choose_login_server LS_BAD "$ASK_REPLY"
        _cl_try=$((_cl_try + 1))
    done
    return 1
}

# ---- 8.3 проверка списка подсетей -------------------------------------------
# A.B.C.D/N через запятую (IPv4). Пробелы вокруг убираются. Отвергаются: /0
# (для этого есть exit node), ведущие нули, биты хоста (192.168.1.5/24).
# Результат: ROUTES_NORMALIZED; при ошибке ROUTES_ERR (empty|format|octet|
# prefix|hostbits) и ROUTES_BAD_ITEM.
ROUTES_NORMALIZED=""
ROUTES_ERR=""
ROUTES_BAD_ITEM=""

_route_item_ok() { # A.B.C.D/N
    ROUTES_BAD_ITEM=$1
    case "$1" in
        */*/*|*/|/*) ROUTES_ERR=format; return 1 ;;
        */*) ;;
        *) ROUTES_ERR=format; return 1 ;;
    esac
    _ri_ip=${1%/*}
    _ri_pf=${1#*/}
    _ri_rest=$_ri_ip
    _ri_val=0
    for _ri_i in 1 2 3 4; do
        if [ "$_ri_i" -lt 4 ]; then
            case "$_ri_rest" in
                *.*) _ri_o=${_ri_rest%%.*}; _ri_rest=${_ri_rest#*.} ;;
                *) ROUTES_ERR=format; return 1 ;;
            esac
        else
            _ri_o=$_ri_rest
        fi
        case "$_ri_o" in
            ''|*[!0-9]*) ROUTES_ERR=format; return 1 ;;
        esac
        if [ "${#_ri_o}" -gt 3 ]; then ROUTES_ERR=octet; return 1; fi
        case "$_ri_o" in 0?*) ROUTES_ERR=octet; return 1 ;; esac
        if [ "$_ri_o" -gt 255 ]; then ROUTES_ERR=octet; return 1; fi
        _ri_val=$(( (_ri_val << 8) | _ri_o ))
    done
    case "$_ri_pf" in
        ''|*[!0-9]*) ROUTES_ERR=format; return 1 ;;
        0?*) ROUTES_ERR=prefix; return 1 ;;
    esac
    if [ "$_ri_pf" -lt 1 ] || [ "$_ri_pf" -gt 32 ]; then
        ROUTES_ERR=prefix
        return 1
    fi
    _ri_mask=$(( (4294967295 << (32 - _ri_pf)) & 4294967295 ))
    if [ $(( _ri_val & ~_ri_mask & 4294967295 )) -ne 0 ]; then
        ROUTES_ERR=hostbits
        return 1
    fi
    return 0
}

routes_validate() { # STRING
    ROUTES_NORMALIZED=""
    ROUTES_ERR=""
    ROUTES_BAD_ITEM=""
    _rv_in=$(printf '%s' "$1" | tr -d ' \t\r\n')
    if [ -z "$_rv_in" ]; then
        ROUTES_ERR=empty
        return 1
    fi
    case "$_rv_in" in
        *[!0-9./,]*|,*|*,|*,,*)
            ROUTES_ERR=format
            ROUTES_BAD_ITEM=$_rv_in
            return 1
            ;;
    esac
    _rv_rest=$_rv_in
    while [ -n "$_rv_rest" ]; do
        case "$_rv_rest" in
            *,*) _rv_item=${_rv_rest%%,*}; _rv_rest=${_rv_rest#*,} ;;
            *)   _rv_item=$_rv_rest; _rv_rest="" ;;
        esac
        _route_item_ok "$_rv_item" || return 1
    done
    ROUTES_BAD_ITEM=""
    ROUTES_NORMALIZED=$_rv_in
    return 0
}

# ---- 8.4 команда tailscale up -----------------------------------------------
# Один источник флагов (_up_flags: по одному на строку) для показа и запуска.
# Запуск собирает "$@" из этих строк без eval и с отключённым glob.

_up_flags() {
    if [ -n "$CFG_LOGIN_SERVER" ]; then
        printf '%s\n' "--login-server=$CFG_LOGIN_SERVER"
    fi
    if [ "$CFG_NETFILTER_MODE" = "off" ]; then
        printf '%s\n' "--netfilter-mode=off"
    fi
    if [ "$TS_ADVERTISE_EXIT_NODE" = "1" ]; then
        printf '%s\n' "--advertise-exit-node"
    fi
    if [ -n "$TS_ADVERTISE_ROUTES" ]; then
        printf '%s\n' "--advertise-routes=$TS_ADVERTISE_ROUTES"
    fi
    return 0
}

build_up_cmd() {
    UP_CMD="tailscale up"
    _bc_flags=$(_up_flags)
    _bc_old=$IFS
    IFS='
'
    set -f
    for _bc_f in $_bc_flags; do
        UP_CMD="$UP_CMD $_bc_f"
    done
    set +f
    IFS=$_bc_old
    return 0
}

# Запуск tailscale up с выводом на экран ПО МЕРЕ появления (ссылка авторизации
# нужна пользователю сразу: команда блокируется до входа) и копией в лог.
# run_ext не подходит: он показал бы вывод только после завершения команды.
_run_up_stream() { # ARGS...
    _rs_out="$RUNDIR/up.out"
    _rs_rcf="$RUNDIR/up.rc"
    : >"$_rs_out"
    rm -f "$_rs_rcf"
    if command -v tee >/dev/null 2>&1; then
        { tailscale up "$@" 2>&1; echo $? >"$_rs_rcf"; } | tee "$_rs_out"
    else
        { tailscale up "$@" 2>&1; echo $? >"$_rs_rcf"; }
    fi
    _rs_rc=$(cat "$_rs_rcf" 2>/dev/null)
    [ -n "$_rs_rc" ] || _rs_rc=1
    while IFS= read -r _rs_line || [ -n "$_rs_line" ]; do
        _log_raw CMD run_tailscale_up "$_rs_line"
    done <"$_rs_out"
    UP_AUTH_URL=$(sed -n 's#.*\(https://[^[:space:]]*\).*#\1#p' "$_rs_out" | tail -n 1)
    rm -f "$_rs_out" "$_rs_rcf"
    return "$_rs_rc"
}

run_tailscale_up() {
    if ! command -v tailscale >/dev/null 2>&1; then
        err run_tailscale_up UP_NO_BIN
        return 1
    fi
    if [ -n "$CFG_LOGIN_SERVER" ] && ! conf_validate LOGIN_SERVER "$CFG_LOGIN_SERVER"; then
        err run_tailscale_up LS_BAD "$CFG_LOGIN_SERVER"
        return 1
    fi
    if [ -n "$TS_ADVERTISE_ROUTES" ]; then
        if ! routes_validate "$TS_ADVERTISE_ROUTES"; then
            err run_tailscale_up UP_ROUTES_BAD "$ROUTES_BAD_ITEM" "$ROUTES_ERR"
            return 1
        fi
        TS_ADVERTISE_ROUTES=$ROUTES_NORMALIZED
    fi
    _ru_flags=$(_up_flags)
    _ru_old=$IFS
    IFS='
'
    set -f
    # shellcheck disable=SC2086
    set -- $_ru_flags
    set +f
    IFS=$_ru_old
    log_info run_tailscale_up "tailscale up $*"
    UP_DONE=0
    _run_up_stream "$@"
    _ru_rc=$?
    if [ "$_ru_rc" -eq 0 ]; then
        UP_DONE=1
    fi
    return "$_ru_rc"
}

# ---- 8.5 интерактивный сценарий tailscale up ---------------------------------
run_tailscale_up_flow() {
    UP_DONE=0
    UP_AUTH_URL=""
    build_up_cmd
    if [ "$NONINTERACTIVE" = 1 ]; then
        say run_tailscale_up_flow UP_NONINTERACTIVE
        return 0
    fi

    # сервер
    ask_yn LS_ASK_CHANGE "${CFG_LOGIN_SERVER:-$(msg_str LS_STANDARD)}"
    if [ $? -eq 0 ]; then
        choose_login_server || warn run_tailscale_up_flow LS_CHANGE_FAILED
    fi

    # exit node
    TS_ADVERTISE_EXIT_NODE=0
    ask_yn UP_ASK_EXIT
    if [ $? -eq 0 ]; then
        TS_ADVERTISE_EXIT_NODE=1
        if fw_is_setup && ! fw_wan_forward_state; then
            ask_yn FW_WAN_ASK_ON
            if [ $? -eq 0 ]; then
                fw_wan_forward_on || warn run_tailscale_up_flow FW_SETUP_FAIL
            fi
        fi
    fi

    # подсети
    TS_ADVERTISE_ROUTES=""
    ask_yn UP_ASK_ROUTES
    if [ $? -eq 0 ]; then
        _fl_try=0
        while [ "$_fl_try" -lt 3 ]; do
            ask_text UP_ASK_ROUTES_INPUT || break
            if routes_validate "$ASK_REPLY"; then
                TS_ADVERTISE_ROUTES=$ROUTES_NORMALIZED
                break
            fi
            err run_tailscale_up_flow UP_ROUTES_BAD "$ROUTES_BAD_ITEM" "$ROUTES_ERR"
            _fl_try=$((_fl_try + 1))
        done
    fi

    build_up_cmd
    ask_yn UP_CMD_CONFIRM "$UP_CMD"
    if [ $? -ne 0 ]; then
        say run_tailscale_up_flow UP_SKIPPED
        return 0
    fi
    say run_tailscale_up_flow UP_RUNNING
    run_tailscale_up
    _fl_rc=$?
    if [ "$_fl_rc" -ne 0 ]; then
        err run_tailscale_up_flow UP_FAIL "$_fl_rc"
        return "$_fl_rc"
    fi
    say run_tailscale_up_flow UP_OK
    route_check_cgnat
    return 0
}

# ---- 8.6 инструкции после установки (п.15 ТЗ) ---------------------------------
show_post_install() {
    build_up_cmd
    printf '\n'
    say show_post_install POST_TITLE
    say show_post_install POST_DONE
    if [ "$UP_DONE" -eq 1 ]; then
        if [ -n "$UP_AUTH_URL" ]; then
            say show_post_install POST_AUTH_URL "$UP_AUTH_URL"
        fi
    else
        say show_post_install POST_UP_NOT_DONE "$UP_CMD"
    fi
    say show_post_install POST_EXIT
    say show_post_install POST_ROUTES
    say show_post_install POST_APPROVE
    say show_post_install POST_ALL_FLAGS
    if [ "$CFG_NETFILTER_MODE" = "off" ]; then
        say show_post_install POST_NF_OFF
    elif [ -n "$DNS_CONFLICTS" ]; then
        warn show_post_install POST_DNS_WARN "$DNS_CONFLICTS"
    fi
    say show_post_install POST_AGAIN
    return 0
}

# ===================== КОНЕЦ СЛОЯ 6 ====================================

# ======================================================================
# 9. ОБНОВЛЕНИЕ, LUCI, УДАЛЕНИЕ
# ======================================================================
# Источник обновления определяется по конфигу (INSTALL_SOURCE/B_SUBMODE).
# Lite через фид: unhold -> update -> upgrade -> hold (hold возвращается при
# любом исходе). Lite direct: версия из ветки feed, пакет ставится через
# менеджер (unhold -> install файла -> hold), подтверждение - ввод yes.

LUCI_PKG="luci-app-tailscale-community"
LUCI_FEED_BASE="https://tokisaki-galaxy.github.io/luci-app-tailscale-community"
LUCI_KEY_RAW_BASE="https://raw.githubusercontent.com/Tokisaki-Galaxy/luci-app-tailscale-community/refs/heads/gh-pages/all"
LUCI_KEY_SHA256_OPKG="eb1d2c3d17ff703dc16caee7cf6e58aee660933d96901bd68a437f3c6d3006ac"
LUCI_KEY_SHA256_APK="0e2cef4d7d82101ccdcf12ae5c40b4357de86add91cc6bed95e01416c47c1017"
TS_UCI_CONF="/etc/config/tailscale"
TS_STATE_DIR="/etc/tailscale"
TS_VAR_DIR="/var/lib/tailscale"

service_restart() {
    if [ ! -x "$INIT_SCRIPT" ]; then
        err service_restart SERVICE_NO_INIT
        return 1
    fi
    if ! run_ext "$INIT_SCRIPT" restart; then
        err service_restart SERVICE_RESTART_FAIL
        return 1
    fi
    say service_restart SERVICE_RESTART_OK
    return 0
}

# Общий хвост: сравнить версии, сообщить, перезапустить службу при изменении.
_update_finish() { # OLD NEW
    if [ "$1" = "$2" ]; then
        say update UPD_NONE "$2"
        return 0
    fi
    say update UPD_OK "${1:--}" "${2:--}"
    service_restart
    return 0
}

update_official() {
    if ! pkg_installed tailscale; then
        err update_official UPD_NOT_INSTALLED
        return 1
    fi
    say update_official UPD_START
    _uo_old=$(pkg_version tailscale)
    pkg_update || return 1
    if ! pkg_upgrade_pkg tailscale; then
        err update_official UPD_FAIL
        return 1
    fi
    _uo_new=$(pkg_version tailscale)
    _update_finish "$_uo_old" "$_uo_new"
}

update_lite_feed() {
    if ! pkg_installed tailscale; then
        err update_lite_feed UPD_NOT_INSTALLED
        return 1
    fi
    say update_lite_feed UPD_START
    _ul_old=$(pkg_version tailscale)
    if ! pkg_unhold tailscale; then
        err update_lite_feed UPD_FAIL
        return 1
    fi
    _ul_rc=0
    pkg_update && pkg_upgrade_pkg tailscale || _ul_rc=1
    # защита возвращается при любом исходе
    if ! pkg_hold tailscale; then
        warn update_lite_feed PKG_HOLD_FAIL tailscale
    fi
    if [ "$_ul_rc" -ne 0 ]; then
        err update_lite_feed UPD_FAIL
        return 1
    fi
    _lite_origin_check
    _ul_new=$(pkg_version tailscale)
    _update_finish "$_ul_old" "$_ul_new"
}

update_lite_direct() {
    if [ "$PKG_MGR" != opkg ] || rel_ge 25 12; then
        err update_lite_direct INSTALL_LITE_DIRECT_WRONG_MGR
        return 1
    fi
    if ! pkg_installed tailscale; then
        err update_lite_direct UPD_NOT_INSTALLED
        return 1
    fi
    say update_lite_direct UPD_START
    _ud_arch=$(feed_arch)
    if [ -z "$_ud_arch" ]; then
        err update_lite_direct FEED_ARCH_UNAVAILABLE
        return 1
    fi
    _ud_new=$(_lite_direct_version "$_ud_arch") || return 1
    _ud_cur=$(pkg_version tailscale) || _ud_cur=$CFG_LITE_VERSION
    if [ "$_ud_cur" = "$_ud_new" ]; then
        say update_lite_direct UPD_NONE "$_ud_cur"
        return 0
    fi
    say update_lite_direct UPD_CURRENT "${_ud_cur:--}" "$_ud_new"
    if [ "$NONINTERACTIVE" = 1 ]; then
        say update_lite_direct UPD_DIRECT_MENU_ONLY
        return 2
    fi
    ask_typed_yes INSTALL_LITE_DIRECT_CONFIRM
    if [ $? -ne 0 ]; then
        say update_lite_direct INSTALL_LITE_DIRECT_DECLINED
        return 2
    fi
    if ! pkg_unhold tailscale; then
        err update_lite_direct UPD_FAIL
        return 1
    fi
    _lite_direct_install_pkg "$_ud_arch" "$_ud_new"
    _ud_rc=$?
    if ! pkg_hold tailscale; then
        warn update_lite_direct PKG_HOLD_FAIL tailscale
    fi
    if [ "$_ud_rc" -ne 0 ]; then
        err update_lite_direct UPD_FAIL
        return 1
    fi
    conf_set LITE_VERSION "$_ud_new" || true
    _update_finish "$_ud_cur" "$_ud_new"
}

update_tailscale() {
    case "$CFG_INSTALL_SOURCE" in
        A) update_official ;;
        B)
            case "$CFG_B_SUBMODE" in
                feed)   update_lite_feed ;;
                direct) update_lite_direct ;;
                *) err update_tailscale UPD_NO_SOURCE; return 1 ;;
            esac
            ;;
        *) err update_tailscale UPD_NO_SOURCE; return 1 ;;
    esac
}

# ---- LuCI -------------------------------------------------------------------
# 25.12+: пакет в официальном фиде. 24.10: фид Tokisaki-Galaxy (подтверждение
# встроено в feed_add). Если пакета нет нигде, просто справка. Фид GuNanOvO
# LuCI-приложения не содержит. luci-base не ставим: без него пропускаем.
install_luci() {
    if ! pkg_installed luci-base; then
        say install_luci LUCI_NO_BASE
        return 0
    fi
    if pkg_installed "$LUCI_PKG"; then
        say install_luci LUCI_ALREADY
        return 0
    fi
    pkg_update || return 1
    if ! pkg_available "$LUCI_PKG"; then
        case "$PKG_MGR" in
            opkg)
                _il_url="$LUCI_FEED_BASE/all"
                _il_key="$LUCI_KEY_RAW_BASE/key-build.pub"
                _il_pin="$LUCI_KEY_SHA256_OPKG"
                ;;
            apk)
                _il_url="$LUCI_FEED_BASE/all/packages.adb"
                _il_key="$LUCI_KEY_RAW_BASE/public-key.pem"
                _il_pin="$LUCI_KEY_SHA256_APK"
                ;;
            *)
                err install_luci PKG_NO_MGR
                return 1
                ;;
        esac
        feed_add luci "$_il_url" "$_il_key" "$_il_pin"
        _il_rc=$?
        if [ "$_il_rc" -eq 2 ]; then
            say install_luci LUCI_FEED_DECLINED
            return 0
        fi
        if [ "$_il_rc" -ne 0 ]; then
            return 1
        fi
        if ! pkg_available "$LUCI_PKG"; then
            say install_luci LUCI_UNAVAILABLE
            return 0
        fi
    fi
    say install_luci LUCI_INSTALLING
    if ! pkg_install "$LUCI_PKG"; then
        err install_luci LUCI_FAIL
        return 1
    fi
    say install_luci LUCI_OK
    return 0
}

# Спрашивает после основного сценария; неинтерактивно пропускается.
install_luci_ask() {
    [ "$NONINTERACTIVE" = 1 ] && return 0
    ask_yn LUCI_ASK
    if [ $? -ne 0 ]; then
        return 0
    fi
    install_luci
}

# ---- удаление ---------------------------------------------------------------
UN_REMOVED=""
UN_KEPT=""

_un_removed() { UN_REMOVED="$UN_REMOVED $1"; }
_un_kept() { UN_KEPT="$UN_KEPT $1"; }

# rm -rf только для абсолютных путей глубже корня (защита от пустой переменной).
_safe_rm() { # PATH
    case "$1" in
        ''|/|//|/.|/..|[!/]*) return 1 ;;
    esac
    [ -e "$1" ] || [ -L "$1" ] || return 0
    rm -rf "$1"
}

# Убирает из sysupgrade.conf строки, точно совпадающие с переданными путями.
_sysupgrade_unregister() { # PATH...
    [ -f "$SYSUPGRADE_CONF" ] || return 0
    _su_tmp="$SYSUPGRADE_CONF.tmp.$$"
    {
        while IFS= read -r _su_line || [ -n "$_su_line" ]; do
            _su_skip=0
            for _su_p in "$@"; do
                if [ "$_su_line" = "$_su_p" ]; then
                    _su_skip=1
                    break
                fi
            done
            if [ "$_su_skip" -eq 0 ]; then
                printf '%s\n' "$_su_line"
            fi
        done <"$SYSUPGRADE_CONF"
    } >"$_su_tmp" 2>/dev/null
    if [ $? -ne 0 ] || ! mv "$_su_tmp" "$SYSUPGRADE_CONF" 2>/dev/null; then
        rm -f "$_su_tmp"
        return 1
    fi
    return 0
}

# Возврат: 0 - выполнено, 2 - отменено пользователем.
uninstall_tailscale() {
    UN_REMOVED=""
    UN_KEPT=""
    ask_typed_yes UN_CONFIRM
    if [ $? -ne 0 ]; then
        say uninstall_tailscale UN_CANCELLED
        return 2
    fi
    # пути, записанные в sysupgrade.conf (до очистки учёта фидов)
    _un_sys=$(_sysupgrade_feed_paths)

    # 1. служба
    if [ -x "$INIT_SCRIPT" ]; then
        run_ext "$INIT_SCRIPT" stop || warn uninstall_tailscale SERVICE_START_FAIL
        run_ext "$INIT_SCRIPT" disable || warn uninstall_tailscale SERVICE_ENABLE_FAIL
        _un_removed service
    fi

    # 2. firewall и сеть (только секции tsi_*)
    if _uci_ok && _fw_any_ours; then
        fw_remove
        _un_removed firewall
    fi

    # 3. LuCI-приложение зависит от tailscale, поэтому удаляется первым
    if pkg_installed "$LUCI_PKG"; then
        if pkg_remove "$LUCI_PKG"; then
            _un_removed luci
        else
            _un_kept luci
        fi
    fi

    # 4. фиды, добавленные скриптом
    for _un_f in luci lite; do
        if feed_exists "$_un_f"; then
            feed_remove "$_un_f"
            _un_removed "feed:$_un_f"
        fi
    done

    # 5. пакет и остатки (conffile и состояние пакету не принадлежат)
    if [ "$PKG_MGR" = opkg ]; then
        pkg_unhold tailscale >/dev/null 2>&1
    fi
    if pkg_installed tailscale; then
        pkg_remove tailscale
    fi
    _un_gone=1
    if pkg_installed tailscale; then
        _un_gone=0
        warn uninstall_tailscale UN_PKG_KEPT
        _un_kept package
        _un_kept state
    else
        _un_removed package
        _safe_rm "$TS_UCI_CONF"
        _safe_rm "$TS_STATE_DIR"
        _safe_rm "$TS_VAR_DIR"
        _un_removed state
    fi

    # 6. конфигурация скрипта (по умолчанию - оставить)
    ask_yn UN_ASK_CONF "$CONF"
    if [ $? -eq 0 ]; then
        _safe_rm "$CONF"
        _safe_rm "$FEEDS_LEDGER"
        _un_removed script-config
    else
        _un_kept script-config
        if [ -f "$FEEDS_LEDGER" ] && [ ! -s "$FEEDS_LEDGER" ]; then
            rm -f "$FEEDS_LEDGER"
        fi
    fi

    # 7. алиас и записи в sysupgrade.conf
    # Если пакет остался, алиас и записи sysupgrade не трогаем (tsi ещё нужен).
    if [ "$_un_gone" -eq 1 ]; then
        # shellcheck disable=SC2086
        _sysupgrade_unregister $SYSUPGRADE_BASE_PATHS $_un_sys
        if [ -e "$SELF_DEST" ]; then
            rm -f "$SELF_DEST"
            _un_removed alias
        fi
        _un_removed sysupgrade-entries
    else
        _un_kept alias
        _un_kept sysupgrade-entries
    fi

    # 8. итог
    printf '\n'
    say uninstall_tailscale UN_REPORT_TITLE
    say uninstall_tailscale UN_REPORT_REMOVED "${UN_REMOVED# }"
    if [ -n "$UN_KEPT" ]; then
        say uninstall_tailscale UN_REPORT_KEPT "${UN_KEPT# }"
    fi
    say uninstall_tailscale UN_NOTE_DEPS
    say uninstall_tailscale UN_DONE
    return 0
}

# ===================== КОНЕЦ СЛОЯ 7 ====================================

# ======================================================================
# 10. CLI, МЕНЮ, MAIN
# ======================================================================
# Режимы: меню (без параметров), --status, --update, --install-official,
# --install-lite; модификаторы --netfilter-off и --login-server=АДРЕС (только
# вместе с --install-*); --help, --version. Нет флагов для удаления и для
# прямого скачивания (только меню), нет -y и --quiet.
# --update и --install-* работают в неинтерактивном режиме (NONINTERACTIVE=1):
# вопросы не задаются, фид Lite добавляется без вопроса только при совпадении
# ключа с хэшем, зафиксированным в скрипте; LuCI не ставится; tailscale up не
# запускается (нужна авторизация).
# Коды возврата: 0 успех, 1 ошибка, 2 не выполнено (отказ, нужно подтверждение,
# неверные параметры).

MODE=""                 # menu | status | update | install-official | install-lite | help | version
ARG_LOGIN_SERVER=""
ARG_NETFILTER_OFF=0
PARSE_ERR=""
INSTALL_RC=0

parse_args() {
    MODE=""
    ARG_LOGIN_SERVER=""
    ARG_NETFILTER_OFF=0
    PARSE_ERR=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --status|--update|--install-official|--install-lite|--help|--version|-h|-V)
                case "$1" in
                    -h) _pa_m=help ;;
                    -V) _pa_m=version ;;
                    *)  _pa_m=${1#--} ;;
                esac
                if [ -n "$MODE" ] && [ "$MODE" != "$_pa_m" ]; then
                    PARSE_ERR=$1
                    return 1
                fi
                MODE=$_pa_m
                ;;
            --netfilter-off)
                ARG_NETFILTER_OFF=1
                ;;
            --login-server=?*)
                ARG_LOGIN_SERVER=${1#*=}
                ;;
            *)
                PARSE_ERR=$1
                return 1
                ;;
        esac
        shift
    done
    [ -n "$MODE" ] || MODE=menu
    case "$MODE" in
        install-official|install-lite) ;;
        *)
            if [ "$ARG_NETFILTER_OFF" = 1 ] || [ -n "$ARG_LOGIN_SERVER" ]; then
                PARSE_ERR="--netfilter-off/--login-server"
                return 1
            fi
            ;;
    esac
    return 0
}

_is_root() {
    [ "$(id -u 2>/dev/null)" = "0" ]
}

# Первый запуск: выбор языка (сообщение двуязычное). Неинтерактивно и при
# отсутствии терминала остаётся язык по умолчанию, в конфиг ничего не пишется.
first_run_language() {
    [ -z "$CFG_LANG" ] || return 0
    [ "$NONINTERACTIVE" = 1 ] && return 0
    msg LANG_FIRST_TITLE
    ask_choice MENU_PROMPT "1 2" || return 0
    case "$ASK_REPLY" in
        1) conf_set LANG ru ;;
        2) conf_set LANG en ;;
    esac
    i18n_init
    return 0
}

# ---- статус -----------------------------------------------------------------
show_status() {
    say show_status ST_TITLE
    if pkg_installed tailscale; then
        say show_status ST_VERSION "$(pkg_version tailscale)"
    else
        say show_status ST_NOT_INSTALLED
    fi
    case "$CFG_INSTALL_SOURCE:$CFG_B_SUBMODE" in
        A:*)        _st_src=official ;;
        B:feed)     _st_src=lite-feed ;;
        B:direct)   _st_src=lite-direct ;;
        *)          _st_src="-" ;;
    esac
    say show_status ST_SOURCE "$_st_src"
    if pidof tailscaled >/dev/null 2>&1; then
        say show_status ST_SERVICE_RUNNING
        _st_up=1
    else
        say show_status ST_SERVICE_STOPPED
        _st_up=0
    fi
    if fw_is_setup; then
        say show_status ST_FW_OK
    else
        say show_status ST_FW_NO
    fi
    say show_status ST_NF "${CFG_NETFILTER_MODE:--}"
    say show_status ST_SERVER "${CFG_LOGIN_SERVER:-$(msg_str LS_STANDARD)}"
    if [ "$_st_up" -eq 1 ] && command -v tailscale >/dev/null 2>&1; then
        say show_status ST_TS_STATUS
        tailscale status 2>&1
    fi
    return 0
}

# ---- установка (общий сценарий для меню и CLI) ---------------------------------
# Критические ошибки до записи firewall откатывают сделанное (feed_remove,
# fw_remove из стека); пакеты и зависимости остаются. Ошибки после установки
# пакета (firewall, служба, up) не прерывают сценарий, но итоговый код = 1.
run_install_flow() {
    INSTALL_RC=0
    rollback_init
    if [ -z "$SOURCE_CHOICE" ]; then
        choose_source || return 1
    fi
    if ! install_deps; then
        rollback_run
        return 1
    fi
    if ! check_tun; then
        if [ "$NONINTERACTIVE" = 1 ]; then
            err run_install_flow INSTALL_TUN_ABORT
            rollback_run
            return 1
        fi
        ask_yn INSTALL_TUN_ASK
        if [ $? -ne 0 ]; then
            err run_install_flow INSTALL_TUN_ABORT
            rollback_run
            return 1
        fi
    fi
    if ! decide_netfilter_mode; then
        rollback_run
        return 1
    fi
    install_selected
    _rif_rc=$?
    if [ "$_rif_rc" -ne 0 ]; then
        rollback_run
        return "$_rif_rc"
    fi
    fw_setup || INSTALL_RC=1
    set_fw_debug_mode || INSTALL_RC=1
    service_enable_start || INSTALL_RC=1
    register_sysupgrade || INSTALL_RC=1
    run_tailscale_up_flow || INSTALL_RC=1
    show_post_install
    install_luci_ask
    rollback_clear
    if [ "$INSTALL_RC" -eq 0 ]; then
        say run_install_flow INSTALL_DONE
    else
        warn run_install_flow INSTALL_DONE_WARN "$LOG_FILE"
    fi
    return "$INSTALL_RC"
}

# ---- меню -----------------------------------------------------------------------
menu_install() {
    SOURCE_CHOICE=""
    run_install_flow
}

settings_language() {
    msg LANG_FIRST_TITLE
    ask_choice MENU_PROMPT "1 2" || return 1
    case "$ASK_REPLY" in
        1) conf_set LANG ru || return 1 ;;
        2) conf_set LANG en || return 1 ;;
    esac
    i18n_init
    say settings_language SET_LANG_SET "$CUR_LANG"
}

settings_netfilter() {
    say settings_netfilter NF_CURRENT "${CFG_NETFILTER_MODE:--}"
    msg SET_NF_EXPLAIN
    msg NF_CHOICE_OFF
    msg NF_CHOICE_ON
    msg SET_NF_BACK
    ask_choice MENU_PROMPT "1 2 3" || return 1
    case "$ASK_REPLY" in
        1) conf_set NETFILTER_MODE off || return 1; say settings_netfilter NF_SET_OFF; say settings_netfilter SET_RERUN_UP ;;
        2) conf_set NETFILTER_MODE on || return 1; say settings_netfilter NF_SET_ON; say settings_netfilter SET_RERUN_UP ;;
        3) : ;;
    esac
}

settings_server() {
    choose_login_server || return 1
    say settings_server SET_RERUN_UP
}

settings_fw_mode() {
    set_fw_debug_mode || return 1
    ask_yn SET_RESTART_ASK
    if [ $? -eq 0 ]; then
        service_restart
    fi
}

settings_verbose() {
    if [ "$CFG_LOG_VERBOSE" = 1 ]; then
        conf_set LOG_VERBOSE 0 || return 1
        say settings_verbose SET_VERBOSE_OFF
    else
        conf_set LOG_VERBOSE 1 || return 1
        say settings_verbose SET_VERBOSE_ON
    fi
}

settings_up() {
    run_tailscale_up_flow
    show_post_install
}

menu_settings() {
    while :; do
        printf '\n'
        msg SET_TITLE
        msg SET_LANG
        msg SET_SERVER
        msg SET_NETFILTER
        msg SET_WAN
        msg SET_FWMODE
        msg SET_VERBOSE
        msg SET_CONFIG
        msg SET_LUCI
        msg SET_UP
        msg SET_BACK
        ask_choice MENU_PROMPT "1 2 3 4 5 6 7 8 9 0" || return 1
        case "$ASK_REPLY" in
            1) settings_language ;;
            2) settings_server ;;
            3) settings_netfilter ;;
            4) fw_wan_forward_toggle ;;
            5) settings_fw_mode ;;
            6) settings_verbose ;;
            7) conf_show ;;
            8) install_luci ;;
            9) settings_up ;;
            0) return 0 ;;
        esac
    done
}

menu_main() {
    while :; do
        printf '\n'
        msg MENU_TITLE
        msg MENU_INSTALL
        msg MENU_UPDATE
        msg MENU_UNINSTALL
        msg MENU_STATUS
        msg MENU_SETTINGS
        msg MENU_EXIT
        ask_choice MENU_PROMPT "1 2 3 4 5 0"
        if [ $? -ne 0 ]; then
            err menu_main ERR_NO_INPUT
            return 1
        fi
        case "$ASK_REPLY" in
            1) menu_install ;;
            2) update_tailscale ;;
            3)
                uninstall_tailscale
                if [ $? -eq 0 ]; then
                    return 0
                fi
                ;;
            4) show_status ;;
            5) menu_settings ;;
            0) return 0 ;;
        esac
    done
}

# ---- точка входа -------------------------------------------------------------------
main() {
    if ! parse_args "$@"; then
        conf_load
        i18n_init
        err main USAGE_ERR "$PARSE_ERR"
        msg USAGE_TEXT >&2
        return 2
    fi
    case "$MODE" in
        help)
            conf_load
            i18n_init
            msg USAGE_TEXT
            return 0
            ;;
        version)
            printf 'tsi %s\n' "$TSI_VERSION"
            return 0
            ;;
    esac
    if ! _is_root; then
        printf 'ERROR: run as root.\nОШИБКА: запустите от root.\n' >&2
        return 1
    fi
    case "$MODE" in
        update|install-official|install-lite) NONINTERACTIVE=1 ;;
    esac
    install_self || return 1
    tsi_init || return 1
    if [ -n "$ARG_LOGIN_SERVER" ]; then
        if ! _m_url=$(login_server_normalize "$ARG_LOGIN_SERVER"); then
            err main LS_BAD "$ARG_LOGIN_SERVER"
            return 2
        fi
        conf_set LOGIN_SERVER "$_m_url" || return 1
    fi
    if [ "$ARG_NETFILTER_OFF" = 1 ]; then
        NETFILTER_FORCE=off
    fi
    if [ "$MODE" = "menu" ]; then
        first_run_language
    fi
    detect_release || return 1
    detect_pkg_mgr || return 1
    detect_arch || true
    case "$MODE" in
        status)           show_status; return 0 ;;
        update)           update_tailscale; return $? ;;
        install-official) SOURCE_CHOICE=official; run_install_flow; return $? ;;
        install-lite)     SOURCE_CHOICE=lite_feed; run_install_flow; return $? ;;
        menu)             menu_main; return $? ;;
    esac
    return 1
}

# Запуск при выполнении файла; при подключении через "." (тесты) -
# TSI_NO_MAIN=1.
if [ "${TSI_NO_MAIN:-0}" != "1" ]; then
    main "$@"
    exit $?
fi
