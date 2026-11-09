#!/bin/bash
# setup-h96max-rk3528.sh — приводит свежий Armbian на H96 Max RK3528 (плата
# RK3528_DDR3_8X4_V12) в рабочее состояние: HDMI, Wi-Fi AIC8800, Bluetooth,
# GPU Mali-450, аппаратный декодер rkvdec2.
#
# Использование:
#   ./setup-h96max-rk3528.sh                 # спросит про рабочий стол, если есть TTY
#   ./setup-h96max-rk3528.sh --desktop=lxqt  # сразу с графикой (lxqt|xfce|kde|mate|cinnamon)
#   ./setup-h96max-rk3528.sh --no-desktop    # только консоль (сервер)
#   ./setup-h96max-rk3528.sh --dry-run       # показать, что будет сделано
#
# Скрипт идемпотентен: можно запускать повторно.
set -euo pipefail

DTB_NAME="rk3528-evb2-ddr3-v10.dtb"
DTB_PATH="/boot/dtb/rockchip/${DTB_NAME}"
ENV_FILE="/boot/armbianEnv.txt"
HERE="$(cd "$(dirname "$0")" && pwd)"

DESKTOP=""      # "", "none", "lxqt", "xfce", "kde", "mate", "cinnamon"
DRY=0

for arg in "$@"; do
  case "$arg" in
    --with-desktop) DESKTOP=lxqt ;;
    --desktop=*)    DESKTOP="${arg#*=}" ;;
    --no-desktop)   DESKTOP=none ;;
    --dry-run)      DRY=1 ;;
    -h|--help)      sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "Неизвестный аргумент: $arg"; exit 2 ;;
  esac
done

case "$DESKTOP" in
  ""|none|lxqt|xfce|kde|mate|cinnamon) ;;
  *) echo "Неизвестное окружение '$DESKTOP'. Варианты: lxqt, xfce, kde, mate, cinnamon, none"; exit 2 ;;
esac

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[x] %s\033[0m\n' "$*" >&2; exit 1; }
doit() { if [ "$DRY" = 1 ]; then echo "  (dry-run) $*"; else "$@"; fi; }

[ "$(id -u)" = 0 ] || die "запускать от root"

# ---------------------------------------------------------------- проверки
log "Проверяю железо и систему"
grep -qi "rk3528" /proc/device-tree/compatible 2>/dev/null || \
  warn "в /proc/device-tree/compatible нет rk3528 — возможно, это другая плата, продолжаю"

. /etc/os-release 2>/dev/null || true
echo "    система: ${PRETTY_NAME:-неизвестно}, ядро $(uname -r)"

[ -f "$DTB_PATH" ] || die "не найден $DTB_PATH — образ не для этой платы или другой DTB"
command -v dtc >/dev/null || { log "Ставлю device-tree-compiler"; doit apt-get update -qq; doit apt-get install -y -qq device-tree-compiler; }

# ---------------------------------------------------------------- DTB
log "Правлю device tree (HDMI/GPU/Wi-Fi/BT/rkvdec2)"
if [ "$DRY" = 0 ] && [ ! -f "${DTB_PATH}.orig" ]; then
  cp -f "$DTB_PATH" "${DTB_PATH}.orig"
  echo "    бэкап: ${DTB_PATH}.orig"
fi
if [ "$DRY" = 1 ]; then
  echo "  (dry-run) python3 $HERE/scripts/dtb-fix.py $DTB_PATH"
else
  python3 "$HERE/scripts/dtb-fix.py" "$DTB_PATH" --out /tmp/dtb.new
  cp -f /tmp/dtb.new "$DTB_PATH"
  echo "    DTB обновлён"
fi

# ---------------------------------------------------------------- armbianEnv
log "Прописываю DTB в $ENV_FILE"
if [ "$DRY" = 0 ]; then
  touch "$ENV_FILE"
  if grep -q '^fdtfile=' "$ENV_FILE"; then
    sed -i "s|^fdtfile=.*|fdtfile=rockchip/${DTB_NAME}|" "$ENV_FILE"
  else
    echo "fdtfile=rockchip/${DTB_NAME}" >> "$ENV_FILE"
  fi
  # console=both занял бы UART (ttyS2), а он нужен Bluetooth
  if grep -q '^console=' "$ENV_FILE"; then
    sed -i 's|^console=.*|console=display|' "$ENV_FILE"
  else
    echo "console=display" >> "$ENV_FILE"
  fi
  echo "    $(grep -E '^(fdtfile|console)=' "$ENV_FILE" | tr '\n' ' ')"
else
  echo "  (dry-run) fdtfile=rockchip/${DTB_NAME}"
fi

# ---------------------------------------------------------------- DTB-guard
log "Ставлю защиту DTB (после обновлений ядра правки не потеряются)"
if [ "$DRY" = 0 ]; then
  install -d /usr/local/share/h96max /var/lib/h96max
  install -m 755 "$HERE/scripts/dtb-guard.sh" /usr/local/bin/h96max-dtb-guard.sh
  install -m 644 "$HERE/scripts/dtb-fix.py" /usr/local/share/h96max/dtb-fix.py
  install -m 644 "$HERE/files/${DTB_NAME}" "/usr/local/share/h96max/${DTB_NAME}"
  install -m 644 "$HERE/scripts/dtb-guard.service" /etc/systemd/system/h96max-dtb-guard.service
  install -m 644 "$HERE/scripts/apt-dtb-guard.conf" /etc/apt/apt.conf.d/99-h96max-dtb-guard
  systemctl daemon-reload
  systemctl enable h96max-dtb-guard.service >/dev/null 2>&1 || true
  /usr/local/bin/h96max-dtb-guard.sh apply || warn "guard не смог применить правки (см. /var/log/h96max-dtb-guard.log)"
fi

# ---------------------------------------------------------------- DNS
log "Настраиваю DNS (systemd-resolved, с кэшем и запасными серверами)"
if [ "$DRY" = 0 ]; then
  install -d /etc/systemd/resolved.conf.d
  install -m 644 "$HERE/scripts/resolved-dns.conf" /etc/systemd/resolved.conf.d/99-h96max.conf
  # DNS в профилях NetworkManager — переживает смену сетей и обновления
  while IFS=: read -r uuid typ; do
    case "$typ" in
      802-11-wireless|802-3-ethernet)
        nmcli connection modify "$uuid" ipv4.dns "1.1.1.1 8.8.8.8" ipv4.ignore-auto-dns no >/dev/null 2>&1 || \
          warn "не удалось задать DNS для профиля $uuid"
        ;;
    esac
  done < <(nmcli -t -f UUID,TYPE connection show 2>/dev/null)
  systemctl enable systemd-resolved >/dev/null 2>&1 || true
  systemctl restart systemd-resolved >/dev/null 2>&1 || true
  # /etc/resolv.conf должен быть ссылкой на stub-резолвер, а не статичным файлом
  if [ ! -L /etc/resolv.conf ] || [ "$(readlink -f /etc/resolv.conf)" != "/run/systemd/resolve/stub-resolv.conf" ]; then
    cp -f /etc/resolv.conf "/root/resolv.conf.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
    ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    echo "    /etc/resolv.conf -> stub-resolv.conf"
  fi
  echo "    $(resolvectl status 2>/dev/null | grep -m1 'resolv.conf mode' | sed 's/^ *//')"
fi

# ---------------------------------------------------------------- Wi-Fi модуль
log "Настройки драйвера AIC8800"
if [ "$DRY" = 0 ]; then
  cat > /etc/modprobe.d/aic8800.conf <<'EOF'
# H96 Max RK3528: 20 МГц, без powersave (иначе SDIO рвётся), регион RU
options aic8800_sdio_wlan use_2040=0 ps_on=0 country_code=RU
options aic8800_sdio_bsp use_2040=0 ps_on=0 country_code=RU
EOF
  # симлинк на прошивки, который ждёт драйвер
  if [ -d /lib/firmware/aic8800/SDIO/aic8800D80 ] && [ ! -e /lib/firmware/aic8800_sdio ]; then
    ln -s /lib/firmware/aic8800/SDIO/aic8800D80 /lib/firmware/aic8800_sdio
    echo "    /lib/firmware/aic8800_sdio -> aic8800/SDIO/aic8800D80"
  fi
fi

# ---------------------------------------------------------------- udev
log "Правила udev (доступ к MPP/dma-heap/render для пользователя)"
if [ "$DRY" = 0 ]; then
  cat > /etc/udev/rules.d/99-mpp.rules <<'EOF'
# Rockchip VPU / GPU без root — нужно для аппаратного декодирования из-под пользователя
SUBSYSTEM=="misc", KERNEL=="mpp_service", MODE="0666"
SUBSYSTEM=="dma_heap", MODE="0666"
SUBSYSTEM=="drm", KERNEL=="renderD*", MODE="0666"
SUBSYSTEM=="drm", KERNEL=="card*", MODE="0666"
EOF
fi

# ---------------------------------------------------------------- Bluetooth
log "Сервисы Bluetooth (btattach + инициализация)"
if [ "$DRY" = 0 ]; then
  install -m 755 "$HERE/scripts/bt-init.sh" /usr/local/bin/bt-init.sh
  install -m 644 "$HERE/scripts/btattach.service" /etc/systemd/system/btattach.service
  install -m 644 "$HERE/scripts/bt-init.service" /etc/systemd/system/bt-init.service
  ln -sf /lib/systemd/system/bluetooth.service /etc/systemd/system/multi-user.target.wants/bluetooth.service
  systemctl daemon-reload
  systemctl enable btattach.service bt-init.service bluetooth.service >/dev/null 2>&1 || true
  systemctl restart btattach.service bt-init.service >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------- пакеты
log "Базовые пакеты"
if [ "$DRY" = 0 ]; then
  apt-get update -qq || warn "apt update не прошёл (нет сети?)"
  apt-get install -y -qq --no-install-recommends bluez rfkill >/dev/null 2>&1 || \
    warn "не удалось поставить bluez/rfkill"
fi

# ---------------------------------------------------------------- рабочий стол
if [ -z "$DESKTOP" ]; then
  if [ -t 0 ]; then
    echo
    echo "Рабочий стол нужен не всем: серверу (Home Assistant, Klipper, Docker) графика не требуется."
    echo "  1) без рабочего стола (рекомендуется)"
    echo "  2) LXQt      — самый лёгкий"
    echo "  3) XFCE      — привычный, средний"
    echo "  4) MATE      — классический"
    echo "  5) Cinnamon  — современный, тяжелее"
    echo "  6) KDE Plasma — самый тяжёлый"
    read -r -p "Выбор [1]: " ans
    case "${ans:-1}" in
      1|"") DESKTOP=none ;;
      2) DESKTOP=lxqt ;;
      3) DESKTOP=xfce ;;
      4) DESKTOP=mate ;;
      5) DESKTOP=cinnamon ;;
      6) DESKTOP=kde ;;
      *) DESKTOP=none ;;
    esac
  else
    DESKTOP=none
  fi
fi

install_desktop() {
  case "$1" in
    lxqt)     PKGS="lxqt-core sddm qterminal pcmanfm-qt"; DM=sddm ;;
    xfce)     PKGS="xfce4 xfce4-goodies lightdm";         DM=lightdm ;;
    mate)     PKGS="mate-desktop-environment lightdm";    DM=lightdm ;;
    cinnamon) PKGS="cinnamon-desktop-environment lightdm"; DM=lightdm ;;
    kde)      PKGS="kde-plasma-desktop sddm";             DM=sddm ;;
  esac
  log "Ставлю рабочий стол: $1 (это надолго, 10–20 минут)"
  apt-get install -y -qq --no-install-recommends $PKGS fonts-noto-core \
      xorg xserver-xorg-video-modesetting >/dev/null 2>&1 || die "не удалось поставить $1"
  systemctl enable "$DM" >/dev/null 2>&1 || true
  echo "    готово, вход через $DM"
}

if [ "$DESKTOP" = none ]; then
  log "Рабочий стол не ставим (серверный режим)"
elif [ "$DRY" = 1 ]; then
  echo "  (dry-run) установка рабочего стола: $DESKTOP"
else
  install_desktop "$DESKTOP"
fi

# ---------------------------------------------------------------- итог
log "Готово. Что проверить после перезагрузки"
cat <<EOF

  reboot

  # Wi-Fi
  nmcli dev wifi list
  nmcli dev wifi connect "ИМЯ_СЕТИ" password "ПАРОЛЬ"

  # Bluetooth (после загрузки ~20 секунд)
  bluetoothctl show          # должен быть MAC и Powered: yes
  bluetoothctl scan on

  # GPU
  glxinfo -B | grep renderer # Mali450

Если что-то не поднялось — смотрите dmesg и /boot/dtb/rockchip/${DTB_NAME}.orig
(оригинальный DTB можно вернуть копированием обратно).

Другой рабочий стол можно поставить позже:
  armbian-desktop-install xfce     # или kde, mate, cinnamon, lxqt
  armbian-config                    # System -> Desktop
EOF
