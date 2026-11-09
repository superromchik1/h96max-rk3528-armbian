#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
dtb-fix.py — правит вендорский DTB H96 Max RK3528 (плата RK3528_DDR3_8X4_V12)
так, чтобы в Armbian работали: HDMI, Wi-Fi AIC8800, Bluetooth, GPU Mali-450,
аппаратный декодер rkvdec2.

Скрипт идемпотентен: повторный запуск ничего не ломает.

Использование:
    dtb-fix.py /boot/dtb/rockchip/rk3528-evb2-ddr3-v10.dtb [--out /tmp/new.dtb]

Требует: dtc (device-tree-compiler), python3.
Все правки делаются в текстовом DTS и проверяются обратной компиляцией.
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

# ---------------------------------------------------------------- утилиты


def run(cmd):
    return subprocess.run(cmd, check=True, capture_output=True, text=True).stdout


def decompile(dtb, dts):
    run(["dtc", "-I", "dtb", "-O", "dts", "-o", dts, "-q", dtb])


def compile_(dts, dtb):
    run(["dtc", "-I", "dts", "-O", "dtb", "-o", dtb, dts])


def find_node(text, name):
    """Возвращает (start, end) диапазон узла `name { ... };`.

    В DTB бывают одноимённые узлы на разных уровнях (например, `sdio-pwrseq`
    и как pinctrl-группа). Берём самый верхний — с минимальным отступом.
    """
    matches = list(re.finditer(r"\n(\t+)%s \{" % re.escape(name), text))
    if not matches:
        return None
    best = min(matches, key=lambda m: len(m.group(1)))
    start = best.start() + 1
    end = text.find("\n\t};", start)
    if end < 0:
        return None
    return start, end


def node_text(text, name):
    rng = find_node(text, name)
    return None if not rng else text[rng[0]:rng[1] + 4]


def replace_node(text, name, new_body):
    rng = find_node(text, name)
    if not rng:
        return text, False
    return text[:rng[0]] + new_body + text[rng[1] + 4:], True


def get_prop(body, prop):
    m = re.search(r"%s = ([^;]+);" % re.escape(prop), body)
    return m.group(1) if m else None


def set_prop(body, prop, value):
    pattern = re.compile(r"%s = [^;]+;" % re.escape(prop))
    if pattern.search(body):
        return pattern.sub("%s = %s;" % (prop, value), body, count=1)
    # вставить после открывающей строки узла
    lines = body.split("\n")
    head = lines[0]
    return "\n".join([head, "\t\t%s = %s;" % (prop, value)] + lines[1:]) if value else body


def del_prop(body, prop):
    return re.sub(r"\n\t+%s = [^;]+;" % re.escape(prop), "", body)


# ---------------------------------------------------------------- правки


def strip_bootargs(text):
    m = re.search(r"\n\tchosen \{(.*?)\n\t\};", text, re.S)
    if not m:
        return text, False
    body = m.group(0)
    if "bootargs" not in body:
        return text, False
    new = re.sub(r"\n\t+bootargs = \"[^\"]*\";", "", body)
    return text.replace(body, new), True


def patch_sdio(text, ph_cru):
    """SDIO под Wi-Fi: 50 МГц, 4 бита, задержка питания, без SDIO-IRQ."""
    body = node_text(text, "mmc@ffc10000")
    if body is None:
        return text, False
    changed = False
    for prop, val in (
        ("max-frequency", "<0x2faf080>"),          # 50 MHz
        ("bus-width", "<0x04>"),
        ("post-power-on-delay-ms", "<0x32>"),      # 50 ms
    ):
        if get_prop(body, prop) != val:
            body = set_prop(body, prop, val)
            changed = True
    if "cap-sd-highspeed;" not in body:
        body = body.replace("\t\tcap-sdio-irq;", "\t\tcap-sd-highspeed;")
        body = body.replace("\t\tbus-width = <0x04>;", "\t\tbus-width = <0x04>;\n\t\tcap-sd-highspeed;")
        changed = True
    if "cap-sdio-irq;" in body:
        body = body.replace("\t\tcap-sdio-irq;\n", "").replace("\t\tcap-sdio-irq;", "")
        changed = True
    text, _ = replace_node(text, "mmc@ffc10000", body)
    return text, changed


def patch_wifi_power(text):
    """
    Ключевая правка: gpio4.4 — это enable регулятора 3.3 В модуля (а не reset SDIO).
    Добавляем regulator-fixed и vmmc-supply; pwrseq переводим на gpio1.6 (WL_REG_ON).
    """
    pwrseq = node_text(text, "sdio-pwrseq")
    if pwrseq is None:
        return text, False

    # phandle gpio4 берём из существующего reset-gpios (это и есть нужный пин)
    m = re.search(r"reset-gpios = <(0x[0-9a-f]+) 0x04", pwrseq)
    if not m:
        return text, False
    ph_gpio4 = m.group(1)

    # phandle gpio1 берём из BT,reset_gpio
    bt = node_text(text, "wireless-bluetooth")
    if bt is None:
        return text, False
    m1 = re.search(r'BT,reset_gpio = <(0x[0-9a-f]+)', bt)
    if not m1:
        return text, False
    ph_gpio1 = m1.group(1)

    changed = False

    # 1) pwrseq -> gpio1.6 active-low (WL_REG_ON)
    new_pwrseq = re.sub(r"reset-gpios = <0x[0-9a-f]+ 0x[0-9a-f]+ 0x[0-9a-f]+>;",
                        "reset-gpios = <%s 0x06 0x01>;" % ph_gpio1, pwrseq, count=1)
    if new_pwrseq != pwrseq:
        text, _ = replace_node(text, "sdio-pwrseq", new_pwrseq)
        changed = True

    # 2) убрать LED-заглушку pwr-wifi (этот же пин теперь у pwrseq)
    led = re.search(r"\n\t\tpwr-wifi \{[^}]*\};", text)
    if led:
        text = text.replace(led.group(0), "")
        changed = True

    # 3) добавить регулятор vcc_wifi на gpio4.4 (active-high, always-on)
    if "vcc-wifi-reg" not in text:
        node = (
            "\n\tvcc_wifi_reg: vcc-wifi-reg {\n"
            "\t\tcompatible = \"regulator-fixed\";\n"
            "\t\tenable-active-high;\n"
            "\t\tgpios = <%s 0x04 0x00>;\n"
            "\t\tregulator-name = \"vcc_wifi\";\n"
            "\t\tregulator-always-on;\n"
            "\t\tregulator-boot-on;\n"
            "\t\tregulator-min-microvolt = <0x325aa0>;\n"
            "\t\tregulator-max-microvolt = <0x325aa0>;\n"
            "\t\tphandle = <0x201>;\n"
            "\t};\n" % ph_gpio4
        )
        k = text.rstrip().rfind("\n};")
        text = text[:k] + node + text[k:]
        changed = True

    # 4) vmmc-supply у SDIO
    body = node_text(text, "mmc@ffc10000")
    if body is not None and "vmmc-supply" not in body:
        body = body.replace("mmc@ffc10000 {", "mmc@ffc10000 {\n\t\tvmmc-supply = <0x201>;", 1)
        text, _ = replace_node(text, "mmc@ffc10000", body)
        changed = True

    return text, changed


def patch_bluetooth(text):
    """Включаем узел, задаём порт и полярность сброса."""
    body = node_text(text, "wireless-bluetooth")
    if body is None:
        return text, False
    changed = False
    if 'status = "okay";' not in body:
        body = body.replace('status = "disabled";', 'status = "okay";')
        changed = True
    if "bt_port" not in body:
        body = body.replace('compatible = "bluetooth-platdata";',
                            'compatible = "bluetooth-platdata";\n\t\tbt_port = "/dev/ttyS2";', 1)
        changed = True
    m = re.search(r'BT,reset_gpio = <(0x[0-9a-f]+) 0x11 (0x[0-9a-f]+)>;', body)
    if m and m.group(2) != "0x01":
        body = body.replace(m.group(0), "BT,reset_gpio = <%s 0x11 0x01>;" % m.group(1))
        changed = True
    text, _ = replace_node(text, "wireless-bluetooth", body)
    return text, changed


def patch_gpu(text):
    """
    lima ждёт клоки bus/core, а вендор даёт clk_mali/aclk_gpu_mali/pclk_gpu.
    Берём значение aclk_gpu_mali и подставляем под оба имени.
    """
    body = node_text(text, "gpu@ff700000")
    if body is None:
        return text, False
    if 'clock-names = "bus\\0core";' in body:
        return text, False
    names = get_prop(body, "clock-names")
    clocks = get_prop(body, "clocks")
    if not names or not clocks:
        return text, False
    nm = [x.strip('"') for x in names.strip("<>").split("\\0")]
    cl = clocks.strip("<>").split()
    if len(nm) != len(cl):
        return text, False
    if "aclk_gpu_mali" not in nm:
        return text, False
    aclk = cl[nm.index("aclk_gpu_mali")]
    if len(aclk.split()) != 2:
        return text, False
    body = set_prop(body, "clocks", "<%s %s %s %s>" % (aclk, aclk))
    body = set_prop(body, "clock-names", '"bus\\0core"')
    body = set_prop(body, "interrupt-names",
                    '"gp\\0gpmmu\\0pp\\0pp0\\0ppmmu0\\0pp1\\0ppmmu1"')
    text, _ = replace_node(text, "gpu@ff700000", body)
    return text, True


def patch_rkvdec(text):
    """Драйвер mpp_rkvdec2 ждёт клоки clk_core/clk_cabac — добавляем дубли."""
    body = node_text(text, "rkvdec@ff740100")
    if body is None:
        return text, False
    if "clk_core" in (get_prop(body, "clock-names") or ""):
        return text, False
    names = get_prop(body, "clock-names")
    clocks = get_prop(body, "clocks")
    if not names or not clocks:
        return text, False
    nm = [x.strip('"') for x in names.strip("<>").split("\\0")]
    cl = clocks.strip("<>").split()
    if len(nm) != len(cl):
        return text, False
    if "aclk_vcodec" not in nm or "clk_hevc_cabac" not in nm:
        return text, False
    core = cl[nm.index("aclk_vcodec")]
    cabac = cl[nm.index("clk_hevc_cabac")]
    body = set_prop(body, "clocks", "<%s %s %s>" % (" ".join(cl), core, cabac))
    body = set_prop(body, "clock-names", '"%s\\0clk_core\\0clk_cabac"' % names.strip("<>").strip('"'))
    text, _ = replace_node(text, "rkvdec@ff740100", body)
    return text, True


def patch_wlan_clock(text):
    """Драйвер Wi-Fi ищет ref_wifi_clk — добавляем фиктивный клок 32 кГц."""
    if "ref_wifi_clk {" in text:
        return text, False
    i = text.find('compatible = "wlan-platdata"')
    if i < 0:
        return text, False
    start = text.rfind("wireless-wlan {", 0, i)
    end = text.index("\n\t};", start)
    body = text[start:end]
    if "ref_wifi_clk" in body:
        return text, False
    body = body.replace("wireless-wlan {",
                        'wireless-wlan {\n\t\tclocks = <0x200>;\n\t\tclock-names = "ref_wifi_clk";', 1)
    text = text[:start] + body + text[end:]
    node = ("\n\tref_wifi_clk {\n"
            "\t\tcompatible = \"fixed-clock\";\n"
            "\t\tclock-frequency = <0x8000>;\n"
            "\t\t#clock-cells = <0x00>;\n"
            "\t\tphandle = <0x200>;\n"
            "\t};\n")
    k = text.rstrip().rfind("\n};")
    text = text[:k] + node + text[k:]
    return text, True


# ---------------------------------------------------------------- main


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dtb")
    ap.add_argument("--out")
    args = ap.parse_args()

    if not shutil.which("dtc"):
        sys.exit("нужен dtc: apt install device-tree-compiler")

    src = args.dtb
    out = args.out or (src + ".fixed")
    tmpdir = tempfile.mkdtemp(prefix="dtbfix-")
    dts = os.path.join(tmpdir, "in.dts")
    decompile(src, dts)
    text = open(dts, encoding="utf-8").read()

    steps = [
        ("вычищаем chosen/bootargs", strip_bootargs),
        ("правим SDIO (50 МГц, 4 бита, задержка)", lambda t: patch_sdio(t, None)),
        ("питание Wi-Fi (regulator 3.3 В) и pwrseq", patch_wifi_power),
        ("включаем Bluetooth", patch_bluetooth),
        ("клоки GPU (bus/core)", patch_gpu),
        ("клоки rkvdec2 (clk_core/clk_cabac)", patch_rkvdec),
        ("клок Wi-Fi (ref_wifi_clk)", patch_wlan_clock),
    ]
    for title, fn in steps:
        text, changed = fn(text)
        print(("%-42s %s" % (title, "изменено" if changed else "уже в порядке")))

    open(dts, "w", encoding="utf-8").write(text)
    compile_(dts, out)
    print("\nГотово: %s" % out)
    print("Установить:")
    print("  cp %s /boot/dtb/rockchip/rk3528-evb2-ddr3-v10.dtb" % out)


if __name__ == "__main__":
    main()
