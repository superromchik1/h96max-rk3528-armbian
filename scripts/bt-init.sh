#!/bin/sh
# bt-init.sh — доводит Bluetooth до рабочего состояния на H96 Max RK3528.
# Ждёт появления hci0, снимает rfkill-блокировку и поднимает интерфейс.
set -u

for i in $(seq 1 30); do
    sleep 1
    [ -e /sys/class/bluetooth/hci0 ] && break
done

rfkill unblock bluetooth 2>/dev/null || true
hciconfig hci0 up 2>/dev/null || true
sleep 1
bluetoothctl power on >/dev/null 2>&1 || true

exit 0
