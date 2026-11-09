#!/bin/bash
# make-image.sh — вшивает фиксы H96 Max RK3528 в готовый образ Armbian (.img),
# чтобы после прошивки всё работало сразу: сервер без рабочего стола,
# но с рабочими Wi-Fi, Bluetooth, GPU и HDMI.
#
# Запускать на Linux (лучше — на самой приставке с Armbian: там aarch64).
#
#   ./make-image.sh Armbian_....img [--out h96max-rk3528-armbian.img]
#
# Учитывает, что в образах Armbian /boot лежит на отдельном FAT-разделе (p1),
# а корень — на ext4 (p2).
set -euo pipefail

IMG="${1:-}"
OUT=""
shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    *) echo "неизвестный аргумент: $1"; exit 2 ;;
  esac
done

[ -n "$IMG" ] || { echo "использование: $0 <image.img> [--out name.img]"; exit 2; }
[ -f "$IMG" ] || { echo "нет файла $IMG"; exit 2; }
[ "$(id -u)" = 0 ] || { echo "нужен root"; exit 2; }

HERE="$(cd "$(dirname "$0")" && pwd)"
DTB_NAME="rk3528-evb2-ddr3-v10.dtb"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31m[x] %s\033[0m\n' "$*" >&2; exit 1; }

command -v losetup >/dev/null || die "нужен losetup (util-linux)"
command -v dtc >/dev/null || die "нужен dtc (apt install device-tree-compiler)"

WORK="$(mktemp -d)"
LOOP=""; BOOT_MNT=""; ROOT_MNT=""
cleanup() {
  set +e
  [ -n "$BOOT_MNT" ] && mountpoint -q "$BOOT_MNT" && umount "$BOOT_MNT"
  [ -n "$ROOT_MNT" ] && mountpoint -q "$ROOT_MNT" && umount "$ROOT_MNT"
  [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

# ---------------------------------------------------------------- разделы
log "Подключаю образ"
LOOP="$(losetup -f --show -P "$IMG")" || die "не удалось подключить образ"
echo "    loop: $LOOP"
sleep 1

ROOT_PART=""; BOOT_PART=""
# в образах Armbian бывает и FAT, и ext4 для /boot — определяем по содержимому
for p in "${LOOP}"p*; do
  [ -b "$p" ] || continue
  T="$(blkid -o value -s TYPE "$p" 2>/dev/null || true)"
  case "$T" in ext4|vfat|fat32|msdos) ;; *) continue ;; esac
  TMPMNT="$WORK/probe-$(basename "$p")"
  mkdir -p "$TMPMNT"
  if mount -o rw "$p" "$TMPMNT" 2>/dev/null; then
    if [ -f "$TMPMNT/armbianEnv.txt" ] || [ -d "$TMPMNT/dtb/rockchip" ]; then
      BOOT_PART="$p"; BOOT_MNT="$TMPMNT"; continue
    fi
    if [ -f "$TMPMNT/etc/os-release" ]; then
      ROOT_PART="$p"; ROOT_MNT="$TMPMNT"; continue
    fi
    umount "$TMPMNT"
  fi
done
[ -n "$ROOT_PART" ] || die "не нашёл корневой раздел (нет /etc/os-release)"
echo "    корень:  $ROOT_PART"
echo "    boot:    ${BOOT_PART:-внутри корня}"

if [ -z "$BOOT_MNT" ]; then
  if [ -f "$ROOT_MNT/boot/armbianEnv.txt" ] || [ -d "$ROOT_MNT/boot/dtb/rockchip" ]; then
    BOOT_DIR="$ROOT_MNT/boot"
  else
    die "не нашёл раздел с /boot (armbianEnv.txt или dtb/rockchip)"
  fi
else
  BOOT_DIR="$BOOT_MNT"
fi
echo "    boot смонтирован: $BOOT_DIR"

DTB="$BOOT_DIR/dtb/rockchip/$DTB_NAME"
[ -f "$DTB" ] || DTB="$BOOT_DIR/boot/dtb/rockchip/$DTB_NAME"
[ -f "$DTB" ] || DTB=$(ls "$BOOT_DIR"/dtb/rockchip/rk3528-*.dtb 2>/dev/null | head -1)
[ -n "$DTB" ] && [ -f "$DTB" ] || die "в образе нет rk3528-*.dtb — это не образ для rk3528"
echo "    DTB: $DTB"

# ---------------------------------------------------------------- DTB
log "Ставлю DTB"
[ -f "${DTB}.orig" ] || cp -f "$DTB" "${DTB}.orig"

DTB_SRC="$HERE/files/$DTB_NAME"
if [ -f "$DTB_SRC" ]; then
  # В образе лежит демо-DTB другой платы; используем проверенный вендорский,
  # вытащенный из Android и пропатченный (он и работает на этой плате).
  cp -f "$DTB_SRC" "$DTB"
  echo "    взят готовый DTB из пакета: $(sha256sum "$DTB_SRC" | cut -c1-16)…"
  python3 "$HERE/scripts/dtb-fix.py" "$DTB" --out "$WORK/dtb.new" >/dev/null
  cp -f "$WORK/dtb.new" "$DTB"
  echo "    контрольный прогон правок выполнен"
else
  echo "    готового DTB нет — патчу тот, что в образе"
  python3 "$HERE/scripts/dtb-fix.py" "$DTB" --out "$WORK/dtb.new"
  cp -f "$WORK/dtb.new" "$DTB"
fi

log "Правлю armbianEnv.txt"
ENVF="$BOOT_DIR/armbianEnv.txt"
touch "$ENVF"
if grep -q '^fdtfile=' "$ENVF"; then
  sed -i "s|^fdtfile=.*|fdtfile=rockchip/${DTB_NAME}|" "$ENVF"
else
  echo "fdtfile=rockchip/${DTB_NAME}" >> "$ENVF"
fi
# console=both занял бы UART (ttyS2), а он нужен Bluetooth
if grep -q '^console=' "$ENVF"; then
  sed -i 's|^console=.*|console=display|' "$ENVF"
else
  echo "console=display" >> "$ENVF"
fi
echo "    $(grep -E '^(fdtfile|console)=' "$ENVF" | tr '\n' ' ')"

# ---------------------------------------------------------------- конфиги
log "Кладу конфиги и сервисы в корень образа"
install -d "$ROOT_MNT/root/h96max-setup" \
           "$ROOT_MNT/etc/modprobe.d" \
           "$ROOT_MNT/etc/udev/rules.d" \
           "$ROOT_MNT/usr/local/bin" \
           "$ROOT_MNT/etc/systemd/system/multi-user.target.wants"
cp -a "$HERE/." "$ROOT_MNT/root/h96max-setup/"

cat > "$ROOT_MNT/etc/modprobe.d/aic8800.conf" <<'EOF'
options aic8800_sdio_wlan use_2040=0 ps_on=0 country_code=RU
options aic8800_sdio_bsp use_2040=0 ps_on=0 country_code=RU
EOF

cat > "$ROOT_MNT/etc/udev/rules.d/99-mpp.rules" <<'EOF'
SUBSYSTEM=="misc", KERNEL=="mpp_service", MODE="0666"
SUBSYSTEM=="dma_heap", MODE="0666"
SUBSYSTEM=="drm", KERNEL=="renderD*", MODE="0666"
SUBSYSTEM=="drm", KERNEL=="card*", MODE="0666"
EOF

install -m 755 "$HERE/scripts/bt-init.sh" "$ROOT_MNT/usr/local/bin/bt-init.sh"
install -m 644 "$HERE/scripts/btattach.service" "$ROOT_MNT/etc/systemd/system/btattach.service"
install -m 644 "$HERE/scripts/bt-init.service" "$ROOT_MNT/etc/systemd/system/bt-init.service"

ln -sf /lib/systemd/system/bluetooth.service \
       "$ROOT_MNT/etc/systemd/system/multi-user.target.wants/bluetooth.service"
ln -sf /etc/systemd/system/btattach.service \
       "$ROOT_MNT/etc/systemd/system/multi-user.target.wants/btattach.service"
ln -sf /etc/systemd/system/bt-init.service \
       "$ROOT_MNT/etc/systemd/system/multi-user.target.wants/bt-init.service"

if [ -d "$ROOT_MNT/lib/firmware/aic8800/SDIO/aic8800D80" ] && [ ! -e "$ROOT_MNT/lib/firmware/aic8800_sdio" ]; then
  ln -s /lib/firmware/aic8800/SDIO/aic8800D80 "$ROOT_MNT/lib/firmware/aic8800_sdio"
fi

# ---------------------------------------------------------------- рабочий стол по желанию
log "Добавляю установщик рабочего стола (по желанию)"
cat > "$ROOT_MNT/usr/local/bin/armbian-desktop-install" <<'EOF'
#!/bin/sh
# Ставит рабочий стол по выбору. Без аргумента — LXQt (самый лёгкий).
#   armbian-desktop-install [lxqt|xfce|kde|mate|cinnamon]
set -e
[ "$(id -u)" = 0 ] || { echo "запускать от root"; exit 1; }
ENV="${1:-lxqt}"
case "$ENV" in
  lxqt)     PKGS="lxqt-core sddm qterminal pcmanfm-qt"; DM=sddm ;;
  xfce)     PKGS="xfce4 xfce4-goodies lightdm";         DM=lightdm ;;
  mate)     PKGS="mate-desktop-environment lightdm";    DM=lightdm ;;
  cinnamon) PKGS="cinnamon-desktop-environment lightdm"; DM=lightdm ;;
  kde)      PKGS="kde-plasma-desktop sddm";             DM=sddm ;;
  *) echo "неизвестное окружение: $ENV (lxqt|xfce|kde|mate|cinnamon)"; exit 1 ;;
esac
apt-get update -qq
apt-get install -y --no-install-recommends $PKGS fonts-noto-core \
  xorg xserver-xorg-video-modesetting
systemctl enable "$DM"
echo "Готово ($ENV): перезагрузитесь, вход через $DM."
EOF
chmod 755 "$ROOT_MNT/usr/local/bin/armbian-desktop-install"

cat > "$ROOT_MNT/etc/motd" <<'EOF'

  Armbian для H96 Max RK3528 — Wi-Fi, Bluetooth, GPU и HDMI уже настроены.
  Нужен рабочий стол?   ->  armbian-desktop-install [lxqt|xfce|kde|mate|cinnamon]
  Подробности и файлы:  ->  /root/h96max-setup/

EOF

# ---------------------------------------------------------------- финал
log "Размонтирую"
umount "$BOOT_MNT" 2>/dev/null || true; BOOT_MNT=""
umount "$ROOT_MNT" 2>/dev/null || true; ROOT_MNT=""
losetup -d "$LOOP"; LOOP=""

if [ -n "$OUT" ]; then
  mv "$IMG" "$OUT"; IMG="$OUT"
fi

log "Готово: $IMG"
ls -lh "$IMG"
echo
echo "Дальше:"
echo "  pigz -1 -c '$IMG' > '${IMG%.img}.img.gz'   # сжать для раздачи"
echo "  dd if='$IMG' of=/dev/sdX bs=4M status=progress   # писать на флешку"
