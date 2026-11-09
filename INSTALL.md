# Полная инструкция: Armbian на H96 Max RK3528

Пошагово, с нуля: от стоковой Android-приставки до рабочей Linux-системы.
Если приставка уже на Armbian — переходите сразу к шагу 5.

---

## Вариант 0. Готовый образ (самый быстрый путь)

Если не хотите ничего настраивать — прошейте готовый образ:

```
h96max-rk3528-armbian.img.gz   (862 МБ)
sha256: f728d5c6ce3ed3420e616b8ef855b0ca0ed280806aec2a808cb0950e215852f4
```

Внутри уже: пропатченный DTB, рабочие Wi-Fi и Bluetooth, udev-правила для VPU,
**рабочего стола нет** (серверный образ). Нужен стол — на приставке выполните
`armbian-desktop-install`.

Записать на флешку:

```bash
gunzip -c h96max-rk3528-armbian.img.gz | dd of=/dev/sdX bs=4M status=progress
```

Дальше — сразу шаг 3 (первая загрузка), шаги 5–6 не нужны: всё уже применено.

## Что понадобится

- H96 Max RK3528 (4/32, плата `RK3528_DDR3_8X4_V12`) — на других ревизиях не проверялось
- microSD 8 ГБ+ или USB-флешка (для первого запуска)
- HDMI-телевизор/монитор, клавиатура (USB)
- Кабель **USB-A ↔ USB-A** (для восстановления через Maskrom, если что-то пойдёт не так)
- ПК с Windows/Linux и `rkdeveloptool` (лежит в папке `tools/`)

## Шаг 1. Скачать образ

Возьмите образ **Armbian для rk3528** от ophub (сборки `h96-max-m2` или универсальные `rockchip`):

- https://github.com/ophub/amlogic-s9xxx-armbian/releases (раздел Rockchip / rk3528)
- файл вида `Armbian_*_rockchip_h96-max-m2_bookworm_*_server_*.img.gz`

> Подойдёт и образ для другой rk3528-платы: главное — чтобы внутри был
> `/boot/dtb/rockchip/rk3528-evb2-ddr3-v10.dtb`. Он есть во всех сборках для rk3528.

## Шаг 2. Записать на флешку

- **Windows:** Rufus или balenaEtcher (`rufus.exe` есть в `tools/`)
- **Linux:** `xz -dc image.img.xz | dd of=/dev/sdX bs=4M status=progress`

## Шаг 3. Первая загрузка

1. Вставьте флешку в приставку.
2. Подключите HDMI и клавиатуру.
3. Включите питание.

Если приставка грузится в Android — нажмите кнопку восстановления/Reset при включении
(на разных платах по-разному: удерживать кнопку в гнезде AV или зажать Reset зубочисткой).
После появления лого Armbian (или консоли) флешку можно не трогать.

Первый запуск: логин `root`, пароль `1234` (Armbian попросит сменить).

## Шаг 4. Установить систему на eMMC (по желанию)

```bash
armbian-install
```

Выберите «Install/Update the bootloader on eMMC» и «Install/Update Armbian to eMMC»,
файловая система ext4. После установки выключите питание, выньте флешку, включите снова —
система загрузится с eMMC.

> **Важно:** не оставляйте флешку вставленной при загрузке, если на ней клон системы —
> совпадающие UUID разделов приводят к путанице с корнем.

## Шаг 5. Применить фиксы (главный шаг)

Скопируйте папку `release/` на приставку (или клонируйте репозиторий) и запустите:

```bash
cd /root/h96max-setup          # или где лежит пакет
chmod +x setup-h96max-rk3528.sh
./setup-h96max-rk3528.sh
```

Скрипт спросит про рабочий стол (по умолчанию — без него). Варианты:

| Команда | Что будет |
|---|---|
| `./setup-h96max-rk3528.sh --no-desktop` | только консоль (сервер, Home Assistant, Klipper) |
| `./setup-h96max-rk3528.sh --desktop=lxqt` | LXQt — самый лёгкий |
| `./setup-h96max-rk3528.sh --desktop=xfce` | XFCE — привычный, средний |
| `./setup-h96max-rk3528.sh --desktop=mate` | MATE — классический |
| `./setup-h96max-rk3528.sh --desktop=cinnamon` | Cinnamon — современный, тяжелее |
| `./setup-h96max-rk3528.sh --desktop=kde` | KDE Plasma — самый тяжёлый |
| `./setup-h96max-rk3528.sh --dry-run` | показать план без изменений |

Если запустить без аргументов и в терминале — скрипт покажет меню с этими вариантами.

Затем:

```bash
reboot
```

## Шаг 6. Проверка

После перезагрузки (дайте ~30 секунд):

```bash
# Wi-Fi
nmcli dev wifi list
nmcli dev wifi connect "ИМЯ" password "ПАРОЛЬ"

# Bluetooth
bluetoothctl show            # должен быть MAC и Powered: yes
bluetoothctl scan on         # список устройств рядом

# GPU
glxinfo -B | grep renderer   # OpenGL renderer string: Mali450

# HDMI/дисплей
cat /sys/class/drm/card0-HDMI-A-1/status   # connected
```

Ожидаемые результаты:

- `wlan0` видит сети 2.4 и 5 ГГц, подключается;
- `hci0` — `UP RUNNING`, MAC вида `D8:74:EF:xx:xx:xx`;
- `glxinfo` показывает **Mali450**;
- в `dmesg` нет `lima: get bus clk failed`.

## Шаг 7. Что дальше

**Сервер (без рабочего стола)** — самые частые сценарии:

```bash
# Home Assistant в Docker
curl -fsSL https://get.docker.com | sh
docker run -d --name hass --restart=unless-stopped --net=host \
  -v /opt/hass:/config ghcr.io/home-assistant/home-assistant:stable

# Klipper (3D-принтер)
sudo apt install git -y && git clone https://github.com/th33xitus/kiauh.git
./kiauh/kiauh.sh
```

**Рабочий стол** — если передумали и хотите графику:

```bash
armbian-desktop-install              # LXQt (по умолчанию)
armbian-desktop-install xfce         # XFCE
armbian-desktop-install kde          # KDE Plasma
armbian-desktop-install mate         # MATE
armbian-desktop-install cinnamon     # Cinnamon
```

Или стандартным способом Armbian: `armbian-config` → System → Desktop.

## Восстановление, если что-то пошло не так

Всегда есть путь назад — **Maskrom**:

1. Отключите питание.
2. Зажмите кнопку в гнезде AV и замкните два контакта на плате (у `RK3528_DDR3_8X4_V12`
   они рядом с eMMC; фото ищите в теме 4PDA, пост 142893859).
3. Подключите USB-A↔USB-A к ПК — устройство определится как `Loader`/`Maskrom` (`VID 2207`).
4. Заливайте образ через `rkdeveloptool` из `tools/`:

```powershell
rkdeveloptool.exe db image.img          # записать образ
rkdeveloptool.exe rd 0 0x100            # проверить чтением
```

Если нужно вернуть только загрузчик (idbloader), он лежит в `tools/vendor_idbloader.bin`
и пишется по смещению `0x8000` (сектор 64):

```powershell
rkdeveloptool.exe wl 64 vendor_idbloader.bin
```

## Частые проблемы

| Симптом | Причина / решение |
|---|---|
| Чёрный экран, нет HDMI | в DTB остался `chosen/bootargs` — скрипт его вычищает; проверьте, что `fdtfile` указывает на `rk3528-evb2-ddr3-v10.dtb` |
| `lima: get bus clk failed -2` | не применены правки GPU — запустите скрипт заново |
| Wi-Fi: `tx msg fc retry fail` | не поднят регулятор 3.3 В (`vcc_wifi`) — DTB не пропатчен |
| Bluetooth: MAC `00:00:00:00:00:00` | используется `hciattach` вместо `btattach`; или `btattach` стартовал до `BT firmware ready` |
| Нет звука по HDMI | проверьте `aplay -l`, выберите HDMI-выход в `alsamixer` |
| Система не грузится с eMMC | залейте `vendor_idbloader.bin` по смещению `0x8000` через Maskrom |

## Полезные файлы репозитория

```
release/
├── setup-h96max-rk3528.sh      # главный установщик
├── scripts/dtb-fix.py          # правки device tree (идемпотентно)
├── scripts/btattach.service    # автозапуск Bluetooth
├── scripts/bt-init.sh          # rfkill unblock + hci0 up
└── files/rk3528-evb2-ddr3-v10.dtb  # уже пропатченный DTB (можно скопировать вручную)
```
