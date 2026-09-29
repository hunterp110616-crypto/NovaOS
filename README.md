# NovaOS

**[Visit the NovaOS website →](https://hunterp110616-crypto.github.io/NovaOS/)**

NovaOS is a 32-bit operating system built entirely from scratch in x86 assembly — its own bootloader, kernel, window manager, USB driver, and sound driver, all hand-written with no underlying Linux, Windows, or BSD code. It's a **basic** OS: it boots on real hardware, gives you a graphical desktop, and lets you do simple everyday things — it is not trying to compete with a modern OS yet.

**Networking (Wi-Fi/Ethernet) is not included in this release.** It's planned for NovaOS 2.0. This release is the foundation: boot, desktop, apps, storage, and sound.

## What's in NovaOS 1.27

- A graphical desktop with a taskbar, Start menu, and draggable/resizable windows
- **Device Manager** — lists real detected hardware (PCI devices) with driver status
- **Task Manager** — see and end running apps
- **Admin Terminal** — a second, separate terminal with its own shell commands (`pcilist`, `sysdump`, and more)
- A regular **Terminal** with its own shell commands
- **Files** app for browsing storage
- Real sound through Intel HD Audio hardware (startup chime, sound effects), with a PC speaker fallback on machines without HD Audio
- Its own USB driver (UHCI + OHCI controllers, USB HID keyboard/mouse) — no external drivers, written from scratch
- A Setup program that can do a fresh install or upgrade an existing NovaOS install, plus a "Try it live" mode that runs entirely from the USB stick
- Right-click the Start button for a Windows-style context menu

## Try it / Install it

`NovaOS-1.27.img` is a **raw bootable disk image** — the same kind of format used by well-known hobby OS projects. It is not a `.iso`; it's built to boot directly from a USB stick via the BIOS, which is the correct format for this project (no CD emulation layer needed).

You can write it to a USB stick with any of these:

- **Raspberry Pi Imager** — choose "Use custom", select `NovaOS-1.27.img`, pick your USB stick, write.
- **Rufus** (Windows) — select the image, choose **DD Image mode** when prompted (not ISO mode), write.
- **balenaEtcher** (Windows/Mac/Linux) — select the image, select the USB stick, flash.

**This will erase the USB stick.** Use a spare one, not one with files you need.

Boot from that USB stick (you may need to change your PC's boot order / boot menu key — often F12, F9, Esc, or Del depending on the machine) and you'll reach NovaOS's own Setup screen, where you can choose to try it live or install it to a disk.

## Building from source

Requires NASM and Python 3. `build_image.py` assembles the kernel and packs the final bootable image.

```bash
python build_image.py
```

## Status

NovaOS is an actively developed hobby/learning project. Expect rough edges. Tested on real hardware (a Toshiba Satellite M750 laptop) as well as in QEMU.

## License

*(Add your chosen license here — MIT is a common, permissive choice for hobby OS projects if you're not sure.)*
