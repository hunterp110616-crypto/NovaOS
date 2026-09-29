; ============================================================
;  NOVA OS  --  Stage 1 boot sector   (boot.asm)   v0.2
; ============================================================
;  Loaded by BIOS at 0x7C00 in 16-bit real mode. Now it:
;    1. loads the Nova kernel (16 sectors) from disk to 0x8000
;    2. enables the A20 line
;    3. loads a GDT and enters 32-bit PROTECTED MODE
;    4. far-jumps into the 32-bit kernel at 0x8000
;
;  Build:  nasm -f bin boot.asm -o boot.bin
; ============================================================
BITS 16
ORG 0x7C00

CODE_SEG equ 0x08          ; offsets into the GDT below
DATA_SEG equ 0x10
KERNEL_SECTORS equ 40      ; how many 512-byte sectors of kernel to load

start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    mov [boot_drive], dl   ; BIOS leaves the boot drive number in DL
    sti

    mov ax, 0x0003         ; 80x25 text mode (clears screen)
    int 0x10

    mov si, msg_load
    call print16

    ; ---- load the kernel from disk (CHS: cyl 0, head 0, sector 2+) ----
    mov ah, 0x02           ; BIOS read sectors
    mov al, KERNEL_SECTORS
    mov ch, 0              ; cylinder 0
    mov cl, 2              ; start at sector 2 (sector 1 is this boot sector)
    mov dh, 0              ; head 0
    mov dl, [boot_drive]
    mov bx, 0x8000         ; ES:BX = 0x0000:0x8000 destination
    int 0x13
    jc disk_error

    ; ---- detect RAM (BIOS int 0x15, AX=E801) while still in real mode ----
    ; result (total KB) stored at physical 0x1000 for the kernel to read
    xor cx, cx
    xor dx, dx
    mov ax, 0xE801
    int 0x15
    jc mem_fail
    test cx, cx            ; some BIOSes return in CX/DX instead of AX/BX
    jz .mem_axbx
    mov ax, cx
    mov bx, dx
.mem_axbx:
    movzx eax, ax          ; AX = KB in the 1-16MB range
    movzx ebx, bx          ; BX = number of 64KB blocks above 16MB
    shl ebx, 6             ; blocks -> KB (x64)
    add eax, ebx
    add eax, 1024          ; + the low 1MB
    mov [0x1000], eax
    jmp mem_done
mem_fail:
    xor eax, eax
    mov [0x1000], eax
mem_done:

    ; ---- enable A20 (fast A20 via system control port 0x92) ----
    in al, 0x92
    or al, 00000010b
    out 0x92, al

    ; ---- switch to protected mode ----
    cli
    lgdt [gdt_descriptor]
    mov eax, cr0
    or eax, 1              ; set PE (protection enable) bit
    mov cr0, eax
    jmp CODE_SEG:0x8000    ; far jump -> flushes pipeline, loads 32-bit CS, enters kernel

disk_error:
    mov si, msg_err
    call print16
.hang:
    hlt
    jmp .hang

; ---- 16-bit BIOS teletype string print (DS:SI, 0-terminated) ----
print16:
    mov ah, 0x0E
.next:
    lodsb
    test al, al
    jz .done
    int 0x10
    jmp .next
.done:
    ret

; ------------------------- GDT -----------------------------
gdt_start:
    dq 0x0000000000000000          ; null descriptor
gdt_code:                          ; base=0, limit=4GB, 32-bit code
    dw 0xFFFF
    dw 0x0000
    db 0x00
    db 10011010b
    db 11001111b
    db 0x00
gdt_data:                          ; base=0, limit=4GB, 32-bit data
    dw 0xFFFF
    dw 0x0000
    db 0x00
    db 10010010b
    db 11001111b
    db 0x00
gdt_end:

gdt_descriptor:
    dw gdt_end - gdt_start - 1      ; size
    dd gdt_start                    ; address

; ------------------------- data ----------------------------
boot_drive: db 0
msg_load:   db "Nova: loading kernel...", 13, 10, 0
msg_err:    db "Nova: DISK ERROR", 13, 10, 0

; --- pad to 510 bytes, then boot signature ---
times 510-($-$$) db 0
dw 0xAA55
