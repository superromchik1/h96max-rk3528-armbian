# Armbian для H96 Max RK3528 (4/32, плата RK3528_DDR3_8X4_V12)

Готовый набор, который превращает дешёвую TV-приставку на **Rockchip RK3528** в полноценный Linux-сервер: работают **Wi-Fi**, **Bluetooth**, **GPU Mali-450**, **HDMI**, загрузка с eMMC стабильная.

Это результат нескольких дней реверс-инжиниринга вендорского device tree. Всё, что нужно было исправить, — в одном скрипте и в готовом образе.

> **Как это сделано.** Проект собран в связке с **DeepSeek Harness** — агентной средой DeepSeek: агент подключался к приставке по SSH, читал `dmesg`, правил device tree, собирал драйверы и проверял результат на живой системе. Я (владелец устройства) ставил задачи и тестировал на телевизоре.

---

## Что работает

| Узел | Статус | Что было сломано |
|---|---|---|
| Загрузка с eMMC | ✅ | — |
| HDMI (1080p, консоль и X) | ✅ | в DTB был `chosen/bootargs` от Android (`init=/init`, `drm_kms_helper.fbdev_emulation=0`) — ядро не поднимало дисплей |
| GPU Mali-450 (lima, OpenGL 2.1) | ✅ | драйвер искал клоки `bus`/`core`, в DTB были `clk_mali`/`aclk_gpu_mali`/`pclk_gpu` — lima падал на probe |
| Аппаратный декодер `rkvdec2` | ⚠️ инициализируется | не хватало клоков `clk_core`/`clk_cabac`; сам VPU декодирует 1080p на 132 fps, но интеграция с пользовательскими плеерами не доделана |
| **Wi-Fi AIC8800D80** | ✅ | пин `gpio4.4`, описанный как «reset SDIO», на этой плате включает **регулятор 3.3 В** модуля |
| **Bluetooth AIC8800** | ✅ | узел `bluetooth-platdata` был `disabled`; транспорт — только `btattach -P h4`, и строго после загрузки BT-прошивки |
| Ethernet 100 Мбит | ✅ | — |
| Звук по HDMI | ✅ | — |

## Что не работает (честно)

- **Аппаратное декодирование в плеерах.** VPU исправен (`mpi_dec_test`: 720p — 204 fps, 1080p — 132 fps), но обвязка `rkmpp` в ffmpeg (5.1 и 6.1) несовместима с MPP 1.1.0 на этом ядре: декодер отдаёт 3–4 кадра и встаёт (`MPP_ERR_BUFFER_FULL`). Программное декодирование FullHD даёт 105 fps — для 1080p хватает, для 4K впритык (~28 fps).
- **Браузер не использует GPU для композитинга:** Mali-450 — OpenGL 2.1, а WebRender требует 3.1. FullHD в браузере возможен, но с рывками на склейках.

## Готовый образ (сервер, без рабочего стола)

```
h96max-rk3528-armbian.img.gz
размер: 862 МБ
sha256: f728d5c6ce3ed3420e616b8ef855b0ca0ed280806aec2a808cb0950e215852f4
```

Внутри: Armbian 26.11 (Debian 12, ядро 6.1.174-rk35xx-ophub), пропатченный DTB,
настроенные Wi-Fi и Bluetooth, udev-правила для VPU, **без графики**.

Прошивать как обычный образ:

```bash
gunzip -c h96max-rk3528-armbian.img.gz | dd of=/dev/sdX bs=4M status=progress
```

или Rufus / balenaEtcher на Windows. Рабочий стол при желании ставится одной командой
(`armbian-desktop-install`, см. ниже).

## Установка из свежего Armbian

Если хотите собрать своё или обновить существующую систему:

```bash
git clone <этот-репозиторий> h96max && cd h96max
./setup-h96max-rk3528.sh                  # спросит про рабочий стол
./setup-h96max-rk3528.sh --no-desktop     # сервер
./setup-h96max-rk3528.sh --desktop=lxqt   # сразу с графикой
```

Скрипт правит DTB (с бэкапом в `.orig`), прописывает `fdtfile` и `console=display`,
настраивает драйвер AIC8800, ставит udev-правила и сервисы Bluetooth.

Подробная пошаговая инструкция, включая перепрошивку с нуля и восстановление через Maskrom, — в [INSTALL.md](INSTALL.md).

## Рабочий стол: любой, по желанию

Графика большинству не нужна (сервер, Home Assistant, Klipper, Docker), поэтому
по умолчанию её нет. Если нужна — выбор не ограничен LXQt.

**Через установщик из образа:**

```bash
armbian-desktop-install            # LXQt (по умолчанию, самый лёгкий)
armbian-desktop-install xfce       # XFCE
armbian-desktop-install kde        # KDE Plasma
armbian-desktop-install mate       # MATE
armbian-desktop-install cinnamon   # Cinnamon
```

**Или стандартными средствами Armbian:**

```bash
armbian-config        # System → Desktop → выбрать окружение из списка
```

**Или вручную через apt:**

```bash
# XFCE — компромисс скорости и привычности
apt install xfce4 xfce4-goodies lightdm

# KDE Plasma — тяжелее, но современный
apt install kde-plasma-desktop sddm

# MATE / Cinnamon
apt install mate-desktop mate-desktop-environment lightdm
apt install cinnamon cinnamon-desktop-environment lightdm

# LXQt — самый лёгкий для 4 ядер A53
apt install lxqt-core sddm qterminal pcmanfm-qt
```

Затем `systemctl enable sddm` (или `lightdm`) и `reboot`.

Ориентир по памяти на этой плате (4 ГБ):

| Окружение | RAM в простое | Заметка |
|---|---|---|
| LXQt | ~350 МБ | самый быстрый на Mali-450 |
| XFCE | ~450 МБ | xfwm4 уже используется как WM |
| MATE | ~500 МБ | — |
| Cinnamon | ~700 МБ | требует GL-акселерации, может быть медленным |
| KDE Plasma | ~900 МБ | тяжело для 4 ядер, но работает |

## Технические детали (самое интересное)

### Wi-Fi: пин, который всё менял

В вендорском DTB пин `gpio4.4` был описан как `reset-gpios` для SDIO. На этой плате он включает **силовой регулятор 3.3 В** модуля AIC8800. Пока пин не поднят как регулятор, чип перечисляется по SDIO, читает ID, но не может принять прошивку — в логе бесконечно `aicwf_sdio_tx_msg: tx msg fc retry fail`.

Правильно так:

```dts
vcc_wifi_reg: vcc-wifi-reg {
    compatible = "regulator-fixed";
    enable-active-high;
    gpios = <&gpio4 4 GPIO_ACTIVE_HIGH>;
    regulator-name = "vcc_wifi";
    regulator-always-on;
    regulator-boot-on;
    regulator-min-microvolt = <3300000>;
    regulator-max-microvolt = <3300000>;
};

&sdio {           /* mmc@ffc10000 */
    vmmc-supply = <&vcc_wifi_reg>;
    max-frequency = <50000000>;
    bus-width = <4>;
    cap-sd-highspeed;
    post-power-on-delay-ms = <50>;
    /* cap-sdio-irq убрать: линия прерываний на этой разводке не работает */
};
```

А `WL_REG_ON` — это `gpio1.6`, его должен дёргать `mmc-pwrseq` (active-low), поэтому LED-заглушку `pwr-wifi` из дерева нужно убрать.

### Bluetooth: не hciattach, а btattach

Чип грузит BT-прошивку силами драйвера (`aicbsp: BT firmware ready` на ~16-й секунде). После этого HCI поднимается только так:

```bash
btattach -B /dev/ttyS2 -S 1500000 -P h4
rfkill unblock bluetooth
hciconfig hci0 up
```

`hciattach` для этого чипа не работает — MAC остаётся `00:00:00:00:00:00`, а `hci0` не отвечает на HCI Reset.

### GPU: имена клоков

```dts
clocks = <&cru ACLK_GPU_MALI>, <&cru ACLK_GPU_MALI>;
clock-names = "bus", "core";
interrupt-names = "gp", "gpmmu", "pp", "pp0", "ppmmu0", "pp1", "ppmmu1";
```

Иначе `lima: get bus clk failed -2` и вся отрисовка уходит в программный режим (проверено: 600 кадров 1080p — 24,4 с против 1,7 с с GPU).

## Совместимость

Проверено на:

- **H96 Max RK3528**, 4 ГБ DDR3 / 32 ГБ eMMC, плата `RK3528_DDR3_8X4_V12`, SoC `rockchip,rk3528a`
- Armbian 26.11 (Debian 12, ядро `6.1.174-rk35xx-ophub`)
- DTB: вендорский, вытащенный из Android и пропатченный

На других ревизиях платы (4/64, DDR4, другие Wi-Fi-чипы) правки могут отличаться — сверяйтесь с `dmesg` и `STATUS.md`, а скрипт `setup.sh` правит DTB на месте под вашу плату.

## Благодарности

- **DeepSeek Harness** — агентная среда, в которой велась вся работа: диагностика по SSH, правки device tree, сборка драйверов, проверка на живой системе.
- **ophub** — за сборки Armbian для Rockchip ([amlogic-s9xxx-armbian](https://github.com/ophub/amlogic-s9xxx-armbian)).

## Лицензия

Скрипты — MIT. Правки device tree — по мотивам вендорского DTB Rockchip.
