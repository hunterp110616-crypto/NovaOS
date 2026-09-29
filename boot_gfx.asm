; ============================================================
;  NOVA OS  --  Stage 1 boot sector (GRAPHICS build)  boot_gfx.asm
; ============================================================
;  Same as boot.asm, but switches the video card into VGA
;  mode 0x13 (320x200, 256 colours, linear framebuffer at
;  0xA0000) just before entering protected mode, so the
;  graphics kernel can draw pixels.
;
;  Build:  nasm -f bin boot_gfx.asm -o boot_gfx.bin
; ============================================================
BITS 16
ORG 0x7C00

CODE_SEG equ 0x08
DATA_SEG equ 0x10
KERNEL_SECTORS equ 40

start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    mov [boot_drive], dl
    sti

    mov ax, 0x0003         ; text mode first, for the loading message
    int 0x10
    mov si, msg_load
    call print16

    ; ---- load the graphics kernel to 0x8000 via LBA extended read ----
    ; (robust for large reads off USB, unlike CHS which corrupts on real HW)
    mov si, dap
    mov ah, 0x42
    mov dl, [boot_drive]
    int 0x13
    jc disk_error

    ; ---- detect RAM (int 0x15 E801) -> physical 0x1000 ----
    xor cx, cx
    xor dx, dx
    mov ax, 0xE801
    int 0x15
    jc .mem_fail
    test cx, cx
    jz .mem_axbx
    mov ax, cx
    mov bx, dx
.mem_axbx:
    movzx eax, ax
    movzx ebx, bx
    shl ebx, 6
    add eax, ebx
    add eax, 1024
    mov [0x1000], eax
    jmp .mem_done
.mem_fail:
    xor eax, eax
    mov [0x1000], eax
.mem_done:

    ; ---- switch to VGA mode 0x13 (320x200x256) ----
    mov ax, 0x0013
    int 0x10

    ; ---- enter protected mode ----
    in al, 0x92            ; A20
    or al, 00000010b
    out 0x92, al

    cli
    lgdt [gdt_descriptor]
    mov eax, cr0
    or eax, 1
    mov cr0, eax
    jmp CODE_SEG:0x8000

disk_error:
    mov si, msg_err
    call print16
.hang:
    hlt
    jmp .hang

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

gdt_start:
    dq 0x0000000000000000
gdt_code:
    dw 0xFFFF
    dw 0x0000
    db 0x00
    db 10011010b
    db 11001111b
    db 0x00
gdt_data:
    dw 0xFFFF
    dw 0x0000
    db 0x00
    db 10010010b
    db 11001111b
    db 0x00
gdt_end:

gdt_descriptor:
    dw gdt_end - gdt_start - 1
    dd gdt_start

boot_drive: db 0
msg_load:   db "Nova: loading GUI...", 13, 10, 0
msg_err:    db "Nova: DISK ERROR", 13, 10, 0

; Disk Address Packet for the LBA read (kernel starts at LBA 1)
dap:
    db 0x10              ; packet size
    db 0                 ; reserved
    dw KERNEL_SECTORS    ; number of sectors to read
    dw 0x8000            ; destination offset
    dw 0x0000            ; destination segment
    dq 1                 ; starting LBA (sector after the boot sector)

times 510-($-$$) db 0
dw 0xAA55
