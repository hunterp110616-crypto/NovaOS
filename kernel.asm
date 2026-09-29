; ============================================================
;  NOVA OS  --  32-bit kernel   (kernel.asm)   v0.2
; ============================================================
;  Entered from the boot sector in 32-bit protected mode.
;  Loaded at physical address 0x8000.
;
;    * writes directly to VGA text memory at 0xB8000
;    * polls the PS/2 keyboard (port 0x60) - no BIOS, no interrupts
;    * runs a real command shell:  help  cpu  about  clear  ver
;    * "cpu" reads the true processor name via the CPUID instruction
;
;  Build:  nasm -f bin kernel.asm -o kernel.bin
; ============================================================
BITS 32
ORG 0x8000

VGA      equ 0xB8000
COLOR    equ 0x0A            ; light-green on black
WHITE    equ 0x0F

kernel_entry:
    mov ax, 0x10             ; DATA_SEG: point all data segments at flat 4GB
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov esp, 0x90000         ; a safe stack below video memory

    call clear_screen
    call enable_cursor
    call setup_idt          ; install interrupt table
    call pic_remap          ; remap the PIC (IRQs -> 0x20..0x2F)
    call pit_init           ; program the timer to ~100 Hz
    sti                     ; enable interrupts (timer now ticks)

    mov esi, banner
    mov bl, WHITE
    call print_str_color

    mov esi, hint
    call print_str

; ---------------- the shell ----------------
shell:
    mov esi, prompt
    call print_str
    mov dword [buf_len], 0

.readkey:
    in al, 0x64             ; keyboard status port
    test al, 1              ; output-buffer-full?
    jz .readkey
    in al, 0x60             ; read scancode

    cmp al, 0xE0            ; extended-key prefix (arrows etc.)
    jne .not_ext
    mov byte [ext_flag], 1
    jmp .readkey
.not_ext:
    cmp byte [ext_flag], 0
    je .scan
    mov byte [ext_flag], 0
    cmp al, 0x48           ; Up arrow -> recall last command
    je .history_up
    jmp .readkey           ; ignore other extended keys
.scan:
    cmp al, 0x2A            ; Left Shift pressed
    je .shift_on
    cmp al, 0x36            ; Right Shift pressed
    je .shift_on
    cmp al, 0xAA            ; Left Shift released
    je .shift_off
    cmp al, 0xB6            ; Right Shift released
    je .shift_off
    cmp al, 0x3A            ; CapsLock (toggle on press)
    je .caps_toggle
    test al, 0x80           ; any other RELEASE -> ignore
    jnz .readkey

    movzx ebx, al
    mov al, [scancodes + ebx]   ; base (unshifted) character
    test al, al             ; unmapped key?
    jz .readkey

    cmp al, 'a'             ; is it a letter a-z? -> apply Shift XOR CapsLock
    jb .not_letter
    cmp al, 'z'
    ja .not_letter
    mov cl, [shift_state]
    xor cl, [caps_state]
    test cl, cl
    jz .have_char          ; lowercase
    sub al, 0x20           ; uppercase
    jmp .have_char
.not_letter:
    cmp byte [shift_state], 0
    je .have_char          ; unshifted symbol already in AL
    mov al, [scancodes_shift + ebx]
    test al, al
    jz .readkey

.have_char:
    cmp al, 0x0A           ; Enter
    je .enter
    cmp al, 0x08           ; Backspace
    je .backspace
    mov edi, [buf_len]     ; normal character: store + echo
    cmp edi, 76
    jae .readkey
    mov [cmdbuf + edi], al
    inc dword [buf_len]
    call print_char
    jmp .readkey

.shift_on:
    mov byte [shift_state], 1
    jmp .readkey
.shift_off:
    mov byte [shift_state], 0
    jmp .readkey
.caps_toggle:
    xor byte [caps_state], 1
    jmp .readkey

.backspace:
    cmp dword [buf_len], 0
    je .readkey
    dec dword [buf_len]
    mov al, 0x08
    call print_char
    jmp .readkey

.enter:
    mov al, 0x0A
    call print_char
    mov edi, [buf_len]
    mov byte [cmdbuf + edi], 0   ; null-terminate
    mov esi, cmdbuf              ; remember command for Up-arrow recall
    mov edi, lastcmd
.savehist:
    mov al, [esi]
    mov [edi], al
    test al, al
    jz .savedone
    inc esi
    inc edi
    jmp .savehist
.savedone:
    call run_command
    jmp shell

.history_up:
    cmp byte [lastcmd], 0        ; nothing stored yet?
    je .readkey
.hu_erase:                       ; wipe whatever is on the current line
    cmp dword [buf_len], 0
    je .hu_load
    dec dword [buf_len]
    mov al, 0x08
    call print_char
    jmp .hu_erase
.hu_load:                        ; copy lastcmd into the buffer + echo it
    mov esi, lastcmd
    mov edi, cmdbuf
    xor ecx, ecx
.hu_copy:
    mov al, [esi]
    test al, al
    jz .hu_done
    mov [edi], al
    call print_char
    inc esi
    inc edi
    inc ecx
    jmp .hu_copy
.hu_done:
    mov [buf_len], ecx
    jmp .readkey

; ---------------- command dispatch ----------------
run_command:
    cmp dword [buf_len], 0
    je .ret

    mov esi, cmdbuf
    mov edi, str_help
    call streq
    je .help
    mov esi, cmdbuf
    mov edi, str_cpu
    call streq
    je .cpu
    mov esi, cmdbuf
    mov edi, str_about
    call streq
    je .about
    mov esi, cmdbuf
    mov edi, str_clear
    call streq
    je .clear
    mov esi, cmdbuf
    mov edi, str_ver
    call streq
    je .ver
    mov esi, cmdbuf
    mov edi, str_reboot
    call streq
    je .reboot
    mov esi, cmdbuf
    mov edi, str_time
    call streq
    je .time
    mov esi, cmdbuf
    mov edi, str_date
    call streq
    je .date
    mov esi, cmdbuf
    mov edi, str_mem
    call streq
    je .mem
    mov esi, cmdbuf
    mov edi, str_uptime
    call streq
    je .uptime
    mov esi, cmdbuf
    mov edi, str_colorsp        ; "color <name>"
    call startswith
    je .do_color
    mov esi, cmdbuf
    mov edi, str_calcsp         ; "calc <a> <op> <b>"
    call startswith
    je .calc

    mov esi, msg_unknown        ; unknown command
    call print_str
    mov esi, cmdbuf
    call print_str
    mov al, 0x0A
    call print_char
.ret:
    ret

.help:
    mov esi, msg_help
    call print_str
    ret
.about:
    mov esi, msg_about
    call print_str
    ret
.ver:
    mov esi, msg_ver
    call print_str
    ret
.clear:
    call clear_screen
    ret
.reboot:
    mov esi, msg_reboot
    call print_str
    cli
.rb_wait:
    in al, 0x64            ; wait for the keyboard controller input buffer to clear
    test al, 0x02
    jnz .rb_wait
    mov al, 0xFE          ; pulse the CPU reset line -> reboot
    out 0x64, al
.rb_hang:
    hlt
    jmp .rb_hang
.cpu:
    mov eax, 0x80000000         ; is the CPU brand string available?
    cpuid
    cmp eax, 0x80000004
    jb .cpu_vendor
    mov edi, cpubuf             ; leaves 0x80000002..4 = 48-char brand string
    mov eax, 0x80000002
    cpuid
    mov [edi], eax
    mov [edi+4], ebx
    mov [edi+8], ecx
    mov [edi+12], edx
    mov eax, 0x80000003
    cpuid
    mov [edi+16], eax
    mov [edi+20], ebx
    mov [edi+24], ecx
    mov [edi+28], edx
    mov eax, 0x80000004
    cpuid
    mov [edi+32], eax
    mov [edi+36], ebx
    mov [edi+40], ecx
    mov [edi+44], edx
    mov byte [edi+48], 0
    jmp .cpu_print
.cpu_vendor:
    mov eax, 0                  ; fall back to the 12-char vendor id
    cpuid
    mov edi, cpubuf
    mov [edi], ebx
    mov [edi+4], edx
    mov [edi+8], ecx
    mov byte [edi+12], 0
.cpu_print:
    mov esi, msg_cpu
    call print_str
    mov esi, cpubuf
    mov bl, WHITE
    call print_str_color
    mov al, 0x0A
    call print_char
    ret

.time:
    call read_rtc
    mov al, [rtc_hour]
    call print_2digit
    mov al, ':'
    call print_char
    mov al, [rtc_min]
    call print_2digit
    mov al, ':'
    call print_char
    mov al, [rtc_sec]
    call print_2digit
    mov al, 0x0A
    call print_char
    ret
.date:
    call read_rtc
    mov al, [rtc_day]
    call print_2digit
    mov al, '/'
    call print_char
    mov al, [rtc_month]
    call print_2digit
    mov al, '/'
    call print_char
    mov al, '2'            ; assume 20xx
    call print_char
    mov al, '0'
    call print_char
    mov al, [rtc_year]
    call print_2digit
    mov al, 0x0A
    call print_char
    ret
.mem:
    mov esi, msg_mem
    call print_str
    mov eax, [0x1000]     ; total KB stashed by the boot sector
    mov ebx, 1024
    xor edx, edx
    div ebx               ; eax = MB
    call print_dec
    mov esi, msg_mb
    call print_str
    ret
.do_color:
    mov [argptr], esi          ; ESI points at the colour name
    mov edi, cn_green
    call streq
    je .c_green
    mov esi, [argptr]
    mov edi, cn_red
    call streq
    je .c_red
    mov esi, [argptr]
    mov edi, cn_blue
    call streq
    je .c_blue
    mov esi, [argptr]
    mov edi, cn_cyan
    call streq
    je .c_cyan
    mov esi, [argptr]
    mov edi, cn_yellow
    call streq
    je .c_yellow
    mov esi, [argptr]
    mov edi, cn_white
    call streq
    je .c_white
    mov esi, [argptr]
    mov edi, cn_magenta
    call streq
    je .c_magenta
    mov esi, [argptr]
    mov edi, cn_gray
    call streq
    je .c_gray
    mov esi, msg_badcolor
    call print_str
    ret
.c_green:
    mov byte [cur_color], 0x0A
    jmp .color_done
.c_red:
    mov byte [cur_color], 0x0C
    jmp .color_done
.c_blue:
    mov byte [cur_color], 0x09
    jmp .color_done
.c_cyan:
    mov byte [cur_color], 0x0B
    jmp .color_done
.c_yellow:
    mov byte [cur_color], 0x0E
    jmp .color_done
.c_white:
    mov byte [cur_color], 0x0F
    jmp .color_done
.c_magenta:
    mov byte [cur_color], 0x0D
    jmp .color_done
.c_gray:
    mov byte [cur_color], 0x07
.color_done:
    mov esi, msg_colorok
    call print_str
    ret
.uptime:
    mov esi, msg_uptime
    call print_str
    mov eax, [ticks]
    mov ebx, 100               ; timer runs at 100 Hz
    xor edx, edx
    div ebx                    ; eax = seconds
    call print_dec
    mov esi, msg_sec
    call print_str
    ret
.calc:                          ; ESI points just past "calc "
    call skip_spaces
    call parse_uint
    mov [num1], eax
    call skip_spaces
    mov al, [esi]
    mov [calc_op], al
    inc esi
    call skip_spaces
    call parse_uint
    mov [num2], eax
    mov eax, [num1]
    mov ebx, [num2]
    mov cl, [calc_op]
    cmp cl, '+'
    je .ca_add
    cmp cl, '-'
    je .ca_sub
    cmp cl, '*'
    je .ca_mul
    cmp cl, '/'
    je .ca_div
    mov esi, msg_calcerr
    call print_str
    ret
.ca_add:
    add eax, ebx
    jmp .ca_show
.ca_sub:
    sub eax, ebx
    jmp .ca_show
.ca_mul:
    imul eax, ebx
    jmp .ca_show
.ca_div:
    test ebx, ebx
    jz .ca_divzero
    xor edx, edx
    div ebx
    jmp .ca_show
.ca_divzero:
    mov esi, msg_divzero
    call print_str
    ret
.ca_show:
    mov esi, msg_eq
    call print_str
    mov ebx, eax               ; handle a negative result (subtraction)
    test ebx, ebx
    jns .ca_pos
    mov al, '-'
    call print_char
    neg ebx
.ca_pos:
    mov eax, ebx
    call print_dec
    mov al, 0x0A
    call print_char
    ret

; ---------------- read the CMOS real-time clock ----------------
read_rtc:
    pushad
.uip:
    mov al, 0x0A          ; status register A
    out 0x70, al
    in  al, 0x71
    test al, 0x80         ; bit7 = update-in-progress
    jnz .uip
    mov al, 0x00
    call .rd
    mov [rtc_sec], al
    mov al, 0x02
    call .rd
    mov [rtc_min], al
    mov al, 0x04
    call .rd
    mov [rtc_hour], al
    mov al, 0x07
    call .rd
    mov [rtc_day], al
    mov al, 0x08
    call .rd
    mov [rtc_month], al
    mov al, 0x09
    call .rd
    mov [rtc_year], al
    ; is the RTC in BCD? (status B bit2 clear = BCD)
    mov al, 0x0B
    call .rd
    test al, 0x04
    jnz .done             ; already binary
    mov al, [rtc_sec]
    call bcd2bin
    mov [rtc_sec], al
    mov al, [rtc_min]
    call bcd2bin
    mov [rtc_min], al
    mov al, [rtc_hour]
    call bcd2bin
    mov [rtc_hour], al
    mov al, [rtc_day]
    call bcd2bin
    mov [rtc_day], al
    mov al, [rtc_month]
    call bcd2bin
    mov [rtc_month], al
    mov al, [rtc_year]
    call bcd2bin
    mov [rtc_year], al
.done:
    popad
    ret
.rd:                      ; AL = CMOS register index -> AL = value
    out 0x70, al
    in  al, 0x71
    ret

bcd2bin:                  ; AL: packed BCD -> AL: binary (0..99)
    push ebx
    push edx
    mov bl, al
    and al, 0x0F          ; units
    mov bh, al
    mov al, bl
    shr al, 4             ; tens
    mov dl, 10
    mul dl                ; AX = tens * 10
    add al, bh            ; + units
    pop edx
    pop ebx
    ret

print_2digit:            ; AL = 0..99 -> two decimal digits
    pushad
    movzx eax, al
    mov bl, 10
    div bl               ; AL = tens, AH = units
    mov bh, ah
    add al, '0'
    call print_char
    mov al, bh
    add al, '0'
    call print_char
    popad
    ret

print_dec:               ; EAX = unsigned number -> decimal
    pushad
    mov ebx, 10
    xor ecx, ecx
    test eax, eax
    jnz .split
    mov al, '0'
    call print_char
    jmp .done
.split:
    test eax, eax
    jz .emit
    xor edx, edx
    div ebx
    add dl, '0'
    push edx
    inc ecx
    jmp .split
.emit:
    test ecx, ecx
    jz .done
    pop edx
    mov al, dl
    call print_char
    dec ecx
    jmp .emit
.done:
    popad
    ret

; ---------------- interrupts: IDT + PIC + PIT timer ----------------
setup_idt:
    pushad
    mov ecx, 256
    mov edi, idt
    mov eax, default_isr
.fill:
    mov [edi], ax              ; offset low
    mov word [edi+2], 0x08     ; selector = kernel code segment
    mov byte [edi+4], 0
    mov byte [edi+5], 0x8E     ; present, ring0, 32-bit interrupt gate
    ror eax, 16
    mov [edi+6], ax            ; offset high
    rol eax, 16
    add edi, 8
    dec ecx
    jnz .fill
    ; vector 0x20 (IRQ0, timer) -> timer_isr
    mov eax, timer_isr
    mov edi, idt + 0x20*8
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

pic_remap:
    mov al, 0x11               ; ICW1: begin init
    out 0x20, al
    out 0xA0, al
    mov al, 0x20               ; ICW2: master IRQs -> 0x20..
    out 0x21, al
    mov al, 0x28               ; ICW2: slave IRQs -> 0x28..
    out 0xA1, al
    mov al, 0x04               ; ICW3: slave is on master IRQ2
    out 0x21, al
    mov al, 0x02
    out 0xA1, al
    mov al, 0x01               ; ICW4: 8086 mode
    out 0x21, al
    out 0xA1, al
    mov al, 0xFE               ; master mask: enable IRQ0 (timer) only
    out 0x21, al
    mov al, 0xFF               ; slave mask: all off
    out 0xA1, al
    ret

pit_init:
    mov al, 0x36               ; channel 0, lo/hi byte, mode 3 (square wave)
    out 0x43, al
    mov ax, 11931              ; 1193182 / 100 -> ~100 Hz
    out 0x40, al
    mov al, ah
    out 0x40, al
    ret

timer_isr:
    pushad
    inc dword [ticks]
    mov al, 0x20               ; EOI to the master PIC
    out 0x20, al
    popad
    iret

default_isr:
    iret

; ---------------- tiny parsers (for calc) ----------------
parse_uint:                    ; ESI -> digits; returns EAX = value, ESI advanced
    xor eax, eax
.pu:
    movzx ebx, byte [esi]
    cmp bl, '0'
    jb .pudone
    cmp bl, '9'
    ja .pudone
    imul eax, eax, 10
    sub ebx, '0'
    add eax, ebx
    inc esi
    jmp .pu
.pudone:
    ret

skip_spaces:                   ; advance ESI past spaces
.sk:
    cmp byte [esi], ' '
    jne .skdone
    inc esi
    jmp .sk
.skdone:
    ret

; ---------------- string compare: ZF=1 if equal ----------------
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
    xor eax, eax            ; ZF = 1
    ret
.neq:
    mov eax, 1
    and eax, eax           ; ZF = 0
    ret

; ---------------- prefix test: ZF=1 if ESI starts with EDI ----------------
; on match, ESI is left pointing just past the prefix (at the argument)
startswith:
.sw:
    mov al, [edi]
    test al, al
    jz .yes                 ; prefix consumed -> match
    mov ah, [esi]
    cmp al, ah
    jne .no
    inc esi
    inc edi
    jmp .sw
.yes:
    xor eax, eax            ; ZF = 1
    ret
.no:
    mov eax, 1
    and eax, eax           ; ZF = 0
    ret

; ---------------- VGA text output ----------------
; print_char: AL = character, uses [text_color]
print_char:
    pushad
    cmp al, 0x0A
    je .newline
    cmp al, 0x08
    je .back
    mov edi, [cursor]
    mov ah, [text_color]
    mov ebx, VGA
    mov [ebx + edi*2], ax
    inc dword [cursor]
    jmp .check
.newline:
    mov eax, [cursor]
    xor edx, edx
    mov ecx, 80
    div ecx                ; eax = row, edx = col
    inc eax
    mul ecx                ; eax = (row+1)*80
    mov [cursor], eax
    jmp .check
.back:
    cmp dword [cursor], 0
    je .done
    dec dword [cursor]
    mov edi, [cursor]
    mov ebx, VGA
    mov word [ebx + edi*2], 0x0A20   ; blank the cell
.check:
    cmp dword [cursor], 2000
    jl .done
    call scroll
.done:
    call update_cursor
    popad
    ret

; print_str: ESI -> 0-terminated string, uses the current colour
print_str:
    mov al, [cur_color]
    mov [text_color], al
.go:
    push esi
.next:
    lodsb
    test al, al
    jz .end
    call print_char
    jmp .next
.end:
    pop esi
    ret

; print_str_color: ESI -> string, BL = colour attribute
print_str_color:
    mov [text_color], bl
    jmp print_str.go

scroll:
    pushad
    mov esi, VGA + 160          ; copy lines 1..24 up over 0..23
    mov edi, VGA
    mov ecx, 24*80
    rep movsd                   ; note: movsd copies 2 cells at a time
    mov edi, VGA + 24*160       ; clear the last line
    mov ecx, 80
    mov ax, 0x0A20
    rep stosw
    mov dword [cursor], 24*80
    popad
    ret

clear_screen:
    pushad
    mov edi, VGA
    mov ecx, 2000
    mov ax, 0x0A20              ; space, green-on-black
    rep stosw
    mov dword [cursor], 0
    popad
    ret

; move the blinking hardware cursor to [cursor] (VGA CRTC, ports 0x3D4/0x3D5)
update_cursor:
    pushad
    mov ebx, [cursor]          ; cell offset 0..1999
    mov dx, 0x3D4
    mov al, 0x0F               ; cursor location low byte
    out dx, al
    mov dx, 0x3D5
    mov al, bl
    out dx, al
    mov dx, 0x3D4
    mov al, 0x0E               ; cursor location high byte
    out dx, al
    mov dx, 0x3D5
    mov al, bh
    out dx, al
    popad
    ret

; enable the hardware cursor as a visible underline (scanlines 14-15)
enable_cursor:
    pushad
    mov dx, 0x3D4
    mov al, 0x0A               ; cursor start register
    out dx, al
    mov dx, 0x3D5
    mov al, 0x0E               ; start scanline 14 (bit5=0 -> cursor visible)
    out dx, al
    mov dx, 0x3D4
    mov al, 0x0B               ; cursor end register
    out dx, al
    mov dx, 0x3D5
    mov al, 0x0F               ; end scanline 15
    out dx, al
    popad
    ret

; ------------------------- data ----------------------------
cursor:      dd 0
text_color:  db COLOR
buf_len:     dd 0
shift_state: db 0
caps_state:  db 0

banner:
    db 10
    db " N   N   OOO   V   V   AAA ", 10
    db " NN  N  O   O  V   V  A   A", 10
    db " N N N  O   O  V   V  AAAAA", 10
    db " N  NN  O   O   V V   A   A", 10
    db " N   N   OOO     V    A   A", 10
    db 10
    db "     O S  -  32-bit kernel v0.6", 10, 0
rtc_sec:   db 0
rtc_min:   db 0
rtc_hour:  db 0
rtc_day:   db 0
rtc_month: db 0
rtc_year:  db 0
hint:
    db 10, "Type 'help' for commands.", 10, 0
prompt:
    db 10, "Nova> ", 0

str_help:   db "help", 0
str_cpu:    db "cpu", 0
str_about:  db "about", 0
str_clear:  db "clear", 0
str_ver:    db "ver", 0
str_reboot: db "reboot", 0
str_time:   db "time", 0
str_date:   db "date", 0
str_mem:    db "mem", 0
str_uptime: db "uptime", 0
str_colorsp: db "color ", 0
str_calcsp:  db "calc ", 0

cn_green:   db "green", 0
cn_red:     db "red", 0
cn_blue:    db "blue", 0
cn_cyan:    db "cyan", 0
cn_yellow:  db "yellow", 0
cn_white:   db "white", 0
cn_magenta: db "magenta", 0
cn_gray:    db "gray", 0

msg_help:   db "Cmds: help cpu mem uptime time date calc color about clear ver reboot", 10, 0
msg_about:  db "Nova OS - a from-scratch operating system.", 10
            db "Own bootloader, own 32-bit kernel. No Windows,", 10
            db "no Linux underneath. Written in x86 assembly.", 10, 0
msg_ver:    db "Nova OS kernel v0.6 (protected mode)", 10, 0
msg_cpu:    db "CPU: ", 0
msg_reboot: db "Rebooting Nova OS...", 10, 0
msg_mem:    db "RAM: ", 0
msg_mb:     db " MB", 10, 0
msg_colorok:  db "Colour updated.", 10, 0
msg_badcolor: db "Colours: green red blue cyan yellow white magenta gray", 10, 0
msg_uptime:  db "Uptime: ", 0
msg_sec:     db " seconds", 10, 0
msg_eq:      db "= ", 0
msg_divzero: db "Cannot divide by zero.", 10, 0
msg_calcerr: db "Usage: calc <a> <+ - * /> <b>", 10, 0
msg_unknown: db "Unknown command: ", 0

cur_color:  db COLOR
argptr:     dd 0
ticks:      dd 0
ext_flag:   db 0
calc_op:    db 0
num1:       dd 0
num2:       dd 0
lastcmd:    times 80 db 0

cmdbuf:  times 80 db 0
cpubuf:  times 52 db 0

; ---- PS/2 scancode set 1 -> ASCII (make codes). 0 = unmapped ----
scancodes:
    db 0,   0,   '1', '2', '3', '4', '5', '6'      ; 00-07
    db '7', '8', '9', '0', '-', '=', 0x08, 0        ; 08-0F  (0x0E=Backspace)
    db 'q', 'w', 'e', 'r', 't', 'y', 'u', 'i'       ; 10-17
    db 'o', 'p', '[', ']', 0x0A, 0,   'a', 's'      ; 18-1F  (0x1C=Enter)
    db 'd', 'f', 'g', 'h', 'j', 'k', 'l', ';'       ; 20-27
    db "'", '`', 0,   '\', 'z', 'x', 'c', 'v'       ; 28-2F
    db 'b', 'n', 'm', ',', '.', '/', 0,   '*'       ; 30-37
    db 0,   ' ', 0,   0,   0,   0,   0,   0          ; 38-3F  (0x39=Space)
    times 128-($-scancodes) db 0

; ---- shifted variants (used for symbols; letters handled separately) ----
scancodes_shift:
    db 0,   0,   '!', '@', '#', '$', '%', '^'       ; 00-07
    db '&', '*', '(', ')', '_', '+', 0x08, 0        ; 08-0F
    db 'Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I'       ; 10-17
    db 'O', 'P', '{', '}', 0x0A, 0,   'A', 'S'      ; 18-1F
    db 'D', 'F', 'G', 'H', 'J', 'K', 'L', ':'       ; 20-27
    db '"', '~', 0,   '|', 'Z', 'X', 'C', 'V'       ; 28-2F
    db 'B', 'N', 'M', '<', '>', '?', 0,   '*'       ; 30-37
    db 0,   ' ', 0,   0,   0,   0,   0,   0          ; 38-3F
    times 128-($-scancodes_shift) db 0

; ---- Interrupt Descriptor Table (256 gates, filled at runtime) ----
idt_descriptor:
    dw 256*8 - 1
    dd idt
idt:
    times 256*8 db 0
