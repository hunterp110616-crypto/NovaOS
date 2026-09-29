; ============================================================
;  NovaOS  --  Shut Down dialog, ACPI power-off, Update-from-USB,
;              and the recorded startup sound (PC-speaker PWM)
;  (included into kernel_vesa.asm)
;
;  Disk layout used here (raw sectors, outside the FAT partition):
;    0 MBR   1..200 Nova Core   200 installed marker   201 icon cfg
;    202 "NOVAUSB " version block (only on a NovaOS USB)
;    256 "NOVASND " sound header (rate, length)   257.. 8-bit samples
; ============================================================

SND_LBA   equ 256
SNDBUF    equ 0x00800000        ; decoded sound samples in RAM
UPD_LBA   equ 202
CORE_SECT equ 199               ; KERNEL_SECTORS: LBA 1-199 (LBA 200 is the installed marker)
SFX_LBA     equ 600             ; Music Maker's one-shot SFX bank -- fixed location, no header sector
SFX_SECTORS equ 146             ; matches sfx.u8's size at build time (build_image.py asserts it fits)

; ---------------- multi-sector reads from any BIOS drive ----------------
; EAX = LBA, ECX = sectors (1..64), EDI = destination, DL = drive.  AL = 0 ok
disk_read_multi:
    cmp dl, 0xFE                     ; the USB stick through our own driver
    jne .bios
    pushad
.u:
    call usb_read_sector
    jc .uf
    inc eax
    add edi, 512
    dec ecx
    jnz .u
    popad
    xor al, al
    ret
.uf:
    popad
    mov al, 1
    ret
.bios:
    pushad
    mov [dap16_lba], eax
    mov dword [dap16_lba+4], 0
    mov [dap_count], cx
    mov [thunk_drive], dl
    mov byte [thunk_cmd], 0x42
    push ecx
    push edi
    call bios_xfer
    pop edi
    pop ecx
    mov esi, BIOSBUF
    shl ecx, 7                   ; *128 dwords
    rep movsd
    mov word [dap_count], 1
    popad
    mov al, [thunk_res]
    ret

; copy COUNT sectors starting at LBA from drive [cp_src] to drive [cp_dst]
; EAX = LBA, ECX = count.  AL = 0 ok.  Calls [cp_tick] every sector if set.
copy_sectors:
    pushad
    mov [cp_lba], eax
    mov [cp_left], ecx
.l:
    cmp dword [cp_left], 0
    je .ok
    mov al, [cp_src]
    mov [inst_drive], al
    mov eax, [cp_lba]
    call wiz_read_target         ; -> DISKBUF
    test al, al
    jnz .fail
    mov al, [cp_dst]
    mov [inst_drive], al
    mov eax, [cp_lba]
    mov esi, DISKBUF
    call bios_write_lba
    test al, al
    jnz .fail
    inc dword [cp_lba]
    dec dword [cp_left]
    cmp dword [cp_tick], 0
    je .l
    call [cp_tick]
    jmp .l
.ok:
    popad
    xor al, al
    ret
.fail:
    popad
    mov al, 1
    ret

; number of sound sectors (header + data) on drive DL, from its header.  EAX = 0 if none
snd_sectors_on:
    push edx
    mov eax, SND_LBA
    mov ecx, 1
    mov edi, WSECT
    call disk_read_multi
    pop edx
    test al, al
    jnz .none
    mov esi, WSECT
    mov edi, snd_magic
    mov ecx, 8
    cld
    repe cmpsb
    jne .none
    mov eax, [WSECT + 12]        ; sample count
    add eax, 511
    shr eax, 9
    inc eax                      ; + header
    cmp eax, 1790                ; must stay below the FAT partition (LBA 2048)
    ja .none
    ret
.none:
    xor eax, eax
    ret

; ---------------- startup sound ----------------
; load the recorded sound from the boot disk into SNDBUF (at boot)
snd_load:
    pushad
    mov dword [snd_len], 0
    mov dl, [0x1014]
    call snd_sectors_on
    test eax, eax
    jz .done
    mov eax, [WSECT + 8]
    mov [snd_rate], eax
    mov eax, [WSECT + 12]
    mov [snd_tmp], eax
    mov eax, SND_LBA + 1
    mov edi, SNDBUF
    mov ecx, [snd_tmp]
    add ecx, 511
    shr ecx, 9
    mov [snd_left], ecx
.chunk:
    cmp dword [snd_left], 0
    je .loaded
    mov ecx, [snd_left]
    cmp ecx, 64
    jbe .c
    mov ecx, 64
.c:
    push eax
    push ecx
    mov dl, [0x1014]
    call disk_read_multi
    test al, al
    pop ecx
    pop eax
    jnz .done
    add eax, ecx
    sub [snd_left], ecx
    shl ecx, 9
    add edi, ecx
    jmp .chunk
.loaded:
    mov eax, [snd_tmp]
    mov [snd_len], eax
.done:
    popad
    ret

; load Music Maker's one-shot SFX bank (fixed LBA/size, no header) into SFX_BUF
sfx_load:
    pushad
    mov eax, SFX_LBA
    mov edi, SFX_BUF
    mov dword [sfx_left], SFX_SECTORS
.chunk:
    cmp dword [sfx_left], 0
    je .done
    mov ecx, [sfx_left]
    cmp ecx, 64
    jbe .c
    mov ecx, 64
.c:
    push eax
    push ecx
    mov dl, [0x1014]
    call disk_read_multi
    test al, al
    pop ecx
    pop eax
    jnz .done
    add eax, ecx
    sub [sfx_left], ecx
    shl ecx, 9
    add edi, ecx
    jmp .chunk
.done:
    popad
    ret
sfx_left: dd 0

; play SNDBUF on the PC speaker: pulse-width modulation, one PIT one-shot per sample
play_startup_sound:
    cmp dword [sound_on], 0
    je .ret
    cmp dword [snd_len], 0
    jne .pcm
    call play_startup_xp         ; no recording on this disk -> the chime
.ret:
    ret
.pcm:
    cmp dword [hda_ok], 0        ; a real sound chip: convert + start it playing, and return
    je .speaker                  ; right away -- the desktop doesn't wait out the whole clip
    call hda_play_startup
    ret
.speaker:
    pushad
    mov eax, 1193182             ; PIT ticks per sample = the PWM range
    xor edx, edx
    div dword [snd_rate]
    dec eax
    mov [pwm_max], eax
    mov eax, [tsc_per_ms]        ; CPU ticks per sample
    mov ebx, 1000
    mul ebx
    div dword [snd_rate]
    mov [pwm_tps], eax
    in al, 0x61
    or al, 3                     ; gate + speaker on
    out 0x61, al
    mov al, 0x90                 ; PIT ch2, low byte only, mode 0 (one-shot)
    out 0x43, al
    mov esi, SNDBUF
    mov ecx, [snd_len]
    rdtsc
    mov [pwm_next], eax
.s:
    movzx eax, byte [esi]
    imul eax, [hda_volume]       ; same master volume the HDA path respects
    mov ebx, 100
    xor edx, edx
    div ebx
    mul dword [pwm_max]
    shr eax, 8
    inc eax
    out 0x42, al                 ; restart the pulse: width = this sample
    mov eax, [pwm_tps]
    add [pwm_next], eax
.w:
    rdtsc
    sub eax, [pwm_next]
    js .w
    inc esi
    dec ecx
    jnz .s
    call spk_off
    popad
    ret

; ---------------- Shut Down dialog ----------------
SD_W equ 520
SD_H equ 260

shutdown_dialog:
    pushad
    call restore_cursor
    call grey_screen
    mov eax, [scrw]
    sub eax, SD_W
    shr eax, 1
    mov [wcx], eax               ; reuse the wizard's card helpers (wiz_rect / wiz_text)
    mov eax, [scrh]
    sub eax, SD_H
    shr eax, 1
    mov [wcy], eax
    call usb_find_update
    mov dword [sd_busy], 0
    call sd_draw
    mov dword [wiz_exit], 0
    mov dword [modal_click], sd_click
    mov byte [prev_btn], 1       ; ignore the click that opened us
    mov byte [mouse_cycle], 0
.loop:
    cmp dword [wiz_exit], 0
    jne .out
    call kbc_poll                ; PS/2 keyboard/mouse, or our USB ones
    jz .loop
    cmp ah, 2
    je .mouse
.key:
    call sd_key
    jmp .loop
.mouse:
    call wiz_mouse_feed
    jmp .loop
.out:
    mov dword [modal_click], wiz_click
    call redraw_all              ; Cancel -> back to the desktop
    cmp byte [mouse_present], 0
    je .nc
    call save_cursor
    call draw_cursor
.nc:
    popad
    ret

grey_screen:                     ; the desktop fades to grey behind the dialog
    pushad
    xor ebx, ebx
.row:
    cmp ebx, [scrh]
    jae .done
    mov edi, ebx
    imul edi, [pitch]
    add edi, [lfb]
    mov ecx, [scrw]
.px:
    mov eax, [edi]
    movzx edx, al
    mov ebp, eax
    shr ebp, 8
    and ebp, 0xFF
    add edx, ebp
    shr eax, 16
    and eax, 0xFF
    add edx, eax
    imul edx, 43                 ; (r+g+b)/3 * ~0.55  ->  grey, dimmed
    shr edx, 8
    add edx, 18
    mov eax, edx
    shl eax, 8
    or eax, edx
    shl eax, 8
    or eax, edx
    mov [edi], eax
    add edi, 4
    dec ecx
    jnz .px
    inc ebx
    jmp .row
.done:
    popad
    ret

sd_draw:
    pushad
    mov eax, 6                   ; shadow
    mov ebx, 6
    mov ecx, SD_W
    mov edx, SD_H
    mov edi, 0x00080A10
    call wiz_rect
    xor eax, eax                 ; body + title bar
    xor ebx, ebx
    mov ecx, SD_W
    mov edx, SD_H
    mov edi, 0x001B2433
    call wiz_rect
    xor eax, eax
    xor ebx, ebx
    mov ecx, SD_W
    mov edx, 36
    mov edi, [accent]
    call wiz_rect
    WTXT sd_title, 16, 10, 0x00FFFFFF
    WTXT sd_ask, 24, 54, 0x00E6ECF2
    cmp dword [sd_busy], 0
    jne .busy
    xor ecx, ecx                 ; three big buttons
.b:
    cmp ecx, 3
    jae .bd
    mov eax, ecx
    imul eax, 160
    add eax, 30
    mov [sd_bx], eax
    push ecx
    mov edi, 0x00283346          ; button face (greyed if Update isn't available)
    mov ecx, 140
    mov ebx, 84
    mov edx, 118
    call wiz_rect
    pop ecx
    push ecx
    mov edi, [sd_col + ecx*4]
    cmp ecx, 2
    jne .ic
    cmp dword [sd_upd], 1
    je .ic
    mov edi, 0x004A5566
.ic:
    mov eax, [sd_bx]
    add eax, 48
    mov ebx, 96
    mov ecx, 44
    mov edx, 44
    call wiz_rect
    pop ecx
    push ecx
    mov esi, [sd_icons + ecx*4]  ; 16x16 pixel-art icon, drawn 2x
    mov eax, [sd_bx]
    add eax, [wcx]
    add eax, 54
    mov ebx, [wcy]
    add ebx, 102
    call draw_icon16
    pop ecx
    push ecx
    mov esi, [sd_lbl + ecx*4]    ; label, centred
    push ecx
    call wiz_strlen
    shl ecx, 3
    mov eax, 140
    sub eax, ecx
    shr eax, 1
    add eax, [sd_bx]
    pop ecx
    mov ebx, 154
    mov edi, 0x00FFFFFF
    call wiz_text
    pop ecx
    inc ecx
    jmp .b
.bd:
    mov eax, [sd_upd]            ; status line under "Update from USB"
    mov esi, [sd_ustat + eax*4]
    call wiz_strlen
    shl ecx, 3
    mov eax, 140
    sub eax, ecx
    sar eax, 1
    add eax, 350
    mov ebx, 176
    mov edi, 0x008A96A6
    cmp dword [sd_upd], 1
    jne .st
    mov edi, 0x0070D890
.st:
    call wiz_text
    cmp dword [sd_upd], 1        ; show the USB's version
    jne .can
    mov esi, sd_usbver
    call wiz_strlen
    mov eax, 360 + 8*8           ; right after "Version "
    mov ebx, 176
    mov edi, 0x0070D890
    call wiz_text
.can:
    mov eax, SD_W - 112          ; Cancel
    mov ebx, SD_H - 42
    mov ecx, 96
    mov edx, 28
    mov edi, 0x003A4658
    call wiz_rect
    WTXT sd_cancel, SD_W - 88, SD_H - 36, 0x00FFFFFF
    WTXT sd_keys, 24, SD_H - 36, 0x006F7C8E
    jmp .fin
.busy:                           ; updating: progress bar instead of buttons
    mov esi, [sd_msg]
    mov eax, 30
    mov ebx, 110
    mov edi, 0x00FFFFFF
    call wiz_text
    mov eax, 30
    mov ebx, 146
    mov ecx, SD_W - 60
    mov edx, 22
    mov edi, 0x00323C4C
    call wiz_rect
    mov eax, [sd_pct]
    imul eax, SD_W - 60
    xor edx, edx
    mov ecx, 100
    div ecx
    test eax, eax
    jz .np
    mov ecx, eax
    mov eax, 30
    mov ebx, 146
    mov edx, 22
    mov edi, WZ_BAR
    call wiz_rect
.np:
    WTXT sd_dont, 30, 184, 0x00FFB070
.fin:
    cmp byte [mouse_present], 0
    je .nc
    cmp dword [sd_busy], 0
    jne .nc
    call save_cursor
    call draw_cursor
.nc:
    popad
    ret

sd_click:
    cmp dword [sd_busy], 0
    jne .r
    xor edi, edi
.b:
    cmp edi, 3
    jae .cancel
    mov eax, edi
    imul eax, 160
    add eax, 30
    mov ebx, 84
    mov ecx, 140
    mov edx, 118
    call wiz_hit
    test eax, eax
    jnz .do
    inc edi
    jmp .b
.do:
    mov eax, edi
    jmp sd_action
.cancel:
    mov eax, SD_W - 112
    mov ebx, SD_H - 42
    mov ecx, 96
    mov edx, 28
    call wiz_hit
    test eax, eax
    jz .r
    mov dword [wiz_exit], 1
.r:
    ret

sd_key:                          ; S = shut down, R = restart, U = update, Esc = cancel
    test al, 0x80
    jnz .r
    cmp al, 0x01
    jne .k1
    mov dword [wiz_exit], 1
    ret
.k1:
    xor ecx, ecx
    cmp al, 0x1F
    je .go
    inc ecx
    cmp al, 0x13
    je .go
    inc ecx
    cmp al, 0x16
    je .go
.r:
    ret
.go:
    mov eax, ecx

sd_action:                       ; EAX = 0 shut down, 1 restart, 2 update
    cmp eax, 1
    je sys_restart
    cmp eax, 2
    je .upd
    jmp sys_shutdown
.upd:
    cmp dword [sd_upd], 1
    je usb_update
    cmp dword [sd_upd], 3        ; running from the USB itself
    je .nope
    cmp dword [sd_upd], 2
    je .nope
    mov dword [sd_upd], 5        ; "Searching..."
    call sd_draw
    call usb_init                ; NovaOS's own USB driver takes over (keyboards / mice keep working)
    call usb_find_update
    call sd_draw
    ret
.nope:
    call err_beep
    ret

sys_restart:
    mov esi, sd_restarting
    call power_screen
    mov ecx, 600
    call tsc_wait_ms
    mov al, 0xFE
    out 0x64, al
.h:
    hlt
    jmp .h

sys_shutdown:
    mov esi, sd_shutting
    call power_screen
    call play_shutdown_chime
    call acpi_poweroff           ; returns only if this computer can't power itself off
    ; fallback: the classic safe-to-turn-off screen
    mov dword [rx], 0
    mov dword [ry], 0
    mov eax, [scrw]
    mov [rw], eax
    mov eax, [scrh]
    mov [rh], eax
    mov dword [rcolor], 0x00000000
    call fillrect
    mov dword [tscale], 2
    mov eax, [scrw]
    sub eax, 40*16
    sar eax, 1
    mov [tx], eax
    mov eax, [scrh]
    shr eax, 1
    sub eax, 16
    mov [ty], eax
    mov dword [tcolor], 0x00FF9A2A
    mov esi, sd_safe
    call draw_text_scaled
.h:
    hlt
    jmp .h

power_screen:                    ; ESI = message.  Dark screen, Nova logo, centred text
    pushad
    push esi
    mov dword [rx], 0
    mov dword [ry], 0
    mov eax, [scrw]
    mov [rw], eax
    mov eax, [scrh]
    mov [rh], eax
    mov dword [rcolor], 0x000B1424
    call fillrect
    mov eax, [scrw]
    shr eax, 1
    mov [dcx], eax
    mov eax, [scrh]
    shr eax, 1
    sub eax, 60
    mov [dcy], eax
    mov dword [drad], 34
    mov dword [dcolor], 0x0022AA55
    call draw_diamond
    mov dword [drad], 14
    mov dword [dcolor], 0x00E6FFF0
    call draw_diamond
    pop esi
    call wiz_strlen
    shl ecx, 4
    mov eax, [scrw]
    sub eax, ecx
    sar eax, 1
    mov [tx], eax
    mov eax, [scrh]
    shr eax, 1
    add eax, 10
    mov [ty], eax
    mov dword [tcolor], 0x00FFFFFF
    mov dword [tscale], 2
    call draw_text_scaled
    popad
    ret

play_shutdown_chime:             ; short, gentle falling notes
    cmp dword [sound_on], 0
    je .r
    pushad
    mov bx, 1522                 ; G5
    mov ecx, 180
    call tone_ms
    mov bx, 1917                 ; Eb5
    mov ecx, 180
    call tone_ms
    mov bx, 2873                 ; Ab4
    mov ecx, 420
    call tone_ms
    call spk_off
    popad
.r:
    ret

; ---------------- ACPI "soft off" (S5) ----------------
acpi_poweroff:
    pushad
    ; RSDP: "RSD PTR " on a 16-byte boundary in 0xE0000-0xFFFFF (or the EBDA)
    movzx esi, word [0x40E]
    shl esi, 4
    mov ecx, 1024 / 16
    call .scan
    test esi, esi
    jnz .rsdp
    mov esi, 0xE0000
    mov ecx, 0x20000 / 16
    call .scan
    test esi, esi
    jz .fail
.rsdp:
    mov esi, [esi + 16]          ; RSDT
    cmp dword [esi], 'RSDT'
    jne .fail
    mov ecx, [esi + 4]
    sub ecx, 36
    shr ecx, 2
    lea edi, [esi + 36]
.t:
    test ecx, ecx
    jz .fail
    mov ebx, [edi]
    cmp dword [ebx], 'FACP'
    je .fadt
    add edi, 4
    dec ecx
    jmp .t
.fadt:
    mov [ac_fadt], ebx
    mov eax, [ebx + 64]          ; PM1a control block (I/O port)
    mov [ac_pm1a], eax
    mov eax, [ebx + 68]
    mov [ac_pm1b], eax
    cmp dword [ac_pm1a], 0       ; no power-control port -> can't do it
    je .fail
    mov esi, [ebx + 40]          ; DSDT -> find the \_S5_ package
    cmp dword [esi], 'DSDT'
    jne .fail
    mov ecx, [esi + 4]
    add ecx, esi
    mov [ac_end], ecx
    add esi, 36
.s5:
    cmp esi, [ac_end]
    jae .fail
    cmp dword [esi], '_S5_'
    jne .s5n
    cmp byte [esi + 4], 0x12     ; PackageOp
    je .pkg
.s5n:
    inc esi
    jmp .s5
.pkg:
    add esi, 5
    movzx eax, byte [esi]        ; PkgLength: top 2 bits = extra length bytes
    shr eax, 6
    inc eax
    add esi, eax
    inc esi                      ; NumElements
    mov al, [esi]
    cmp al, 0x0A                 ; BytePrefix?
    jne .typ
    inc esi
    mov al, [esi]
.typ:
    movzx eax, al
    and eax, 7
    shl eax, 10
    or eax, 0x2000               ; SLP_EN
    mov [ac_slp], eax
    ; switch ACPI on if the firmware left it off (SCI_EN = bit 0)
    mov edx, [ac_pm1a]
    in ax, dx
    test ax, 1
    jnz .on
    mov ebx, [ac_fadt]
    mov edx, [ebx + 48]          ; SMI_CMD
    test edx, edx
    jz .on
    mov al, [ebx + 52]           ; ACPI_ENABLE
    out dx, al
    mov ecx, 300
.wt:
    push ecx
    mov ecx, 1
    call tsc_wait_ms
    pop ecx
    mov edx, [ac_pm1a]
    in ax, dx
    test ax, 1
    jnz .on
    dec ecx
    jnz .wt
.on:
    mov edx, [ac_pm1a]
    mov eax, [ac_slp]
    out dx, ax
    mov edx, [ac_pm1b]
    test edx, edx
    jz .wait
    out dx, ax
.wait:
    mov ecx, 1500                ; give the hardware a moment to cut the power
    call tsc_wait_ms
.fail:
    popad
    ret
.scan:                           ; ESI start, ECX paragraphs -> ESI = RSDP or 0
    cmp dword [esi], 'RSD '
    jne .sn
    cmp dword [esi + 4], 'PTR '
    je .sf
.sn:
    add esi, 16
    dec ecx
    jnz .scan
    xor esi, esi
.sf:
    ret

; ---------------- Update from USB ----------------
; sd_upd: 0 no update USB, 1 update available, 2 same version, 3 running from the USB
usb_find_update:
    pushad
    mov dword [sd_upd], 3
    cmp dword [install_mode], 0
    je .done
    mov dword [sd_upd], 0
    mov byte [upd_own], 0
    cmp dword [usb_active], 0    ; USB not ours yet -> ask the BIOS (a stick in since power-on)
    je .bios
    mov byte [upd_own], 1
    call usb_scan                ; our driver: look for a stick right now
    cmp dword [usb_ready], 0
    je .done
    mov al, 0xFE
    jmp .o
.bios:
    mov al, 0x81                 ; the "other" BIOS disk
    cmp byte [0x1014], 0x81
    jne .o
    mov al, 0x80
.o:
    mov [upd_drive], al
    mov dl, al
    mov eax, UPD_LBA
    mov ecx, 1
    mov edi, WSECT
    call disk_read_multi
    test al, al
    jnz .miss
    mov esi, WSECT
    mov edi, upd_magic
    mov ecx, 8
    cld
    repe cmpsb
    jne .miss
    mov esi, WSECT + 8           ; its version
    mov edi, sd_usbver
    mov ecx, 15
    rep movsb
    mov byte [sd_usbver + 15], 0
    mov esi, WSECT + 8           ; same as what's running?
    mov edi, nova_ver
    mov ecx, 16
    repe cmpsb
    mov dword [sd_upd], 2
    je .done
    mov dword [sd_upd], 1
    jmp .done
.miss:
    cmp byte [upd_own], 0
    jne .done
    mov dword [sd_upd], 4        ; "Click to search" (with our own USB driver)
.done:
    popad
    ret

usb_update:
    mov dword [sd_busy], 1
    mov dword [sd_pct], 0
    mov dword [sd_msg], sd_upd_go
    call sd_draw
    mov al, [upd_drive]
    mov [cp_src], al
    mov al, [0x1014]
    mov [cp_dst], al
    ; boot code from the USB + THIS disk's own partition table
    mov al, [cp_dst]
    mov [inst_drive], al
    xor eax, eax
    call wiz_read_target
    test al, al
    jnz .fail
    mov esi, DISKBUF + 446
    mov edi, upd_ptab
    mov ecx, 66
    rep movsb
    mov al, [cp_src]
    mov [inst_drive], al
    xor eax, eax
    call wiz_read_target
    test al, al
    jnz .fail
    mov esi, DISKBUF
    mov edi, WSECT
    mov ecx, 446
    rep movsb
    mov esi, upd_ptab
    mov ecx, 66
    rep movsb
    mov al, [cp_dst]
    mov [inst_drive], al
    xor eax, eax
    mov esi, WSECT
    call bios_write_lba
    test al, al
    jnz .fail
    ; the Nova Core
    mov dword [cp_done], 0
    mov dword [cp_tick], upd_tick
    mov eax, 1
    mov ecx, CORE_SECT
    call copy_sectors
    test al, al
    jnz .fail
    ; the startup sound
    mov dl, [cp_src]
    call snd_sectors_on
    test eax, eax
    jz .nosnd
    mov ecx, eax
    mov eax, SND_LBA
    call copy_sectors
    test al, al
    jnz .fail
.nosnd:
    mov ecx, SFX_SECTORS             ; Music Maker's SFX bank -- same cp_src/cp_dst as the sound copy above
    mov eax, SFX_LBA
    call copy_sectors
    test al, al
    jnz .fail
    mov dword [cp_tick], 0
    ; stamp the new version on this disk's installed marker
    mov dl, [cp_src]
    mov eax, UPD_LBA
    mov ecx, 1
    mov edi, WSECT
    call disk_read_multi
    mov esi, inst_magic
    mov edi, WSECT
    mov ecx, 8
    rep movsb                    ; "NOVAINST" + the USB's version + build (same offsets)
    mov al, [cp_dst]
    mov [inst_drive], al
    mov eax, 200
    mov esi, WSECT
    call bios_write_lba
    test al, al
    jnz .fail
    mov dword [sd_pct], 100
    mov dword [sd_msg], sd_upd_ok
    call sd_draw
    mov bx, 1140
    call play_note
    mov ecx, 1500
    call tsc_wait_ms
    jmp sys_restart              ; restart into the new version automatically
.fail:
    mov dword [cp_tick], 0
    mov dword [sd_msg], sd_upd_bad
    call sd_draw
    call long_beep
    mov ecx, 2500
    call tsc_wait_ms
    mov dword [sd_busy], 0
    call sd_draw
    ret

upd_tick:                        ; progress bar while copying (every 10 sectors)
    inc dword [cp_done]
    mov eax, [cp_done]
    xor edx, edx
    mov ecx, 10
    div ecx
    test edx, edx
    jnz .r
    mov eax, [cp_done]
    imul eax, 95
    xor edx, edx
    mov ecx, CORE_SECT + 160
    div ecx
    cmp eax, 95
    jbe .p
    mov eax, 95
.p:
    mov [sd_pct], eax
    call sd_draw
.r:
    ret

draw_icon16:                     ; ESI = 16 words (bit 15 = left), EAX = x, EBX = y; white, 2x
    pushad
    mov [ic_x], eax
    mov [ic_y], ebx
    xor edx, edx
.r:
    cmp edx, 16
    jae .d
    movzx ebp, word [esi + edx*2]
    xor ecx, ecx
.c:
    cmp ecx, 16
    jae .nr
    test ebp, 0x8000
    jz .s
    mov eax, ecx
    shl eax, 1
    add eax, [ic_x]
    mov [rx], eax
    mov eax, edx
    shl eax, 1
    add eax, [ic_y]
    mov [ry], eax
    mov dword [rw], 2
    mov dword [rh], 2
    mov dword [rcolor], 0x00FFFFFF
    call fillrect
.s:
    shl ebp, 1
    inc ecx
    jmp .c
.nr:
    inc edx
    jmp .r
.d:
    popad
    ret
ic_x: dd 0
ic_y: dd 0

; ---------------- state + strings ----------------
modal_click:  dd wiz_click
snd_rate:     dd 16000
snd_len:      dd 0
snd_tmp:      dd 0
snd_left:     dd 0
pwm_max:      dd 0
pwm_tps:      dd 0
pwm_next:     dd 0
cp_src:       db 0
cp_dst:       db 0
upd_drive:    db 0
cp_lba:       dd 0
cp_left:      dd 0
cp_tick:      dd 0
cp_done:      dd 0
sd_upd:       dd 0
sd_busy:      dd 0
sd_pct:       dd 0
sd_msg:       dd 0
sd_bx:        dd 0
ac_fadt:      dd 0
ac_pm1a:      dd 0
ac_pm1b:      dd 0
ac_end:       dd 0
ac_slp:       dd 0
upd_ptab:     times 66 db 0
sd_usbver:    times 16 db 0
snd_magic:    db "NOVASND "
upd_magic:    db "NOVAUSB "
sd_col:       dd 0x00C0392B, 0x0027AE60, 0x002C6FB4
sd_icons:     dd sd_i0, sd_i1, sd_i2
sd_i0:        dw 0x0180, 0x0180, 0x1998, 0x318C, 0x6186, 0x6186, 0xC183, 0xC003, 0xC003, 0xC003, 0x6006, 0x6006, 0x300C, 0x1C38, 0x0FF0, 0x03C0
sd_i1:        dw 0x07C6, 0x1FF6, 0x383E, 0x701E, 0x603E, 0xC000, 0xC000, 0xC000, 0xC003, 0xC003, 0x6006, 0x6006, 0x381C, 0x1FF8, 0x07E0, 0x0000
sd_i2:        dw 0x03C0, 0x03C0, 0x03C0, 0x03C0, 0x03C0, 0x03C0, 0x3FFC, 0x1FF8, 0x0FF0, 0x07E0, 0x03C0, 0x0180, 0xC003, 0xC003, 0xFFFF, 0xFFFF
sd_lbl:       dd sd_l0, sd_l1, sd_l2
sd_l0:        db "Shut down", 0
sd_l1:        db "Restart", 0
sd_l2:        db "Update from USB", 0
sd_ustat:     dd sd_u0, sd_u1, sd_u2, sd_u3, sd_u4, sd_u5
sd_u0:        db "No update USB found", 0
sd_u1:        db "Version        ", 0
sd_u2:        db "Already up to date", 0
sd_u3:        db "Running from USB", 0
sd_u4:        db "Click to search", 0
sd_u5:        db "Searching...", 0
upd_own:      db 0
sd_title:     db "Turn off NovaOS", 0
sd_ask:       db "What do you want NovaOS to do?", 0
sd_cancel:    db "Cancel", 0
sd_keys:      db "S / R / U  or  Esc", 0
sd_shutting:  db "NovaOS is shutting down...", 0
sd_restarting: db "Restarting...", 0
sd_safe:      db "It's now safe to turn off your computer.", 0
sd_upd_go:    db "Updating NovaOS from the USB...", 0
sd_upd_ok:    db "Update complete! Restarting...", 0
sd_upd_bad:   db "Update failed - nothing was changed on", 0
sd_dont:      db "Your files are kept. Don't turn off the computer.", 0
