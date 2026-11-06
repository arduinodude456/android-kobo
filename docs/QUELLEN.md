# Technische Quellen

- QEMU: [Multi-threaded TCG](https://www.qemu.org/docs/master/devel/multi-thread-tcg.html) – Voraussetzungen, Verhalten und Grenzen paralleler vCPUs.
- QEMU: [QEMU-Systemoptionen](https://www.qemu.org/docs/master/system/qemu-manpage.html) – Optionen und Beschleuniger.
- Android: [VSync](https://source.android.com/docs/core/graphics/implement-vsync) – Zusammenhang von App, SurfaceFlinger und Hardware Composer. Die Seite beschreibt aktuelle Android-Versionen; konkrete Eigenschaften von Android 4.4 separat prüfen.
- Kobo: [Libra Colour – technische Daten](https://ereader.kobo.com/en-us/products/kobo-libra-colour) – Zweikern-CPU und 1264 × 1680 Pixel.
- Linaro: [QEMU: A Tale of Performance analysis](https://www.linaro.org/blog/qemu-a-tale-of-performance-analysis/) – Performanceanalyse von Android unter TCG; keine direkt übertragbaren Zahlen für den Kobo.
- Android Open Source Project: [Dalvik-VM: Verification und Optimierung](https://android.googlesource.com/platform/dalvik-snapshot/+/ics-mr1/docs/embedded-vm-control.html) – die Standardkonfiguration überprüft und optimiert DEX-Code; geänderte Flags benötigen neue Optimierungscaches.
- Android Open Source Project: [Android-4.4-SurfaceFlinger](https://android.googlesource.com/platform/frameworks/native/+/android-4.4_r1/services/surfaceflinger/SurfaceFlinger.cpp) – Quelle der tatsächlich verwendeten Android-Generation.
- Google: [Android-19 ARM-v7 System-Image](https://dl.google.com/android/repository/sys-img/android/armeabi-v7a-19_r05.zip) – Standardquelle des Build-Workflows; nur gemäß den Google-SDK-Lizenzbedingungen verwenden.
- Android Open Source Project: [KitKat Generic.kl](https://android.googlesource.com/platform/frameworks/base/+/android-4.4.4_r2/data/keyboards/Generic.kl) – Linux-Tastencodes 158 und 172 sind Android BACK und HOME; 1 und 102 sind ESCAPE und MOVE_HOME.
- QEMU: [Virtio-Input-HID-Implementierung](https://github.com/qemu/qemu/blob/v9.0.2/hw/input/virtio-input-hid.c) – die virtuelle Tastatur nutzt die QEMU-zu-Linux-Tastencodetabelle.
- [RFB-Protokoll RFC 6143](https://www.rfc-editor.org/rfc/rfc6143.html) und [LuaSocket-TCP](https://lunarmodules.github.io/luasocket/tcp.html) – Framing und Behandlung unvollständiger Lese-/Schreibvorgänge.
- QEMU 9.0.2: [VNC-Implementierung und erweiterte Tastaturereignisse](https://github.com/qemu/qemu/blob/v9.0.2/ui/vnc.c) – normales KeyEvent maskiert das Keysym auf 16 Bit; die QEMU-Erweiterung überträgt den Tastencode separat.
