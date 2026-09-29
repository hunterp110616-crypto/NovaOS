@echo off
REM ============================================
REM   Boot NovaOS 1.0 in QEMU
REM   Double-click this file to run your OS.
REM ============================================
cd /d "%~dp0"
set QEMU=tools\qemu\qemu-system-i386.exe
set IMG=nova_fat.img

if not exist "%QEMU%" (
  echo QEMU not found at %QEMU%
  echo Make sure this .bat is inside the NovaKernel folder.
  pause
  exit /b 1
)
if not exist "%IMG%" (
  echo NovaOS image not found: %IMG%
  pause
  exit /b 1
)

echo Booting NovaOS...
"%QEMU%" -drive file=%IMG%,format=raw,index=0,media=disk -m 64 -vga std -name "NovaOS 1.0"
