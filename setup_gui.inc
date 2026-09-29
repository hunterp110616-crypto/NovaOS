; ============================================================
;  NovaOS  --  XP-style boot screen + graphical Setup wizard
;  (included into kernel_vesa.asm)
;
;  Boot flow:  boot screen -> if this is the live USB (no "installed"
;  marker) -> Setup wizard first (like Windows). "Try NovaOS" leaves the
;  wizard and starts the live desktop. After installing -> Restart ->
;  the installed disk boots straight to the desktop.
; ============================================================

WIZ_W    equ 760
WIZ_H    equ 480
WZ_HEAD  equ 0x001F4E8C
WZ_SIDE  equ 0x00173B66
WZ_BODY  equ 0x00F4F6FA
WZ_TXT   equ 0x001C2430
WZ_MUTE  equ 0x005A6472
WZ_ACC   equ 0x002C6FB4
WZ_BTN2  equ 0x00DDE2EA
WZ_DIS   equ 0x00C9CED6
WZ_OK    equ 0x001E8E4E
WZ_BAD   equ 0x00C23B3B
WZ_BAR   equ 0x002FAE5B
WZ_BARBG equ 0x00D7DCE4
WB_Y     equ WIZ_H - 56          ; button row (card-relative)

%macro WTXT 4                    ; string, x, y, colour  (card-relative)
    mov esi, %1
    mov eax, %2
    mov ebx, %3
    mov edi, %4
    call wiz_text
%endmacro
%macro WTITLE 3                  ; string, x, y  (2x, dark)
    mov esi, %1
    mov eax, %2
    mov ebx, %3
    call wiz_title
%endmacro

; ---------------- precise millisecond wait (PIT channel 2, polled) ----------------
; Same speed on every computer (unlike a busy loop). ECX = milliseconds.
pit_wait_ms:
    pushad
.ms:
    test ecx, ecx
    jz .done
    in al, 0x61
    and al, 0xFC                 ; gate off, speaker off
    out 0x61, al
    mov al, 0xB0                 ; channel 2, lo/hi byte, mode 0 (one-shot)
    out 0x43, al
    mov al, 0xA9                 ; 1193 ticks = 1 ms
    out 0x42, al
    mov al, 0x04
    out 0x42, al
    in al, 0x61
    or al, 0x01                  ; gate on -> start counting (speaker stays off)
    and al, 0xFD
    out 0x61, al
    mov edx, 20000               ; safety timeout (never hang if the timer misbehaves)
.w:
    in al, 0x61
    test al, 0x20                ; OUT2 goes high when the count finishes
    jnz .next
    dec edx
    jnz .w
.next:
    dec ecx
    jmp .ms
.done:
    in al, 0x61
    and al, 0xFC
    out 0x61, al
    popad
    ret

; ================= XP-style boot screen =================
xp_boot_screen:
    pushad
    mov dword [rx], 0            ; black screen
    mov dword [ry], 0
    mov eax, [scrw]
    mov [rw], eax
    mov eax, [scrh]
    mov [rh], eax
    mov dword [rcolor], 0x00000000
    call fillrect
    mov eax, [scrw]
    shr eax, 1
    mov [xb_mx], eax
    mov eax, [scrh]
    shr eax, 1
    mov [xb_my], eax
    ; Nova diamond logo, left of the wordmark
    mov eax, [xb_mx]
    sub eax, 178
    mov [dcx], eax
    mov eax, [xb_my]
    sub eax, 66
    mov [dcy], eax
    mov dword [drad], 50
    mov dword [dcolor], 0x00186B3D
    call draw_diamond
    mov dword [drad], 36
    mov dword [dcolor], 0x0022AA55
    call draw_diamond
    mov dword [drad], 15
    mov dword [dcolor], 0x00E6FFF0
    call draw_diamond
    ; "Nova" big white + "OS" orange, XP style
    mov dword [tscale], 5
    mov eax, [xb_mx]
    sub eax, 108
    mov [tx], eax
    mov eax, [xb_my]
    sub eax, 112
    mov [ty], eax
    mov dword [tcolor], 0x00FFFFFF
    mov esi, xb_nova
    call draw_text_scaled
    mov dword [tscale], 3
    mov eax, [xb_mx]
    add eax, 60
    mov [tx], eax
    mov eax, [xb_my]
    sub eax, 110
    mov [ty], eax
    mov dword [tcolor], 0x00FF7A1A
    mov esi, xb_os
    call draw_text_scaled
    ; "version 1.0" under-right
    mov dword [tscale], 2
    mov eax, [xb_mx]
    sub eax, 4
    mov [tx], eax
    mov eax, [xb_my]
    sub eax, 24
    mov [ty], eax
    mov dword [tcolor], 0x00D8D8D8
    mov esi, xb_ver
    call draw_text_scaled
    ; copyright bottom-left, "Nova" bottom-right
    mov dword [tx], 28
    mov eax, [scrh]
    sub eax, 40
    mov [ty], eax
    mov dword [tcolor], 0x00808080
    mov esi, xb_copy
    call draw_text
    mov dword [tscale], 2
    mov eax, [scrw]
    sub eax, 100
    mov [tx], eax
    mov eax, [scrh]
    sub eax, 52
    mov [ty], eax
    mov dword [tcolor], 0x00C8C8C8
    mov esi, xb_nova
    call draw_text_scaled
    ; ---- progress box (rounded, grey rim) ----
    mov eax, [xb_mx]
    sub eax, 80
    mov [xb_bx], eax
    mov eax, [xb_my]
    add eax, 96
    mov [xb_by], eax
    mov eax, [xb_bx]             ; rim: three overlapping rects = rounded corners
    add eax, 2
    mov [rx], eax
    mov eax, [xb_by]
    mov [ry], eax
    mov dword [rw], 156
    mov dword [rh], 18
    mov dword [rcolor], 0x009A9A9A
    call fillrect
    mov eax, [xb_bx]
    mov [rx], eax
    mov eax, [xb_by]
    add eax, 2
    mov [ry], eax
    mov dword [rw], 160
    mov dword [rh], 14
    call fillrect
    mov eax, [xb_bx]
    inc eax
    mov [rx], eax
    mov eax, [xb_by]
    inc eax
    mov [ry], eax
    mov dword [rw], 158
    mov dword [rh], 16
    call fillrect
    ; ---- animate the three sliding blue blocks (~3.5 s) ----
    mov dword [xb_frame], 0
.frame:
    cmp dword [xb_frame], 112
    jae .anim_done
    mov eax, [xb_bx]             ; clear the inside
    add eax, 2
    mov [rx], eax
    mov eax, [xb_by]
    add eax, 2
    mov [ry], eax
    mov dword [rw], 156
    mov dword [rh], 14
    mov dword [rcolor], 0x00000000
    call fillrect
    mov eax, [xb_frame]          ; group position slides 4 px per frame, wraps
    shl eax, 2
    xor edx, edx
    mov ecx, 196                 ; 156 inside + 40 lead-in
    div ecx
    sub edx, 40
    mov [xb_pos], edx
    xor ecx, ecx
.blk:
    cmp ecx, 3
    jae .blk_done
    mov eax, ecx
    imul eax, 13
    add eax, [xb_pos]            ; block offset inside the box
    call xb_block
    inc ecx
    jmp .blk
.blk_done:
    push ecx
    mov ecx, 31
    call pit_wait_ms
    pop ecx
    inc dword [xb_frame]
    jmp .frame
.anim_done:
    popad
    ret

xb_block:                        ; EAX = block x offset inside the box (may be off the ends)
    pushad
    mov ebx, eax                 ; left edge
    mov edx, eax
    add edx, 10                  ; right edge (block is 10 px wide)
    cmp ebx, 0
    jge .l
    xor ebx, ebx
.l:
    cmp edx, 156
    jle .r
    mov edx, 156
.r:
    cmp edx, ebx
    jle .none
    mov eax, [xb_bx]
    add eax, 2
    add eax, ebx
    mov [rx], eax
    sub edx, ebx
    mov [rw], edx
    mov eax, [xb_by]
    add eax, 4
    mov [ry], eax
    mov dword [rh], 10
    mov dword [rcolor], 0x002155D6
    call fillrect
    mov dword [rh], 3            ; lighter top = the XP gloss
    mov dword [rcolor], 0x006C9BF5
    call fillrect
.none:
    popad
    ret

; ================= graphical Setup wizard =================
; pages: 0 welcome, 1 language, 2 disk, 3 ready, 4 installing,
;        5 done, 6 already installed, 7 failed
run_setup:
    pushad
    mov dword [wiz_exit], 0
    mov dword [wiz_agree], 0
    mov dword [wiz_err], 0
    mov dword [wiz_page], 0
    cmp dword [install_mode], 0
    je .pg
    mov dword [wiz_page], 6
.pg:
    mov eax, [scrw]
    sub eax, WIZ_W
    sar eax, 1
    jns .cx
    xor eax, eax                 ; tiny screen: pin to the corner, never draw off-screen left
.cx:
    mov [wcx], eax
    mov eax, [scrh]
    sub eax, WIZ_H
    sar eax, 1
    jns .cy
    xor eax, eax
.cy:
    mov [wcy], eax
    mov byte [prev_btn], 0
    mov byte [mouse_cycle], 0
    mov byte [wiz_ext], 0
    cmp dword [wiz_page], 0
    jne .np
    call wiz_probe               ; is NovaOS already on the disk? (offer Upgrade)
.np:
    call wiz_redraw
.loop:
    cmp dword [wiz_exit], 0
    jne .out
    call kbc_poll                ; PS/2 keyboard/mouse, or our USB ones
    jz .loop
    cmp ah, 2
    je .mouse
.key:
    call wiz_key
    jmp .loop
.mouse:
    call wiz_mouse_feed
    jmp .loop
.out:
    mov byte [prev_btn], 0
    popad
    ret

wiz_mouse_feed:                  ; AL = a mouse byte (own packet parser, own click handling)
    mov bl, [mouse_cycle]
    cmp bl, 1
    je .b1
    cmp bl, 2
    je .b2
    test al, 0x08
    jz .ret
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
    call wiz_mouse_update
.ret:
    ret

wiz_mouse_update:
    pushad
    movsx eax, byte [mouse_dx]
    add eax, [mouse_x]
    cmp eax, 0
    jge .x1
    xor eax, eax
.x1:
    mov ebx, [scrw]
    sub ebx, CUR_W
    cmp eax, ebx
    jle .x2
    mov eax, ebx
.x2:
    mov [mouse_x], eax
    movsx eax, byte [mouse_dy]
    mov ebx, [mouse_y]
    sub ebx, eax
    mov eax, ebx
    cmp eax, 0
    jge .y1
    xor eax, eax
.y1:
    mov ebx, [scrh]
    sub ebx, CUR_H
    cmp eax, ebx
    jle .y2
    mov eax, ebx
.y2:
    mov [mouse_y], eax
    call restore_cursor
    mov eax, [mouse_x]
    mov [cur_x], eax
    mov eax, [mouse_y]
    mov [cur_y], eax
    call save_cursor
    call draw_cursor
    mov al, [mouse_flags]        ; new left-click?
    and al, 1
    mov bl, [prev_btn]
    mov [prev_btn], al
    test al, al
    jz .done
    test bl, bl
    jnz .done
    call [modal_click]           ; Setup or the Shut Down dialog
.done:
    popad
    ret

wiz_hit:                         ; EAX x, EBX y, ECX w, EDX h (card-relative) -> EAX=1 if the mouse is inside
    push esi
    add eax, [wcx]
    add ebx, [wcy]
    mov esi, [mouse_x]
    cmp esi, eax
    jl .no
    add eax, ecx
    cmp esi, eax
    jge .no
    mov esi, [mouse_y]
    cmp esi, ebx
    jl .no
    add ebx, edx
    cmp esi, ebx
    jge .no
    mov eax, 1
    pop esi
    ret
.no:
    xor eax, eax
    pop esi
    ret

wiz_click:
    mov ecx, [wiz_page]
    cmp ecx, 4                   ; installing: ignore clicks
    je .r
    ; primary (right) button
    mov eax, WIZ_W - 146
    mov ebx, WB_Y
    mov ecx, 126
    mov edx, 36
    call wiz_hit
    test eax, eax
    jz .nprim
    call wiz_next
    ret
.nprim:
    ; Back button (pages 1-3)
    mov ecx, [wiz_page]
    cmp ecx, 1
    jb .nback
    cmp ecx, 3
    ja .nback
    mov eax, WIZ_W - 284
    mov ebx, WB_Y
    mov ecx, 126
    mov edx, 36
    call wiz_hit
    test eax, eax
    jz .nback
    call wiz_back
    ret
.nback:
    ; left button: Try NovaOS / Cancel (page 0)
    cmp dword [wiz_page], 0
    jne .nleft
    mov eax, 200
    mov ebx, WB_Y
    mov ecx, 160
    mov edx, 36
    call wiz_hit
    test eax, eax
    jz .nleft
    mov dword [wiz_exit], 1
    ret
.nleft:
    ; language rows (page 1)
    cmp dword [wiz_page], 1
    jne .nlang
    xor edi, edi
.lr:
    cmp edi, 3
    jae .r
    mov eax, 220
    mov ebx, edi
    imul ebx, 50
    add ebx, 176
    mov ecx, 320
    mov edx, 40
    call wiz_hit
    test eax, eax
    jz .lnext
    mov [wiz_lang], edi
    mov [inst_lang], edi
    call wiz_redraw
    ret
.lnext:
    inc edi
    jmp .lr
.nlang:
    ; "erase and install" checkbox (page 2)
    cmp dword [wiz_page], 2
    jne .r
    cmp dword [wiz_disk_ok], 0
    je .r
    cmp dword [wiz_found], 0
    je .fnf
    mov eax, 220
    mov ebx, 250
    mov ecx, 420
    mov edx, 30
    call wiz_hit
    test eax, eax
    jz .fc2
    mov dword [wiz_mode], 0
    call wiz_redraw
    ret
.fc2:
    mov eax, 220
    mov ebx, 284
    mov ecx, 420
    mov edx, 30
    call wiz_hit
    test eax, eax
    jz .fc3
    mov dword [wiz_mode], 1
    mov dword [wiz_agree], 0
    call wiz_redraw
    ret
.fc3:
    cmp dword [wiz_mode], 0
    je .r
    mov eax, 220
    mov ebx, 320
    mov ecx, 420
    mov edx, 30
    call wiz_hit
    test eax, eax
    jz .r
    xor dword [wiz_agree], 1
    call wiz_redraw
    ret
.fnf:
    mov eax, 220
    mov ebx, 252
    mov ecx, 400
    mov edx, 30
    call wiz_hit
    test eax, eax
    jz .r
    xor dword [wiz_agree], 1
    call wiz_redraw
.r:
    ret

wiz_key:                         ; AL = scancode
    cmp al, 0xE0
    jne .noe0
    mov byte [wiz_ext], 1
    ret
.noe0:
    test al, 0x80                ; key release
    jz .press
    mov byte [wiz_ext], 0
    ret
.press:
    cmp dword [wiz_page], 4
    je .r
    cmp byte [wiz_ext], 0
    je .plain
    mov byte [wiz_ext], 0
    cmp dword [wiz_page], 2      ; arrows pick Upgrade / Clean install
    jne .nk2
    cmp dword [wiz_found], 0
    je .r
    xor edx, edx
    cmp al, 0x48
    je .ms
    mov edx, 1
    cmp al, 0x50
    jne .r
.ms:
    mov [wiz_mode], edx
    mov dword [wiz_agree], 0
    call wiz_redraw
    ret
.nk2:
    cmp dword [wiz_page], 1      ; arrows move the language choice
    jne .r
    cmp al, 0x48
    je .up
    cmp al, 0x50
    je .down
    ret
.up:
    cmp dword [wiz_lang], 0
    je .r
    dec dword [wiz_lang]
    jmp .langset
.down:
    cmp dword [wiz_lang], 2
    jae .r
    inc dword [wiz_lang]
.langset:
    mov eax, [wiz_lang]
    mov [inst_lang], eax
    call wiz_redraw
    ret
.plain:
    cmp al, 0x1C                 ; Enter = the main button
    jne .n1
    call wiz_next
    ret
.n1:
    cmp al, 0x01                 ; Esc / Backspace = Back
    je .back
    cmp al, 0x0E
    jne .n2
.back:
    call wiz_back
    ret
.n2:
    cmp al, 0x39                 ; Space ticks the erase checkbox
    jne .n3
    cmp dword [wiz_page], 2
    jne .r
    cmp dword [wiz_disk_ok], 0
    je .r
    cmp dword [wiz_found], 0
    je .spok
    cmp dword [wiz_mode], 0
    je .r
.spok:
    xor dword [wiz_agree], 1
    call wiz_redraw
    ret
.n3:
    cmp dword [wiz_page], 1      ; 1 / 2 / 3 pick a language
    jne .r
    cmp al, 0x02
    jb .r
    cmp al, 0x04
    ja .r
    movzx eax, al
    sub eax, 2
    mov [wiz_lang], eax
    mov [inst_lang], eax
    call wiz_redraw
.r:
    ret

wiz_next:
    mov eax, [wiz_page]
    cmp eax, 0
    je .to1
    cmp eax, 1
    je .to2
    cmp eax, 2
    je .to3
    cmp eax, 3
    je .inst
    cmp eax, 5
    je .restart
    mov dword [wiz_exit], 1      ; pages 6/7: Close
    ret
.to1:
    mov dword [wiz_page], 1
    jmp .draw
.to2:
    call wiz_probe
    mov dword [wiz_agree], 0
    mov dword [wiz_page], 2
    jmp .draw
.to3:
    cmp dword [wiz_disk_ok], 0
    je .nope
    cmp dword [wiz_found], 0
    je .ag
    cmp dword [wiz_mode], 0
    je .go3
.ag:
    cmp dword [wiz_agree], 0
    je .nope
.go3:
    mov dword [wiz_page], 3
    jmp .draw
.nope:
    call err_beep
    ret
.inst:
    mov dword [wiz_page], 4
    call wiz_redraw
    call wiz_install
    mov dword [wiz_page], 5
    cmp dword [wiz_err], 0
    je .draw
    mov dword [wiz_page], 7
.draw:
    call wiz_redraw
    ret
.restart:
    mov al, 0xFE                 ; pulse the CPU reset line (keyboard controller)
    out 0x64, al
.hang:
    hlt
    jmp .hang

wiz_back:
    mov eax, [wiz_page]
    cmp eax, 1
    jb .r
    cmp eax, 3
    ja .r
    dec dword [wiz_page]
    call wiz_redraw
.r:
    ret

; read LBA EAX of [inst_drive] into DISKBUF.  AL = 0 ok
wiz_read_target:
    cmp byte [inst_drive], 0xFE      ; the USB stick through our own driver?
    jne .bios
    push edi
    mov edi, DISKBUF
    call usb_read_sector
    pop edi
    setc al
    ret
.bios:
    pushad
    mov [dap16_lba], eax
    mov dword [dap16_lba+4], 0
    mov word [dap_count], 1
    mov al, [inst_drive]
    mov [thunk_drive], al
    mov byte [thunk_cmd], 0x42
    call bios_xfer
    mov esi, BIOSBUF
    mov edi, DISKBUF
    mov ecx, 128
    rep movsd
    popad
    mov al, [thunk_res]
    ret

; Is there a safe install target?  wiz_disk_ok = 1 yes.  wiz_disk_why: 1 none, 2 it's the NovaOS USB
wiz_probe:
    pushad
    mov dword [wiz_disk_ok], 0
    mov dword [wiz_disk_why], 1
    mov dword [wiz_found], 0
    mov dword [wiz_mode], 1
    mov byte [inst_drive], 0x81
    mov al, [0x1014]             ; booted from the 2nd disk itself? never overwrite it
    cmp al, 0x81
    je .usb
    mov eax, 200                 ; 1) installed NovaOS?  (marker at LBA 200, any version)
    call wiz_read_target
    test al, al
    jnz .d                       ; can't read it -> "no disk"
    cld
    mov esi, DISKBUF
    mov edi, inst_magic
    mov ecx, 8
    repe cmpsb
    je .found
    mov eax, UPD_LBA             ; 2) a NovaOS USB?  (new ones carry "NOVAUSB " at LBA 202)
    call wiz_read_target
    test al, al
    jnz .d
    mov esi, DISKBUF
    mov edi, upd_magic
    mov ecx, 8
    repe cmpsb
    je .usb
    xor eax, eax                 ;    ...older ones: NovaOS's FAT32 partition (type 0x0C, LBA 2048, 66581 sectors)
    call wiz_read_target
    test al, al
    jnz .d
    cmp byte [DISKBUF + 446 + 4], 0x0C
    jne .ok
    cmp dword [DISKBUF + 446 + 8], 2048
    jne .ok
    cmp dword [DISKBUF + 446 + 12], 66581
    je .usb
    jmp .ok                      ; 3) some other disk -> fine to install
.found:
    mov eax, 200                 ; (re-read: DISKBUF holds the marker for the version copy below)
    call wiz_read_target
    mov dword [wiz_found], 1     ; an installed NovaOS -> Upgrade is possible (default)
    mov dword [wiz_mode], 0
    mov esi, DISKBUF + 8         ; its version (older builds didn't store one)
    mov edi, wiz_oldver
    mov ecx, 15
    rep movsb
    mov byte [wiz_oldver + 15], 0
    cmp byte [wiz_oldver], 0
    jne .ok
    mov dword [wiz_oldver], '1.0 '     ; no stamp = 1.0
    mov byte [wiz_oldver + 3], 0
.ok:
    mov dword [wiz_disk_ok], 1
    mov dword [wiz_disk_why], 0
    jmp .d
.usb:
    mov dword [wiz_disk_why], 2
.d:
    popad
    ret

; copy NovaOS to the target disk, updating the progress bar
wiz_install:
    pushad
    mov dword [wiz_err], 0
    mov byte [inst_drive], 0x81
    call probe_drive
    test al, al
    jnz .fail
    mov eax, 2
    mov esi, wz_st_copy
    call wiz_progress
    mov esi, 0x7C00              ; new boot code...
    mov edi, WSECT
    mov ecx, 128
    rep movsd
    cmp dword [wiz_mode], 0
    jne .bs
    xor eax, eax                 ; ...upgrade: keep the disk's own partition table
    call wiz_read_target
    test al, al
    jnz .fail
    mov esi, DISKBUF + 446
    mov edi, WSECT + 446
    mov ecx, 66
    rep movsb
.bs:
    xor eax, eax                 ; boot sector -> LBA 0
    mov esi, WSECT
    call bios_write_lba
    test al, al
    jnz .fail
    mov dword [inst_i], 0
.wk:
    mov eax, [inst_i]
    cmp eax, 199                 ; KERNEL_SECTORS (LBA 1-199; 200 = marker)
    jae .fmt
    mov esi, 0x8000
    mov ebx, [inst_i]
    shl ebx, 9
    add esi, ebx
    inc eax
    call bios_write_lba
    test al, al
    jnz .fail
    mov eax, [inst_i]
    and eax, 7
    jnz .noprog
    mov eax, [inst_i]            ; 5% .. 65%
    imul eax, 60
    xor edx, edx
    mov ecx, 199
    div ecx
    add eax, 5
    xor esi, esi
    call wiz_progress
.noprog:
    inc dword [inst_i]
    jmp .wk
.fmt:
    mov dl, [0x1014]             ; copy the startup sound (raw sectors 256+) to the disk
    call snd_sectors_on
    test eax, eax
    jz .nosnd
    mov ecx, eax
    mov al, [0x1014]
    mov [cp_src], al
    mov byte [cp_dst], 0x81
    mov dword [cp_tick], 0
    mov eax, SND_LBA
    call copy_sectors
    mov byte [inst_drive], 0x81
.nosnd:
    mov al, [0x1014]                 ; Music Maker's SFX bank -- fixed size, independent of the sound copy above
    mov [cp_src], al
    mov byte [cp_dst], 0x81
    mov dword [cp_tick], 0
    mov ecx, SFX_SECTORS
    mov eax, SFX_LBA
    call copy_sectors
    mov byte [inst_drive], 0x81
    cmp dword [wiz_mode], 0
    jne .clean
    mov eax, 80                  ; upgrade: the data partition (your files) is left alone
    mov esi, wz_st_keep
    call wiz_progress
    jmp .mk
.clean:
    mov eax, 68
    mov esi, wz_st_fmt
    call wiz_progress
    call fmt_fat
.mk:
    mov eax, 92
    mov esi, wz_st_fin
    call wiz_progress
    mov edi, WSECT               ; the "installed" marker -> LBA 200
    xor eax, eax
    mov ecx, 128
    rep stosd
    mov esi, inst_magic
    mov edi, WSECT
    mov ecx, 8
    rep movsb
    mov esi, nova_ver            ; stamp the version so a later Setup can say what's installed
    mov edi, WSECT + 8
    mov ecx, nova_ver_len
    rep movsb
    mov eax, 200
    mov esi, WSECT
    call bios_write_lba
    test al, al
    jnz .fail
    mov eax, 100
    mov esi, wz_st_done
    call wiz_progress
    mov ecx, 700
    call pit_wait_ms
    mov bx, 1140                 ; happy "ding"
    call play_note
    mov bx, 760
    call play_note
    popad
    ret
.fail:
    mov dword [wiz_err], 1
    call long_beep
    popad
    ret

; EAX = percent, ESI = new status line (0 = keep)
wiz_progress:
    pushad
    mov [wiz_pct], eax
    test esi, esi
    jz .keep
    mov [wiz_status], esi
.keep:
    call wiz_draw_progress
    popad
    ret

wiz_draw_progress:
    pushad
    mov eax, 220
    mov ebx, 214
    mov ecx, 480
    mov edx, 24
    mov edi, WZ_BARBG
    call wiz_rect
    mov eax, [wiz_pct]
    imul eax, 480
    xor edx, edx
    mov ecx, 100
    div ecx
    test eax, eax
    jz .nofill
    mov ecx, eax
    mov eax, 220
    mov ebx, 214
    mov edx, 24
    mov edi, WZ_BAR
    call wiz_rect
.nofill:
    mov eax, 220                 ; status line
    mov ebx, 250
    mov ecx, 480
    mov edx, 20
    mov edi, WZ_BODY
    call wiz_rect
    mov esi, [wiz_status]
    test esi, esi
    jz .nost
    mov eax, 220
    mov ebx, 252
    mov edi, WZ_MUTE
    call wiz_text
.nost:
    mov eax, [wiz_pct]           ; "NN%"
    mov edi, wiz_pctbuf
    xor ecx, ecx
    cmp eax, 100
    jb .two
    mov byte [edi], '1'
    mov byte [edi+1], '0'
    mov byte [edi+2], '0'
    mov ecx, 3
    jmp .pct
.two:
    mov ebx, 10
    xor edx, edx
    div ebx
    test eax, eax
    jz .one
    add al, '0'
    mov [edi], al
    inc ecx
.one:
    add dl, '0'
    mov [edi+ecx], dl
    inc ecx
.pct:
    mov byte [edi+ecx], '%'
    mov byte [edi+ecx+1], 0
    mov esi, wiz_pctbuf
    mov eax, 668
    mov ebx, 252
    mov edi, WZ_TXT
    call wiz_text
    popad
    ret

; ---------------- drawing helpers (card-relative) ----------------
wiz_rect:                        ; EAX x, EBX y, ECX w, EDX h, EDI colour
    pushad
    add eax, [wcx]
    mov [rx], eax
    add ebx, [wcy]
    mov [ry], ebx
    mov [rw], ecx
    mov [rh], edx
    mov [rcolor], edi
    call fillrect
    popad
    ret

wiz_text:                        ; ESI string, EAX x, EBX y, EDI colour
    pushad
    add eax, [wcx]
    mov [tx], eax
    add ebx, [wcy]
    mov [ty], ebx
    mov [tcolor], edi
    call draw_text
    popad
    ret

wiz_title:                       ; ESI string, EAX x, EBX y  (2x, dark)
    pushad
    add eax, [wcx]
    mov [tx], eax
    add ebx, [wcy]
    mov [ty], ebx
    mov dword [tcolor], WZ_TXT
    mov dword [tscale], 2
    call draw_text_scaled
    popad
    ret

wiz_strlen:                      ; ESI -> ECX
    push esi
    xor ecx, ecx
.l:
    cmp byte [esi], 0
    je .d
    inc esi
    inc ecx
    jmp .l
.d:
    pop esi
    ret

wiz_btn:                         ; EAX x, ECX width, ESI label, EDX style 0=main 1=plain 2=disabled
    pushad
    mov [wb_x], eax
    mov [wb_w], ecx
    mov [wb_lbl], esi
    mov edi, WZ_ACC
    mov dword [wb_tc], 0x00FFFFFF
    cmp edx, 1
    jne .s2
    mov edi, WZ_BTN2
    mov dword [wb_tc], WZ_TXT
.s2:
    cmp edx, 2
    jne .s3
    mov edi, WZ_DIS
    mov dword [wb_tc], 0x008A919C
.s3:
    mov eax, [wb_x]
    mov ebx, WB_Y
    mov ecx, [wb_w]
    mov edx, 36
    call wiz_rect
    mov esi, [wb_lbl]
    call wiz_strlen
    shl ecx, 3
    mov eax, [wb_w]
    sub eax, ecx
    sar eax, 1
    add eax, [wb_x]
    mov ebx, WB_Y + 10
    mov edi, [wb_tc]
    call wiz_text
    popad
    ret

; ---------------- full page redraw ----------------
wiz_redraw:
    pushad
    call draw_gradient
    mov eax, 8                   ; card shadow
    mov ebx, 8
    mov ecx, WIZ_W
    mov edx, WIZ_H
    mov edi, 0x00060A12
    call wiz_rect
    xor eax, eax                 ; header band
    xor ebx, ebx
    mov ecx, WIZ_W
    mov edx, 64
    mov edi, WZ_HEAD
    call wiz_rect
    mov eax, [wcx]               ; header logo
    add eax, 38
    mov [dcx], eax
    mov eax, [wcy]
    add eax, 32
    mov [dcy], eax
    mov dword [drad], 20
    mov dword [dcolor], 0x0022AA55
    call draw_diamond
    mov dword [drad], 8
    mov dword [dcolor], 0x00E6FFF0
    call draw_diamond
    mov eax, [wcx]
    add eax, 72
    mov [tx], eax
    mov eax, [wcy]
    add eax, 16
    mov [ty], eax
    mov dword [tcolor], 0x00FFFFFF
    mov dword [tscale], 2
    mov esi, wz_head
    call draw_text_scaled
    xor eax, eax                 ; sidebar + body
    mov ebx, 64
    mov ecx, 180
    mov edx, WIZ_H - 64
    mov edi, WZ_SIDE
    call wiz_rect
    mov eax, 180
    mov ebx, 64
    mov ecx, WIZ_W - 180
    mov edx, WIZ_H - 64
    mov edi, WZ_BODY
    call wiz_rect
    ; sidebar steps: done = light, current = white + marker, next = dim
    mov eax, [wiz_page]
    movzx eax, byte [wz_stepmap + eax]
    mov [wz_cur], eax
    xor ecx, ecx
.st:
    cmp ecx, 5
    jae .stdone
    mov ebx, ecx
    imul ebx, 40
    add ebx, 96
    mov edi, 0x006F86A6
    cmp ecx, [wz_cur]
    ja .stc
    mov edi, 0x009FC0E6
    jb .stc
    mov edi, 0x00FFFFFF
    push ecx
    mov eax, 14
    mov ecx, 4
    mov edx, 16
    push edi
    mov edi, 0x006FB2FF
    call wiz_rect
    pop edi
    pop ecx
.stc:
    mov esi, [wz_steps + ecx*4]
    mov eax, 30
    call wiz_text
    inc ecx
    jmp .st
.stdone:
    mov eax, [wiz_page]
    cmp eax, 0
    je .p0
    cmp eax, 1
    je .p1
    cmp eax, 2
    je .p2
    cmp eax, 3
    je .p3
    cmp eax, 4
    je .p4
    cmp eax, 5
    je .p5
    cmp eax, 6
    je .p6
    jmp .p7

.p0:
    WTITLE wz_t0, 200, 90
    WTXT wz_0a, 200, 150, WZ_TXT
    WTXT wz_0b, 200, 174, WZ_TXT
    cmp dword [wiz_from_desk], 0
    jne .p0x                     ; opened from the desktop: no "Try NovaOS" hint
    WTXT wz_0c, 200, 222, WZ_MUTE
    WTXT wz_0d, 200, 246, WZ_MUTE
.p0x:
    cmp dword [wiz_found], 0
    je .p0nf
    WTXT wz_0f1, 200, 294, WZ_OK
    mov esi, wiz_oldver
    mov eax, 200 + 8*21
    mov ebx, 294
    mov edi, WZ_OK
    call wiz_text
    WTXT wz_0f2, 200, 318, WZ_OK
.p0nf:
    mov esi, wz_try
    cmp dword [wiz_from_desk], 0
    je .p0b
    mov esi, wz_cancel
.p0b:
    mov eax, 200
    mov ecx, 160
    mov edx, 1
    call wiz_btn
    mov esi, wz_next
    jmp .prim0

.p1:
    WTITLE wz_t1, 200, 90
    WTXT wz_1a, 200, 140, WZ_MUTE
    xor ecx, ecx
.opt:
    cmp ecx, 3
    jae .optd
    mov ebx, ecx
    imul ebx, 50
    add ebx, 176
    mov edi, 0x00FFFFFF
    cmp ecx, [wiz_lang]
    jne .ob
    mov edi, 0x00DCE8F8
.ob:
    push ecx
    mov eax, 220
    mov ecx, 320
    mov edx, 40
    call wiz_rect
    mov eax, 236                 ; radio box
    add ebx, 12
    mov ecx, 16
    mov edx, 16
    mov edi, 0x008A94A6
    call wiz_rect
    mov eax, 238
    add ebx, 2
    mov ecx, 12
    mov edx, 12
    mov edi, 0x00FFFFFF
    call wiz_rect
    pop ecx
    cmp ecx, [wiz_lang]
    jne .onot
    push ecx
    mov eax, 240
    add ebx, 2
    mov ecx, 8
    mov edx, 8
    mov edi, WZ_ACC
    call wiz_rect
    sub ebx, 2
    pop ecx
.onot:
    sub ebx, 2
    mov esi, [lang_names + ecx*4]
    mov eax, 264
    mov edi, WZ_TXT
    call wiz_text
    inc ecx
    jmp .opt
.optd:
    WTXT wz_1b, 220, 340, WZ_MUTE
    call .backbtn
    mov esi, wz_next
    jmp .prim0

.p2:
    WTITLE wz_t2, 200, 90
    WTXT wz_2a, 200, 140, WZ_MUTE
    mov eax, 220                 ; disk card
    mov ebx, 170
    mov ecx, 500
    mov edx, 64
    mov edi, 0x00FFFFFF
    call wiz_rect
    mov eax, 236                 ; disk icon
    mov ebx, 180
    mov ecx, 36
    mov edx, 44
    mov edi, 0x007A8494
    call wiz_rect
    mov eax, 240
    mov ebx, 206
    mov ecx, 28
    mov edx, 4
    mov edi, 0x00B9C2CF
    call wiz_rect
    WTXT wz_2disk, 288, 182, WZ_TXT
    cmp dword [wiz_disk_ok], 0
    je .p2bad
    cmp dword [wiz_found], 0
    jne .p2up
    WTXT wz_2ok, 288, 204, WZ_OK
    ; checkbox
    mov eax, 222
    mov ebx, 258
    mov ecx, 18
    mov edx, 18
    mov edi, 0x008A94A6
    call wiz_rect
    mov eax, 224
    mov ebx, 260
    mov ecx, 14
    mov edx, 14
    mov edi, 0x00FFFFFF
    cmp dword [wiz_agree], 0
    je .cb
    mov edi, WZ_ACC
.cb:
    call wiz_rect
    cmp dword [wiz_agree], 0
    je .cbn
    mov eax, 228
    mov ebx, 264
    mov ecx, 6
    mov edx, 6
    mov edi, 0x00FFFFFF
    call wiz_rect
.cbn:
    WTXT wz_2chk, 250, 259, WZ_TXT
    WTXT wz_2w1, 220, 300, WZ_BAD
    WTXT wz_2w2, 220, 324, WZ_MUTE
    jmp .p2btn
.p2up:
    WTXT wz_2fnd, 288, 204, WZ_OK
    mov esi, wiz_oldver
    mov eax, 288 + 8*15
    mov ebx, 204
    mov edi, WZ_OK
    call wiz_text
    xor ecx, ecx                 ; two choices
.m:
    cmp ecx, 2
    jae .md
    mov ebx, ecx
    imul ebx, 34
    add ebx, 250
    mov edi, 0x00FFFFFF
    cmp ecx, [wiz_mode]
    jne .mb
    mov edi, 0x00DCE8F8
.mb:
    push ecx
    mov eax, 220
    mov ecx, 420
    mov edx, 30
    call wiz_rect
    mov eax, 232
    add ebx, 8
    mov ecx, 14
    mov edx, 14
    mov edi, 0x008A94A6
    call wiz_rect
    mov eax, 234
    add ebx, 2
    mov ecx, 10
    mov edx, 10
    mov edi, 0x00FFFFFF
    call wiz_rect
    pop ecx
    cmp ecx, [wiz_mode]
    jne .mn
    push ecx
    mov eax, 236
    add ebx, 2
    mov ecx, 6
    mov edx, 6
    mov edi, WZ_ACC
    call wiz_rect
    sub ebx, 2
    pop ecx
.mn:
    sub ebx, 3
    mov esi, [wz_modes + ecx*4]
    mov eax, 256
    mov edi, WZ_TXT
    call wiz_text
    inc ecx
    jmp .m
.md:
    cmp dword [wiz_mode], 0
    jne .mclean
    WTXT wz_2k1, 220, 334, WZ_OK
    WTXT wz_2k2, 220, 358, WZ_MUTE
    jmp .p2btn
.mclean:
    mov ebx, 326
    call wiz_checkbox
    WTXT wz_2w1, 220, 364, WZ_BAD
    jmp .p2btn
.p2bad:
    cmp dword [wiz_disk_why], 2
    je .p2usb
    WTXT wz_2nf, 288, 204, WZ_BAD
    WTXT wz_2nf1, 220, 262, WZ_MUTE
    WTXT wz_2nf2, 220, 286, WZ_MUTE
    jmp .p2btn
.p2usb:
    WTXT wz_2us, 288, 204, WZ_BAD
    WTXT wz_2us1, 220, 262, WZ_MUTE
    WTXT wz_2us2, 220, 286, WZ_MUTE
.p2btn:
    call .backbtn
    mov edx, 2                   ; Next is greyed out until it's safe + ticked
    cmp dword [wiz_disk_ok], 0
    je .p2n
    cmp dword [wiz_found], 0
    je .p2ag
    cmp dword [wiz_mode], 0
    je .p2en
.p2ag:
    cmp dword [wiz_agree], 0
    je .p2n
.p2en:
    xor edx, edx
.p2n:
    mov eax, WIZ_W - 146
    mov ecx, 126
    mov esi, wz_next
    call wiz_btn
    jmp .fin

.p3:
    mov esi, wz_t3
    cmp dword [wiz_mode], 0
    jne .p3tt
    mov esi, wz_t3u
.p3tt:
    mov eax, 200
    mov ebx, 90
    call wiz_title
    WTXT wz_3l1, 200, 150, WZ_MUTE
    mov eax, [wiz_lang]
    mov esi, [lang_names + eax*4]
    mov eax, 340
    mov ebx, 150
    mov edi, WZ_TXT
    call wiz_text
    WTXT wz_3l2, 200, 178, WZ_MUTE
    WTXT wz_3v2, 340, 178, WZ_TXT
    WTXT wz_3l3, 200, 206, WZ_MUTE
    mov esi, wz_3v3
    cmp dword [wiz_mode], 0
    jne .p3v
    mov esi, wz_3v3u
.p3v:
    mov eax, 340
    mov ebx, 206
    mov edi, WZ_TXT
    call wiz_text
    WTXT wz_3l4, 200, 234, WZ_MUTE
    mov esi, wz_mode_c
    cmp dword [wiz_mode], 0
    jne .p3m
    mov esi, wz_mode_u
.p3m:
    mov eax, 340
    mov ebx, 234
    mov edi, WZ_TXT
    call wiz_text
    mov esi, wz_3a
    cmp dword [wiz_mode], 0
    jne .p3a
    mov esi, wz_3au
.p3a:
    mov eax, 200
    mov ebx, 274
    mov edi, WZ_TXT
    call wiz_text
    WTXT wz_3b, 200, 298, WZ_TXT
    call .backbtn
    mov esi, wz_install
    cmp dword [wiz_mode], 0
    jne .prim0
    mov esi, wz_upgrade
    jmp .prim0

.p4:
    mov esi, wz_t4
    cmp dword [wiz_mode], 0
    jne .p4t
    mov esi, wz_t4u
.p4t:
    mov eax, 200
    mov ebx, 90
    call wiz_title
    WTXT wz_4a, 200, 150, WZ_MUTE
    WTXT wz_4b, 200, 174, WZ_MUTE
    mov dword [wiz_pct], 0
    mov dword [wiz_status], wz_st_prep
    call wiz_draw_progress
    jmp .fin

.p5:
    cmp dword [wiz_mode], 0
    jne .p5c
    WTITLE wz_t5u, 200, 90
    WTXT wz_5au, 200, 150, WZ_OK
    jmp .p5r
.p5c:
    WTITLE wz_t5, 200, 90
    WTXT wz_5a, 200, 150, WZ_OK
.p5r:
    WTXT wz_5b, 200, 198, WZ_TXT
    WTXT wz_5c, 200, 222, WZ_TXT
    WTXT wz_5d, 200, 270, WZ_MUTE
    mov esi, wz_restart
    jmp .prim0

.p6:
    WTITLE wz_t6, 200, 90
    WTXT wz_6a, 200, 150, WZ_TXT
    WTXT wz_6b, 200, 174, WZ_TXT
    mov esi, wz_close
    jmp .prim0

.p7:
    WTITLE wz_t7, 200, 90
    WTXT wz_7a, 200, 150, WZ_BAD
    WTXT wz_7b, 200, 174, WZ_TXT
    WTXT wz_7c, 200, 198, WZ_TXT
    mov esi, wz_close

.prim0:                          ; ESI = main-button label (enabled)
    mov eax, WIZ_W - 146
    mov ecx, 126
    xor edx, edx
    call wiz_btn
.fin:
    cmp byte [mouse_present], 0
    je .nc
    call save_cursor
    call draw_cursor
.nc:
    popad
    ret
.backbtn:
    mov eax, WIZ_W - 284
    mov ecx, 126
    mov esi, wz_back
    mov edx, 1
    call wiz_btn
    ret

wiz_checkbox:                    ; EBX = y: 'Erase this disk and install NovaOS'
    pushad
    mov [wcb_y], ebx
    mov eax, 222
    add ebx, 4
    mov ecx, 18
    mov edx, 18
    mov edi, 0x008A94A6
    call wiz_rect
    mov eax, 224
    mov ebx, [wcb_y]
    add ebx, 6
    mov ecx, 14
    mov edx, 14
    mov edi, 0x00FFFFFF
    cmp dword [wiz_agree], 0
    je .b
    mov edi, WZ_ACC
.b:
    call wiz_rect
    cmp dword [wiz_agree], 0
    je .t
    mov eax, 228
    mov ebx, [wcb_y]
    add ebx, 10
    mov ecx, 6
    mov edx, 6
    mov edi, 0x00FFFFFF
    call wiz_rect
.t:
    mov esi, wz_2chk
    mov eax, 250
    mov ebx, [wcb_y]
    add ebx, 5
    mov edi, WZ_TXT
    call wiz_text
    popad
    ret

; ---------------- state + strings ----------------
wiz_found:    dd 0
wiz_mode:     dd 1               ; 0 = upgrade (keep files), 1 = clean install
wcb_y:        dd 0
wiz_oldver:   times 16 db 0
nova_ver:     db "1.27", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, "2026-09-28", 0
nova_ver_len equ $ - nova_ver
wz_modes:     dd wz_mu, wz_mc
wz_mu:        db "Upgrade NovaOS  (keeps your files)", 0
wz_mc:        db "Clean install  (erases this disk)", 0
wz_0f1:       db "Found NovaOS version ", 0
wz_0f2:       db "on this computer - you can upgrade it.", 0
wz_2fnd:      db "NovaOS version ", 0
wz_2k1:       db "Your documents, folders and Trash are kept.", 0
wz_2k2:       db "Only the NovaOS system is replaced.", 0
wz_3l4:       db "Type:", 0
wz_mode_u:    db "Upgrade (keep my files)", 0
wz_mode_c:    db "Clean install", 0
wz_3v3u:      db "kept (nothing is erased)", 0
wz_upgrade:   db "Upgrade", 0
wz_t3u:       db "Ready to upgrade", 0
wz_3au:       db "Click Upgrade to begin. Don't turn off the", 0
wz_t4u:       db "Upgrading NovaOS", 0
wz_st_keep:   db "Keeping your files...", 0
wz_t5u:       db "NovaOS is upgraded!", 0
wz_5au:       db "Upgrade finished - your files were kept.", 0
wcx:          dd 0
wcy:          dd 0
wiz_page:     dd 0
wiz_lang:     dd 0
wiz_agree:    dd 0
wiz_disk_ok:  dd 0
wiz_disk_why: dd 0
wiz_exit:     dd 0
wiz_err:      dd 0
wiz_from_desk: dd 0
wiz_pct:      dd 0
wiz_status:   dd 0
wiz_ext:      db 0
wiz_pctbuf:   times 6 db 0
wb_x:         dd 0
wb_w:         dd 0
wb_lbl:       dd 0
wb_tc:        dd 0
wz_cur:       dd 0
xb_mx:        dd 0
xb_my:        dd 0
xb_bx:        dd 0
xb_by:        dd 0
xb_pos:       dd 0
xb_frame:     dd 0
xb_nova:      db "Nova", 0
xb_os:        db "OS", 0
xb_ver:       db "version 1.27", 0
xb_copy:      db "Copyright (C) 2026 NovaOS", 0
wz_stepmap:   db 0, 1, 2, 3, 3, 4, 0, 3
wz_steps:     dd wz_s0, wz_s1, wz_s2, wz_s3, wz_s4
wz_s0:        db "Welcome", 0
wz_s1:        db "Language", 0
wz_s2:        db "Choose disk", 0
wz_s3:        db "Install", 0
wz_s4:        db "Finish", 0
wz_head:      db "NovaOS Setup", 0
wz_next:      db "Next >", 0
wz_back:      db "< Back", 0
wz_try:       db "Try NovaOS", 0
wz_cancel:    db "Cancel", 0
wz_install:   db "Install", 0
wz_restart:   db "Restart", 0
wz_close:     db "Close", 0
wz_t0:        db "Welcome to NovaOS", 0
wz_0a:        db "Setup will install NovaOS on this computer's disk.", 0
wz_0b:        db "It only takes a minute.", 0
wz_0c:        db "Want to look around first? Click Try NovaOS to use", 0
wz_0d:        db "it straight from the USB without installing.", 0
wz_t1:        db "Choose your language", 0
wz_1a:        db "Pick one, then click Next.", 0
wz_1b:        db "(Menus are English-only for now.)", 0
wz_t2:        db "Choose a disk", 0
wz_2a:        db "Where do you want to install NovaOS?", 0
wz_2disk:     db "Disk 1 - internal hard drive", 0
wz_2ok:       db "Ready to install", 0
wz_2chk:      db "Erase this disk and install NovaOS", 0
wz_2w1:       db "Everything on this disk will be deleted.", 0
wz_2w2:       db "The NovaOS USB you started from is not touched.", 0
wz_2nf:       db "No disk found", 0
wz_2nf1:      db "Setup can't find a second disk. Check that the", 0
wz_2nf2:      db "internal drive is plugged in and on in the BIOS.", 0
wz_2us:       db "That's the NovaOS USB - can't install on it", 0
wz_2us1:      db "Start the computer from the NovaOS USB so the", 0
wz_2us2:      db "internal drive is the second disk, then try again.", 0
wz_t3:        db "Ready to install", 0
wz_3l1:       db "Language:", 0
wz_3l2:       db "Install to:", 0
wz_3v2:       db "Disk 1 (internal hard drive)", 0
wz_3l3:       db "Your files:", 0
wz_3v3:       db "a new, empty data partition", 0
wz_3a:        db "Click Install to begin. Don't turn off the", 0
wz_3b:        db "computer while NovaOS is installing.", 0
wz_t4:        db "Installing NovaOS", 0
wz_4a:        db "Please wait. This only takes a moment.", 0
wz_4b:        db "Don't turn off your computer.", 0
wz_st_prep:   db "Getting ready...", 0
wz_st_copy:   db "Copying NovaOS system files...", 0
wz_st_fmt:    db "Creating the data partition for your files...", 0
wz_st_fin:    db "Finishing installation...", 0
wz_st_done:   db "Done!", 0
wz_t5:        db "NovaOS is installed!", 0
wz_5a:        db "Setup finished successfully.", 0
wz_5b:        db "1. Remove the NovaOS USB drive.", 0
wz_5c:        db "2. Click Restart. NovaOS will start from the disk.", 0
wz_5d:        db "Welcome to NovaOS.", 0
wz_t6:        db "Already installed", 0
wz_6a:        db "NovaOS is already installed on this disk.", 0
wz_6b:        db "To reinstall, start the computer from the NovaOS USB.", 0
wz_t7:        db "Setup couldn't finish", 0
wz_7a:        db "A disk error stopped the installation.", 0
wz_7b:        db "Click Close to use NovaOS from the USB, then", 0
wz_7c:        db "restart and try Setup again.", 0
