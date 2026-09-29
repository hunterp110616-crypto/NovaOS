@echo off
REM ===== Build Nova OS boot sector =====
cd /d "%~dp0"
set NASM=tools\nasm-2.16.03\nasm.exe
"%NASM%" -f bin boot.asm -o boot.bin
if errorlevel 1 (echo BUILD FAILED & pause & exit /b 1)
echo Built boot.bin
for %%A in (boot.bin) do echo Size: %%~zA bytes  (must be 512)
