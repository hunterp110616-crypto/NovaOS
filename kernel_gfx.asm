; ============================================================
;  NOVA OS  --  Graphics kernel  kernel_gfx.asm   v0.7 (shell)
; ============================================================
;  32-bit protected mode, VGA mode 0x13 (320x200x256), linear
;  framebuffer at 0xA0000. Now a real GRAPHICAL SHELL:
;    * a "Nova Terminal" window drawn with rectangles + font
;    * keyboard (IRQ1) and PS/2 mouse (IRQ12) both interrupt-driven
;    * a text console (font-rendered) with scrolling
;    * commands: help cpu mem clear ver about reboot
;
;  Build:  nasm -f bin kernel_gfx.asm -o kernel_gfx.bin
; ============================================================
BITS 32
ORG 0x8000

FB   equ 0xA0000
SCRW equ 320
SCRH equ 200

C_BLACK  equ 0
C_BLUE   equ 1
C_GREEN  equ 2
C_CYAN   equ 3
C_RED    equ 4
C_LGRAY  equ 7
C_DGRAY  equ 8
C_LBLUE  equ 9
C_LGREEN equ 10
C_YELLOW equ 14
C_WHITE  equ 15

; console text area (in pixels / character cells of 8x8)
CON_X0   equ 8
CON_Y0   equ 44
CON_COLS equ 37
CON_ROWS equ 9
CON_BG   equ C_BLACK
TXTCOL   equ C_LGREEN
; CLR button (clickable) in the title bar
BTN_X0   equ 280
BTN_Y0   equ 22
BTN_X1   equ 312
BTN_Y1   equ 39

kentry:
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov esp, 0x90000

    ; -------- draw the desktop + terminal window --------
    mov al, C_BLUE
    call clear_gfx

    ; top menu bar
    mov dword [rx],0
    mov dword [ry],0
    mov dword [rw],SCRW
    mov dword [rh],18
    mov byte [rcolor],C_GREEN
    call fillrect
    mov byte [tcolor],C_BLACK
    mov dword [tx],4
    mov dword [ty],1
    mov esi,txt_top
    call draw_text

    ; window frame
    mov dword [rx],4
    mov dword [ry],20
    mov dword [rw],312
    mov dword [rh],178
    mov byte [rcolor],C_DGRAY
    call fillrect
    ; title bar
    mov dword [rx],6
    mov dword [ry],22
    mov dword [rw],308
    mov dword [rh],18
    mov byte [rcolor],C_LBLUE
    call fillrect
    mov byte [tcolor],C_WHITE
    mov dword [tx],10
    mov dword [ty],23
    mov esi,txt_title
    call draw_text
    ; console body (black)
    mov dword [rx],6
    mov dword [ry],42
    mov dword [rw],308
    mov dword [rh],154
    mov byte [rcolor],C_BLACK
    call fillrect

    ; -------- console banner + first prompt --------
    mov dword [gcol],0
    mov dword [grow],0
    mov esi, con_banner
    call gprint
    call gprompt

    ; -------- input: KEYBOARD ONLY, polled (no mouse - reliable on real HW) --------
    ; We do NOT touch the PS/2 mouse or the controller config, so the keyboard
    ; behaves exactly like the working text build. Interrupts stay off; we poll.
    call kbd_flush           ; drop any stale bytes
    cli
.poll:
    in al, 0x64
    test al, 0x01            ; output buffer full?
    jz .poll
    in al, 0x60              ; read the byte and hand it straight to the shell
    call handle_scancode     ; (handle_scancode ignores key-release codes itself)
    jmp .poll

; ================= keyboard shell logic =================
handle_scancode:            ; AL = scancode
    cmp al, 0x2A
    je .sh_on
    cmp al, 0x36
    je .sh_on
    cmp al, 0xAA
    je .sh_off
    cmp al, 0xB6
    je .sh_off
    test al, 0x80
    jnz .ret                 ; ignore other key releases
    movzx ebx, al
    cmp byte [gshift], 0
    je .unshift
    mov al, [scancodes_shift + ebx]
    jmp .have
.unshift:
    mov al, [scancodes + ebx]
.have:
    test al, al
    jz .ret
    cmp al, 0x0A
    je .enter
    cmp al, 0x08
    je .back
    mov edi, [gbuf_len]      ; normal char
    cmp edi, 58
    jae .ret
    mov [gcmd + edi], al
    inc dword [gbuf_len]
    call gputchar
    ret
.back:
    cmp dword [gbuf_len], 0
    je .ret
    dec dword [gbuf_len]
    call gbackspace
    ret
.enter:
    call gnewline
    mov edi, [gbuf_len]
    mov byte [gcmd + edi], 0
    call grun_command
    call gprompt
    ret
.sh_on:
    mov byte [gshift], 1
    ret
.sh_off:
    mov byte [gshift], 0
    ret
.ret:
    ret

gprompt:
    mov dword [gbuf_len], 0
    mov esi, con_prompt
    call gprint
    ret

; ================= command dispatch =================
grun_command:
    cmp dword [gbuf_len], 0
    je .ret
    mov esi, gcmd
    mov edi, gs_help
    call streq
    je .help
    mov esi, gcmd
    mov edi, gs_cpu
    call streq
    je .cpu
    mov esi, gcmd
    mov edi, gs_mem
    call streq
    je .mem
    mov esi, gcmd
    mov edi, gs_clear
    call streq
    je .clear
    mov esi, gcmd
    mov edi, gs_ver
    call streq
    je .ver
    mov esi, gcmd
    mov edi, gs_about
    call streq
    je .about
    mov esi, gcmd
    mov edi, gs_reboot
    call streq
    je .reboot
    mov esi, gm_unknown
    call gprint
    mov esi, gcmd
    call gprint
    call gnewline
.ret:
    ret
.help:
    mov esi, gm_help
    call gprint
    ret
.ver:
    mov esi, gm_ver
    call gprint
    ret
.about:
    mov esi, gm_about
    call gprint
    ret
.clear:
    call gclear_console
    ret
.mem:
    mov esi, gm_mem
    call gprint
    mov eax, [0x1000]
    mov ebx, 1024
    xor edx, edx
    div ebx
    call gprint_dec
    mov esi, gm_mb
    call gprint
    ret
.reboot:
    mov esi, gm_reboot
    call gprint
    cli
.rb:
    in al, 0x64
    test al, 0x02
    jnz .rb
    mov al, 0xFE
    out 0x64, al
.rbh:
    hlt
    jmp .rbh
.cpu:
    mov eax, 0x80000000
    cpuid
    cmp eax, 0x80000004
    jb .cpu_v
    mov edi, gcpubuf
    mov eax, 0x80000002
    cpuid
    mov [edi],eax
    mov [edi+4],ebx
    mov [edi+8],ecx
    mov [edi+12],edx
    mov eax, 0x80000003
    cpuid
    mov [edi+16],eax
    mov [edi+20],ebx
    mov [edi+24],ecx
    mov [edi+28],edx
    mov eax, 0x80000004
    cpuid
    mov [edi+32],eax
    mov [edi+36],ebx
    mov [edi+40],ecx
    mov [edi+44],edx
    mov byte [edi+48],0
    jmp .cpu_p
.cpu_v:
    mov eax, 0
    cpuid
    mov edi, gcpubuf
    mov [edi],ebx
    mov [edi+4],edx
    mov [edi+8],ecx
    mov byte [edi+12],0
.cpu_p:
    mov esi, gm_cpu
    call gprint
    mov esi, gcpubuf
    call gprint
    call gnewline
    ret

; ================= console text (font-rendered) =================
gputchar:                    ; AL = character
    mov [gchar], al
    pushad
    mov eax, [gcol]
    imul eax, 8
    add eax, CON_X0
    mov [tx], eax
    mov eax, [grow]
    imul eax, 16
    add eax, CON_Y0
    mov [ty], eax
    mov byte [tcolor], TXTCOL
    mov al, [gchar]
    call draw_char
    inc dword [gcol]
    mov eax, [gcol]
    cmp eax, CON_COLS
    jl .done
    mov dword [gcol], 0
    inc dword [grow]
    call gcheck_scroll
.done:
    popad
    ret

gnewline:
    pushad
    mov dword [gcol], 0
    inc dword [grow]
    call gcheck_scroll
    popad
    ret

gputchar_hex:                ; AL = byte -> two hex digits via gputchar
    pushad
    mov bl, al
    shr al, 4
    call .nib
    mov al, bl
    and al, 0x0F
    call .nib
    popad
    ret
.nib:
    and al, 0x0F
    cmp al, 10
    jb .dig
    add al, 'A'-10
    jmp .draw
.dig:
    add al, '0'
.draw:
    call gputchar
    ret

gbackspace:
    pushad
    cmp dword [gcol], 0
    je .done
    dec dword [gcol]
    ; blank the cell
    mov eax, [gcol]
    imul eax, 8
    add eax, CON_X0
    mov dword [rx], eax
    mov eax, [grow]
    imul eax, 16
    add eax, CON_Y0
    mov dword [ry], eax
    mov dword [rw], 8
    mov dword [rh], 16
    mov byte [rcolor], CON_BG
    call fillrect
.done:
    popad
    ret

gcheck_scroll:
    mov eax, [grow]
    cmp eax, CON_ROWS
    jl .ok
    call gscroll
    mov dword [grow], CON_ROWS-1
.ok:
    ret

gscroll:
    pushad
    mov ecx, (CON_ROWS-1)*16     ; pixel rows to move up
    mov ebx, CON_Y0
.row:
    mov esi, ebx
    add esi, 16
    imul esi, SCRW
    add esi, CON_X0
    add esi, FB
    mov edi, ebx
    imul edi, SCRW
    add edi, CON_X0
    add edi, FB
    push ecx
    mov ecx, CON_COLS*8
    rep movsb
    pop ecx
    inc ebx
    dec ecx
    jnz .row
    ; clear the last text row
    mov ecx, 16
    mov ebx, CON_Y0 + (CON_ROWS-1)*16
.clr:
    mov edi, ebx
    imul edi, SCRW
    add edi, CON_X0
    add edi, FB
    push ecx
    mov ecx, CON_COLS*8
    mov al, CON_BG
    rep stosb
    pop ecx
    inc ebx
    dec ecx
    jnz .clr
    popad
    ret

gclear_console:
    pushad
    mov dword [rx], CON_X0
    mov dword [ry], CON_Y0
    mov dword [rw], CON_COLS*8
    mov dword [rh], CON_ROWS*16
    mov byte [rcolor], CON_BG
    call fillrect
    mov dword [gcol], 0
    mov dword [grow], 0
    popad
    ret

gprint:                      ; ESI -> 0-terminated string
    pushad
.next:
    mov al, [esi]
    test al, al
    jz .done
    cmp al, 0x0A
    jne .ch
    call gnewline
    jmp .adv
.ch:
    call gputchar
.adv:
    inc esi
    jmp .next
.done:
    popad
    ret

gprint_dec:                  ; EAX = number
    pushad
    mov ebx, 10
    xor ecx, ecx
    test eax, eax
    jnz .sp
    mov al, '0'
    call gputchar
    jmp .done
.sp:
    test eax, eax
    jz .em
    xor edx, edx
    div ebx
    add dl, '0'
    push edx
    inc ecx
    jmp .sp
.em:
    test ecx, ecx
    jz .done
    pop edx
    mov al, dl
    call gputchar
    dec ecx
    jmp .em
.done:
    popad
    ret

; ================= string compare (ZF=1 if equal) =================
streq:
.next:
    mov al, [esi]
    mov ah, [edi]
    cmp al, ah
    jne .neq
    test al, al
    jz .eq
    inc esi
    inc edi
    jmp .next
.eq:
    xor eax, eax
    ret
.neq:
    mov eax, 1
    and eax, eax
    ret

; ================= graphics primitives =================
clear_gfx:
    pushad
    mov edi, FB
    mov ecx, SCRW*SCRH
    rep stosb
    popad
    ret

fillrect:
    pushad
    mov ebx, [ry]
    mov ecx, [rh]
.row:
    test ecx, ecx
    jz .done
    mov edi, ebx
    imul edi, SCRW
    add edi, [rx]
    add edi, FB
    mov edx, [rw]
    mov al, [rcolor]
.col:
    test edx, edx
    jz .nextrow
    mov [edi], al
    inc edi
    dec edx
    jmp .col
.nextrow:
    inc ebx
    dec ecx
    jmp .row
.done:
    popad
    ret

; draw_char: AL=char, position [tx],[ty], colour [tcolor]
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

draw_text:                   ; ESI -> string, uses [tx],[ty],[tcolor]
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

; ================= interrupts (IDT + PIC) =================
setup_idt_gfx:
    pushad
    mov ecx, 256
    mov edi, idt
    mov eax, default_isr
.fill:
    mov [edi], ax
    mov word [edi+2], 0x08
    mov byte [edi+4], 0
    mov byte [edi+5], 0x8E
    ror eax, 16
    mov [edi+6], ax
    rol eax, 16
    add edi, 8
    dec ecx
    jnz .fill
    ; IRQ1 (keyboard) -> vector 0x21
    mov eax, keyboard_isr
    mov edi, idt + 0x21*8
    mov [edi], ax
    mov word [edi+2], 0x08
    mov byte [edi+4], 0
    mov byte [edi+5], 0x8E
    ror eax, 16
    mov [edi+6], ax
    rol eax, 16
    ; IRQ12 (mouse) -> vector 0x2C
    mov eax, mouse_isr
    mov edi, idt + 0x2C*8
    mov [edi], ax
    mov word [edi+2], 0x08
    mov byte [edi+4], 0
    mov byte [edi+5], 0x8E
    ror eax, 16
    mov [edi+6], ax
    rol eax, 16
    lidt [idt_descriptor]
    popad
    ret

pic_init_gfx:
    mov al, 0x11
    out 0x20, al
    out 0xA0, al
    mov al, 0x20
    out 0x21, al
    mov al, 0x28
    out 0xA1, al
    mov al, 0x04
    out 0x21, al
    mov al, 0x02
    out 0xA1, al
    mov al, 0x01
    out 0x21, al
    out 0xA1, al
    mov al, 0xF9             ; master: unmask IRQ1 (kbd) + IRQ2 (cascade)
    out 0x21, al
    mov al, 0xEF             ; slave: unmask IRQ12 (mouse)
    out 0xA1, al
    ret

default_isr:
    iret

keyboard_isr:               ; IRQ1
    pushad
    in al, 0x60
    movzx ebx, byte [ktail]
    mov [kbuf + ebx], al
    inc byte [ktail]
    and byte [ktail], 31
    mov al, 0x20
    out 0x20, al
    popad
    iret

; ================= PS/2 mouse =================
ps2_wait_in:
    in al, 0x64
    test al, 0x02
    jnz ps2_wait_in
    ret
ps2_wait_out:
    in al, 0x64
    test al, 0x01
    jz ps2_wait_out
    ret

mouse_write:
    mov bl, al
    call ps2_wait_in
    mov al, 0xD4
    out 0x64, al
    call ps2_wait_in
    mov al, bl
    out 0x60, al
    call ps2_wait_out
    in al, 0x60
    ret

mouse_init:
    call ps2_wait_in
    mov al, 0xA8
    out 0x64, al
    call ps2_wait_in
    mov al, 0x20
    out 0x64, al
    call ps2_wait_out
    in al, 0x60
    or al, 0x02
    and al, 0xDF
    mov bl, al
    call ps2_wait_in
    mov al, 0x60
    out 0x64, al
    call ps2_wait_in
    mov al, bl
    out 0x60, al
    mov al, 0xF6
    call mouse_write
    mov al, 0xF4
    call mouse_write
    ret

pic_mask_all:                ; mask every IRQ at the PIC (we poll instead)
    mov al, 0xFF
    out 0x21, al
    out 0xA1, al
    ret

kbd_flush:                   ; drain any bytes waiting in the 8042 buffer
.f:
    in al, 0x64
    test al, 0x01
    jz .done
    in al, 0x60
    jmp .f
.done:
    ret

mouse_feed:                  ; AL = a byte read from the mouse (polled)
    mov bl, [mouse_cycle]
    cmp bl, 1
    je .b1
    cmp bl, 2
    je .b2
.b0:
    test al, 0x08            ; byte 0 must have the sync bit set
    jz .ret                  ; out of sync -> drop this byte
    mov [mouse_flags], al
    mov byte [mouse_cycle], 1
    ret
.b1:
    mov [mouse_dx], al
    mov byte [mouse_cycle], 2
    ret
.b2:
    mov [mouse_dy], al
    mov byte [mouse_cycle], 0
    call mouse_update
.ret:
    ret

mouse_isr:                   ; IRQ12
    pushad
    in al, 0x60
    mov bl, [mouse_cycle]
    cmp bl, 1
    je .b1
    cmp bl, 2
    je .b2
.b0:
    test al, 0x08
    jz .eoi
    mov [mouse_flags], al
    mov byte [mouse_cycle], 1
    jmp .eoi
.b1:
    mov [mouse_dx], al
    mov byte [mouse_cycle], 2
    jmp .eoi
.b2:
    mov [mouse_dy], al
    mov byte [mouse_cycle], 0
    call mouse_update
.eoi:
    mov al, 0x20
    out 0xA0, al
    mov al, 0x20
    out 0x20, al
    popad
    iret

mouse_update:
    pushad
    movsx eax, byte [mouse_dx]
    add eax, [mouse_x]
    cmp eax, 0
    jge .xlo
    xor eax, eax
.xlo:
    cmp eax, 311
    jle .xhi
    mov eax, 311
.xhi:
    mov [mouse_newx], eax
    movsx eax, byte [mouse_dy]
    mov ebx, [mouse_y]
    sub ebx, eax
    mov eax, ebx
    cmp eax, 0
    jge .ylo
    xor eax, eax
.ylo:
    cmp eax, 187
    jle .yhi
    mov eax, 187
.yhi:
    mov [mouse_newy], eax
    mov eax, [mouse_x]
    mov [cur_x], eax
    mov eax, [mouse_y]
    mov [cur_y], eax
    call restore_under
    mov eax, [mouse_newx]
    mov [mouse_x], eax
    mov [cur_x], eax
    mov eax, [mouse_newy]
    mov [mouse_y], eax
    mov [cur_y], eax
    call save_under
    call draw_cursor
    ; ---- left-button click edge detection ----
    mov al, [mouse_flags]
    and al, 1                ; left button state
    mov bl, [prev_btn]
    mov [prev_btn], al
    test al, al
    jz .noclick
    test bl, bl
    jnz .noclick             ; button was already down -> not a new press
    call handle_click
.noclick:
    popad
    ret

; a new left-click happened at (mouse_x, mouse_y) -- hit-test the CLR button
handle_click:
    mov eax, [mouse_x]
    cmp eax, BTN_X0
    jl .none
    cmp eax, BTN_X1
    jg .none
    mov eax, [mouse_y]
    cmp eax, BTN_Y0
    jl .none
    cmp eax, BTN_Y1
    jg .none
    ; clicked CLR: remove cursor, clear console, new prompt, redraw cursor
    call restore_under
    call gclear_console
    call gprompt
    call save_under
    call draw_cursor
.none:
    ret

draw_clr_button:
    pushad
    mov dword [rx], BTN_X0
    mov dword [ry], BTN_Y0
    mov dword [rw], BTN_X1-BTN_X0
    mov dword [rh], BTN_Y1-BTN_Y0
    mov byte [rcolor], C_RED
    call fillrect
    mov byte [tcolor], C_WHITE
    mov dword [tx], BTN_X0+4
    mov dword [ty], BTN_Y0+1
    mov esi, txt_clr
    call draw_text
    popad
    ret

save_under:
    pushad
    mov edi, cursor_save
    xor ebx, ebx
.row:
    cmp ebx, 12
    jae .done
    mov esi, [cur_y]
    add esi, ebx
    imul esi, SCRW
    add esi, [cur_x]
    add esi, FB
    mov ecx, 8
.col:
    mov al, [esi]
    mov [edi], al
    inc esi
    inc edi
    dec ecx
    jnz .col
    inc ebx
    jmp .row
.done:
    popad
    ret

restore_under:
    pushad
    mov esi, cursor_save
    xor ebx, ebx
.row:
    cmp ebx, 12
    jae .done
    mov edi, [cur_y]
    add edi, ebx
    imul edi, SCRW
    add edi, [cur_x]
    add edi, FB
    mov ecx, 8
.col:
    mov al, [esi]
    mov [edi], al
    inc esi
    inc edi
    dec ecx
    jnz .col
    inc ebx
    jmp .row
.done:
    popad
    ret

draw_cursor:
    pushad
    mov esi, cursor_bmp
    xor ebx, ebx
.row:
    cmp ebx, 12
    jae .done
    mov dl, [esi + ebx]
    xor ecx, ecx
.col:
    cmp ecx, 8
    jae .next
    test dl, 0x80
    jz .skip
    push ebx
    push ecx
    push edx
    mov edi, [cur_y]
    add edi, ebx
    imul edi, SCRW
    mov eax, [cur_x]
    add eax, ecx
    add edi, eax
    add edi, FB
    mov byte [edi], C_WHITE
    pop edx
    pop ecx
    pop ebx
.skip:
    shl dl, 1
    inc ecx
    jmp .col
.next:
    inc ebx
    jmp .row
.done:
    popad
    ret

; ================= data =================
rx: dd 0
ry: dd 0
rw: dd 0
rh: dd 0
rcolor: db 0
tx: dd 0
ty: dd 0
tcolor: db 0

gcol: dd 0
grow: dd 0
gchar: db 0
gshift: db 0
gbuf_len: dd 0
gcmd: times 64 db 0
gcpubuf: times 52 db 0

khead: db 0
ktail: db 0
kbuf: times 32 db 0

mouse_cycle: db 0
mouse_flags: db 0
prev_btn: db 0
mouse_dx: db 0
mouse_dy: db 0
mouse_x: dd 0
mouse_y: dd 0
mouse_newx: dd 0
mouse_newy: dd 0
cur_x: dd 0
cur_y: dd 0
cursor_save: times 8*12 db 0
cursor_bmp:                  ; small arrow (7 rows used)
    db 0x80,0xC0,0xE0,0xF0,0xF8,0xD8,0x88,0x00,0x00,0x00,0x00,0x00

txt_top:    db "NOVA OS", 0
txt_title:  db "Nova Terminal", 0
txt_clr:    db "CLR", 0
con_banner: db "Nova OS graphical shell v0.7", 10, "Keyboard ready. Type 'help'.", 10, 0
con_prompt: db 10, "Nova> ", 0

gs_help:   db "help", 0
gs_cpu:    db "cpu", 0
gs_mem:    db "mem", 0
gs_clear:  db "clear", 0
gs_ver:    db "ver", 0
gs_about:  db "about", 0
gs_reboot: db "reboot", 0

gm_help:   db "Cmds: help cpu mem clear ver about reboot", 10, 0
gm_ver:    db "Nova OS GUI kernel v0.7", 10, 0
gm_about:  db "Nova OS - from-scratch graphical OS.", 10, "Own kernel, VGA graphics, mouse + keyboard.", 10, 0
gm_cpu:    db "CPU: ", 0
gm_mem:    db "RAM: ", 0
gm_mb:     db " MB", 10, 0
gm_reboot: db "Rebooting...", 10, 0
gm_unknown: db "Unknown command: ", 0

; scancode set 1 -> ASCII (unshifted / shifted)
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
scancodes_shift:
    db 0,0,'!','@','#','$','%','^'
    db '&','*','(',')','_','+',0x08,0
    db 'Q','W','E','R','T','Y','U','I'
    db 'O','P','{','}',0x0A,0,'A','S'
    db 'D','F','G','H','J','K','L',':'
    db '"','~',0,'|','Z','X','C','V'
    db 'B','N','M','<','>','?',0,'*'
    db 0,' ',0,0,0,0,0,0
    times 128-($-scancodes_shift) db 0

idt_descriptor:
    dw 256*8 - 1
    dd idt
idt:
    times 256*8 db 0

; ---------------- 8x16 bitmap font (ASCII 32..126) ----------------
%include "font8x16.inc"
