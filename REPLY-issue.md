# Короткий ответ для GitHub-issue / форума

> Кому: в issue вида «Does H96 Max RK3528 work with Armbian? Wi-Fi/BT not working».

---

Да, работает — но требует правок device tree. У меня H96 Max RK3528, 4/32, плата `RK3528_DDR3_8X4_V12`, Wi-Fi+BT на AIC8800D80.

Коротко, что нужно:

1. **HDMI**: вычистить `chosen/bootargs` из вендорского DTB (`rk3528-evb2-ddr3-v10.dtb`) — иначе чёрный экран.
2. **Wi-Fi**: `gpio4.4` в этом DTB описан как reset SDIO, но фактически это **enable регулятора 3.3 В** модуля. Нужно добавить `regulator-fixed` (`vcc_wifi`) и `vmmc-supply` у `mmc@ffc10000`, а `WL_REG_ON` (`gpio1.6`) отдать `mmc-pwrseq` (active-low). Плюс `post-power-on-delay-ms = <50>`, 50 МГц, 4 бита, без `cap-sdio-irq`.
3. **Bluetooth**: включить узел `bluetooth-platdata` (`status = "okay"`, `bt_port = "/dev/ttyS2"`), а HCI поднимать **не** `hciattach`, а `btattach -B /dev/ttyS2 -S 1500000 -P h4` — и только после `aicbsp: BT firmware ready` в dmesg. Дальше `rfkill unblock bluetooth` и `hciconfig hci0 up`.
4. **GPU**: у `gpu@ff700000` заменить имена клоков на `bus`/`core` (в вендорском DTB `clk_mali`/`aclk_gpu_mali`/`pclk_gpu`) и `interrupt-names` на mainline-вариант.
5. **rkvdec2**: добавить клоки `clk_core`/`clk_cabac` (драйвер `mpp_rkvdec2` их требует).

Всё это делает скрипт: `setup-h96max-rk3528.sh` (правит DTB с бэкапом, ставит сервисы Bluetooth, udev-правила). Запускается на свежем Armbian и спрашивает, нужен ли рабочий стол.

Рабочий результат после правок: `wlan0` в сети, `hci0 UP RUNNING` с реальным MAC, `glxinfo` → Mali450.

Что пока не работает: аппаратное декодирование в ffmpeg и пользовательских плеерах — `rkmpp`-обвязка ffmpeg 5.1/6.1 несовместима с публичным MPP 1.1.0 на этом ядре (`MPP_ERR_BUFFER_FULL` после 3–4 кадров). Сам VPU исправен: `mpi_dec_test` даёт 1080p 132 fps. Если у кого-то есть MPP из SDK, совпадающего с ядром ophub (`mpp_service` от 14.10.2026), — поделитесь, это последний недостающий кусок.
