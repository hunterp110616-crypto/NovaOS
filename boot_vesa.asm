; ============================================================
;  NOVA OS  --  Stage 1 boot sector (VESA hi-res)  boot_vesa.asm
; ============================================================
;  Loads the kernel (LBA), detects RAM, then uses VBE to find a
;  high-res 32bpp mode with a LINEAR FRAMEBUFFER, sets it, and
;  stores the framebuffer address/pitch/width/height for the
;  kernel. Falls through resolutions 1024x768 -> 800x600 -> 640x480.
;
;  Params stored (physical addresses, read by the kernel):
;    0x1000 dd  total RAM in KB
;    0x1004 dd  linear framebuffer physical address
;    0x1008 dd  bytes per scanline (pitch)
;    0x100C dd  width  (pixels)
;    0x1010 dd  height (pixels)
;
;  Build:  nasm -f bin boot_vesa.asm -o boot_vesa.bin
; ============================================================
BITS 16
ORG 0x7C00

CODE_SEG equ 0x08
DATA_SEG equ 0x10
KERNEL_SECTORS equ 199           ; LBA 1-199 (200 = installed marker!), two reads: 127 + 72

start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    mov [boot_drive], dl
    mov [0x1014], dl          ; hand the BIOS boot-drive number to the kernel
    sti


    mov ax, 0x0003
    int 0x10

    ; ---- load kernel to 0x8000 via LBA ----
    mov si, dap
    mov ah, 0x42
    mov dl, [boot_drive]
    int 0x13
    jc disk_error
    mov si, dap2              ; second part (one int 13h read tops out at 127 sectors)
    mov ah, 0x42
    mov dl, [boot_drive]
    int 0x13
    jc disk_error

    ; ---- detect RAM (E801) -> 0x1000 ----
    xor cx, cx
    xor dx, dx
    mov ax, 0xE801
    int 0x15
    jc .memfail
    test cx, cx
    jz .memok
    mov ax, cx
    mov bx, dx
.memok:
    movzx eax, ax
    movzx ebx, bx
    shl ebx, 6
    add eax, ebx
    add eax, 1024
    mov [0x1000], eax
    jmp .memdone
.memfail:
    xor eax, eax
    mov [0x1000], eax
.memdone:

    ; ---- VBE: get controller info block at 0x2000 ----
    xor ax, ax
    mov es, ax
    mov ax, 0x4F00
    mov di, 0x2000
    int 0x10
    cmp ax, 0x004F
    jne vesa_fail

    mov bp, targets
.try_target:
    mov ax, [bp]              ; target width (0 = end)
    test ax, ax
    jz vesa_fail
    ; reload the mode-list pointer (offset 14, segment 16 in the info block)
    mov si, [0x2000 + 14]
    mov ax, [0x2000 + 16]
    mov fs, ax
.walk:
    mov cx, [fs:si]
    add si, 2
    cmp cx, 0xFFFF
    je .next_target
    push si
    push bp
    mov ax, 0x4F01
    mov di, 0x3000
    int 0x10
    pop bp
    pop si
    cmp ax, 0x004F
    jne .walk
    mov ax, [0x3000 + 0]      ; mode attributes
    test ax, 0x80            ; bit7 = linear framebuffer available
    jz .walk
    mov al, [0x3000 + 0x19]   ; bits per pixel
    cmp al, 32
    jne .walk
    mov ax, [0x3000 + 0x12]   ; width
    cmp ax, [bp]
    jne .walk
    mov ax, [0x3000 + 0x14]   ; height
    cmp ax, [bp + 2]
    jne .walk
    jmp .found
.next_target:
    add bp, 4
    jmp .try_target

.found:
    or cx, 0x4000            ; request linear framebuffer
    mov [savedmode], cx
    mov eax, [0x3000 + 0x28]  ; linear framebuffer physical address
    mov [0x1004], eax
    movzx eax, word [0x3000 + 0x10]   ; bytes per scanline
    mov [0x1008], eax
    movzx eax, word [0x3000 + 0x12]   ; width
    mov [0x100C], eax
    movzx eax, word [0x3000 + 0x14]   ; height
    mov [0x1010], eax
    ; set the mode
    mov ax, 0x4F02
    mov bx, [savedmode]
    int 0x10
    cmp ax, 0x004F
    jne vesa_fail

    ; ---- enter protected mode ----
    in al, 0x92
    or al, 00000010b
    out 0x92, al
    cli
    lgdt [gdt_descriptor]
    mov eax, cr0
    or eax, 1
    mov cr0, eax
    jmp CODE_SEG:0x8000

vesa_fail:
    mov si, msg_vesa
    call print16
.h1:
    hlt
    jmp .h1
disk_error:
    mov si, msg_err
    call print16
.h2:
    hlt
    jmp .h2

print16:
    mov ah, 0x0E
.n:
    lodsb
    test al, al
    jz .d
    int 0x10
    jmp .n
.d:
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
savedmode:  dw 0
targets:    dw 1024,768, 800,600, 640,480, 0,0
msg_err:    db "DISK ERR", 13, 10, 0
msg_vesa:   db "NO VESA", 13, 10, 0

dap:
    db 0x10
    db 0
    dw 127
    dw 0x8000
    dw 0x0000
    dq 1
dap2:
    db 0x10
    db 0
    dw KERNEL_SECTORS - 127
    dw 0x0000
    dw 0x17E0                 ; 0x17E00 = 0x8000 + 127*512
    dq 128

; ---- MBR partition table at offset 446 (so Windows sees the FAT32 partition) ----
times 446-($-$$) db 0
part1:
    db 0x00                  ; status (not active)
    db 0xFE, 0xFF, 0xFF      ; CHS first (LBA-only marker)
    db 0x0C                  ; type: FAT32 (LBA)
    db 0xFE, 0xFF, 0xFF      ; CHS last
    dd 2048                  ; first LBA of the partition
    dd 66581                 ; sector count (matches fat32.img)
    times 48 db 0            ; three empty partition entries
dw 0xAA55
