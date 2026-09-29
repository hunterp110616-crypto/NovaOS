; ============================================================
;  NOVA OS  --  keyboard/render DIAGNOSTIC  kernel_diag.asm
; ============================================================
;  Tiny graphics kernel to isolate the real-hardware problem.
;    1. Draws a KNOWN test string  -> shows if rendering is OK
;    2. Prints the RAW HEX of every scancode from port 0x60
;       -> shows exactly what the keyboard sends (set 1 vs 2 vs junk)
;  Boot with boot_gfx.bin (which sets VGA mode 0x13).
; ============================================================
BITS 32
ORG 0x8000
FB   equ 0xA0000
SCRW equ 320

kentry:
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov esp, 0x90000

    ; clear screen to blue
    mov edi, FB
    mov ecx, SCRW*200
    mov al, 1
    rep stosb

    ; test string (white) at (8,8) -- is rendering correct?
    mov dword [tx], 8
    mov dword [ty], 8
    mov byte [tcolor], 15
    mov esi, teststr
    call draw_text

    ; label (cyan) at (8,30)
    mov dword [tx], 8
    mov dword [ty], 30
    mov byte [tcolor], 3
    mov esi, keylbl
    call draw_text

    ; scancode hex dump starts at (8,52)
    mov dword [hx], 8
    mov dword [hy], 52

    cli
.poll:
    in al, 0x64
    test al, 0x01
    jz .poll
    in al, 0x60
    mov [rawsc], al
    test al, 0x80            ; release? -> just show hex, no char
    jnz .hex
    movzx ebx, al
    mov al, [scancodes + ebx]
    test al, al
    jz .hex
    ; draw the MAPPED character (green) at the cursor
    mov eax, [hx]
    mov [tx], eax
    mov eax, [hy]
    mov [ty], eax
    mov byte [tcolor], 10
    mov al, [rawsc]
    movzx ebx, al
    mov al, [scancodes + ebx]
    call draw_char
    add dword [hx], 10
.hex:
    mov al, [rawsc]
    call print_hex_byte
    mov al, ' '
    ; small gap: advance cursor
    add dword [hx], 6
    mov eax, [hx]
    cmp eax, 290
    jl .poll
    mov dword [hx], 8
    add dword [hy], 18
    jmp .poll

print_hex_byte:              ; AL = byte -> two hex digits + gap
    pushad
    mov bl, al
    shr al, 4
    call .nib
    mov al, bl
    and al, 0x0F
    call .nib
    add dword [hx], 10       ; gap between bytes
    mov eax, [hx]
    cmp eax, 300
    jl .done
    mov dword [hx], 8
    add dword [hy], 18
.done:
    popad
    ret
.nib:
    cmp al, 10
    jb .dig
    add al, 'A'-10
    jmp .draw
.dig:
    add al, '0'
.draw:
    push eax
    mov eax, [hx]
    mov [tx], eax
    mov eax, [hy]
    mov [ty], eax
    mov byte [tcolor], 14    ; yellow
    pop eax
    call draw_char
    add dword [hx], 8
    ret

; ---- draw one glyph AL at [tx],[ty] colour [tcolor] ----
draw_char:
    pushad
    movzx eax, al
    sub eax, 32
    js .done
    cmp eax, 94
    ja .done
    imul eax, 16
    add eax, font8x16
    mov esi, eax
    xor ebx, ebx
.row:
    cmp ebx, 16
    jae .done
    mov dl, [esi + ebx]
    xor ecx, ecx
.col:
    cmp ecx, 8
    jae .nextrow
    test dl, 0x80
    jz .skip
    push ebx
    push ecx
    push edx
    mov edi, [ty]
    add edi, ebx
    imul edi, SCRW
    mov eax, [tx]
    add eax, ecx
    add edi, eax
    add edi, FB
    mov al, [tcolor]
    mov [edi], al
    pop edx
    pop ecx
    pop ebx
.skip:
    shl dl, 1
    inc ecx
    jmp .col
.nextrow:
    inc ebx
    jmp .row
.done:
    popad
    ret

draw_text:
    pushad
.next:
    mov al, [esi]
    test al, al
    jz .done
    call draw_char
    add dword [tx], 8
    inc esi
    jmp .next
.done:
    popad
    ret

tx: dd 0
ty: dd 0
tcolor: db 0
hx: dd 0
hy: dd 0
rawsc: db 0
teststr: db "NOVA 0123456789 ABCabc xyz", 0
keylbl:  db "Type: green=letter yellow=code", 0

scancodes:
    db 0,0,'1','2','3','4','5','6'
    db '7','8','9','0','-','=',0x08,0
    db 'q','w','e','r','t','y','u','i'
    db 'o','p','[',']',0x0A,0,'a','s'
    db 'd','f','g','h','j','k','l',';'
    db "'",'`',0,'\','z','x','c','v'
    db 'b','n','m',',','.','/',0,'*'
    db 0,' ',0,0,0,0,0,0
    times 128-($-scancodes) db 0

%include "font8x16.inc"
