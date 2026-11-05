#!/usr/bin/env python3
"""virtio-tablet meldet BTN_LEFT statt BTN_TOUCH. Android-4.4-EventHub stuft ein Geraet mit ABS_X/ABS_Y nur dann
als Touchscreen ein, wenn BTN_TOUCH existiert -> sonst werden Eingaben ignoriert. Dieser Patch
 - setzt BTN_TOUCH (und INPUT_PROP_DIRECT) fuer absolute Zeigergeraete,
 - spiegelt BTN_LEFT-Ereignisse als BTN_TOUCH.
Bricht mit Fehler ab, wenn eine Stelle nicht gefunden wird."""
import re, sys
p = sys.argv[1]
s = open(p).read()
if "BTN_TOUCH" in s:
    print("virtio_input.c bereits gepatcht"); sys.exit(0)

# 1) Ereignisse spiegeln
m = re.search(r"([ \t]*)input_event\(vi->idev,[^;]*?\);", s, re.S)
if not m: sys.exit("FEHLER: input_event() in virtio_input.c nicht gefunden")
ind = m.group(1)
mirror = ("\n" + ind + "if (le16_to_cpu(event->type) == EV_KEY && le16_to_cpu(event->code) == BTN_LEFT &&\n"
          + ind + "    test_bit(EV_ABS, vi->idev->evbit))\n"
          + ind + "\tinput_event(vi->idev, EV_KEY, BTN_TOUCH, le32_to_cpu(event->value));")
s = s[:m.end()] + mirror + s[m.end():]

# 2) Faehigkeiten setzen, direkt vor der Registrierung
m = re.search(r"([ \t]*)(\w+\s*=\s*)?input_register_device\(vi->idev\)", s)
if not m: sys.exit("FEHLER: input_register_device() in virtio_input.c nicht gefunden")
ind = m.group(1)
caps = (ind + "if (test_bit(EV_ABS, vi->idev->evbit) && test_bit(BTN_LEFT, vi->idev->keybit)) {\n"
        + ind + "\t__set_bit(EV_KEY, vi->idev->evbit);\n"
        + ind + "\t__set_bit(BTN_TOUCH, vi->idev->keybit);\n"
        + ind + "\t__set_bit(INPUT_PROP_DIRECT, vi->idev->propbit);\n"
        + ind + "}\n")
s = s[:m.start()] + caps + s[m.start():]
open(p, "w").write(s)
print("virtio_input.c gepatcht")
