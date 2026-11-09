#!/bin/bash
# h96max-dtb-guard.sh — страховка для H96 Max RK3528.
#
# Обновление ядра или загрузчика может заменить /boot/dtb/rockchip/rk3528-*.dtb
# стоковым файлом. Без наших правок в DTB отваливаются Wi-Fi, Bluetooth, GPU и HDMI.
# Этот скрипт проверяет DTB при каждой загрузке и после установки пакетов:
#   * если DTB на месте и пропатчен — ничего не делает;
#   * если DTB заменён — заново применяет правки (idempotent dtb-fix);
#   * если DTB пропал — восстанавливает из /usr/local/share/h96max;
#   * проверяет fdtfile и console=display в armbianEnv.txt.
#
# Использование:
#   h96max-dtb-guard.sh            # применить (режим по умолчанию)
#   h96max-dtb-guard.sh check      # только проверить, код возврата 0/1
#   h96max-dtb-guard.sh quiet      # без вывода в stdout (для apt-хука)
#
# Для тестов пути можно переопределить:
#   H96MAX_BOOT_DIR=/tmp/boot H96MAX_SHARE_DIR=/tmp/share ...
set -uo pipefail

MODE="${1:-apply}"

BOOT="${H96MAX_BOOT_DIR:-/boot}"
SHARE="${H96MAX_SHARE_DIR:-/usr/local/share/h96max}"
STATE_DIR="${H96MAX_STATE_DIR:-/var/lib/h96max}"
LOG="${H96MAX_LOG:-/var/log/h96max-dtb-guard.log}"

DTB_NAME="rk3528-evb2-ddr3-v10.dtb"
DTB="$BOOT/dtb/rockchip/$DTB_NAME"
ENV_FILE="$BOOT/armbianEnv.txt"
STAMP="$STATE_DIR/dtb.sha256"
FIXER="$SHARE/dtb-fix.py"
PACKAGED_DTB="$SHARE/$DTB_NAME"

say() {
    [ "$MODE" = "quiet" ] && return 0
    echo "$@"
}

logline() {
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
    echo "$ts $*" >>"$LOG" 2>/dev/null || true
    logger -t h96max-dtb-guard -- "$*" 2>/dev/null || true
}

sha() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

# Проверяет, что пропатченный DTB действительно содержит наши узлы.
# Возвращает 0, только если все признаки на месте.
verify_patched() {
    local dtb="$1" dts
    dts="$(mktemp /tmp/h96max-dts.XXXXXX)" || return 1
    if ! dtc -I dtb -O dts "$dtb" >"$dts" 2>/dev/null; then
        rm -f "$dts"
        return 1
    fi
    local ok=0
    grep -q 'vcc-wifi-reg' "$dts"     || ok=1
    grep -q 'bt_port' "$dts"          || ok=1
    grep -q 'bus\\0core' "$dts"       || ok=1
    grep -q 'clk_core' "$dts"         || ok=1
    grep -q 'clk_cabac' "$dts"        || ok=1
    grep -q 'mmc-pwrseq-simple' "$dts" || ok=1
    rm -f "$dts"
    return $ok
}

# Атомарно заменяет DTB: временный файл рядом + mv (атомарное переименование).
# При обрыве питания в худшем случае останется старый файл, а не «полузаписанный».
replace_dtb() {
    local src="$1" dst="$2" dir tmp
    dir="$(dirname "$dst")"
    tmp="$(mktemp "$dir/.dtb-guard.XXXXXX")" || return 1
    if ! cp -f "$src" "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    chmod 644 "$tmp" 2>/dev/null || true
    if ! mv -f "$tmp" "$dst"; then
        rm -f "$tmp"
        return 1
    fi
    sync
    return 0
}

fail=0

# ---------------------------------------------------------------- DTB
check_dtb() {
    if [ ! -f "$DTB" ]; then
        say "  DTB отсутствует: $DTB"
        return 1
    fi
    local cur want
    cur="$(sha "$DTB")"
    [ -n "$cur" ] || return 1

    if [ -f "$STAMP" ]; then
        want="$(cat "$STAMP" 2>/dev/null)"
        if [ -n "$want" ] && [ "$cur" = "$want" ]; then
            say "  DTB: в порядке (совпадает с эталоном)"
            return 0
        fi
    fi

    # хеш не совпал — проверяем, пропатчен ли файл по факту
    if [ ! -f "$FIXER" ]; then
        say "  DTB: не совпадает с эталоном, но нет $FIXER — пропускаю"
        logline "нет $FIXER, проверить DTB невозможно"
        return 1
    fi
    command -v dtc >/dev/null || { say "  DTB: нет dtc — пропускаю"; logline "нет dtc"; return 1; }
    command -v python3 >/dev/null || { say "  DTB: нет python3 — пропускаю"; logline "нет python3"; return 1; }

    local tmp
    tmp="$(mktemp /tmp/h96max-dtb.XXXXXX.dtb)" || return 1
    if ! python3 "$FIXER" "$DTB" --out "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        say "  DTB: не удалось применить правки"
        logline "dtb-fix завершился ошибкой для $DTB"
        return 1
    fi
    if ! dtc -I dtb -O dts "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        say "  DTB: результат правки невалиден — оставляю как есть"
        logline "dtb-fix дал невалидный DTB, изменения отменены"
        return 1
    fi
    if ! verify_patched "$tmp"; then
        rm -f "$tmp"
        say "  DTB: в результате правки нет нужных узлов — оставляю как есть"
        logline "после dtb-fix не найдены ожидаемые узлы, запись отменена"
        return 1
    fi

    local new
    new="$(sha "$tmp")"
    if [ "$new" = "$cur" ]; then
        # файл уже пропатчен, просто запоминаем хеш
        mkdir -p "$STATE_DIR" 2>/dev/null || true
        echo "$cur" >"$STAMP" 2>/dev/null || true
        say "  DTB: уже пропатчен (хеш обновлён)"
        logline "DTB уже содержал правки, эталон обновлён: $cur"
        rm -f "$tmp"
        return 0
    fi

    if [ "$MODE" = "check" ]; then
        say "  DTB: требует правки (будет исправлен при загрузке)"
        rm -f "$tmp"
        return 1
    fi

    [ -f "${DTB}.orig" ] || cp -f "$DTB" "${DTB}.orig" 2>/dev/null || true
    if replace_dtb "$tmp" "$DTB"; then
        mkdir -p "$STATE_DIR" 2>/dev/null || true
        echo "$new" >"$STAMP" 2>/dev/null || true
        say "  DTB: правки применены заново"
        logline "DTB перепатчен после обновления: $new"
    else
        say "  DTB: не удалось записать — файл не изменён"
        logline "ошибка записи $DTB"
        rm -f "$tmp"
        return 1
    fi
    rm -f "$tmp"
    return 0
}

restore_dtb() {
    if [ ! -f "$PACKAGED_DTB" ]; then
        say "  DTB: восстановить нечем (нет $PACKAGED_DTB)"
        logline "DTB отсутствует и нет копии в $SHARE"
        return 1
    fi
    if [ "$MODE" = "check" ]; then
        say "  DTB: отсутствует (будет восстановлен при загрузке)"
        return 1
    fi
    install -d "$(dirname "$DTB")" 2>/dev/null || true
    if replace_dtb "$PACKAGED_DTB" "$DTB"; then
        mkdir -p "$STATE_DIR" 2>/dev/null || true
        sha "$DTB" >"$STAMP" 2>/dev/null || true
        say "  DTB: восстановлен из пакета"
        logline "DTB восстановлен из $PACKAGED_DTB"
        return 0
    fi
    say "  DTB: не удалось восстановить"
    logline "ошибка восстановления DTB"
    return 1
}

# ---------------------------------------------------------------- armbianEnv
set_env() {  # $1 — ключ, $2 — желаемое значение
    local key="$1" val="$2"
    if grep -q "^${key}=" "$ENV_FILE"; then
        sed -i "s|^${key}=.*|${key}=${val}|" "$ENV_FILE"
    else
        echo "${key}=${val}" >>"$ENV_FILE"
    fi
    grep -q "^${key}=${val}$" "$ENV_FILE"
}

check_env() {
    if [ ! -f "$ENV_FILE" ]; then
        say "  armbianEnv.txt: отсутствует"
        return 1
    fi
    local bad=0

    if grep -q "^fdtfile=rockchip/${DTB_NAME}$" "$ENV_FILE"; then
        say "  armbianEnv: fdtfile в порядке"
    else
        bad=1
        if [ "$MODE" = "check" ]; then
            say "  armbianEnv: fdtfile неверный"
        else
            if set_env fdtfile "rockchip/${DTB_NAME}"; then
                say "  armbianEnv: fdtfile исправлен"
                logline "исправлен fdtfile в $ENV_FILE"
            else
                say "  armbianEnv: не удалось исправить fdtfile"
                logline "ошибка записи fdtfile в $ENV_FILE"
                return 1
            fi
        fi
    fi

    # console=both занял бы UART (ttyS2), который нужен Bluetooth
    if grep -q '^console=display$' "$ENV_FILE"; then
        say "  armbianEnv: console в порядке"
    else
        bad=1
        if [ "$MODE" = "check" ]; then
            say "  armbianEnv: console неверный"
        else
            if set_env console "display"; then
                say "  armbianEnv: console исправлен"
                logline "исправлен console в $ENV_FILE"
            else
                say "  armbianEnv: не удалось исправить console"
                logline "ошибка записи console в $ENV_FILE"
                return 1
            fi
        fi
    fi

    if [ "$bad" = 1 ] && [ "$MODE" = "check" ]; then
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------- main
[ "$MODE" = "quiet" ] || echo "H96 Max RK3528: проверка DTB"

if [ -f "$DTB" ]; then
    check_dtb || fail=1
else
    restore_dtb && { check_dtb || fail=1; } || fail=1
fi

check_env || fail=1

if [ "$fail" = 1 ] && [ "$MODE" != "quiet" ]; then
    if [ "$MODE" = "check" ]; then
        echo "Итог: есть проблемы (см. выше)"
    else
        echo "Итог: не всё удалось исправить"
    fi
elif [ "$MODE" != "quiet" ]; then
    echo "Итог: всё в порядке"
fi

exit "$fail"
