; ============================================================
;  NOVA OS  --  VESA hi-res kernel  kernel_vesa.asm  v0.8
; ============================================================
;  32-bit protected mode, drawing 32bpp true-colour to a LINEAR
;  framebuffer set up by boot_vesa. Reads framebuffer address /
;  pitch / width / height from low memory (0x1004..0x1010).
;  A graphical terminal with a keyboard shell, at real resolution.
;
;  Build:  nasm -f bin kernel_vesa.asm -o kernel_vesa.bin
; ============================================================
BITS 32
ORG 0x8000

; Which build this is. 0 = the free download anyone can flash from GitHub.
; 1 = the store-bought edition (unlocks bonus apps, no product key -- just
; a different build from the same source). Flip this one line and rebuild.
EDITION_STORE equ 0

; 0x00RRGGBB colours  (sleek dark theme)
C_DESK   equ 0x000A101C   ; desktop fallback (gradient overrides)
C_GREEN  equ 0x00268F5E   ; accent (Start button)
C_BLACK  equ 0x00000000
C_DGRAY  equ 0x00161C26   ; bars / frames
C_LBLUE  equ 0x002C6FB4   ; focused title bar (accent blue)
C_WHITE  equ 0x00E6ECF2   ; soft white text
C_CONBG  equ 0x00121821   ; window body
C_TEXT   equ 0x008FE9B6   ; terminal text (mint)

; desktop gradient (top -> bottom), per-channel base + delta
GT_R equ 42
GT_G equ 62
GT_B equ 102
GD_R equ -32
GD_G equ -46
GD_B equ -74

CUR_W    equ 16           ; cursor is an 8x12 arrow drawn at 2x -> 16x24
CUR_H    equ 24
CURSAVE  equ 0x00200000   ; scratch RAM to save pixels under the cursor
MENUSAVE equ 0x00400000   ; scratch RAM to save pixels under the Start menu
PAINTBUF equ 0x00500000   ; paint canvas backing store
DISKBUF  equ 0x00700000   ; scratch RAM for one disk sector (512 bytes)
FSDIR    equ 0x00700000   ; FAT: directory / file-data sector buffer
FSFAT    equ 0x00710000   ; FAT: FAT-table sector buffer
BIOSBUF  equ 0x00070000   ; low-mem (<1MB) landing zone for BIOS int13h transfers (above the 200-sector core)
SAVEBUF  equ 0x00720000   ; editor text assembled for saving
WSECT    equ 0x00721000   ; one sector staged for a disk write
STORBUF  equ 0x00730000   ; FAT block buffer for the storage scan (32 KB)
PAINT_STRIDE equ 800
PAINT_H  equ 560
FILEBASE equ 0x00600000   ; RAM filesystem: NFILES buffers of MAXCOLS*MAXROWS
NFILES   equ 6
SGW      equ 28           ; snake grid width
SGH      equ 16           ; snake grid height
SCELL    equ 12           ; snake cell pixels
TITLE_H  equ 22           ; window title-bar height
MAXCOLS  equ 100          ; text grid stride (max console columns)
MAXROWS  equ 34           ; max console rows

kentry:
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov esp, 0x90000

    ; ---- load video parameters from the boot loader ----
    mov eax, [0x1004]
    mov [lfb], eax
    mov eax, [0x1008]
    mov [pitch], eax
    mov eax, [0x100C]
    mov [scrw], eax
    mov eax, [0x1010]
    mov [scrh], eax

    ; ---- verify the boot disk is readable; sad screen if not ----
    xor eax, eax
    call bios_read_lba
    test al, al
    jz .disk_ok
    mov esi, sad_disk
    call sad_mac                 ; shows the error screen + chime, never returns
.disk_ok:

    ; ---- XP-style boot screen ----
    call xp_boot_screen
    call tsc_calibrate           ; time sounds by the CPU clock (same speed everywhere)
    call snd_load                ; the recorded startup sound (raw sectors 256+)
    call sfx_load                ; Music Maker's one-shot SFX bank (raw sectors 600+)
    call hda_init                ; real sound chip, if this board has one (falls back to the beeper if not)
    call devmgr_scan             ; every PCI device on the board, for the Device Manager app

    ; ---- like Windows: the live USB boots into Setup first ----
    call detect_media            ; install_mode = 1 only on an installed disk (marker at LBA 200)
    cmp dword [install_mode], 0
    jne .installed
    call kbd_flush
    call mouse_init
    call kbd_flush
    mov eax, [scrw]
    shr eax, 1
    mov [mouse_x], eax
    mov [cur_x], eax
    mov eax, [scrh]
    shr eax, 1
    mov [mouse_y], eax
    mov [cur_y], eax
    mov dword [wiz_from_desk], 0
    call run_setup               ; returns only if the user picks "Try NovaOS"
.installed:

    ; ---- window manager init ----
    call gclear_grid
    call paint_init
    call fs_init
    call detect_media            ; sets install_mode by checking for a FAT data partition
    mov eax, [fs_rootclus]       ; file manager starts at the root directory
    mov [cwd_cluster], eax
    mov [save_dir], eax
    call ensure_trash            ; make sure a Trash folder exists
    call ensure_system           ; hidden, protected \SYSTEM folder (Nova Core files)
    call ensure_readme           ; README.TXT on the desktop after an install / upgrade
    call desk_init_pos           ; default icon grid, then load saved positions
    call desk_load_cfg
    mov dword [desk_pos_init], 1
    call snake_init
    mov dword [zcount], 0
    mov dword [focus], -1
    mov eax, 0                   ; open the Terminal window
    call open_window
    mov eax, 0                   ; terminal geometry, then banner into the grid
    call load_win_geom
    mov dword [gcol], 0
    mov dword [grow], 0
    mov esi, con_banner
    call gprint
    call gprompt
    call admin_ctx_swap         ; -> write the Admin Terminal's own banner into its own grid
    mov esi, admin_banner
    call gprint
    call gprompt
    call admin_ctx_swap         ; -> back to the normal Terminal's context
    call redraw_all             ; compose the whole desktop

    ; ---- mouse (auto-detected) ----
    call kbd_flush
    call mouse_init
    call kbd_flush
    cmp byte [mouse_present], 0
    je .nomouse
    mov eax, [scrw]
    shr eax, 1
    mov [mouse_x], eax
    mov [cur_x], eax
    mov eax, [scrh]
    shr eax, 1
    mov [mouse_y], eax
    mov [cur_y], eax
    call save_cursor
    call draw_cursor
.nomouse:
    call play_startup_sound      ; recorded sound (or the chime) as the desktop appears
    cmp dword [hda_ok], 0        ; tell the user plainly which sound path this computer is using
    je .snd_pcspk
    mov esi, nt_hda_yes1
    mov edi, nt_hda_yes2
    jmp .snd_tell
.snd_pcspk:
    mov esi, nt_hda_no1
    mov edi, nt_hda_no2
.snd_tell:
    call notify
    ; (USB is taken over only when a USB feature is used - until then the BIOS keeps
    ;  USB keyboards and mice working)

    ; ---- main poll loop (non-blocking, animates when idle) ----
    cli
.poll:
    call kbc_poll                ; PS/2 keyboard/mouse, or our USB ones
    jz .tick
    cmp ah, 2
    je .pmouse
    jmp .kbd
.tick:
    call anim_tick
    jmp .poll
.kbd:
    mov [kbd_sc], al
    cmp al, 0x5B                 ; Windows key (0xE0 0x5B) toggles Start
    jne .notwin
    cmp byte [last_sc], 0xE0
    jne .notwin
    mov byte [last_sc], 0
    call toggle_start
    jmp .poll
.notwin:
    mov [last_sc], al
    cmp dword [rename_mode], 0   ; renaming? capture all keys
    je .norn
    call rename_input
    jmp .poll
.norn:
    mov ecx, [focus]
    cmp ecx, 0                   ; Terminal focused?
    je .kterm
    cmp ecx, 5                   ; Text Editor focused?
    je .kedit
    cmp ecx, 13                  ; Snake focused?
    je .ksnake
    cmp ecx, 14                  ; Music Maker focused?
    je .kmusic
    cmp ecx, 17                  ; Admin Terminal focused?
    je .kadmin
    jmp .poll
.kadmin:
    cmp byte [ws_state + 17], 1
    jne .poll
    mov eax, 17
    call load_win_geom
    cmp byte [mouse_present], 0
    je .natc
    call restore_cursor
    mov al, [kbd_sc]
    call handle_admin_scancode
    call save_cursor
    call draw_cursor
    jmp .poll
.natc:
    mov al, [kbd_sc]
    call handle_admin_scancode
    jmp .poll
.kmusic:
    cmp byte [ws_state + 14], 1
    jne .poll
    mov al, [kbd_sc]
    call handle_music_scancode
    jmp .poll
.ksnake:
    cmp byte [ws_state + 13], 1
    jne .poll
    mov al, [kbd_sc]
    call handle_snake_scancode
    jmp .poll
.kterm:
    cmp byte [ws_state + 0], 1
    jne .poll
    mov eax, 0
    call load_win_geom
    cmp byte [mouse_present], 0
    je .ntc
    call restore_cursor
    mov al, [kbd_sc]
    call handle_scancode
    call save_cursor
    call draw_cursor
    jmp .poll
.ntc:
    mov al, [kbd_sc]
    call handle_scancode
    jmp .poll
.kedit:
    cmp byte [ws_state + 5], 1
    jne .poll
    mov eax, 5
    call load_win_geom
    mov al, [kbd_sc]
    call handle_editor_scancode
    jmp .poll
.pmouse:
    call mouse_feed
    jmp .poll

; ================= keyboard shell =================
handle_scancode:
    cmp al, 0x2A
    je .sh_on
    cmp al, 0x36
    je .sh_on
    cmp al, 0xAA
    je .sh_off
    cmp al, 0xB6
    je .sh_off
    test al, 0x80
    jnz .ret
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
    mov edi, [gbuf_len]
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

; ================= NovaOS Setup wizard =================
; Line-driven: each Enter answers the current step. Steps:
;   1 = choose language, 2 = confirm + install
setup_input:
    cmp dword [setup_step], 1
    je .lang
    cmp dword [setup_step], 2
    je .confirm
    ; unknown -> exit wizard
    mov dword [setup_active], 0
    ret
.lang:
    ; read first char of gcmd: '2'/'3' pick a language, else English
    mov al, [gcmd]
    mov dword [inst_lang], 0
    cmp al, '2'
    jne .l1
    mov dword [inst_lang], 1
.l1:
    cmp al, '3'
    jne .l2
    mov dword [inst_lang], 2
.l2:
    mov esi, gm_setup_picked
    call gprint
    mov eax, [inst_lang]
    shl eax, 2
    mov esi, [lang_names + eax]
    call gprint
    call gnewline
    ; move to confirm step
    mov dword [setup_step], 2
    mov esi, gm_setup_confirm
    call gprint
    ret
.confirm:
    ; accept only exactly "yes"
    mov esi, gcmd
    mov edi, gs_yes
    call streq
    jne .cancel
    call do_install
    mov dword [setup_active], 0
    mov dword [setup_step], 0
    ret
.cancel:
    mov esi, gm_setup_cancel
    call gprint
    mov dword [setup_active], 0
    mov dword [setup_step], 0
    ret

; write NovaOS (boot sector + kernel) onto the install target disk via BIOS
do_install:
    mov byte [inst_drive], 0x81      ; always the 2nd disk, never the boot drive
    call probe_drive                 ; is it present?
    test al, al
    jnz .nodisk
    mov esi, gm_inst_go
    call gprint
    ; boot sector (still in RAM at 0x7C00) -> target LBA 0
    xor eax, eax
    mov esi, 0x7C00
    call bios_write_lba
    ; kernel (RAM at 0x8000) -> target LBA 1..KERNEL_SECTORS
    mov dword [inst_i], 0
.wk:
    mov eax, [inst_i]
    cmp eax, 199                     ; KERNEL_SECTORS (LBA 1-199; 200 = marker)
    jae .wdone
    mov esi, 0x8000
    mov ebx, [inst_i]
    shl ebx, 9                       ; *512
    add esi, ebx
    mov eax, [inst_i]
    inc eax                          ; target LBA = i + 1
    call bios_write_lba
    ; progress: a dot every 16 sectors
    mov eax, [inst_i]
    and eax, 15
    jnz .noprog
    mov al, '.'
    call gputchar
.noprog:
    inc dword [inst_i]
    jmp .wk
.wdone:
    call gnewline
    mov esi, gm_fmt
    call gprint
    call fmt_fat                  ; lay down an empty FAT32 data partition
    ; write the "installed" marker to LBA 200 (inst_drive still = target)
    mov edi, WSECT
    xor eax, eax
    mov ecx, 128
    rep stosd
    mov esi, inst_magic
    mov edi, WSECT
    mov ecx, 8
    rep movsb
    mov eax, 200
    mov esi, WSECT
    call bios_write_lba
    call gnewline
    mov esi, gm_inst_done
    call gprint
    ret
.nodisk:
    mov esi, gm_inst_nodisk
    call gprint
    ret

grun_command:
    cmp dword [setup_active], 0      ; in the Setup wizard? route the line there
    je .notsetup
    call setup_input
    ret
.notsetup:
    cmp dword [gbuf_len], 0
    je .ret
    mov esi, gcmd
    mov edi, gs_install
    call streq
    je .install
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
    mov edi, gs_res
    call streq
    je .res
    mov esi, gcmd
    mov edi, gs_reboot
    call streq
    je .reboot
    mov esi, gcmd
    mov edi, gs_disk
    call streq
    je .disk
    mov esi, gcmd
    mov edi, gs_crash
    call streq
    je .crash
    mov esi, gcmd
    mov edi, gs_usb
    call streq
    je .usb
    mov esi, gcmd
    mov edi, gs_beep
    call streq
    je .beep
    mov esi, gcmd
    mov edi, gs_apps
    call streq
    je .apps
    mov esi, gcmd
    mov edi, gs_ls
    call streq
    je .ls
    ; cat <file>  (prefix match)
    mov esi, gcmd
    mov edi, gs_cat
    call strprefix
    je .cat
    ; echo <text>  (prefix match)
    mov esi, gcmd
    mov edi, gs_echo
    call strprefix
    je .echo
    mov esi, gcmd
    mov edi, gs_pcilist
    call streq
    je .pcilist
    mov esi, gcmd
    mov edi, gs_sysdump
    call streq
    je .sysdump
    mov esi, gm_unknown
    call gprint
    mov esi, gcmd
    call gprint
    call gnewline
.ret:
    ret
.pcilist:
    call gprint_pcilist
    ret
.sysdump:
    call gprint_sysdump
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
.res:
    mov esi, gm_res
    call gprint
    mov eax, [scrw]
    call gprint_dec
    mov al, 'x'
    call gputchar
    mov eax, [scrh]
    call gprint_dec
    call gnewline
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
.crash:
    mov esi, sad_test
    call sad_mac                 ; show the error screen (halts)
    ret
.disk:
    ; list the disks the BIOS can see (works on AHCI, unlike raw ATA)
    mov esi, gm_disk1
    call gprint
    ; boot disk (drive number the loader stashed at 0x1014)
    mov esi, gm_disk_boot
    call gprint
    xor eax, eax
    call bios_read_lba
    test al, al
    jnz .disk_bootbad
    mov esi, gm_disk_ok
    call gprint
    jmp .disk_second
.disk_bootbad:
    mov esi, gm_disk_bad
    call gprint
.disk_second:
    ; probe a second BIOS disk (0x81) - the install target
    mov esi, gm_disk_2nd
    call gprint
    mov byte [inst_drive], 0x81
    call probe_drive
    test al, al
    jnz .disk_no2
    mov esi, gm_disk_ok
    call gprint
    ret
.disk_no2:
    mov esi, gm_disk_absent
    call gprint
    ret
.usb:
    ; ask the BIOS to read sector 0 of the BOOT device (the USB, on real HW)
    mov esi, gm_usb1
    call gprint
    xor eax, eax
    call bios_read_lba
    test al, al
    jnz .usb_fail
    mov esi, gm_disk2
    call gprint
    mov esi, DISKBUF
    xor ecx, ecx
.usb_hx:
    mov al, [esi]
    call ghex_byte
    mov al, ' '
    call gputchar
    inc esi
    inc ecx
    cmp ecx, 16
    jb .usb_hx
    call gnewline
    mov al, [DISKBUF + 510]
    cmp al, 0x55
    jne .usb_nosig
    mov al, [DISKBUF + 511]
    cmp al, 0xAA
    jne .usb_nosig
    mov esi, gm_usb_ok
    call gprint
    ret
.usb_nosig:
    mov esi, gm_usb_read
    call gprint
    ret
.usb_fail:
    mov esi, gm_usb_fail
    call gprint
    ret
.beep:
    mov bx, 1522                 ; a clean 'G' tone
    call play_note
    ret
.apps:
    mov esi, gm_apps
    call gprint
    ret
.echo:
    ; print everything after "echo " (esi already advanced past the prefix)
    call gprint
    call gnewline
    ret
.ls:
    mov esi, gm_ls1
    call gprint
    call fat_list
    ret
.cat:
    ; esi already points past "cat "
    call fat_cat
    ret
.install:                        ; open the graphical Setup wizard
    mov dword [wiz_from_desk], 1
    call run_setup
    mov dword [wiz_from_desk], 0
    call redraw_all
    ret
.cpu:
    mov eax, 0x80000000
    cpuid
    cmp eax, 0x80000004
    jb .cpu_v
    mov edi, gcpubuf
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
    jmp .cpu_p
.cpu_v:
    mov eax, 0
    cpuid
    mov edi, gcpubuf
    mov [edi], ebx
    mov [edi+4], edx
    mov [edi+8], ecx
    mov byte [edi+12], 0
.cpu_p:
    mov esi, gm_cpu
    call gprint
    mov esi, gcpubuf
    call gprint
    call gnewline
    ret

; ================= console text =================
gputchar:
    mov [gchar], al
    pushad
    ; store into the text grid: tbuf[grow*MAXCOLS + gcol]
    mov eax, [grow]
    imul eax, MAXCOLS
    add eax, [gcol]
    mov bl, [gchar]
    mov edi, [cur_text_buf]
    mov [edi + eax], bl
    ; draw it
    mov eax, [gcol]
    shl eax, 3
    add eax, [con_x0]
    mov [tx], eax
    mov eax, [grow]
    shl eax, 4
    add eax, [con_y0]
    mov [ty], eax
    mov dword [tcolor], C_TEXT
    mov al, [gchar]
    call draw_char
    inc dword [gcol]
    mov eax, [gcol]
    cmp eax, [con_cols]
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

gbackspace:
    pushad
    cmp dword [gcol], 0
    je .done
    dec dword [gcol]
    ; clear grid cell
    mov eax, [grow]
    imul eax, MAXCOLS
    add eax, [gcol]
    mov edi, [cur_text_buf]
    mov byte [edi + eax], ' '
    mov eax, [gcol]
    shl eax, 3
    add eax, [con_x0]
    mov [rx], eax
    mov eax, [grow]
    shl eax, 4
    add eax, [con_y0]
    mov [ry], eax
    mov dword [rw], 8
    mov dword [rh], 16
    mov dword [rcolor], C_CONBG
    call fillrect
.done:
    popad
    ret

gcheck_scroll:
    mov eax, [grow]
    cmp eax, [con_rows]
    jl .ok
    call gscroll
    mov eax, [con_rows]
    dec eax
    mov [grow], eax
.ok:
    ret

gscroll:
    pushad
    mov eax, [con_rows]
    dec eax
    shl eax, 4                 ; (con_rows-1)*16 pixel rows
    mov ecx, eax
    mov ebx, [con_y0]
.row:
    test ecx, ecx
    jz .clear
    mov eax, ebx
    add eax, 16
    imul eax, [pitch]
    add eax, [lfb]
    mov edx, [con_x0]
    shl edx, 2
    add eax, edx
    mov esi, eax
    mov eax, ebx
    imul eax, [pitch]
    add eax, [lfb]
    add eax, edx
    mov edi, eax
    push ecx
    mov ecx, [con_cols]
    shl ecx, 3                 ; con_cols*8 pixels
    rep movsd
    pop ecx
    inc ebx
    dec ecx
    jmp .row
.clear:
    mov eax, [con_rows]
    dec eax
    shl eax, 4
    add eax, [con_y0]
    mov ebx, eax
    mov ecx, 16
.crow:
    test ecx, ecx
    jz .grid
    mov eax, ebx
    imul eax, [pitch]
    add eax, [lfb]
    mov edx, [con_x0]
    shl edx, 2
    add eax, edx
    mov edi, eax
    push ecx
    mov ecx, [con_cols]
    shl ecx, 3
    mov eax, C_CONBG
    rep stosd
    pop ecx
    inc ebx
    dec ecx
    jmp .crow
.grid:
    ; shift the text grid up one row, clear the last row
    mov ebx, 0                ; dest row
.grow:
    mov eax, [con_rows]
    dec eax
    cmp ebx, eax              ; stop at last row
    jae .gclear
    mov esi, ebx
    inc esi
    imul esi, MAXCOLS
    add esi, [cur_text_buf]   ; src = row+1
    mov edi, ebx
    imul edi, MAXCOLS
    add edi, [cur_text_buf]   ; dst = row
    mov ecx, [con_cols]
    rep movsb
    inc ebx
    jmp .grow
.gclear:
    mov edi, ebx
    imul edi, MAXCOLS
    add edi, [cur_text_buf]
    mov ecx, [con_cols]
    mov al, ' '
    rep stosb
.done:
    popad
    ret

gclear_console:
    pushad
    mov eax, [con_x0]
    mov [rx], eax
    mov eax, [con_y0]
    mov [ry], eax
    mov eax, [con_cols]
    shl eax, 3
    mov [rw], eax
    mov eax, [con_rows]
    shl eax, 4
    mov [rh], eax
    mov dword [rcolor], C_CONBG
    call fillrect
    call gclear_grid
    mov dword [gcol], 0
    mov dword [grow], 0
    popad
    ret

gclear_grid:                 ; fill the whole text grid with spaces
    pushad
    mov edi, [cur_text_buf]
    mov ecx, MAXCOLS * MAXROWS
    mov al, ' '
    rep stosb
    popad
    ret

; redraw the whole window (frame + title + body + all grid text) at [wx],[wy]
; load window [eax]'s geometry into wx/wy/ww/wh and console vars
load_win_geom:
    push eax
    push ebx
    mov ebx, [ws_x + eax*4]
    mov [wx], ebx
    mov ebx, [ws_y + eax*4]
    mov [wy], ebx
    mov ebx, [ws_w + eax*4]
    mov [ww], ebx
    mov ebx, [ws_h + eax*4]
    mov [wh], ebx
    mov ebx, [wx]
    add ebx, 4
    mov [con_x0], ebx
    mov ebx, [wy]
    add ebx, TITLE_H + 4
    mov [con_y0], ebx
    mov ebx, [ww]
    sub ebx, 8
    shr ebx, 3
    cmp ebx, MAXCOLS
    jbe .cc
    mov ebx, MAXCOLS
.cc:
    mov [con_cols], ebx
    mov ebx, [wh]
    sub ebx, TITLE_H + 8
    shr ebx, 4
    cmp ebx, MAXROWS
    jbe .cr
    mov ebx, MAXROWS
.cr:
    mov [con_rows], ebx
    pop ebx
    pop eax
    ret

; draw one window (id in EAX): frame, title, close/min/resize, body, content
draw_window:
    pushad
    mov [cur_app], eax
    call load_win_geom
    mov eax, [cur_app]
    xor ebx, ebx
    cmp eax, [focus]
    jne .nf0
    inc ebx
.nf0:
    mov [dw_foc], ebx
    ; slim rounded border
    mov eax, [wx]
    dec eax
    mov [rx], eax
    mov eax, [wy]
    dec eax
    mov [ry], eax
    mov eax, [ww]
    add eax, 2
    mov [rw], eax
    mov eax, [wh]
    add eax, 2
    mov [rh], eax
    mov dword [rcolor], 0x0028303C
    cmp dword [dw_foc], 0
    je .bc
    mov dword [rcolor], 0x003C4858
.bc:
    mov dword [rrad], 8
    mov dword [rround], 3
    call fill_rrect
    ; title bar (rounded top)
    mov eax, [wx]
    mov [rx], eax
    mov eax, [wy]
    mov [ry], eax
    mov eax, [ww]
    mov [rw], eax
    mov dword [rh], TITLE_H
    mov dword [rcolor], 0x00181E28
    cmp dword [dw_foc], 0
    je .tc
    mov dword [rcolor], 0x00212A38
.tc:
    mov dword [rround], 1
    call fill_rrect
    ; body (rounded bottom)
    mov eax, [wy]
    add eax, TITLE_H
    mov [ry], eax
    mov eax, [wh]
    sub eax, TITLE_H
    mov [rh], eax
    mov dword [rcolor], C_CONBG
    mov dword [rround], 2
    call fill_rrect
    ; accent line under the title of the window you're using
    cmp dword [dw_foc], 0
    je .nacc
    mov eax, [wx]
    mov [rx], eax
    mov eax, [wy]
    add eax, TITLE_H - 2
    mov [ry], eax
    mov eax, [ww]
    mov [rw], eax
    mov dword [rh], 2
    mov eax, [accent]
    mov [rcolor], eax
    call fillrect
.nacc:
    ; title text
    mov dword [tcolor], 0x008B93A7
    cmp dword [dw_foc], 0
    je .ttc
    mov dword [tcolor], C_WHITE
.ttc:
    mov eax, [wx]
    add eax, 12
    mov [tx], eax
    mov eax, [wy]
    add eax, 3
    mov [ty], eax
    mov eax, [cur_app]
    mov esi, [app_titles + eax*4]
    call draw_text
    ; round buttons (same click areas as before): close, minimise, maximise
    mov eax, [wy]
    add eax, 10
    mov [ccy], eax
    mov dword [ccr], 6
    mov eax, [wx]
    add eax, [ww]
    sub eax, 12
    mov [ccx], eax
    mov dword [rcolor], 0x00FF5F57
    cmp dword [dw_foc], 0
    jne .c1
    mov dword [rcolor], 0x00454D5B
.c1:
    call fill_circle
    sub dword [ccx], 20
    mov dword [rcolor], 0x00FEBC2E
    cmp dword [dw_foc], 0
    jne .c2
    mov dword [rcolor], 0x00454D5B
.c2:
    call fill_circle
    sub dword [ccx], 20
    mov dword [rcolor], 0x0028C840
    cmp dword [dw_foc], 0
    jne .c3
    mov dword [rcolor], 0x00454D5B
.c3:
    call fill_circle
    ; little marks inside the buttons (on the window you're using)
    cmp dword [dw_foc], 0
    je .nmark
    mov dword [rcolor], 0x006B1D18        ; x
    mov eax, [wx]
    add eax, [ww]
    sub eax, 14
    mov [rx], eax
    mov eax, [wy]
    add eax, 8
    mov [ry], eax
    mov dword [rw], 2
    mov dword [rh], 2
    call fillrect
    add dword [rx], 2
    add dword [ry], 2
    call fillrect
    sub dword [ry], 4
    add dword [rx], 0
    call fillrect
    sub dword [rx], 4
    add dword [ry], 4
    call fillrect
    mov dword [rcolor], 0x00725214        ; -
    mov eax, [wx]
    add eax, [ww]
    sub eax, 35
    mov [rx], eax
    mov eax, [wy]
    add eax, 9
    mov [ry], eax
    mov dword [rw], 6
    mov dword [rh], 2
    call fillrect
    mov dword [rcolor], 0x000D5A1C        ; +
    mov eax, [wx]
    add eax, [ww]
    sub eax, 55
    mov [rx], eax
    call fillrect
    add dword [rx], 2
    sub dword [ry], 2
    mov dword [rw], 2
    mov dword [rh], 6
    call fillrect
.nmark:
    ; resize grip: three soft dots
    mov dword [rcolor], 0x004A5568
    mov dword [rw], 2
    mov dword [rh], 2
    mov eax, [wx]
    add eax, [ww]
    sub eax, 6
    mov [rx], eax
    mov eax, [wy]
    add eax, [wh]
    sub eax, 6
    mov [ry], eax
    call fillrect
    sub dword [rx], 4
    call fillrect
    add dword [rx], 4
    sub dword [ry], 4
    call fillrect
    ; content
    call draw_app_content
    popad
    ret

; smooth vertical gradient wallpaper across the whole screen
draw_gradient:
    pushad
    xor ebx, ebx
.row:
    cmp ebx, [scrh]
    jae .done
    mov eax, ebx
    imul eax, dword [grad_dr]
    cdq
    idiv dword [scrh]
    add eax, [grad_r]
    and eax, 0xFF
    shl eax, 16
    mov edi, eax
    mov eax, ebx
    imul eax, dword [grad_dg]
    cdq
    idiv dword [scrh]
    add eax, [grad_g]
    and eax, 0xFF
    shl eax, 8
    or edi, eax
    mov eax, ebx
    imul eax, dword [grad_db]
    cdq
    idiv dword [scrh]
    add eax, [grad_b]
    and eax, 0xFF
    or edi, eax
    mov eax, ebx
    imul eax, [pitch]
    add eax, [lfb]
    mov esi, eax
    mov ecx, [scrw]
    mov eax, edi
.px:
    mov [esi], eax
    add esi, 4
    dec ecx
    jnz .px
    inc ebx
    jmp .row
.done:
    popad
    ret

; drop-shadow behind window [EAX]
draw_shadow:
    cmp byte [shadows_on], 0
    je .off
    pushad
    mov ebx, [ws_x + eax*4]
    add ebx, 6
    mov [rx], ebx
    mov ebx, [ws_y + eax*4]
    add ebx, 6
    mov [ry], ebx
    mov ebx, [ws_w + eax*4]
    add ebx, 4
    mov [rw], ebx
    mov ebx, [ws_h + eax*4]
    add ebx, 2
    mov [rh], ebx
    sub dword [rx], 2
    mov dword [rcolor], 0x00080C14
    mov dword [rrad], 8
    mov dword [rround], 3
    call fill_rrect
    popad
.off:
    ret

; faint Nova logo watermark in the desktop corner
draw_watermark:
    pushad
    mov eax, [scrw]
    sub eax, 110
    mov [dcx], eax
    mov eax, [scrh]
    sub eax, 150
    mov [dcy], eax
    mov dword [drad], 42
    mov dword [dcolor], 0x001B2C44
    call draw_diamond
    mov dword [drad], 18
    mov dword [dcolor], 0x0026405F
    call draw_diamond
    mov eax, [scrw]
    sub eax, 138
    mov [tx], eax
    mov eax, [scrh]
    sub eax, 96
    mov [ty], eax
    mov dword [tcolor], 0x002E4666
    mov esi, txt_top
    call draw_text
    popad
    ret

; read the root directory into the desktop-icon arrays
desk_read:
    pushad
    cmp dword [has_fatfs], 0
    je .done
    call fat_mount
    mov dword [desk_count], 0
    mov eax, [fs_rootclus]
    call clus_to_sector
    mov edi, FSDIR
    call fs_read_sector
    xor ebx, ebx
.e:
    cmp ebx, 16
    jae .done
    mov eax, ebx
    shl eax, 5
    lea esi, [FSDIR + eax]
    mov al, [esi]
    test al, al
    jz .done
    cmp al, 0xE5
    je .next
    mov al, [esi+11]
    cmp al, 0x0F
    je .next
    test al, 0x08
    jnz .next
    test byte [esi+11], 0x02     ; hidden (e.g. SYSTEM) -> no desktop icon
    jnz .next
    cmp byte [esi], '.'
    je .next
    mov ecx, [desk_count]
    cmp ecx, 12
    jae .done
    mov eax, ecx
    imul eax, 11
    lea edi, [desk_name + eax]
    push ecx
    push ebx
    mov ecx, 11
    rep movsb
    pop ebx
    pop ecx
    mov eax, ebx
    shl eax, 5
    lea esi, [FSDIR + eax]
    mov al, [esi+11]
    mov [desk_attr + ecx], al
    movzx eax, word [esi+20]
    shl eax, 16
    movzx edx, word [esi+26]
    or eax, edx
    mov [desk_clus + ecx*4], eax
    mov eax, [esi+28]
    mov [desk_size + ecx*4], eax
    inc dword [desk_count]
.next:
    inc ebx
    jmp .e
.done:
    popad
    ret

desk_icon_pos:               ; EBX = index -> [ico_x],[ico_y]  (grid, 8 per column)
    push eax
    push ecx
    push edx
    mov eax, ebx
    xor edx, edx
    mov ecx, 8
    div ecx                  ; eax = col, edx = row
    imul eax, 108
    add eax, 24
    mov [ico_x], eax
    mov eax, edx
    imul eax, 78
    add eax, 46
    mov [ico_y], eax
    pop edx
    pop ecx
    pop eax
    ret

; draw a trash-bin icon at [ico_x],[ico_y]
draw_bin_icon:
    pushad
    mov eax, [ico_x]            ; handle
    add eax, 26
    mov [rx], eax
    mov eax, [ico_y]
    add eax, 1
    mov [ry], eax
    mov dword [rw], 12
    mov dword [rh], 3
    mov dword [rcolor], 0x00A6AEB6
    call fillrect
    mov eax, [ico_x]           ; lid
    add eax, 14
    mov [rx], eax
    mov eax, [ico_y]
    add eax, 5
    mov [ry], eax
    mov dword [rw], 36
    mov dword [rh], 5
    mov dword [rcolor], 0x00A6AEB6
    call fillrect
    mov eax, [ico_x]           ; body
    add eax, 17
    mov [rx], eax
    mov eax, [ico_y]
    add eax, 11
    mov [ry], eax
    mov dword [rw], 30
    mov dword [rh], 27
    mov dword [rcolor], 0x00838B94
    call fillrect
    mov ecx, 3                 ; three vertical ridges
    mov ebx, 6
.rg:
    mov eax, [ico_x]
    add eax, 17
    add eax, ebx
    mov [rx], eax
    mov eax, [ico_y]
    add eax, 14
    mov [ry], eax
    mov dword [rw], 3
    mov dword [rh], 21
    mov dword [rcolor], 0x00646A72
    call fillrect
    add ebx, 8
    dec ecx
    jnz .rg
    popad
    ret

; a document icon at ico_x/ico_y for desktop entry EAX: page, folded corner, a band with its type
draw_file_icon:
    pushad
    imul eax, 11
    lea esi, [desk_name + eax + 8]      ; the extension
    ; the page, with its top-right corner folded over
    xor ecx, ecx
.pr:
    cmp ecx, 36
    jae .pdone
    mov eax, [ico_x]
    add eax, 16
    mov [rx], eax
    mov eax, [ico_y]
    add eax, 2
    add eax, ecx
    mov [ry], eax
    mov dword [rh], 1
    mov dword [rw], 30
    cmp ecx, 9
    jae .full
    mov eax, 21
    add eax, ecx
    mov [rw], eax                        ; page part of this row
    mov dword [rcolor], 0x00EEF2F6
    call fillrect
    mov eax, [rx]                        ; the fold (a little triangle)
    add eax, 21
    mov [rx], eax
    mov eax, ecx
    inc eax
    mov [rw], eax
    mov dword [rcolor], 0x00B8C2CE
    call fillrect
    jmp .pn
.full:
    mov dword [rcolor], 0x00EEF2F6
    call fillrect
.pn:
    inc ecx
    jmp .pr
.pdone:
    ; the type band: NTR = purple music, TXT = blue text, anything else = grey
    mov dword [rcolor], 0x006B7686
    mov edx, 0                           ; 1 = song, 2 = text
    cmp word [esi], 'NT'
    jne .t1
    cmp byte [esi + 2], 'R'
    jne .t1
    mov dword [rcolor], 0x00B23AC9
    mov edx, 1
    jmp .band
.t1:
    cmp word [esi], 'TX'
    jne .band
    cmp byte [esi + 2], 'T'
    jne .band
    mov dword [rcolor], 0x002F7FD8
    mov edx, 2
.band:
    mov eax, [ico_x]
    add eax, 16
    mov [rx], eax
    mov eax, [ico_y]
    add eax, 22
    mov [ry], eax
    mov dword [rw], 30
    mov dword [rh], 16
    call fillrect
    push dword [rcolor]
    mov eax, [ico_x]                     ; the extension, in white
    add eax, 19
    mov [tx], eax
    mov eax, [ico_y]
    add eax, 22
    mov [ty], eax
    mov dword [tcolor], 0x00FFFFFF
    mov ecx, 3
.ext:
    mov al, [esi]
    call draw_char
    add dword [tx], 8
    inc esi
    dec ecx
    jnz .ext
    pop dword [rcolor]
    ; a picture on the page
    cmp edx, 1
    jne .lines
    mov eax, [ico_x]                     ; a music note
    add eax, 26
    mov [ccx], eax
    mov eax, [ico_y]
    add eax, 16
    mov [ccy], eax
    mov dword [ccr], 3
    call fill_circle
    mov eax, [ico_x]
    add eax, 28
    mov [rx], eax
    mov eax, [ico_y]
    add eax, 7
    mov [ry], eax
    mov dword [rw], 2
    mov dword [rh], 9
    call fillrect
    mov dword [rw], 6
    mov dword [rh], 2
    call fillrect
    jmp .done
.lines:
    mov dword [rcolor], 0x00A9B4C2       ; text lines
    mov eax, [ico_x]
    add eax, 20
    mov [rx], eax
    mov dword [rh], 2
    mov eax, [ico_y]
    add eax, 8
    mov [ry], eax
    mov dword [rw], 14
    call fillrect
    add dword [ry], 4
    mov dword [rw], 20
    call fillrect
    add dword [ry], 4
    mov dword [rw], 17
    call fillrect
.done:
    popad
    ret

draw_desktop_icons:
    cmp dword [has_fatfs], 0
    je .ret
    pushad
    cmp dword [desk_pos_init], 0    ; lay out the default grid once
    jne .posok
    mov dword [desk_pos_init], 1
    call desk_init_pos
.posok:
    cmp dword [desk_dirty], 0
    je .draw
    mov dword [desk_dirty], 0
    call desk_read
.draw:
    xor ebx, ebx
.l:
    cmp ebx, [desk_count]
    jae .done
    mov eax, [desk_ix + ebx*4]
    mov [ico_x], eax
    mov eax, [desk_iy + ebx*4]
    mov [ico_y], eax
    mov eax, [desk_clus + ebx*4]
    cmp eax, [trash_cluster]
    je .bin
    mov al, [desk_attr + ebx]
    test al, 0x10
    jz .file
    ; folder icon: a back with a tab, a lighter front
    mov dword [rrad], 4
    mov dword [rround], 3
    mov eax, [ico_x]
    add eax, 14
    mov [rx], eax
    mov eax, [ico_y]
    add eax, 2
    mov [ry], eax
    mov dword [rw], 16
    mov dword [rh], 10
    mov dword [rcolor], 0x00C9941A
    call fill_rrect
    mov eax, [ico_y]
    add eax, 6
    mov [ry], eax
    mov dword [rw], 36
    mov dword [rh], 28
    call fill_rrect
    mov eax, [ico_y]
    add eax, 11
    mov [ry], eax
    mov dword [rh], 23
    mov dword [rcolor], 0x00F2C24A
    call fill_rrect
    jmp .label
.file:
    mov eax, ebx
    call draw_file_icon
    jmp .label
.bin:
    call draw_bin_icon
.label:
    mov eax, [ico_x]
    mov [tx], eax
    mov eax, [ico_y]
    add eax, 42
    mov [ty], eax
    mov dword [tcolor], C_WHITE
    mov eax, ebx
    imul eax, 11
    lea esi, [desk_name + eax]
    call print_83_at
    inc ebx
    jmp .l
.done:
    popad
.ret:
    ret

; lay out the default icon grid into desk_ix/desk_iy (once)
desk_init_pos:
    pushad
    xor ebx, ebx
.l:
    cmp ebx, 12
    jae .done
    call desk_icon_pos
    mov eax, [ico_x]
    mov [desk_ix + ebx*4], eax
    mov eax, [ico_y]
    mov [desk_iy + ebx*4], eax
    inc ebx
    jmp .l
.done:
    popad
    ret

; -> EAX = index of the desktop icon under the cursor, or -1
desk_hit:
    push ebx
    push ecx
    xor ebx, ebx
.l:
    cmp ebx, [desk_count]
    jae .none
    mov eax, [mouse_x]
    mov ecx, [desk_ix + ebx*4]
    cmp eax, ecx
    jl .n
    add ecx, 64
    cmp eax, ecx
    jg .n
    mov eax, [mouse_y]
    mov ecx, [desk_iy + ebx*4]
    cmp eax, ecx
    jl .n
    add ecx, 58
    cmp eax, ecx
    jg .n
    mov eax, ebx
    pop ecx
    pop ebx
    ret
.n:
    inc ebx
    jmp .l
.none:
    pop ecx
    pop ebx
    mov eax, -1
    ret

; open the desktop icon whose index is in EAX (file -> editor, folder -> Files)
desk_open_icon:
    mov ebx, eax
    mov al, [desk_attr + ebx]
    test al, 0x10
    jz .file
    mov eax, [desk_clus + ebx*4]
    test eax, eax
    jz .ret
    mov [cwd_cluster], eax
    mov dword [files_dirty], 1
    mov dword [desk_dirty], 1
    mov eax, 8
    call open_window
    call recompose
    ret
.file:
    mov eax, ebx                 ; a Music Maker song? -> open it there instead of the text editor
    imul eax, 11
    lea esi, [desk_name + eax]
    cmp word [esi + 8], 'NT'
    jne .text
    cmp byte [esi + 10], 'R'
    jne .text
    mov eax, [desk_clus + ebx*4]
    xor edx, edx
    call music_open_file
    ret
.text:
    mov dword [ed_ro], 0
    mov eax, [desk_size + ebx*4]
    mov [fl_size], eax
    mov eax, ebx
    imul eax, 11
    lea esi, [desk_name + eax]
    mov edi, ed_fname
    mov ecx, 11
    rep movsb
    mov eax, [fs_rootclus]
    mov [save_dir], eax
    mov eax, [desk_clus + ebx*4]
    call fat_load_to_editor
    mov eax, 5
    call open_window
    call recompose
.ret:
    ret

; recompose the whole screen from window state
redraw_all:
    pushad
    call draw_gradient
    call draw_watermark
    call draw_desktop_icons
    ; windows bottom-to-top, open only
    xor esi, esi
.w:
    cmp esi, [zcount]
    jae .bars
    movzx eax, byte [zorder + esi]
    cmp byte [ws_state + eax], 1
    jne .wnext
    push esi
    call draw_shadow            ; drop-shadow behind the window
    pop esi
    push esi
    call draw_window
    pop esi
.wnext:
    inc esi
    jmp .w
.bars:
    ; top bar (dark, sleek)
    mov dword [rx], 0
    mov dword [ry], 0
    mov eax, [scrw]
    mov [rw], eax
    mov dword [rh], 26
    mov dword [rcolor], C_DGRAY
    call fillrect
    ; accent underline
    mov dword [rx], 0
    mov dword [ry], 25
    mov eax, [scrw]
    mov [rw], eax
    mov dword [rh], 1
    mov eax, [accent]
    mov [rcolor], eax
    call fillrect
    mov dword [tcolor], C_WHITE
    mov dword [tx], 8
    mov dword [ty], 5
    mov esi, txt_top
    call draw_text
    call draw_taskbar2
    popad
    ret

recompose:
    call redraw_all
    call draw_notif_center       ; side panel, if open
    call draw_toast              ; corner toast, if active
    cmp byte [mouse_present], 0
    je .done
    call save_cursor
    call draw_cursor
.done:
    ret

; ---- notification toast (bottom-right card, auto-dismiss after 4s) ----
notify:                          ; ESI = line1 ptr, EDI = line2 ptr
    mov [notif_msg1], esi
    mov [notif_msg2], edi
    call notif_push              ; add to the history list
    mov dword [notif_timer], 1   ; 1 = a toast is showing
    call now_seconds
    mov [notif_start_sec], eax
    call draw_toast
    ret

now_seconds:                     ; -> EAX = seconds since midnight (from the RTC)
    push ebx                     ; read twice and require agreement -- read_rtc only guards
    push ecx                     ; against UIP at the START of a read, not a tick landing
    push edx                     ; mid-sequence (torn read -> a wildly wrong value for one call,
    mov edx, 8                   ; which would fool a watchdog into stopping early). Bounded --
.retry:                          ; accept whatever the last attempt read rather than risk a hang.
    call read_rtc
    movzx eax, byte [rtc_hour]
    imul eax, 3600
    movzx ebx, byte [rtc_min]
    imul ebx, 60
    add eax, ebx
    movzx ebx, byte [rtc_sec]
    add eax, ebx
    mov ecx, eax
    call read_rtc
    movzx eax, byte [rtc_hour]
    imul eax, 3600
    movzx ebx, byte [rtc_min]
    imul ebx, 60
    add eax, ebx
    movzx ebx, byte [rtc_sec]
    add eax, ebx
    cmp eax, ecx
    je .agree
    dec edx
    jnz .retry
.agree:
    pop edx
    pop ecx
    pop ebx
    ret

notif_push:                      ; ESI=l1, EDI=l2 -> newest at index 0 (keep 5)
    pushad
    mov ecx, 4
.sh:
    mov eax, [nhist1 + ecx*4 - 4]
    mov [nhist1 + ecx*4], eax
    mov eax, [nhist2 + ecx*4 - 4]
    mov [nhist2 + ecx*4], eax
    dec ecx
    jnz .sh
    mov [nhist1], esi
    mov [nhist2], edi
    popad
    ret

toast_dismiss:                   ; close the toast now (click-to-close / timeout)
    mov dword [notif_timer], 0
    call recompose
    ret

draw_toast:
    cmp dword [notif_timer], 0
    je .ret
    pushad
    mov eax, [scrw]
    sub eax, 320
    mov [rx], eax
    mov eax, [scrh]
    sub eax, 98
    mov [ry], eax
    mov dword [rw], 312
    mov dword [rh], 58
    mov dword [rcolor], 0x00202A38
    call fillrect
    mov eax, [scrw]           ; accent bar on the left edge
    sub eax, 320
    mov [rx], eax
    mov eax, [scrh]
    sub eax, 98
    mov [ry], eax
    mov dword [rw], 5
    mov dword [rh], 58
    mov eax, [accent]
    mov [rcolor], eax
    call fillrect
    mov eax, [scrw]           ; line 1
    sub eax, 304
    mov [tx], eax
    mov eax, [scrh]
    sub eax, 90
    mov [ty], eax
    mov dword [tcolor], C_WHITE
    mov esi, [notif_msg1]
    call draw_text
    mov eax, [scrw]           ; line 2
    sub eax, 304
    mov [tx], eax
    mov eax, [scrh]
    sub eax, 68
    mov [ty], eax
    mov dword [tcolor], 0x00A8B4C0
    mov esi, [notif_msg2]
    call draw_text
    popad
.ret:
    ret

put2:                            ; AL = 0..99 -> two ASCII digits at [EDI], EDI += 2
    movzx eax, al
    xor edx, edx
    mov ecx, 10
    div ecx
    add al, '0'
    mov [edi], al
    inc edi
    add dl, '0'
    mov [edi], dl
    inc edi
    ret

; ---- Notification Center + widgets (right-side slide-in panel) ----
draw_notif_center:
    cmp dword [notif_open], 0
    je .ret
    pushad
    call read_rtc
    ; panel background
    mov eax, [scrw]
    sub eax, 264
    mov [rx], eax
    mov dword [ry], 32
    mov dword [rw], 264
    mov eax, [scrh]
    sub eax, 64
    mov [rh], eax
    mov dword [rcolor], 0x00161C26
    call fillrect
    ; title
    mov eax, [scrw]
    sub eax, 248
    mov [tx], eax
    mov dword [ty], 46
    mov dword [tcolor], C_WHITE
    mov esi, nc_title
    call draw_text
    ; ===== Clock widget card =====
    mov eax, [scrw]
    sub eax, 250
    mov [rx], eax
    mov dword [ry], 74
    mov dword [rw], 236
    mov dword [rh], 78
    mov dword [rcolor], 0x00202A38
    call fillrect
    ; time HH:MM
    mov edi, nc_time
    mov al, [rtc_hour]
    call put2
    mov byte [edi], ':'
    inc edi
    mov al, [rtc_min]
    call put2
    mov byte [edi], 0
    mov eax, [scrw]
    sub eax, 238
    mov [tx], eax
    mov dword [ty], 84
    mov dword [tcolor], 0x008FE9B6
    mov dword [tscale], 2
    mov esi, nc_time
    call draw_text_scaled
    ; date DD/MM/20YY
    mov edi, nc_date
    mov al, [rtc_day]
    call put2
    mov byte [edi], '/'
    inc edi
    mov al, [rtc_month]
    call put2
    mov byte [edi], '/'
    inc edi
    mov byte [edi], '2'
    inc edi
    mov byte [edi], '0'
    inc edi
    mov al, [rtc_year]
    call put2
    mov byte [edi], 0
    mov eax, [scrw]
    sub eax, 238
    mov [tx], eax
    mov dword [ty], 124
    mov dword [tcolor], 0x00B8C4D0
    mov esi, nc_date
    call draw_text
    ; ===== System widget card =====
    mov eax, [scrw]
    sub eax, 250
    mov [rx], eax
    mov dword [ry], 162
    mov dword [rw], 236
    mov dword [rh], 46
    mov dword [rcolor], 0x00202A38
    call fillrect
    mov eax, [scrw]
    sub eax, 238
    mov [tx], eax
    mov dword [ty], 172
    mov dword [tcolor], C_WHITE
    mov esi, nc_sys1
    call draw_text
    mov eax, [scrw]
    sub eax, 238
    mov [tx], eax
    mov dword [ty], 190
    mov dword [tcolor], 0x00B8C4D0
    mov esi, nc_sys2
    call draw_text
    ; ===== Notification list =====
    mov eax, [scrw]
    sub eax, 248
    mov [tx], eax
    mov dword [ty], 224
    mov dword [tcolor], 0x00808C98
    mov esi, nc_recent
    call draw_text
    cmp dword [nhist1], 0
    jne .list
    mov eax, [scrw]
    sub eax, 248
    mov [tx], eax
    mov dword [ty], 248
    mov dword [tcolor], 0x00808C98
    mov esi, nc_none
    call draw_text
    jmp .fin
.list:
    xor ebx, ebx                 ; index 0..4
    mov dword [nc_y], 246
.le:
    cmp ebx, 5
    jae .fin
    mov esi, [nhist1 + ebx*4]
    test esi, esi
    jz .fin
    ; card
    mov eax, [scrw]
    sub eax, 250
    mov [rx], eax
    mov eax, [nc_y]
    mov [ry], eax
    mov dword [rw], 236
    mov dword [rh], 40
    mov dword [rcolor], 0x00202A38
    call fillrect
    ; line 1
    mov eax, [scrw]
    sub eax, 242
    mov [tx], eax
    mov eax, [nc_y]
    add eax, 4
    mov [ty], eax
    mov dword [tcolor], C_WHITE
    mov esi, [nhist1 + ebx*4]
    call draw_text
    ; line 2
    mov eax, [scrw]
    sub eax, 242
    mov [tx], eax
    mov eax, [nc_y]
    add eax, 20
    mov [ty], eax
    mov dword [tcolor], 0x00A8B4C0
    mov esi, [nhist2 + ebx*4]
    call draw_text
    add dword [nc_y], 46
    inc ebx
    jmp .le
.fin:
    popad
.ret:
    ret

draw_taskbar2:
    pushad
    mov dword [rx], 0
    mov eax, [scrh]
    sub eax, 30
    mov [ry], eax
    mov eax, [scrw]
    mov [rw], eax
    mov dword [rh], 30
    mov dword [rcolor], C_DGRAY
    call fillrect
    ; top edge highlight
    mov eax, [scrh]
    sub eax, 30
    mov [ry], eax
    mov dword [rh], 1
    mov dword [rcolor], 0x00262E3C
    call fillrect
    ; Start button: rounded, with the Nova diamond
    mov dword [rx], 4
    mov eax, [scrh]
    sub eax, 27
    mov [ry], eax
    mov dword [rw], 80
    mov dword [rh], 24
    mov dword [rcolor], C_GREEN
    mov dword [rrad], 6
    mov dword [rround], 3
    call fill_rrect
    mov dword [dcx], 17
    mov eax, [scrh]
    sub eax, 15
    mov [dcy], eax
    mov dword [drad], 6
    mov dword [dcolor], 0x00E6ECF2
    call draw_diamond
    mov dword [drad], 2
    mov dword [dcolor], C_GREEN
    call draw_diamond
    mov dword [tcolor], C_WHITE
    mov dword [tx], 30
    mov eax, [scrh]
    sub eax, 23
    mov [ty], eax
    mov esi, txt_start
    call draw_text
    ; a button per open/minimized window
    xor ebx, ebx
    mov dword [tb_bx], 90
.b:
    cmp ebx, 18
    jae .done
    cmp byte [ws_state + ebx], 0
    je .bnext
    mov eax, [tb_bx]
    mov [rx], eax
    mov eax, [scrh]
    sub eax, 27
    mov [ry], eax
    mov dword [rw], 110
    mov dword [rh], 24
    mov dword [rcolor], 0x001E2530
    mov eax, ebx
    cmp eax, [focus]
    jne .nf
    mov dword [rcolor], 0x002C3646
.nf:
    mov dword [rrad], 6
    mov dword [rround], 3
    call fill_rrect
    cmp ebx, [focus]                 ; the window you're using gets an accent underline
    jne .nul
    push dword [rx]
    add dword [rx], 30
    mov dword [rw], 50
    add dword [ry], 21
    mov dword [rh], 2
    mov eax, [accent]
    mov [rcolor], eax
    call fillrect
    pop dword [rx]
.nul:
    mov eax, [scrh]                  ; its app icon
    sub eax, 24
    mov [ry], eax
    add dword [rx], 4
    mov eax, ebx
    call draw_app_icon
    mov dword [tcolor], C_WHITE
    mov eax, [tb_bx]
    add eax, 26
    mov [tx], eax
    mov eax, [scrh]
    sub eax, 23
    mov [ty], eax
    mov esi, [app_titles + ebx*4]
    mov ecx, 10                      ; as much of the name as fits the button
.tn:
    mov al, [esi]
    test al, al
    jz .tnd
    call draw_char
    add dword [tx], 8
    inc esi
    dec ecx
    jnz .tn
.tnd:
    add dword [tb_bx], 116
.bnext:
    inc ebx
    jmp .b
.done:
    call draw_notif_button
    call draw_clock_taskbar
    popad
    ret

; a bell button just left of the clock; opens the Notification Center
draw_notif_button:
    pushad
    mov eax, [scrw]
    sub eax, 108
    mov [rx], eax
    mov eax, [scrh]
    sub eax, 27
    mov [ry], eax
    mov dword [rw], 30
    mov dword [rh], 24
    cmp dword [notif_open], 0
    je .bg0
    mov eax, [accent]
    mov [rcolor], eax
    jmp .bgf
.bg0:
    mov dword [rcolor], 0x00242C38
.bgf:
    call fillrect
    ; bell: top nub
    mov eax, [scrw]
    sub eax, 95
    mov [rx], eax
    mov eax, [scrh]
    sub eax, 23
    mov [ry], eax
    mov dword [rw], 4
    mov dword [rh], 3
    mov dword [rcolor], C_WHITE
    call fillrect
    ; bell body
    mov eax, [scrw]
    sub eax, 97
    mov [rx], eax
    mov eax, [scrh]
    sub eax, 20
    mov [ry], eax
    mov dword [rw], 8
    mov dword [rh], 7
    call fillrect
    ; bell rim
    mov eax, [scrw]
    sub eax, 99
    mov [rx], eax
    mov eax, [scrh]
    sub eax, 13
    mov [ry], eax
    mov dword [rw], 12
    mov dword [rh], 2
    call fillrect
    ; clapper
    mov eax, [scrw]
    sub eax, 94
    mov [rx], eax
    mov eax, [scrh]
    sub eax, 11
    mov [ry], eax
    mov dword [rw], 2
    mov dword [rh], 2
    call fillrect
    popad
    ret

; draw the 12-hour clock (e.g. "6:42p") at the far-right of the taskbar
draw_clock_taskbar:
    pushad
    call read_rtc
    ; ---- convert 24h -> 12h with am/pm ----
    movzx eax, byte [rtc_hour]
    mov byte [clk_ap], 'a'
    cmp eax, 12
    jb .am
    mov byte [clk_ap], 'p'
    cmp eax, 12
    je .hok
    sub eax, 12
    jmp .hok
.am:
    test eax, eax
    jnz .hok
    mov eax, 12                  ; midnight -> 12a
.hok:
    mov edi, clkbuf
    cmp eax, 10                  ; hour, no leading zero
    jb .h1
    mov byte [edi], '1'
    inc edi
    sub eax, 10
.h1:
    add al, '0'
    mov [edi], al
    inc edi
    mov byte [edi], ':'
    inc edi
    movzx eax, byte [rtc_min]    ; minutes, two digits
    xor edx, edx
    mov ecx, 10
    div ecx
    add al, '0'
    mov [edi], al
    inc edi
    add dl, '0'
    mov [edi], dl
    inc edi
    mov al, [clk_ap]
    mov [edi], al
    inc edi
    mov byte [edi], 0
    ; ---- chip + draw ----
    mov eax, [scrw]
    sub eax, 72
    mov [rx], eax
    mov eax, [scrh]
    sub eax, 27
    mov [ry], eax
    mov dword [rw], 68
    mov dword [rh], 24
    mov dword [rcolor], C_DGRAY
    call fillrect
    mov eax, [scrw]
    sub eax, 64
    mov [tx], eax
    mov eax, [scrh]
    sub eax, 23
    mov [ty], eax
    mov dword [tcolor], C_WHITE
    mov esi, clkbuf
    call draw_text
    popad
    ret

; ---- z-order + window state ----
z_remove:                    ; remove window EAX from zorder
    xor ecx, ecx
    xor edx, edx
.l:
    cmp ecx, [zcount]
    jae .done
    movzx ebx, byte [zorder + ecx]
    cmp ebx, eax
    je .skip
    mov [zorder + edx], bl
    inc edx
.skip:
    inc ecx
    jmp .l
.done:
    mov [zcount], edx
    ret

z_bring_front:               ; move window EAX to top of z-order
    call z_remove
    mov ecx, [zcount]
    mov [zorder + ecx], al
    inc dword [zcount]
    ret

z_top_open:                  ; -> EAX = topmost OPEN window id, or -1
    mov esi, [zcount]
.l:
    dec esi
    js .no
    movzx eax, byte [zorder + esi]
    cmp byte [ws_state + eax], 1
    jne .l
    ret
.no:
    mov eax, -1
    ret

open_window:                 ; EAX = app id -> open/show its window on top
    cmp byte [ws_state + eax], 0
    jne .exists
    mov ebx, [def_x + eax*4]
    mov [ws_x + eax*4], ebx
    mov ebx, [def_y + eax*4]
    mov [ws_y + eax*4], ebx
    mov ebx, [def_w + eax*4]
    mov [ws_w + eax*4], ebx
    mov ebx, [def_h + eax*4]
    mov [ws_h + eax*4], ebx
.exists:
    mov byte [ws_state + eax], 1
    mov [focus], eax
    call z_bring_front
    cmp eax, 8                   ; Files -> refresh the directory listing
    jne .nf
    mov dword [files_dirty], 1
    mov dword [desk_dirty], 1
.nf:
    cmp eax, 11                  ; screensaver -> gentle melody
    jne .x
    call play_saver_tune
.x:
    ret

focus_window:                ; EAX = id -> restore if minimized, focus, raise
    cmp byte [ws_state + eax], 2
    jne .ok
    mov byte [ws_state + eax], 1
.ok:
    mov [focus], eax
    call z_bring_front
    ret

minimize_window:             ; EAX = id
    mov byte [ws_state + eax], 2
    call z_top_open
    mov [focus], eax
    ret

maximize_toggle:             ; EAX = id
    cmp byte [ws_max + eax], 0
    jne .restore
    ; save current geometry
    mov ebx, [ws_x + eax*4]
    mov [ws_sx + eax*4], ebx
    mov ebx, [ws_y + eax*4]
    mov [ws_sy + eax*4], ebx
    mov ebx, [ws_w + eax*4]
    mov [ws_sw + eax*4], ebx
    mov ebx, [ws_h + eax*4]
    mov [ws_sh + eax*4], ebx
    ; fill the screen (below top bar, above taskbar)
    mov dword [ws_x + eax*4], 2
    mov dword [ws_y + eax*4], 30
    mov ebx, [scrw]
    sub ebx, 4
    mov [ws_w + eax*4], ebx
    mov ebx, [scrh]
    sub ebx, 64
    mov [ws_h + eax*4], ebx
    mov byte [ws_max + eax], 1
    ret
.restore:
    mov ebx, [ws_sx + eax*4]
    mov [ws_x + eax*4], ebx
    mov ebx, [ws_sy + eax*4]
    mov [ws_y + eax*4], ebx
    mov ebx, [ws_sw + eax*4]
    mov [ws_w + eax*4], ebx
    mov ebx, [ws_sh + eax*4]
    mov [ws_h + eax*4], ebx
    mov byte [ws_max + eax], 0
    ret

close_window:                ; EAX = id
    mov byte [ws_state + eax], 0
    call z_remove
    call z_top_open
    mov [focus], eax
    ret

; ---- hit testing ----
find_window_at:              ; -> EAX = topmost open window under cursor, or -1
    mov esi, [zcount]
.l:
    dec esi
    js .no
    movzx eax, byte [zorder + esi]
    cmp byte [ws_state + eax], 1
    jne .l
    mov ebx, [ws_x + eax*4]
    mov ecx, [mouse_x]
    cmp ecx, ebx
    jl .l
    add ebx, [ws_w + eax*4]
    cmp ecx, ebx
    jg .l
    mov ebx, [ws_y + eax*4]
    mov ecx, [mouse_y]
    cmp ecx, ebx
    jl .l
    add ebx, [ws_h + eax*4]
    cmp ecx, ebx
    jg .l
    ret
.no:
    mov eax, -1
    ret

hit_taskbar:                 ; -> EAX = window id if a taskbar button clicked, else -1
    mov eax, [mouse_y]
    mov ecx, [scrh]
    sub ecx, 27
    cmp eax, ecx
    jl .no
    mov ecx, [scrh]
    sub ecx, 3
    cmp eax, ecx
    jg .no
    xor ebx, ebx
    mov edx, 90
.l:
    cmp ebx, 18
    jae .no
    cmp byte [ws_state + ebx], 0
    je .lnext
    mov eax, [mouse_x]
    cmp eax, edx
    jl .adv
    mov ecx, edx
    add ecx, 110
    cmp eax, ecx
    jg .adv
    mov eax, ebx
    ret
.adv:
    add edx, 116
.lnext:
    inc ebx
    jmp .l
.no:
    mov eax, -1
    ret

; handle a click within window [drag_win]: close/min/resize/title/body
check_regions:
    mov eax, [drag_win]
    ; close button
    mov ebx, [ws_x + eax*4]
    add ebx, [ws_w + eax*4]
    sub ebx, 20
    mov ecx, [mouse_x]
    cmp ecx, ebx
    jl .nclose
    add ebx, 16
    cmp ecx, ebx
    jg .nclose
    mov ebx, [ws_y + eax*4]
    add ebx, 3
    mov ecx, [mouse_y]
    cmp ecx, ebx
    jl .nclose
    add ebx, 16
    cmp ecx, ebx
    jg .nclose
    call close_window
    call recompose
    ret
.nclose:
    mov eax, [drag_win]
    ; minimize button
    mov ebx, [ws_x + eax*4]
    add ebx, [ws_w + eax*4]
    sub ebx, 40
    mov ecx, [mouse_x]
    cmp ecx, ebx
    jl .nmin
    add ebx, 16
    cmp ecx, ebx
    jg .nmin
    mov ebx, [ws_y + eax*4]
    add ebx, 3
    mov ecx, [mouse_y]
    cmp ecx, ebx
    jl .nmin
    add ebx, 16
    cmp ecx, ebx
    jg .nmin
    call minimize_window
    call recompose
    ret
.nmin:
    mov eax, [drag_win]
    ; maximize button
    mov ebx, [ws_x + eax*4]
    add ebx, [ws_w + eax*4]
    sub ebx, 60
    mov ecx, [mouse_x]
    cmp ecx, ebx
    jl .nmax
    add ebx, 16
    cmp ecx, ebx
    jg .nmax
    mov ebx, [ws_y + eax*4]
    add ebx, 3
    mov ecx, [mouse_y]
    cmp ecx, ebx
    jl .nmax
    add ebx, 16
    cmp ecx, ebx
    jg .nmax
    call maximize_toggle
    call recompose
    ret
.nmax:
    mov eax, [drag_win]
    ; resize grip (bottom-right corner)
    mov ebx, [ws_x + eax*4]
    add ebx, [ws_w + eax*4]
    sub ebx, 14
    mov ecx, [mouse_x]
    cmp ecx, ebx
    jl .ngrip
    mov ebx, [ws_y + eax*4]
    add ebx, [ws_h + eax*4]
    sub ebx, 14
    mov ecx, [mouse_y]
    cmp ecx, ebx
    jl .ngrip
    mov byte [drag_mode], 2
    call ol_begin
    ret
.ngrip:
    mov eax, [drag_win]
    ; title bar -> start move
    mov ebx, [ws_y + eax*4]
    mov ecx, [mouse_y]
    cmp ecx, ebx
    jl .body
    add ebx, TITLE_H
    cmp ecx, ebx
    jg .body
    mov byte [drag_mode], 1
    mov ebx, [mouse_x]
    sub ebx, [ws_x + eax*4]
    mov [drag_dx], ebx
    mov ebx, [mouse_y]
    sub ebx, [ws_y + eax*4]
    mov [drag_dy], ebx
    call ol_begin
    ret
.body:
    mov eax, [drag_win]
    cmp eax, 1
    je .bcalc
    cmp eax, 7
    je .bpaint
    cmp eax, 9
    je .bset
    cmp eax, 12
    je .bsnd
    cmp eax, 8
    je .bfile
    cmp eax, 5
    je .bedit
    cmp eax, 14
    je .bmus
    cmp eax, 16
    je .btaskmgr
    ret
.bmus:
    call load_win_geom          ; con_* = Music Maker window
    call music_click
    ret
.btaskmgr:
    call load_win_geom          ; con_* = Task Manager window
    call taskmgr_click
    ret
.bedit:
    call load_win_geom          ; con_* = editor window
    ; Save button hit-test (top-right of body, 60x20 at con_y0+2)
    mov eax, [con_cols]
    shl eax, 3
    add eax, [con_x0]
    sub eax, 66
    mov ebx, [mouse_x]
    cmp ebx, eax
    jl .ret_e
    mov eax, [con_y0]
    add eax, 2
    mov ecx, [mouse_y]
    cmp ecx, eax
    jl .ret_e
    add eax, 20
    cmp ecx, eax
    jg .ret_e
    call ed_do_save
.ret_e:
    ret
.bfile:
    call load_win_geom
    call file_click
    ret
.bset:
    call load_win_geom
    call settings_click
    ret
.bsnd:
    call load_win_geom
    call sound_click
    ret
.bcalc:
    call load_win_geom
    call calc_click
    call recompose
    ret
.bpaint:
    call load_win_geom          ; con_* = paint window
    ; palette row click?
    mov eax, [mouse_y]
    mov ebx, [con_y0]
    cmp eax, ebx
    jl .startpaint
    add ebx, 20
    cmp eax, ebx
    jg .startpaint
    ; in size-button area?
    mov eax, [mouse_x]
    mov ebx, [con_x0]
    add ebx, 216
    cmp eax, ebx
    jge .szpick
    ; colour swatch
    mov eax, [mouse_x]
    sub eax, [con_x0]
    js .pdone
    xor edx, edx
    mov ecx, 26
    div ecx
    cmp eax, 8
    jae .pdone
    mov ecx, [paint_pal + eax*4]
    mov [paint_color], ecx
    jmp .pdone
.szpick:
    ; Clear button area?
    mov eax, [mouse_x]
    mov ebx, [con_x0]
    add ebx, 310
    cmp eax, ebx
    jl .szonly
    call paint_init             ; wipe canvas to white
    call recompose
    jmp .pdone
.szonly:
    mov eax, [mouse_x]
    sub eax, [con_x0]
    sub eax, 216
    xor edx, edx
    mov ecx, 28
    div ecx
    cmp eax, 0
    je .s0
    cmp eax, 1
    je .s1
    cmp eax, 2
    je .s2
    jmp .pdone
.s0:
    mov dword [brush_sz], 3
    jmp .pdone
.s1:
    mov dword [brush_sz], 6
    jmp .pdone
.s2:
    mov dword [brush_sz], 10
    jmp .pdone
.startpaint:
    mov byte [drag_mode], 3
    call paint_dot
.pdone:
    ret

do_move:
    mov eax, [drag_win]
    mov ebx, [mouse_x]
    sub ebx, [drag_dx]
    cmp ebx, 2
    jge .x1
    mov ebx, 2
.x1:
    mov ecx, [scrw]
    sub ecx, [ws_w + eax*4]
    sub ecx, 2
    cmp ebx, ecx
    jle .x2
    mov ebx, ecx
.x2:
    mov [ws_x + eax*4], ebx
    mov ebx, [mouse_y]
    sub ebx, [drag_dy]
    cmp ebx, 30
    jge .y1
    mov ebx, 30
.y1:
    mov ecx, [scrh]
    sub ecx, [ws_h + eax*4]
    sub ecx, 34
    cmp ebx, ecx
    jle .y2
    mov ebx, ecx
.y2:
    mov [ws_y + eax*4], ebx
    call recompose
    ret

do_resize:
    mov eax, [drag_win]
    mov ebx, [mouse_x]
    sub ebx, [ws_x + eax*4]
    cmp ebx, 220
    jge .w1
    mov ebx, 220
.w1:
    mov ecx, [scrw]
    sub ecx, [ws_x + eax*4]
    sub ecx, 4
    cmp ebx, ecx
    jle .w2
    mov ebx, ecx
.w2:
    mov [ws_w + eax*4], ebx
    mov ebx, [mouse_y]
    sub ebx, [ws_y + eax*4]
    cmp ebx, 130
    jge .h1
    mov ebx, 130
.h1:
    mov ecx, [scrh]
    sub ecx, [ws_y + eax*4]
    sub ecx, 34
    cmp ebx, ecx
    jle .h2
    mov ebx, ecx
.h2:
    mov [ws_h + eax*4], ebx
    call recompose
    ret

; draw the current app's content in the window body
draw_app_content:
    mov eax, [cur_app]
    cmp eax, 1
    je draw_calc_content
    cmp eax, 2
    je draw_clock_content
    cmp eax, 3
    je draw_sys_content
    cmp eax, 4
    je draw_about_content
    cmp eax, 5
    je draw_editor_content
    cmp eax, 6
    je draw_browser_content
    cmp eax, 7
    je draw_paint_content
    cmp eax, 8
    je draw_file_content
    cmp eax, 9
    je draw_settings_content
    cmp eax, 10
    je draw_bounce_content
    cmp eax, 11
    je draw_saver_content
    cmp eax, 12
    je draw_sound_content
    cmp eax, 13
    je draw_snake_content
    cmp eax, 14
    je draw_music_content
    cmp eax, 15
    je draw_devmgr_content
    cmp eax, 16
    je draw_taskmgr_content
    cmp eax, 17
    je draw_admin_content
    ; default: Terminal
    mov esi, tbuf
    call draw_grid
    ret

; ---- Snake game ----
snake_init:
    pushad
    mov dword [slen], 4
    mov dword [sdir], 3          ; right
    mov byte [sdead], 0
    ; body cells (head first): (10,8),(9,8),(8,8),(7,8)
    mov byte [snx+0], 10
    mov byte [sny+0], 8
    mov byte [snx+1], 9
    mov byte [sny+1], 8
    mov byte [snx+2], 8
    mov byte [sny+2], 8
    mov byte [snx+3], 7
    mov byte [sny+3], 8
    mov dword [sfx], 18
    mov dword [sfy], 6
    popad
    ret

place_food:                  ; pseudo-random food from the frame counter
    mov eax, [frame]
    imul eax, 7
    add eax, 13
    xor edx, edx
    mov ecx, SGW
    div ecx
    mov [sfx], edx
    mov eax, [frame]
    imul eax, 11
    add eax, 5
    xor edx, edx
    mov ecx, SGH
    div ecx
    mov [sfy], edx
    ret

snake_step:
    cmp byte [sdead], 0
    jne .ret
    ; new head = body[0] + dir
    movzx eax, byte [snx+0]
    movzx ebx, byte [sny+0]
    mov ecx, [sdir]
    cmp ecx, 0
    je .up
    cmp ecx, 1
    je .down
    cmp ecx, 2
    je .left
    inc eax                     ; right
    jmp .have
.up:
    dec ebx
    jmp .have
.down:
    inc ebx
    jmp .have
.left:
    dec eax
    jmp .have
.have:
    ; wall collision
    cmp eax, 0
    jl .die
    cmp eax, SGW
    jge .die
    cmp ebx, 0
    jl .die
    cmp ebx, SGH
    jge .die
    ; self collision (check body[0..slen-1])
    mov [.nhx], al
    mov [.nhy], bl
    xor esi, esi
.sc:
    cmp esi, [slen]
    jae .scdone
    movzx ecx, byte [snx+esi]
    cmp cl, [.nhx]
    jne .scn
    movzx ecx, byte [sny+esi]
    cmp cl, [.nhy]
    je .die
.scn:
    inc esi
    jmp .sc
.scdone:
    ; food?
    mov eax, [sfx]
    movzx ebx, byte [.nhx]
    cmp eax, ebx
    jne .noeat
    mov eax, [sfy]
    movzx ebx, byte [.nhy]
    cmp eax, ebx
    jne .noeat
    mov byte [.grow], 1
    jmp .shift
.noeat:
    mov byte [.grow], 0
.shift:
    ; shift body up by one: for i=slen..1: body[i]=body[i-1]
    mov esi, [slen]
.sh:
    cmp esi, 1
    jl .sh2
    mov ecx, esi
    dec ecx
    mov al, [snx+ecx]
    mov [snx+esi], al
    mov al, [sny+ecx]
    mov [sny+esi], al
    dec esi
    jmp .sh
.sh2:
    mov al, [.nhx]
    mov [snx+0], al
    mov al, [.nhy]
    mov [sny+0], al
    cmp byte [.grow], 0
    je .ret
    inc dword [slen]
    call place_food
.ret:
    ret
.die:
    mov byte [sdead], 1
    ret
.nhx: db 0
.nhy: db 0
.grow: db 0

draw_snake_content:
    pushad
    ; green border around the play field
    mov eax, [con_x0]
    sub eax, 3
    mov [rx], eax
    mov eax, [con_y0]
    sub eax, 3
    mov [ry], eax
    mov dword [rw], SGW*SCELL + 6
    mov dword [rh], SGH*SCELL + 6
    mov dword [rcolor], 0x0030D060
    call fillrect
    ; play field (dark) inside the border
    mov eax, [con_x0]
    mov [rx], eax
    mov eax, [con_y0]
    mov [ry], eax
    mov dword [rw], SGW*SCELL
    mov dword [rh], SGH*SCELL
    mov dword [rcolor], 0x00101820
    call fillrect
    ; food
    mov eax, [sfx]
    imul eax, SCELL
    add eax, [con_x0]
    add eax, 1
    mov [rx], eax
    mov eax, [sfy]
    imul eax, SCELL
    add eax, [con_y0]
    add eax, 1
    mov [ry], eax
    mov dword [rw], SCELL-2
    mov dword [rh], SCELL-2
    mov dword [rcolor], 0x00E05040
    call fillrect
    ; snake body
    xor esi, esi
.b:
    cmp esi, [slen]
    jae .bd
    movzx eax, byte [snx+esi]
    imul eax, SCELL
    add eax, [con_x0]
    add eax, 1
    mov [rx], eax
    movzx eax, byte [sny+esi]
    imul eax, SCELL
    add eax, [con_y0]
    add eax, 1
    mov [ry], eax
    mov dword [rw], SCELL-2
    mov dword [rh], SCELL-2
    mov dword [rcolor], 0x0040E070
    cmp esi, 0
    jne .draw
    mov dword [rcolor], 0x0080FFA0    ; head brighter
.draw:
    call fillrect
    inc esi
    jmp .b
.bd:
    ; game over text
    cmp byte [sdead], 0
    je .done
    mov eax, [con_x0]
    add eax, 20
    mov [tx], eax
    mov eax, [con_y0]
    add eax, SGH*SCELL + 6
    mov [ty], eax
    mov dword [tcolor], 0x00FF8080
    mov esi, snk_over
    call draw_text
.done:
    popad
    ret

snake_anim:
    inc dword [snake_cnt]        ; only step every 64th tick (playable speed)
    mov eax, [snake_cnt]
    and eax, 63
    jz .go
    ret
.go:
    pushad
    cmp byte [mouse_present], 0
    je .nc
    call restore_cursor
.nc:
    mov eax, 13
    call load_win_geom
    call snake_step
    mov dword [cur_app], 13
    call draw_snake_content
    cmp byte [mouse_present], 0
    je .done
    call save_cursor
    call draw_cursor
.done:
    popad
    ret

handle_snake_scancode:       ; AL = scancode (arrow keys via 0xE0 prefix)
    cmp al, 0xE0
    jne .ns
    mov byte [sk_ext], 1
    ret
.ns:
    cmp byte [sk_ext], 0
    je .other
    mov byte [sk_ext], 0
    cmp al, 0x48
    je .up
    cmp al, 0x50
    je .down
    cmp al, 0x4B
    je .left
    cmp al, 0x4D
    je .right
    ret
.up:
    cmp dword [sdir], 1
    je .r
    mov dword [sdir], 0
    ret
.down:
    cmp dword [sdir], 0
    je .r
    mov dword [sdir], 1
    ret
.left:
    cmp dword [sdir], 3
    je .r
    mov dword [sdir], 2
    ret
.right:
    cmp dword [sdir], 2
    je .r
    mov dword [sdir], 3
    ret
.other:
    cmp al, 0x39                ; space = restart
    jne .r
    call snake_init
.r:
    ret

draw_bounce_content:
    pushad
    mov eax, [con_x0]
    add eax, [ball_x]
    add eax, 12
    mov [dcx], eax
    mov eax, [con_y0]
    add eax, [ball_y]
    add eax, 12
    mov [dcy], eax
    mov dword [drad], 11
    mov dword [dcolor], 0x00FFC040
    call draw_diamond
    mov dword [drad], 5
    mov dword [dcolor], 0x00FFFFFF
    call draw_diamond
    popad
    ret

draw_cloud:                  ; white cloud puff cluster at [clx],[cly]
    mov eax, [clx]
    mov [dcx], eax
    mov eax, [cly]
    mov [dcy], eax
    mov dword [drad], 13
    mov dword [dcolor], 0x00F0F4FA
    call draw_diamond
    mov eax, [clx]
    sub eax, 16
    mov [dcx], eax
    mov eax, [cly]
    add eax, 4
    mov [dcy], eax
    mov dword [drad], 9
    mov dword [dcolor], 0x00F0F4FA
    call draw_diamond
    mov eax, [clx]
    add eax, 16
    mov [dcx], eax
    mov eax, [cly]
    add eax, 4
    mov [dcy], eax
    mov dword [drad], 9
    mov dword [dcolor], 0x00F0F4FA
    call draw_diamond
    ret

draw_saver_content:          ; original scenic "hills + sky" wallpaper
    pushad
    mov eax, [con_cols]
    shl eax, 3
    mov [bnc_w], eax
    mov eax, [con_rows]
    shl eax, 4
    mov [bnc_h], eax
    ; sky fill
    mov eax, [con_x0]
    mov [rx], eax
    mov eax, [con_y0]
    mov [ry], eax
    mov eax, [bnc_w]
    mov [rw], eax
    mov eax, [bnc_h]
    mov [rh], eax
    mov dword [rcolor], 0x004E8CC0
    call fillrect
    ; darker upper sky
    mov eax, [con_x0]
    mov [rx], eax
    mov eax, [con_y0]
    mov [ry], eax
    mov eax, [bnc_w]
    mov [rw], eax
    mov eax, [bnc_h]
    imul eax, 3
    xor edx, edx
    mov ecx, 10
    div ecx
    mov [rh], eax
    mov dword [rcolor], 0x003A6EAC
    call fillrect
    ; ground (green), bottom 45%
    mov eax, [bnc_h]
    imul eax, 55
    xor edx, edx
    mov ecx, 100
    div ecx
    add eax, [con_y0]
    mov [ry], eax
    mov eax, [con_x0]
    mov [rx], eax
    mov eax, [bnc_w]
    mov [rw], eax
    mov eax, [bnc_h]
    imul eax, 45
    xor edx, edx
    mov ecx, 100
    div ecx
    mov [rh], eax
    mov dword [rcolor], 0x004A9A3A
    call fillrect
    ; rolling hills (green diamonds at the horizon)
    mov eax, [con_x0]
    add eax, 60
    mov [dcx], eax
    mov eax, [bnc_h]
    imul eax, 55
    xor edx, edx
    mov ecx, 100
    div ecx
    add eax, [con_y0]
    mov [dcy], eax
    mov dword [drad], 52
    mov dword [dcolor], 0x00368030
    call draw_diamond
    mov eax, [con_x0]
    add eax, [bnc_w]
    sub eax, 90
    mov [dcx], eax
    mov eax, [bnc_h]
    imul eax, 55
    xor edx, edx
    mov ecx, 100
    div ecx
    add eax, [con_y0]
    mov [dcy], eax
    mov dword [drad], 64
    mov dword [dcolor], 0x003E8C34
    call draw_diamond
    ; sun (top-right)
    mov eax, [con_x0]
    add eax, [bnc_w]
    sub eax, 64
    mov [dcx], eax
    mov eax, [con_y0]
    add eax, 44
    mov [dcy], eax
    mov dword [drad], 30
    mov dword [dcolor], 0x00FFE060
    call draw_diamond
    mov dword [drad], 19
    mov dword [dcolor], 0x00FFF4B0
    call draw_diamond
    ; static clouds
    mov eax, [con_x0]
    add eax, 74
    mov [clx], eax
    mov eax, [con_y0]
    add eax, 34
    mov [cly], eax
    call draw_cloud
    mov eax, [con_x0]
    add eax, 190
    mov [clx], eax
    mov eax, [con_y0]
    add eax, 60
    mov [cly], eax
    call draw_cloud
    ; drifting cloud
    mov eax, [con_x0]
    add eax, [sav_x]
    mov [clx], eax
    mov eax, [con_y0]
    add eax, 48
    mov [cly], eax
    call draw_cloud
    ; label
    mov eax, [con_x0]
    add eax, 10
    mov [tx], eax
    mov eax, [con_y0]
    add eax, [bnc_h]
    sub eax, 24
    mov [ty], eax
    mov dword [tcolor], 0x00E8F0FF
    mov esi, sav_txt
    call draw_text
    popad
    ret

draw_sound_content:
    pushad
    mov eax, [con_x0]
    add eax, 8
    mov [tx], eax
    mov eax, [con_y0]
    add eax, 4
    mov [ty], eax
    mov dword [tcolor], C_WHITE
    mov esi, snd_lbl
    call draw_text
    ; 8 piano keys
    xor ebx, ebx
.k:
    cmp ebx, 8
    jae .done
    mov eax, ebx
    imul eax, 44
    add eax, [con_x0]
    add eax, 8
    mov [rx], eax
    mov eax, [con_y0]
    add eax, 30
    mov [ry], eax
    mov dword [rw], 40
    mov dword [rh], 120
    mov dword [rcolor], 0x00E8ECF0
    call fillrect
    ; number label
    mov dword [tcolor], 0x00202830
    mov eax, [rx]
    add eax, 16
    mov [tx], eax
    mov eax, [con_y0]
    add eax, 130
    mov [ty], eax
    mov eax, ebx
    add eax, '1'
    call draw_char
    inc ebx
    jmp .k
.done:
    popad
    ret

; ---- animation ----
anim_tick:
    call music_tick              ; Music Maker: next note due? (cheap when it isn't playing)
    call hda_watchdog            ; stop the startup clip once it's played through (cheap when idle)
    inc dword [frame]
    mov eax, [frame]
    and eax, 0x00001FFF
    jz .go
    ret
.go:
    call draw_clock_taskbar      ; keep the taskbar clock ticking
    ; toast auto-dismiss after ~4 real seconds (RTC-timed)
    cmp dword [notif_timer], 0
    je .no_toast
    call now_seconds
    sub eax, [notif_start_sec]
    jns .nn
    add eax, 86400               ; midnight wrap
.nn:
    cmp eax, 4
    jb .toast_keep
    mov dword [notif_timer], 0
    call recompose               ; time up -> erase the toast
    jmp .no_toast
.toast_keep:
    call draw_toast
.no_toast:
    ; blink the editor caret when the editor is focused
    cmp dword [focus], 5
    jne .no_caret
    xor dword [ed_cursor_on], 1
    call blink_ed_caret
.no_caret:
    mov eax, [focus]
    cmp eax, 2
    je .clock
    cmp eax, 10
    je .bounce
    cmp eax, 11
    je .saver
    cmp eax, 13
    je .snake
    ret
.snake:
    cmp byte [ws_state + 13], 1
    jne .r
    call snake_anim
    ret
.clock:
    cmp byte [ws_state + 2], 1
    jne .r
    call clock_anim
.r:
    ret
.bounce:
    cmp byte [ws_state + 10], 1
    jne .r
    call bounce_anim
    ret
.saver:
    cmp byte [ws_state + 11], 1
    jne .r
    call saver_anim
    ret

; --- targeted (flicker-free) per-app animation ---
clock_anim:
    pushad
    cmp byte [mouse_present], 0
    je .nc
    call restore_cursor
.nc:
    mov eax, 2
    call load_win_geom
    mov dword [cur_app], 2
    mov eax, [con_x0]
    mov [rx], eax
    mov eax, [con_y0]
    add eax, 8
    mov [ry], eax
    mov dword [rw], 240
    mov dword [rh], 72
    mov dword [rcolor], C_CONBG
    call fillrect
    call draw_clock_content
    cmp byte [mouse_present], 0
    je .done
    call save_cursor
    call draw_cursor
.done:
    popad
    ret

bounce_anim:
    pushad
    cmp byte [mouse_present], 0
    je .nc
    call restore_cursor
.nc:
    mov eax, 10
    call load_win_geom
    ; erase the ball at its old spot
    mov eax, [con_x0]
    add eax, [ball_x]
    mov [rx], eax
    mov eax, [con_y0]
    add eax, [ball_y]
    mov [ry], eax
    mov dword [rw], 26
    mov dword [rh], 26
    mov dword [rcolor], C_CONBG
    call fillrect
    call bounce_step
    call draw_bounce_content
    cmp byte [mouse_present], 0
    je .done
    call save_cursor
    call draw_cursor
.done:
    popad
    ret

saver_anim:
    inc dword [saver_cnt]        ; slow, gentle drift (every 6th tick)
    mov eax, [saver_cnt]
    and eax, 7
    jz .go
    ret
.go:
    pushad
    cmp byte [mouse_present], 0
    je .nc
    call restore_cursor
.nc:
    mov eax, 11
    call load_win_geom
    mov dword [cur_app], 11
    call saver_step
    call draw_saver_content      ; full scene redraw (fills the body)
    cmp byte [mouse_present], 0
    je .done
    call save_cursor
    call draw_cursor
.done:
    popad
    ret

anim_redraw:                 ; redraw the focused window's body + content (+cursor)
    pushad
    cmp byte [mouse_present], 0
    je .nc
    call restore_cursor
.nc:
    mov eax, [focus]
    mov [cur_app], eax
    call load_win_geom
    mov eax, [wx]
    mov [rx], eax
    mov eax, [wy]
    add eax, TITLE_H
    mov [ry], eax
    mov eax, [ww]
    mov [rw], eax
    mov eax, [wh]
    sub eax, TITLE_H
    mov [rh], eax
    mov dword [rcolor], C_CONBG
    call fillrect
    call draw_app_content
    cmp byte [mouse_present], 0
    je .done
    call save_cursor
    call draw_cursor
.done:
    popad
    ret

bounce_step:
    mov eax, 10
    call load_win_geom
    mov eax, [con_cols]
    shl eax, 3
    sub eax, 24
    mov [bnc_w], eax
    mov eax, [con_rows]
    shl eax, 4
    sub eax, 24
    mov [bnc_h], eax
    mov eax, [ball_x]
    add eax, [ball_vx]
    cmp eax, 0
    jge .x1
    neg dword [ball_vx]
    xor eax, eax
.x1:
    cmp eax, [bnc_w]
    jle .x2
    neg dword [ball_vx]
    mov eax, [bnc_w]
.x2:
    mov [ball_x], eax
    mov eax, [ball_y]
    add eax, [ball_vy]
    cmp eax, 0
    jge .y1
    neg dword [ball_vy]
    xor eax, eax
.y1:
    cmp eax, [bnc_h]
    jle .y2
    neg dword [ball_vy]
    mov eax, [bnc_h]
.y2:
    mov [ball_y], eax
    ret

saver_step:                  ; drift the cloud horizontally (gentle bounce)
    mov eax, 11
    call load_win_geom
    mov eax, [con_cols]
    shl eax, 3
    sub eax, 50
    mov [bnc_w], eax
    mov eax, [sav_x]
    add eax, [sav_vx]
    cmp eax, 24
    jge .x1
    neg dword [sav_vx]
    mov eax, 24
.x1:
    cmp eax, [bnc_w]
    jle .x2
    neg dword [sav_vx]
    mov eax, [bnc_w]
.x2:
    mov [sav_x], eax
    ret

play_saver_tune:             ; original gentle melody (not any copyrighted tune)
    mov bx, 2712
    call play_note
    mov bx, 2281
    call play_note
    mov bx, 1810
    call play_note
    mov bx, 2032
    call play_note
    mov bx, 1522
    call play_note
    ret

sound_click:                 ; play the clicked piano key
    mov eax, [mouse_x]
    sub eax, [con_x0]
    sub eax, 8
    js .ret
    xor edx, edx
    mov ecx, 44
    div ecx
    cmp eax, 8
    jae .ret
    mov bx, [note_div + eax*4]
    call play_note
.ret:
    ret

; text line helper: draw ESI at (con_x0, con_y0+[fmline]), colour EDX
fm_textline:
    mov eax, [con_x0]
    add eax, 8
    mov [tx], eax
    mov eax, [con_y0]
    add eax, [fmline]
    mov [ty], eax
    mov [tcolor], edx
    call draw_text
    ret

; 8.3 name at [tx],[ty] via draw_char, advancing tx (framebuffer, not console)
print_83_at:
    pushad
    mov ecx, 8
    mov ebx, esi
.np:
    mov al, [ebx]
    cmp al, ' '
    je .npend
    call draw_char
    add dword [tx], 8
    inc ebx
    dec ecx
    jnz .np
.npend:
    mov al, [esi+8]
    cmp al, ' '
    je .done
    mov al, '.'
    call draw_char
    add dword [tx], 8
    mov ecx, 3
    lea ebx, [esi+8]
.ep:
    mov al, [ebx]
    cmp al, ' '
    je .done
    call draw_char
    add dword [tx], 8
    inc ebx
    dec ecx
    jnz .ep
.done:
    popad
    ret

draw_file_content:
    pushad
    ; refresh the listing from disk if something changed
    cmp dword [files_dirty], 0
    je .draw
    mov dword [files_dirty], 0
    cmp dword [has_fatfs], 0
    je .draw
    call fm_mount                ; disk or USB stick
    mov eax, [cwd_cluster]
    test eax, eax
    jnz .rd
    mov eax, [fs_rootclus]
    mov [cwd_cluster], eax
.rd:
    mov eax, [cwd_cluster]
    call dir_read
    call fm_unmount
    cmp dword [fm_vol], 0
    je .draw
    cmp dword [usb_ready], 0
    jne .draw
    call fm_use_disk             ; the stick stopped answering (unplugged)
    mov dword [files_dirty], 1
    mov esi, nt_usb_out1
    mov edi, nt_usb_out2
    call notify
.draw:
    cmp dword [has_fatfs], 0
    jne .havefs
    mov eax, [con_x0]
    add eax, 8
    mov [tx], eax
    mov eax, [con_y0]
    add eax, 10
    mov [ty], eax
    mov dword [tcolor], 0x00FF8080
    mov esi, fm_err1
    call draw_text
    mov eax, [con_x0]
    add eax, 8
    mov [tx], eax
    mov eax, [con_y0]
    add eax, 30
    mov [ty], eax
    mov esi, fm_err2
    call draw_text
    popad
    ret
.havefs:
    ; toolbar: New File
    mov eax, [con_x0]
    add eax, 8
    mov [rx], eax
    mov eax, [con_y0]
    add eax, 4
    mov [ry], eax
    mov dword [rw], 84
    mov dword [rh], 20
    mov dword [rcolor], 0x00305070
    call fillrect
    mov eax, [rx]
    add eax, 6
    mov [tx], eax
    mov eax, [ry]
    add eax, 2
    mov [ty], eax
    mov dword [tcolor], C_WHITE
    mov esi, fm_newf
    call draw_text
    ; New Folder
    mov eax, [con_x0]
    add eax, 96
    mov [rx], eax
    mov eax, [con_y0]
    add eax, 4
    mov [ry], eax
    mov dword [rw], 96
    mov dword [rh], 20
    mov dword [rcolor], 0x00504030
    call fillrect
    mov eax, [rx]
    add eax, 6
    mov [tx], eax
    mov eax, [ry]
    add eax, 2
    mov [ty], eax
    mov esi, fm_newd
    call draw_text
    ; Up (only if not at root; always on the USB stick)
    cmp dword [fm_vol], 0
    jne .upbtn
    mov eax, [cwd_cluster]
    cmp eax, [fs_rootclus]
    je .rows
.upbtn:
    mov eax, [con_x0]
    add eax, 200
    mov [rx], eax
    mov eax, [con_y0]
    add eax, 4
    mov [ry], eax
    mov dword [rw], 48
    mov dword [rh], 20
    mov dword [rcolor], 0x00404850
    call fillrect
    mov eax, [rx]
    add eax, 12
    mov [tx], eax
    mov eax, [ry]
    add eax, 2
    mov [ty], eax
    mov esi, fm_up
    call draw_text
    ; Empty Trash button (only when inside the Trash folder, never on the USB stick)
    cmp dword [fm_vol], 0
    jne .rows
    mov eax, [cwd_cluster]
    cmp eax, [trash_cluster]
    jne .rows
    mov eax, [con_x0]
    add eax, 252
    mov [rx], eax
    mov eax, [con_y0]
    add eax, 4
    mov [ry], eax
    mov dword [rw], 96
    mov dword [rh], 20
    mov dword [rcolor], 0x00803838
    call fillrect
    mov eax, [rx]
    add eax, 6
    mov [tx], eax
    mov eax, [ry]
    add eax, 2
    mov [ty], eax
    mov dword [tcolor], C_WHITE
    mov esi, fm_empty_btn
    call draw_text
.rows:
    cmp dword [fm_vol], 0
    jne .usblbl
    cmp dword [install_mode], 0  ; installed systems have our own USB driver
    je .nousb
    mov eax, [cwd_cluster]
    cmp eax, [fs_rootclus]
    jne .nousb
    mov eax, [con_x0]            ; [ USB Drive ]
    add eax, 252
    mov [rx], eax
    mov eax, [con_y0]
    add eax, 4
    mov [ry], eax
    mov dword [rw], 96
    mov dword [rh], 20
    mov dword [rcolor], 0x00286048
    call fillrect
    mov eax, [rx]
    add eax, 12
    mov [tx], eax
    mov eax, [ry]
    add eax, 2
    mov [ty], eax
    mov dword [tcolor], C_WHITE
    mov esi, fm_usb_lbl
    call draw_text
    jmp .nousb
.usblbl:
    mov eax, [con_x0]            ; [ Refresh ]
    add eax, 252
    mov [rx], eax
    mov eax, [con_y0]
    add eax, 4
    mov [ry], eax
    mov dword [rw], 96
    mov dword [rh], 20
    mov dword [rcolor], 0x00286048
    call fillrect
    mov eax, [rx]
    add eax, 20
    mov [tx], eax
    mov eax, [ry]
    add eax, 2
    mov [ty], eax
    mov dword [tcolor], C_WHITE
    mov esi, fm_usb_ref
    call draw_text
    mov eax, [con_x0]
    add eax, 356
    mov [tx], eax
    mov eax, [con_y0]
    add eax, 6
    mov [ty], eax
    mov dword [tcolor], 0x0070D890
    mov esi, fm_usb_ro
    call draw_text
.nousb:
    call sys_warn_draw           ; SYSTEM folder locked? draw the warning instead
    test al, al
    jnz .fdone
    xor ebx, ebx
.row:
    cmp ebx, [dir_count]
    jae .listed
    cmp ebx, 14
    jae .listed
    mov eax, ebx
    imul eax, 20
    add eax, [con_y0]
    add eax, 32
    mov [fmrow_y], eax
    ; icon square (folder = yellow, file = blue)
    mov eax, [con_x0]
    add eax, 10
    mov [rx], eax
    mov eax, [fmrow_y]
    add eax, 2
    mov [ry], eax
    mov dword [rw], 12
    mov dword [rh], 12
    mov al, [dir_attr + ebx]
    test al, 0x10
    jz .fic
    mov dword [rcolor], 0x00E0C040
    jmp .icf
.fic:
    mov dword [rcolor], 0x005090D0
.icf:
    call fillrect
    mov eax, [con_x0]
    add eax, 30
    mov [tx], eax
    mov eax, [fmrow_y]
    mov [ty], eax
    mov dword [tcolor], C_WHITE
    test byte [dir_attr + ebx], 0x02   ; hidden/system -> faded, like Windows
    jz .fwhite
    mov dword [tcolor], 0x008A96A6
.fwhite:
    mov eax, ebx
    imul eax, 11
    lea esi, [dir_name + eax]
    call print_83_at
    ; R (rename) button
    mov eax, [con_cols]
    shl eax, 3
    add eax, [con_x0]
    sub eax, 48
    mov [rx], eax
    mov eax, [fmrow_y]
    mov [ry], eax
    mov dword [rw], 18
    mov dword [rh], 16
    mov dword [rcolor], 0x00405565   ; blue = rename
    cmp dword [fm_vol], 0
    jne .rbtncol
    mov eax, [cwd_cluster]
    cmp eax, [trash_cluster]
    jne .rbtncol
    mov dword [rcolor], 0x00268F5E   ; green = restore (inside Trash)
.rbtncol:
    call fillrect
    mov eax, [rx]
    add eax, 5
    mov [tx], eax
    mov eax, [ry]
    add eax, 1
    mov [ty], eax
    mov dword [tcolor], C_WHITE
    mov al, 'R'
    call draw_char
    ; X (delete) button
    mov eax, [con_cols]
    shl eax, 3
    add eax, [con_x0]
    sub eax, 26
    mov [rx], eax
    mov eax, [fmrow_y]
    mov [ry], eax
    mov dword [rw], 18
    mov dword [rh], 16
    mov dword [rcolor], 0x00803838
    call fillrect
    mov eax, [rx]
    add eax, 5
    mov [tx], eax
    mov eax, [ry]
    add eax, 1
    mov [ty], eax
    mov dword [tcolor], C_WHITE
    mov al, 'X'
    call draw_char
    inc ebx
    jmp .row
.listed:
    ; empty-folder hint
    cmp dword [dir_count], 0
    jne .fdone
    mov eax, [con_x0]
    add eax, 10
    mov [tx], eax
    mov eax, [con_y0]
    add eax, 36
    mov [ty], eax
    mov dword [tcolor], 0x00808C98
    mov esi, fm_empty
    call draw_text
.fdone:
    ; error line (folder/disk full)
    cmp byte [fs_err], 0
    je .noerr
    mov eax, [con_x0]
    add eax, 8
    mov [tx], eax
    mov eax, [con_y0]
    add eax, 322
    mov [ty], eax
    mov dword [tcolor], 0x00FF8080
    mov esi, fm_full
    call draw_text
.noerr:
    ; rename input box (overlays the toolbar when active)
    cmp dword [rename_mode], 0
    je .nrb
    mov eax, [con_x0]
    add eax, 6
    mov [rx], eax
    mov eax, [con_y0]
    add eax, 2
    mov [ry], eax
    mov eax, [con_cols]
    shl eax, 3
    sub eax, 16
    mov [rw], eax
    mov dword [rh], 24
    mov dword [rcolor], 0x00202A38
    call fillrect
    mov eax, [con_x0]
    add eax, 12
    mov [tx], eax
    mov eax, [con_y0]
    add eax, 6
    mov [ty], eax
    mov dword [tcolor], 0x00FFE080
    mov esi, rn_prompt
    call draw_text
    mov eax, [con_x0]
    add eax, 92
    mov [rn_tx0], eax
    mov [tx], eax
    mov dword [tcolor], C_WHITE
    mov esi, rename_buf
    call draw_text
    mov eax, [rename_len]
    shl eax, 3
    add eax, [rn_tx0]
    mov [tx], eax
    mov al, '_'
    call draw_char
.nrb:
    popad
    ret

draw_settings_tabs:
    pushad
    xor ebx, ebx
.t:
    cmp ebx, 3
    jae .done
    mov eax, ebx
    imul eax, 94
    add eax, [con_x0]
    add eax, 8
    mov [rx], eax
    mov eax, [con_y0]
    add eax, 4
    mov [ry], eax
    mov dword [rw], 88
    mov dword [rh], 26
    cmp ebx, [set_tab]
    jne .inact
    mov eax, [accent]
    mov [rcolor], eax
    jmp .fill
.inact:
    mov dword [rcolor], 0x00242C38
.fill:
    call fillrect
    mov eax, [rx]
    add eax, 14
    mov [tx], eax
    mov eax, [ry]
    add eax, 5
    mov [ty], eax
    mov dword [tcolor], C_WHITE
    mov esi, [set_tabs + ebx*4]
    call draw_text
    inc ebx
    jmp .t
.done:
    popad
    ret

; read ECX (<=64) sectors from partition-relative LBA EAX into buffer EDI
fs_read_multi:
    pushad
    add eax, [part_base]
    mov [dap_count], cx
    mov [dap16_lba], eax
    mov dword [dap16_lba+4], 0
    mov al, [0x1014]
    mov [thunk_drive], al
    mov byte [thunk_cmd], 0x42
    call bios_xfer
    movzx ecx, word [dap_count]
    shl ecx, 7
    mov esi, BIOSBUF
    rep movsd
    mov word [dap_count], 1
    popad
    ret

; scan the FAT: [stor_total]=data clusters, [stor_free]=free clusters
count_free_clusters:
    pushad
    call fat_mount
    mov eax, [fs_totsec]
    sub eax, [fs_data_start]
    xor edx, edx
    mov ecx, [fs_spc]
    div ecx
    mov [stor_total], eax
    mov dword [stor_free], 0
    mov dword [stor_fsec], 0
.blk:
    mov eax, [stor_fsec]
    cmp eax, [fs_fatsz]
    jae .adjust
    mov ecx, [fs_fatsz]
    sub ecx, eax
    cmp ecx, 64
    jbe .cok
    mov ecx, 64
.cok:
    mov [stor_n], ecx
    mov eax, [fs_rsvd]
    add eax, [stor_fsec]
    mov ecx, [stor_n]
    mov edi, STORBUF
    call fs_read_multi
    mov ecx, [stor_n]
    shl ecx, 7
    mov esi, STORBUF
.cl:
    test ecx, ecx
    jz .nxt
    mov eax, [esi]
    and eax, 0x0FFFFFFF
    jnz .nf
    inc dword [stor_free]
.nf:
    add esi, 4
    dec ecx
    jmp .cl
.nxt:
    mov eax, [stor_n]
    add [stor_fsec], eax
    jmp .blk
.adjust:
    mov eax, [fs_fatsz]         ; free = zeros - (entries beyond the valid range)
    shl eax, 7
    sub eax, [stor_total]
    sub eax, 2
    mov ebx, [stor_free]
    sub ebx, eax
    mov [stor_free], ebx
    popad
    ret

; draw a "Used: N MB" style line: ESI=label at fmline, EAX=clusters -> MB
stor_line:                       ; ESI=label, EAX=clusters, [fmline]=y offset
    pushad
    mov [stor_tmp], eax
    mov eax, [con_x0]
    add eax, 8
    mov [tx], eax
    mov eax, [con_y0]
    add eax, [fmline]
    mov [ty], eax
    mov dword [tcolor], C_TEXT
    call draw_text
    mov eax, [con_x0]
    add eax, 110
    mov [tx], eax
    mov dword [tcolor], C_WHITE
    mov eax, [stor_tmp]
    shr eax, 11                  ; clusters/2048 = MB (512-byte clusters)
    call draw_num
    mov al, ' '
    call draw_char
    add dword [tx], 8
    mov al, 'M'
    call draw_char
    add dword [tx], 8
    mov al, 'B'
    call draw_char
    popad
    ret

draw_storage_tab:
    pushad
    cmp dword [has_fatfs], 0
    jne .have
    mov dword [fmline], 60
    mov edx, 0x00FF8080
    mov esi, stor_none
    call fm_textline
    popad
    ret
.have:
    cmp dword [stor_scanned], 0
    jne .draw
    call count_free_clusters
    mov dword [stor_scanned], 1
.draw:
    mov dword [fmline], 46
    mov edx, C_WHITE
    mov esi, stor_hdr
    call fm_textline
    mov dword [fmline], 80
    mov esi, stor_total_l
    mov eax, [stor_total]
    call stor_line
    mov dword [fmline], 104
    mov esi, stor_used_l
    mov eax, [stor_total]
    sub eax, [stor_free]
    call stor_line
    mov dword [fmline], 128
    mov esi, stor_free_l
    mov eax, [stor_free]
    call stor_line
    ; usage bar
    mov eax, [con_x0]
    add eax, 8
    mov [rx], eax
    mov eax, [con_y0]
    add eax, 160
    mov [ry], eax
    mov dword [rw], 300
    mov dword [rh], 18
    mov dword [rcolor], 0x00202A38
    call fillrect
    ; filled portion = 300 * used / total
    mov eax, [stor_total]
    sub eax, [stor_free]        ; used
    mov ebx, 300
    imul ebx
    mov ebx, [stor_total]
    test ebx, ebx
    jz .nobar
    xor edx, edx
    div ebx                     ; eax = fill width
    mov [stor_tmp], eax
    mov eax, [con_x0]
    add eax, 8
    mov [rx], eax
    mov eax, [con_y0]
    add eax, 160
    mov [ry], eax
    mov eax, [stor_tmp]
    mov [rw], eax
    mov dword [rh], 18
    mov eax, [accent]
    mov [rcolor], eax
    call fillrect
.nobar:
    popad
    ret

draw_settings_content:
    pushad
    call draw_settings_tabs
    cmp dword [set_tab], 1
    je .about
    cmp dword [set_tab], 2
    je .storage
    ; ===== General tab =====
    ; row 1: accent colour + swatch + Change button
    mov dword [fmline], 40
    mov edx, C_TEXT
    mov esi, set_1
    call fm_textline
    ; swatch
    mov eax, [con_x0]
    add eax, 180
    mov [rx], eax
    mov eax, [con_y0]
    add eax, 40
    mov [ry], eax
    mov dword [rw], 40
    mov dword [rh], 16
    mov eax, [accent]
    mov [rcolor], eax
    call fillrect
    call set_button             ; Change button at fixed x, [con_y0]+40
    ; row 2: wallpaper + Change
    mov dword [fmline], 78
    mov edx, C_TEXT
    mov esi, set_2
    call fm_textline
    mov dword [setrow], 78
    call set_button2
    ; row 3: shadows ON/OFF button
    mov dword [fmline], 116
    mov edx, C_TEXT
    mov esi, set_3
    call fm_textline
    ; ON/OFF button
    mov eax, [con_x0]
    add eax, 250
    mov [rx], eax
    mov eax, [con_y0]
    add eax, 114
    mov [ry], eax
    mov dword [rw], 70
    mov dword [rh], 22
    mov dword [rcolor], 0x00303C4A
    call fillrect
    mov dword [tcolor], C_WHITE
    mov eax, [con_x0]
    add eax, 262
    mov [tx], eax
    mov eax, [con_y0]
    add eax, 117
    mov [ty], eax
    cmp byte [shadows_on], 0
    je .off
    mov esi, set_on
    jmp .drawtog
.off:
    mov esi, set_off
.drawtog:
    call draw_text
    ; row 4: Sound ON/OFF (mute)
    mov dword [fmline], 154
    mov edx, C_TEXT
    mov esi, set_snd
    call fm_textline
    mov eax, [con_x0]
    add eax, 250
    mov [rx], eax
    mov eax, [con_y0]
    add eax, 152
    mov [ry], eax
    mov dword [rw], 70
    mov dword [rh], 22
    mov dword [rcolor], 0x00303C4A
    call fillrect
    mov dword [tcolor], C_WHITE
    mov eax, [con_x0]
    add eax, 262
    mov [tx], eax
    mov eax, [con_y0]
    add eax, 155
    mov [ty], eax
    cmp dword [sound_on], 0
    je .sndoff
    mov esi, set_on
    jmp .snddraw
.sndoff:
    mov esi, set_off
.snddraw:
    call draw_text
    ; row 5: master Volume, -/+ buttons with a live test beep
    mov dword [fmline], 192
    mov edx, C_TEXT
    mov esi, set_vol
    call fm_textline
    mov eax, [hda_volume]
    call draw_num
    mov al, '%'
    call draw_char
    add dword [tx], 8
    mov eax, [con_x0]
    add eax, 250
    mov [rx], eax
    mov eax, [con_y0]
    add eax, 190
    mov [ry], eax
    mov dword [rw], 30
    mov dword [rh], 22
    mov dword [rcolor], 0x00303C4A
    call fillrect
    mov dword [tcolor], C_WHITE
    mov eax, [con_x0]
    add eax, 261
    mov [tx], eax
    mov eax, [con_y0]
    add eax, 193
    mov [ty], eax
    mov esi, set_minus
    call draw_text
    mov eax, [con_x0]
    add eax, 288
    mov [rx], eax
    mov eax, [con_y0]
    add eax, 190
    mov [ry], eax
    mov dword [rw], 30
    mov dword [rh], 22
    mov dword [rcolor], 0x00303C4A
    call fillrect
    mov eax, [con_x0]
    add eax, 299
    mov [tx], eax
    mov eax, [con_y0]
    add eax, 193
    mov [ty], eax
    mov esi, set_plus
    call draw_text
    popad
    ret
.about:
    mov dword [fmline], 44
    mov edx, C_WHITE
    mov esi, set_about1
    call fm_textline
    mov dword [fmline], 76
    mov edx, C_TEXT
    mov esi, set_about2
    call fm_textline
    mov dword [fmline], 100
    mov esi, set_about3
    call fm_textline
    mov dword [fmline], 124
    mov esi, set_about4
    call fm_textline
    popad
    ret
.storage:
    call draw_storage_tab
    popad
    ret

; "Change" button for the accent row (y = con_y0+40)
set_button:
    mov eax, [con_x0]
    add eax, 250
    mov [rx], eax
    mov eax, [con_y0]
    add eax, 38
    mov [ry], eax
    mov dword [rw], 70
    mov dword [rh], 22
    mov dword [rcolor], 0x00303C4A
    call fillrect
    mov dword [tcolor], C_WHITE
    mov eax, [con_x0]
    add eax, 260
    mov [tx], eax
    mov eax, [con_y0]
    add eax, 41
    mov [ty], eax
    mov esi, set_btn
    call draw_text
    ret

; "Change" button for the wallpaper row (y = con_y0+[setrow]-2)
set_button2:
    mov eax, [con_x0]
    add eax, 250
    mov [rx], eax
    mov eax, [con_y0]
    add eax, 76
    mov [ry], eax
    mov dword [rw], 70
    mov dword [rh], 22
    mov dword [rcolor], 0x00303C4A
    call fillrect
    mov dword [tcolor], C_WHITE
    mov eax, [con_x0]
    add eax, 260
    mov [tx], eax
    mov eax, [con_y0]
    add eax, 79
    mov [ty], eax
    mov esi, set_btn
    call draw_text
    ret

; a click inside the Settings window body (con_* already loaded)
settings_click:
    ; tab bar row?  y in [con_y0+4, con_y0+30]
    mov eax, [mouse_y]
    mov ebx, [con_y0]
    add ebx, 4
    cmp eax, ebx
    jl .body
    add ebx, 26
    cmp eax, ebx
    jg .body
    mov eax, [mouse_x]
    sub eax, [con_x0]
    sub eax, 8
    js .ret
    xor edx, edx
    mov ecx, 94
    div ecx
    cmp eax, 3
    jae .ret
    mov [set_tab], eax
    cmp eax, 2
    jne .tabok
    mov dword [stor_scanned], 0
.tabok:
    call recompose
    ret
.body:
    cmp dword [set_tab], 0          ; only the General tab has controls
    jne .ret
    mov eax, [mouse_y]
    sub eax, [con_y0]
    cmp eax, 190
    jl .notvol
    cmp eax, 212
    jg .notvol
    mov eax, [mouse_x]
    mov ebx, [con_x0]
    add ebx, 250
    cmp eax, ebx
    jl .ret
    add ebx, 30
    cmp eax, ebx
    jg .r5plus
    call vol_down
    call recompose
    ret
.r5plus:
    add ebx, 28
    cmp eax, ebx
    jg .ret
    call vol_up
    call recompose
    ret
.notvol:
    mov eax, [mouse_x]
    mov ebx, [con_x0]
    add ebx, 250
    cmp eax, ebx
    jl .ret
    add ebx, 70
    cmp eax, ebx
    jg .ret
    mov eax, [mouse_y]
    sub eax, [con_y0]
    cmp eax, 38
    jl .ret
    cmp eax, 60
    jg .r2
    call cycle_accent
    call recompose
    ret
.r2:
    cmp eax, 76
    jl .ret
    cmp eax, 98
    jg .r3
    call cycle_wall
    call recompose
    ret
.r3:
    cmp eax, 114
    jl .ret
    cmp eax, 136
    jg .r4
    xor byte [shadows_on], 1
    call recompose
    ret
.r4:
    cmp eax, 152
    jl .ret
    cmp eax, 174
    jg .ret
    xor dword [sound_on], 1
    call recompose
.ret:
    ret

; +/- the master volume by 10, clamp 0..100, and play a live test beep at the new
; level (through HDA when present; PC speaker respects the same [hda_volume] too)
vol_down:
    mov eax, [hda_volume]
    sub eax, 10
    jns .set
    xor eax, eax
.set:
    mov [hda_volume], eax
    jmp vol_beep
vol_up:
    mov eax, [hda_volume]
    add eax, 10
    cmp eax, 100
    jle .set
    mov eax, 100
.set:
    mov [hda_volume], eax
vol_beep:
    mov bx, 1432                      ; a short, clear pitch
    cmp dword [hda_ok], 0
    je .pcspk
    mov eax, [hda_volume]
    call hda_beep                     ; volume-scaled amplitude, HDA path
    ret
.pcspk:
    call play_note                    ; PC speaker has no real amplitude control -- fixed loudness
    ret

cycle_accent:
    mov eax, [accent_sel]
    inc eax
    and eax, 3
    mov [accent_sel], eax
    mov eax, [accent_opts + eax*4]
    mov [accent], eax
    ret

cycle_wall:
    mov eax, [wall_sel]
    inc eax
    cmp eax, 4
    jl .ok
    xor eax, eax
.ok:
    mov [wall_sel], eax
    ; base offset = sel*6 dwords
    imul eax, 24                 ; 6 dwords * 4 bytes
    mov esi, wall_opts
    add esi, eax
    mov ebx, [esi]
    mov [grad_r], ebx
    mov ebx, [esi+4]
    mov [grad_g], ebx
    mov ebx, [esi+8]
    mov [grad_b], ebx
    mov ebx, [esi+12]
    mov [grad_dr], ebx
    mov ebx, [esi+16]
    mov [grad_dg], ebx
    mov ebx, [esi+20]
    mov [grad_db], ebx
    ret

paint_init:                  ; clear canvas to white (once)
    pushad
    mov edi, PAINTBUF
    mov ecx, PAINT_STRIDE*PAINT_H
    mov eax, 0x00FFFFFF
    rep stosd
    popad
    ret

; ---- RAM filesystem ----
fs_init:                     ; blank all file buffers
    pushad
    mov edi, FILEBASE
    mov ecx, NFILES * MAXCOLS * MAXROWS
    mov al, ' '
    rep stosb
    popad
    ret

new_file:                    ; installed mode: blank the next slot, open it in the Editor
    mov dword [ed_ro], 0
    mov eax, [new_slot]
    cmp eax, NFILES
    jb .ok
    xor eax, eax
    mov [new_slot], eax
.ok:
    mov [ed_curfile], eax
    ; ed_fname = "NOTEn   TXT" (8.3) so Save has a target filename
    push eax
    mov edi, ed_fname
    mov byte [edi+0], 'N'
    mov byte [edi+1], 'O'
    mov byte [edi+2], 'T'
    mov byte [edi+3], 'E'
    add al, '0'
    mov [edi+4], al
    mov byte [edi+5], ' '
    mov byte [edi+6], ' '
    mov byte [edi+7], ' '
    mov byte [edi+8], 'T'
    mov byte [edi+9], 'X'
    mov byte [edi+10], 'T'
    pop eax
    push eax
    imul eax, MAXCOLS*MAXROWS
    add eax, FILEBASE
    mov edi, eax
    mov ecx, MAXCOLS*MAXROWS
    mov al, ' '
    rep stosb                ; blank the slot
    pop eax
    inc dword [new_slot]
    call file_load
    mov dword [ed_col], 0
    mov dword [ed_row], 0
    mov byte [fs_err], 0
    mov eax, 5               ; Text Editor app id
    call open_window
    call recompose
    ret

file_load:                   ; EAX = index -> copy file into ed_buf
    pushad
    imul eax, MAXCOLS*MAXROWS
    add eax, FILEBASE
    mov esi, eax
    mov edi, ed_buf
    mov ecx, MAXCOLS*MAXROWS
    rep movsb
    popad
    ret

ed_save:                     ; copy ed_buf back to the current file
    cmp dword [ed_curfile], 0
    jl .ret
    pushad
    mov eax, [ed_curfile]
    imul eax, MAXCOLS*MAXROWS
    add eax, FILEBASE
    mov edi, eax
    mov esi, ed_buf
    mov ecx, MAXCOLS*MAXROWS
    rep movsb
    popad
.ret:
    ret

file_click:                  ; Files window body click
    cmp dword [has_fatfs], 0
    je .ret
    ; toolbar row? (y in [con_y0+4, con_y0+24])
    mov eax, [mouse_y]
    mov ebx, [con_y0]
    add ebx, 4
    cmp eax, ebx
    jl .rows
    add ebx, 20
    cmp eax, ebx
    jg .rows
    mov eax, [mouse_x]           ; pick a button by x
    mov ebx, [con_x0]
    add ebx, 8
    cmp eax, ebx
    jl .ret
    add ebx, 84
    cmp eax, ebx
    jl .bnewfile
    mov ebx, [con_x0]
    add ebx, 96
    cmp eax, ebx
    jl .ret
    add ebx, 96
    cmp eax, ebx
    jl .bnewfolder
    mov ebx, [con_x0]
    add ebx, 200
    cmp eax, ebx
    jl .ret
    add ebx, 48
    cmp eax, ebx
    jl .bup
    mov ebx, [con_x0]           ; Empty Trash button (x 252..348)
    add ebx, 252
    cmp eax, ebx
    jl .ret
    add ebx, 96
    cmp eax, ebx
    jl .bempty
    ret
.bempty:
    cmp dword [fm_vol], 0
    jne .brefresh
    cmp dword [install_mode], 0  ; at the disk's top level this is the USB Drive button
    je .notusb
    mov eax, [cwd_cluster]
    cmp eax, [fs_rootclus]
    jne .notusb
    call usb_scan                ; look for a stick now (only when asked)
    cmp dword [usb_ready], 0
    je .nostick
    call fm_use_usb
    call recompose
    ret
.nostick:
    call usb_diag_text           ; line 2 = what the driver saw (helps fix real hardware)
    mov edi, esi
    mov esi, nt_usb_none1
    cmp dword [u_best], 2
    jne .nst
    mov esi, nt_usb_fmt1         ; a stick, but not one we can read
.nst:
    call notify
    call recompose
    ret
.brefresh:                       ; Refresh on the stick: still there?
    call usb_scan
    cmp dword [usb_ready], 0
    je .gone
    mov dword [files_dirty], 1
    call recompose
    ret
.gone:
    call fm_use_disk
    mov esi, nt_usb_out1
    mov edi, nt_usb_out2
    call notify
    call recompose
    ret
.notusb:
    mov eax, [cwd_cluster]
    cmp eax, [trash_cluster]
    jne .ret
    call empty_trash
    mov dword [files_dirty], 1
    mov dword [desk_dirty], 1
    mov esi, nt_emptied1
    mov edi, nt_emptied2
    call notify
    call recompose
    ret
.bnewfile:
    cmp dword [fm_vol], 0
    jne .usbro
    cmp dword [install_mode], 0
    je .blocked
    mov eax, [cwd_cluster]       ; save into the current folder
    mov [save_dir], eax
    call new_file
    ret
.bnewfolder:
    cmp dword [fm_vol], 0
    jne .usbro
    cmp dword [install_mode], 0
    je .blocked
    call do_newfolder
    ret
.usbro:
    call err_beep
    mov esi, nt_usbro1
    mov edi, nt_usbro2
    call notify
    call recompose
    ret
.blocked:
    call long_beep
    mov esi, nt_live1
    mov edi, nt_live2
    call notify
    call recompose
    ret
.bup:
    cmp dword [fm_vol], 0
    je .bup0
    mov eax, [cwd_cluster]
    cmp eax, [fm_usb_root]
    jne .bupp
    call fm_use_disk             ; top of the stick -> back to the disk
    call recompose
    ret
.bup0:
    mov eax, [cwd_cluster]
    cmp eax, [fs_rootclus]
    je .ret
.bupp:
    mov eax, [parent_cluster]
    mov [cwd_cluster], eax
    mov dword [files_dirty], 1
    mov dword [desk_dirty], 1
    call recompose
    ret
.rows:
    call sys_warn_click          ; SYSTEM locked: only 'Show files anyway' works
    test al, al
    jnz .ret
    mov eax, [mouse_y]
    sub eax, [con_y0]
    sub eax, 32
    js .ret
    xor edx, edx
    mov ecx, 20
    div ecx
    cmp eax, [dir_count]
    jae .ret
    cmp eax, 14
    jae .ret
    mov [fm_sel], eax
    ; R / X buttons on the right?
    mov ecx, [mouse_x]
    mov eax, [con_cols]
    shl eax, 3
    add eax, [con_x0]           ; right edge
    mov edx, eax
    sub edx, 26                 ; X button threshold
    cmp ecx, edx
    jge .do_delete
    mov edx, eax
    sub edx, 48                 ; R button threshold
    cmp ecx, edx
    jge .do_rename
    ; otherwise open / enter
    mov ebx, [fm_sel]
    mov al, [dir_attr + ebx]
    test al, 0x10
    jz .openfile
    mov eax, [dir_clus + ebx*4]
    test eax, eax
    jz .ret
    mov [cwd_cluster], eax
    mov dword [files_dirty], 1
    mov dword [desk_dirty], 1
    call recompose
    ret
.do_rename:
    call sys_protect             ; system files can't be renamed
    test al, al
    jnz .ret
    ; inside Trash, the R button restores instead of renaming
    mov eax, [cwd_cluster]
    cmp eax, [trash_cluster]
    jne .rn
    call fat_restore
    mov dword [files_dirty], 1
    mov dword [desk_dirty], 1
    call recompose
    ret
.rn:
    mov eax, [fm_sel]
    mov [rename_row], eax
    mov dword [rename_mode], 1
    mov dword [rename_len], 0
    mov byte [rename_buf], 0
    call recompose
    ret
.do_delete:
    call sys_protect             ; ...or deleted
    test al, al
    jnz .ret
    mov eax, [fm_sel]
    mov [del_row], eax
    call fat_delete
    test al, al
    jz .del_ok
    mov byte [fs_err], 1        ; folder not empty
    call err_beep
    call recompose
    ret
.del_ok:
    mov dword [files_dirty], 1
    mov dword [desk_dirty], 1
    mov eax, [cwd_cluster]
    cmp eax, [trash_cluster]
    je .del_perm
    mov esi, nt_trash1
    mov edi, nt_trash2
    call notify
.del_perm:
    call recompose
    ret
.openfile:
    mov ebx, [fm_sel]
    mov eax, ebx                 ; a Music Maker song? -> open it there
    imul eax, 11
    lea esi, [dir_name + eax]
    cmp word [esi + 8], 'NT'
    jne .oftext
    cmp byte [esi + 10], 'R'
    jne .oftext
    mov eax, [dir_clus + ebx*4]
    mov edx, [fm_vol]
    call music_open_file
    ret
.oftext:
    movzx eax, byte [dir_attr + ebx]   ; remember if it's a read-only/system file
    and eax, 0x05
    mov [ed_ro], eax
    mov eax, [dir_size + ebx*4]
    mov [fl_size], eax
    mov eax, [fm_sel]           ; ed_fname = the file's name
    imul eax, 11
    lea esi, [dir_name + eax]
    mov edi, ed_fname
    mov ecx, 11
    rep movsb
    mov eax, [cwd_cluster]      ; re-save into the same folder
    mov [save_dir], eax
    cmp dword [fm_vol], 0        ; from the USB stick -> read-only in the editor
    je .ofd
    mov dword [ed_ro], 1
.ofd:
    call fm_mount
    mov ebx, [fm_sel]
    mov eax, [dir_clus + ebx*4]
    call fat_load_to_editor
    call fm_unmount
    mov eax, 5
    call open_window
    call recompose
    ret
.ret:
    ret

; create a folder with an auto-name (FOLDER0..7) in the current directory
do_newfolder:
    mov edi, name83
    mov byte [edi+0], 'F'
    mov byte [edi+1], 'O'
    mov byte [edi+2], 'L'
    mov byte [edi+3], 'D'
    mov byte [edi+4], 'E'
    mov byte [edi+5], 'R'
    mov eax, [folder_slot]
    and eax, 7
    add al, '0'
    mov [edi+6], al
    mov byte [edi+7], ' '
    mov byte [edi+8], ' '
    mov byte [edi+9], ' '
    mov byte [edi+10], ' '
    inc dword [folder_slot]
    call fat_mkdir
    test al, al
    jnz .full
    mov dword [files_dirty], 1
    mov dword [desk_dirty], 1
    mov esi, nt_mkdir1
    mov edi, nt_mkdir2
    call notify
    call recompose
    ret
.full:
    mov byte [fs_err], 1
    call err_beep
    call recompose
    ret

draw_paint_content:
    pushad
    ; palette swatches
    xor ebx, ebx
.pal:
    cmp ebx, 8
    jae .pd
    mov eax, ebx
    imul eax, 26
    add eax, [con_x0]
    mov [rx], eax
    mov eax, [con_y0]
    mov [ry], eax
    mov dword [rw], 24
    mov dword [rh], 20
    mov eax, [paint_pal + ebx*4]
    mov [rcolor], eax
    call fillrect
    inc ebx
    jmp .pal
.pd:
    ; brush-size buttons S / M / L
    xor ebx, ebx
.sz:
    cmp ebx, 3
    jae .szdone
    mov eax, ebx
    imul eax, 28
    add eax, [con_x0]
    add eax, 216
    mov [rx], eax
    mov eax, [con_y0]
    mov [ry], eax
    mov dword [rw], 26
    mov dword [rh], 20
    mov dword [rcolor], 0x00384250
    call fillrect
    mov dword [tcolor], C_WHITE
    mov eax, [rx]
    add eax, 9
    mov [tx], eax
    mov eax, [con_y0]
    add eax, 2
    mov [ty], eax
    movzx eax, byte [sz_lbl + ebx]
    call draw_char
    inc ebx
    jmp .sz
.szdone:
    ; Clear button
    mov eax, [con_x0]
    add eax, 310
    mov [rx], eax
    mov eax, [con_y0]
    mov [ry], eax
    mov dword [rw], 54
    mov dword [rh], 20
    mov dword [rcolor], 0x00803838
    call fillrect
    mov dword [tcolor], C_WHITE
    mov eax, [con_x0]
    add eax, 316
    mov [tx], eax
    mov eax, [con_y0]
    add eax, 2
    mov [ty], eax
    mov esi, clr_lbl
    call draw_text
    ; canvas display size
    mov eax, [con_cols]
    shl eax, 3
    cmp eax, PAINT_STRIDE
    jbe .cw
    mov eax, PAINT_STRIDE
.cw:
    mov [paint_dw], eax
    mov eax, [con_rows]
    shl eax, 4
    sub eax, 26
    cmp eax, PAINT_H
    jbe .ch
    mov eax, PAINT_H
.ch:
    mov [paint_dh], eax
    ; blit canvas below palette
    xor ebx, ebx
.blit:
    mov eax, [paint_dh]
    cmp ebx, eax
    jae .done
    mov eax, ebx
    imul eax, PAINT_STRIDE*4
    add eax, PAINTBUF
    mov esi, eax
    mov eax, [con_y0]
    add eax, 26
    add eax, ebx
    imul eax, [pitch]
    add eax, [lfb]
    mov edx, [con_x0]
    shl edx, 2
    add eax, edx
    mov edi, eax
    mov ecx, [paint_dw]
    rep movsd
    inc ebx
    jmp .blit
.done:
    popad
    ret

paint_dot:                   ; draw a 3x3 brush at the cursor (canvas + screen)
    pushad
    mov eax, [mouse_x]
    sub eax, [con_x0]
    js .done
    cmp eax, [paint_dw]
    jae .done
    mov [pcx], eax
    mov eax, [mouse_y]
    sub eax, [con_y0]
    sub eax, 26
    js .done
    cmp eax, [paint_dh]
    jae .done
    mov [pcy], eax
    xor ebx, ebx
.j:
    cmp ebx, [brush_sz]
    jae .done
    xor ecx, ecx
.i:
    cmp ecx, [brush_sz]
    jae .jn
    ; canvas pixel
    mov eax, [pcy]
    add eax, ebx
    imul eax, PAINT_STRIDE
    add eax, [pcx]
    add eax, ecx
    shl eax, 2
    add eax, PAINTBUF
    mov edx, [paint_color]
    mov [eax], edx
    ; screen pixel
    mov eax, [mouse_y]
    add eax, ebx
    imul eax, [pitch]
    add eax, [lfb]
    mov edx, [mouse_x]
    add edx, ecx
    shl edx, 2
    add eax, edx
    mov edx, [paint_color]
    mov [eax], edx
    inc ecx
    jmp .i
.jn:
    inc ebx
    jmp .j
.done:
    popad
    ret

; draw a MAXCOLS-stride grid (ESI = buffer base) into the console area
draw_grid:
    pushad
    xor ebx, ebx
.rrow:
    mov eax, [con_rows]
    cmp ebx, eax
    jae .done
    xor ebp, ebp
.rcol:
    mov eax, [con_cols]
    cmp ebp, eax
    jae .rnext
    mov eax, ebx
    imul eax, MAXCOLS
    add eax, ebp
    movzx eax, byte [esi + eax]
    cmp al, ' '
    jbe .rskip
    push ebx
    push ebp
    push eax
    mov eax, ebp
    shl eax, 3
    add eax, [con_x0]
    mov [tx], eax
    mov eax, ebx
    shl eax, 4
    add eax, [con_y0]
    mov [ty], eax
    mov dword [tcolor], C_TEXT
    pop eax
    call draw_char
    pop ebp
    pop ebx
.rskip:
    inc ebp
    jmp .rcol
.rnext:
    inc ebx
    jmp .rrow
.done:
    popad
    ret

draw_editor_content:
    pushad
    ; ---- toolbar with a Save button (top-right of the body) ----
    mov eax, [con_cols]
    shl eax, 3
    add eax, [con_x0]
    sub eax, 66
    mov [rx], eax
    mov eax, [con_y0]
    add eax, 2
    mov [ry], eax
    mov dword [rw], 60
    mov dword [rh], 20
    mov eax, [accent]
    mov [rcolor], eax
    call fillrect
    mov eax, [rx]
    add eax, 13
    mov [tx], eax
    mov eax, [ry]
    add eax, 2
    mov [ty], eax
    mov dword [tcolor], C_WHITE
    mov esi, ed_save_lbl
    call draw_text
    ; ---- text grid, shifted below the toolbar ----
    add dword [con_y0], 26
    sub dword [con_rows], 2
    mov esi, ed_buf
    call draw_grid
    call draw_ed_caret               ; con_y0 is the shifted text origin here
    ; hint if empty
    cmp dword [ed_col], 0
    jne .skip
    cmp dword [ed_row], 0
    jne .skip
    mov eax, [con_x0]
    mov [tx], eax
    mov eax, [con_y0]
    mov [ty], eax
    mov dword [tcolor], 0x00586472
    mov esi, ed_hint
    call draw_text
.skip:
    sub dword [con_y0], 26
    add dword [con_rows], 2
    popad
    ret

; draw/erase the editor caret; assumes con_x0/con_y0 = shifted text origin
draw_ed_caret:
    pushad
    mov eax, [ed_col]
    shl eax, 3
    add eax, [con_x0]
    mov [rx], eax
    mov eax, [ed_row]
    shl eax, 4
    add eax, [con_y0]
    mov [ry], eax
    mov dword [rw], 2
    mov dword [rh], 14
    cmp dword [ed_cursor_on], 0
    je .off
    mov eax, [accent]
    mov [rcolor], eax
    jmp .fill
.off:
    mov dword [rcolor], C_CONBG
.fill:
    call fillrect
    popad
    ret

; blink from anim_tick: load editor geometry, apply the toolbar offset, draw caret
blink_ed_caret:
    cmp byte [ws_state + 5], 1
    jne .ret
    pushad
    mov eax, 5
    call load_win_geom
    add dword [con_y0], 26
    call draw_ed_caret
    sub dword [con_y0], 26
    popad
.ret:
    ret

; Convert the editor grid (rows 0..ed_row) into CRLF text at SAVEBUF. ECX = length.
build_savetext:
    pushad
    mov edi, SAVEBUF
    xor ebx, ebx
    mov edx, [ed_row]
    inc edx                      ; number of rows to emit
.row:
    cmp ebx, edx
    jae .done
    mov esi, ebx
    imul esi, MAXCOLS
    add esi, ed_buf
    mov dword [bs_last], -1
    xor eax, eax
.scan:
    mov cl, [esi + eax]
    cmp cl, ' '
    jbe .sp
    mov [bs_last], eax
.sp:
    inc eax
    cmp eax, MAXCOLS
    jb .scan
    cmp dword [bs_last], -1
    je .crlf
    xor eax, eax
.cp:
    mov cl, [esi + eax]
    mov [edi], cl
    inc edi
    cmp eax, [bs_last]
    jae .crlf
    inc eax
    jmp .cp
.crlf:
    mov byte [edi], 13
    inc edi
    mov byte [edi], 10
    inc edi
    inc ebx
    jmp .row
.done:
    mov ecx, edi
    sub ecx, SAVEBUF
    mov [savelen], ecx
    popad
    mov ecx, [savelen]
    ret

; Save button: persist to the FAT data partition if present, else error + toast
ed_do_save:
    cmp dword [ed_ro], 0         ; system / read-only file: refuse
    je .rw
    call err_beep
    mov esi, nt_ro1
    mov edi, nt_ro2
    call notify
    call recompose
    ret
.rw:
    cmp dword [install_mode], 0
    je .nofs
    call build_savetext          ; ECX = length, text at SAVEBUF
    push ecx
    mov esi, ed_fname            ; filename -> name83
    mov edi, name83
    mov ecx, 11
    rep movsb
    pop ecx
    mov esi, SAVEBUF
    call fat_write_file
    test al, al
    jnz .werr
    mov dword [files_dirty], 1
    mov dword [desk_dirty], 1
    mov esi, nt_saved1
    mov edi, nt_saved2
    call notify
    call recompose
    ret
.werr:
    mov esi, nt_werr1
    mov edi, nt_werr2
    call notify
    call recompose
    ret
.nofs:
    call long_beep
    mov esi, nt_nosave1
    mov edi, nt_nosave2
    call notify
    call recompose
    ret

draw_browser_content:
    pushad
    ; URL bar
    mov eax, [con_x0]
    mov [rx], eax
    mov eax, [con_y0]
    mov [ry], eax
    mov eax, [con_cols]
    shl eax, 3
    mov [rw], eax
    mov dword [rh], 22
    mov dword [rcolor], 0x00202A36
    call fillrect
    mov eax, [con_x0]
    add eax, 6
    mov [tx], eax
    mov eax, [con_y0]
    add eax, 3
    mov [ty], eax
    mov dword [tcolor], 0x008FB6E9
    mov esi, web_url
    call draw_text
    ; page text
    mov dword [tcolor], C_WHITE
    mov eax, [con_x0]
    add eax, 4
    mov [tx], eax
    mov eax, [con_y0]
    add eax, 38
    mov [ty], eax
    mov esi, web_1
    call draw_text
    mov dword [tcolor], 0x00B8C4D0
    mov eax, [con_x0]
    add eax, 4
    mov [tx], eax
    mov eax, [con_y0]
    add eax, 66
    mov [ty], eax
    mov esi, web_2
    call draw_text
    mov eax, [con_x0]
    add eax, 4
    mov [tx], eax
    mov eax, [con_y0]
    add eax, 88
    mov [ty], eax
    mov esi, web_3
    call draw_text
    mov eax, [con_x0]
    add eax, 4
    mov [tx], eax
    mov eax, [con_y0]
    add eax, 108
    mov [ty], eax
    mov esi, web_4
    call draw_text
    mov eax, [con_x0]
    add eax, 4
    mov [tx], eax
    mov eax, [con_y0]
    add eax, 136
    mov [ty], eax
    mov esi, web_5
    call draw_text
    mov eax, [con_x0]
    add eax, 4
    mov [tx], eax
    mov eax, [con_y0]
    add eax, 156
    mov [ty], eax
    mov esi, web_6
    call draw_text
    popad
    ret

; ---- text editor keyboard ----
ed_putchar:                  ; AL = char
    push eax
    push ebx
    push edi
    mov ebx, [ed_row]
    imul ebx, MAXCOLS
    add ebx, [ed_col]
    mov [ed_buf + ebx], al
    inc dword [ed_col]
    mov eax, [ed_col]
    cmp eax, [con_cols]
    jl .done
    mov dword [ed_col], 0
    inc dword [ed_row]
    mov eax, [ed_row]
    cmp eax, [con_rows]
    jl .done
    mov eax, [con_rows]
    dec eax
    mov [ed_row], eax
.done:
    pop edi
    pop ebx
    pop eax
    ret

handle_editor_scancode:      ; AL = scancode
    cmp al, 0x2A
    je .son
    cmp al, 0x36
    je .son
    cmp al, 0xAA
    je .soff
    cmp al, 0xB6
    je .soff
    test al, 0x80
    jnz .ret
    movzx ebx, al
    cmp byte [ed_shift], 0
    je .un
    mov al, [scancodes_shift + ebx]
    jmp .have
.un:
    mov al, [scancodes + ebx]
.have:
    test al, al
    jz .ret
    cmp al, 0x0A
    je .enter
    cmp al, 0x08
    je .back
    call ed_putchar
    call ed_save
    call recompose
    ret
.enter:
    mov dword [ed_col], 0
    inc dword [ed_row]
    mov eax, [ed_row]
    cmp eax, [con_rows]
    jl .er
    mov eax, [con_rows]
    dec eax
    mov [ed_row], eax
.er:
    call ed_save
    call recompose
    ret
.back:
    cmp dword [ed_col], 0
    je .ret
    dec dword [ed_col]
    mov ebx, [ed_row]
    imul ebx, MAXCOLS
    add ebx, [ed_col]
    mov byte [ed_buf + ebx], ' '
    call ed_save
    call recompose
    ret
.son:
    mov byte [ed_shift], 1
    ret
.soff:
    mov byte [ed_shift], 0
    ret
.ret:
    ret

gprint:
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

gprint_dec:
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

; ================= print AL as two hex digits =================
ghex_byte:
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
    add al, 'A' - 10
    jmp .put
.dig:
    add al, '0'
.put:
    call gputchar
    ret

; ================= ATA PIO: read one sector (LBA28) =================
; IN:  EAX = LBA,  EDI = 512-byte destination buffer
; Reads the PRIMARY MASTER (internal IDE/SATA-legacy disk), not USB.
; Returns CF=0 on success, CF=1 on timeout.
ata_read_sector:
    push eax
    push ebx
    push ecx
    push edx
    push edi
    mov ebx, eax                 ; save LBA in EBX
    ; wait for BSY clear
    mov dx, 0x1F7
    mov ecx, 100000
.wait_bsy:
    in al, dx
    test al, 0x80
    jz .ready
    dec ecx
    jnz .wait_bsy
    jmp .fail
.ready:
    ; drive/head: 0xE0 (LBA, master) | ((LBA>>24)&0x0F)
    mov dx, 0x1F6
    mov eax, ebx
    shr eax, 24
    and al, 0x0F
    or al, 0xE0
    or al, byte [ata_devbit]     ; 0x00 = master, 0x10 = slave
    out dx, al
    ; sector count = 1
    mov dx, 0x1F2
    mov al, 1
    out dx, al
    ; LBA 0..7
    mov dx, 0x1F3
    mov al, bl
    out dx, al
    ; LBA 8..15
    mov dx, 0x1F4
    mov eax, ebx
    shr eax, 8
    out dx, al
    ; LBA 16..23
    mov dx, 0x1F5
    mov eax, ebx
    shr eax, 16
    out dx, al
    ; command 0x20 = READ SECTORS
    mov dx, 0x1F7
    mov al, 0x20
    out dx, al
    ; wait until DRQ set (BSY clear + DRQ set), or error
    mov ecx, 100000
.wait_drq:
    in al, dx
    test al, 0x01                ; ERR
    jnz .fail
    test al, 0x80                ; BSY still set?
    jnz .again
    test al, 0x08                ; DRQ set?
    jnz .xfer
.again:
    dec ecx
    jnz .wait_drq
    jmp .fail
.xfer:
    mov dx, 0x1F0
    mov ecx, 256                 ; 256 words = 512 bytes
    rep insw                     ; -> ES:EDI (flat), EDI = buffer
    clc
    jmp .out
.fail:
    stc
.out:
    pop edi
    pop edx
    pop ecx
    pop ebx
    pop eax
    ret

; ================= BIOS thunk: read/write one sector via int 13h =================
; Briefly drops to real mode so the BIOS (which HAS a USB driver) does the disk
; I/O for us, then returns to protected mode. The 512-byte payload lives at the
; low-memory buffer BIOSBUF (BIOS read fills it; BIOS write sends it).
; bios_xfer: caller sets [dap16_lba], [thunk_drive], [thunk_cmd] (0x42 read /
;            0x43 write). Result in [thunk_res] (0 ok, 1 error).
bios_xfer:
    call mus_quiet               ; (the speaker would hold its note for the whole disk job)
    lgdt [k_gdt_desc]
    mov [thunk_esp], esp
    cli
    jmp 0x18:.pm16
BITS 16
.pm16:
    mov ax, 0x20                 ; data16 selector
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov eax, cr0
    and al, 0xFE                 ; clear PE -> real mode
    mov cr0, eax
    jmp 0:.rm16
.rm16:
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov sp, 0x6F00               ; real-mode scratch stack (free low RAM)
    sti
    mov si, dap16
    mov dl, [thunk_drive]
    mov ah, [thunk_cmd]          ; 0x42 read / 0x43 write
    mov al, 0
    int 0x13
    mov byte [thunk_res], 0
    jnc .rok
    mov byte [thunk_res], 1
.rok:
    cli
    mov eax, cr0
    or al, 1                     ; set PE -> back to protected mode
    mov cr0, eax
    jmp 0x08:.pm32
BITS 32
.pm32:
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov esp, [thunk_esp]
    ret

; Read one sector of the BOOT drive.  IN: EAX = LBA.  OUT: 512B at DISKBUF, AL result
bios_read_lba:
    pushad
    mov word [dap_count], 1
    mov [dap16_lba], eax
    mov dword [dap16_lba+4], 0
    mov al, [0x1014]             ; boot-drive number the loader stashed
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

; Read one sector of drive [inst_drive] into DISKBUF (used to probe an install target)
probe_drive:                     ; IN: [inst_drive].  OUT: AL = 0 ok
    pushad
    mov dword [dap16_lba], 0
    mov dword [dap16_lba+4], 0
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

; Write one sector to drive [inst_drive].  IN: EAX = LBA, ESI = 512-byte source
bios_write_lba:
    pushad
    mov word [dap_count], 1
    mov edi, BIOSBUF             ; stage the payload in the BIOS buffer
    mov ecx, 128
    rep movsd
    mov [dap16_lba], eax
    mov dword [dap16_lba+4], 0
    mov al, [inst_drive]
    mov [thunk_drive], al
    mov byte [thunk_cmd], 0x43
    call bios_xfer
    popad
    mov al, [thunk_res]
    ret

; Write ECX (<=64) zeroed sectors to drive [inst_drive] starting at EAX = LBA.
; One BIOS call transfers all of them, so formatting is fast.
bios_write_zeros:
    pushad
    mov [zw_lba], eax
    mov [dap_count], cx
    mov edi, BIOSBUF            ; zero ECX*512 bytes of the BIOS buffer
    movzx ecx, cx
    shl ecx, 7                  ; *128 dwords
    xor eax, eax
    rep stosd
    mov eax, [zw_lba]
    mov [dap16_lba], eax
    mov dword [dap16_lba+4], 0
    mov al, [inst_drive]
    mov [thunk_drive], al
    mov byte [thunk_cmd], 0x43
    call bios_xfer
    mov word [dap_count], 1
    popad
    mov al, [thunk_res]
    ret

align 8
k_gdt:
    dq 0x0000000000000000
    db 0xFF,0xFF,0x00,0x00,0x00,10011010b,11001111b,0x00   ; 0x08 code32
    db 0xFF,0xFF,0x00,0x00,0x00,10010010b,11001111b,0x00   ; 0x10 data32
    db 0xFF,0xFF,0x00,0x00,0x00,10011010b,00001111b,0x00   ; 0x18 code16
    db 0xFF,0xFF,0x00,0x00,0x00,10010010b,00001111b,0x00   ; 0x20 data16
k_gdt_end:
k_gdt_desc:
    dw k_gdt_end - k_gdt - 1
    dd k_gdt
dap16:
    db 0x10
    db 0
dap_count:
    dw 1                         ; sectors per transfer
    dw 0x0000                    ; buffer offset
    dw 0x7000                    ; buffer segment (phys 0x70000 = BIOSBUF)
dap16_lba:
    dq 0
zw_lba:      dd 0
thunk_esp:   dd 0
thunk_res:   db 0
thunk_drive: db 0
thunk_cmd:   db 0x42
inst_drive:  db 0x81            ; install target BIOS drive (2nd disk = internal, usually)
inst_i:      dd 0
setup_active: dd 0
setup_step:  dd 0
inst_lang:   dd 0

; ================= FAT32 filesystem (read-only) =================
; Backend: fs_read_sector reads a partition-relative LBA. For now it reads the
; ATA device selected by ata_devbit (0x10 = primary slave, where QEMU mounts the
; FAT image) offset by part_base. Later this can point at the BIOS thunk instead.
fs_read_sector:              ; EAX = partition-relative LBA, EDI = 512-byte buffer
    cmp dword [vol], 1           ; the USB stick (read through our USB driver)?
    jne .bios
    push eax
    add eax, [usb_part]
    call usb_read_sector
    pop eax
    ret
.bios:
    push eax
    push esi
    push ecx
    add eax, [part_base]
    push edi
    call bios_read_lba       ; BIOS thunk reads the boot drive -> DISKBUF
    pop edi
    mov esi, DISKBUF         ; copy the sector into the caller's buffer
    mov ecx, 128
    rep movsd
    pop ecx
    pop esi
    pop eax
    ret

; parse the BPB from sector 0; AL = 0 ok, 1 fail
fat_mount:
    xor eax, eax
    mov edi, FSDIR
    call fs_read_sector
    movzx eax, word [FSDIR + 11]     ; bytes per sector
    cmp eax, 512
    jne .bad
    movzx eax, byte [FSDIR + 13]
    mov [fs_spc], eax
    movzx eax, word [FSDIR + 14]
    mov [fs_rsvd], eax
    movzx eax, byte [FSDIR + 16]
    mov [fs_nfat], eax
    mov eax, [FSDIR + 36]
    mov [fs_fatsz], eax
    mov eax, [FSDIR + 44]
    mov [fs_rootclus], eax
    mov eax, [FSDIR + 32]            ; total sectors (32-bit)
    mov [fs_totsec], eax
    mov eax, [fs_nfat]
    imul eax, [fs_fatsz]
    add eax, [fs_rsvd]
    mov [fs_data_start], eax
    xor al, al
    ret
.bad:
    mov al, 1
    ret

; Decide live-USB vs installed by whether the BOOT disk actually carries our
; FAT32 data partition (LBA 2048). The USB does; a freshly-installed internal
; disk does not. Content-based, so it can't be fooled by BIOS "removable" flags.
;   install_mode = 0 -> live USB  (FAT present, block file creation)
;   install_mode = 1 -> installed (no FAT, allow file creation)
; has_fatfs = a writable FAT partition exists (both USB and installed).
; install_mode = 1 ONLY if the "installed" marker is present at LBA 200 (written
; by the installer). A raw USB has zeros there -> live mode -> no file creation.
detect_media:
    call fat_mount
    test al, al
    jnz .nofs
    mov dword [has_fatfs], 1
    mov eax, 200
    call bios_read_lba           ; read the marker sector of the boot drive
    mov esi, DISKBUF
    mov edi, inst_magic
    mov ecx, 8
.cmp:
    mov al, [esi]
    cmp al, [edi]
    jne .live
    inc esi
    inc edi
    dec ecx
    jnz .cmp
    mov dword [install_mode], 1  ; marker found -> installed
    ret
.live:
    mov dword [install_mode], 0  ; no marker -> live USB (read-only for new files)
    ret
.nofs:
    mov dword [has_fatfs], 0
    mov dword [install_mode], 0
    ret
inst_magic: db "NOVAINST"

clus_to_sector:              ; EAX cluster -> EAX first (partition-relative) sector
    sub eax, 2
    imul eax, [fs_spc]
    add eax, [fs_data_start]
    ret

fat_next:                    ; EAX cluster -> EAX next cluster (from the FAT)
    push ecx
    push edx
    shl eax, 2               ; byte offset = cluster*4
    xor edx, edx
    mov ecx, 512
    div ecx                  ; eax = FAT sector index, edx = byte within sector
    mov [fat_off], edx
    add eax, [fs_rsvd]
    mov edi, FSFAT
    call fs_read_sector
    mov edx, [fat_off]
    mov eax, [FSFAT + edx]
    and eax, 0x0FFFFFFF
    pop edx
    pop ecx
    ret

print_83:                    ; ESI -> 11-byte 8.3 name; print it as NAME.EXT
    pushad
    mov ecx, 8
    mov ebx, esi
.np:
    mov al, [ebx]
    cmp al, ' '
    je .npend
    call gputchar
    inc ebx
    dec ecx
    jnz .np
.npend:
    mov al, [esi + 8]
    cmp al, ' '
    je .done
    mov al, '.'
    call gputchar
    mov ecx, 3
    lea ebx, [esi + 8]
.ep:
    mov al, [ebx]
    cmp al, ' '
    je .done
    call gputchar
    inc ebx
    dec ecx
    jnz .ep
.done:
    popad
    ret

; ls : list files in the root directory
fat_list:
    call fat_mount
    test al, al
    jnz .fail
    mov eax, [fs_rootclus]
    mov [cur_clus], eax
.cl:
    mov eax, [cur_clus]
    call clus_to_sector
    mov [cur_sec], eax
    mov dword [sec_i], 0
.sl:
    mov eax, [cur_sec]
    add eax, [sec_i]
    mov edi, FSDIR
    call fs_read_sector
    mov esi, FSDIR
    mov ecx, 16
.el:
    mov al, [esi]
    test al, al
    jz .done
    cmp al, 0xE5
    je .ne
    mov al, [esi + 11]
    cmp al, 0x0F             ; long-file-name entry
    je .ne
    test al, 0x08           ; volume label / device
    jnz .ne
    push ecx
    call print_83
    call gnewline
    pop ecx
.ne:
    add esi, 32
    dec ecx
    jnz .el
    mov eax, [sec_i]
    inc eax
    mov [sec_i], eax
    cmp eax, [fs_spc]
    jb .sl
    mov eax, [cur_clus]
    call fat_next
    cmp eax, 0x0FFFFFF8
    jae .done
    mov [cur_clus], eax
    jmp .cl
.done:
    ret
.fail:
    cmp dword [install_mode], 0
    je .fail_live
    mov esi, gm_fs_inst          ; installed disk with no data partition
    call gprint
    ret
.fail_live:
    mov esi, gm_fs_fail
    call gprint
    ret

upcase:
    cmp al, 'a'
    jb .r
    cmp al, 'z'
    ja .r
    sub al, 32
.r:
    ret

name_to_83:                  ; ESI -> asciiz filename -> name83 (11 bytes, padded)
    pushad
    mov edi, name83
    mov ecx, 11
    mov al, ' '
.fill:
    mov [edi], al
    inc edi
    dec ecx
    jnz .fill
    mov edi, name83
    mov ecx, 8
.np:
    mov al, [esi]
    test al, al
    jz .done
    cmp al, '.'
    je .ext
    call upcase
    mov [edi], al
    inc edi
    inc esi
    dec ecx
    jnz .np
.skip:
    mov al, [esi]
    test al, al
    jz .done
    cmp al, '.'
    je .ext
    inc esi
    jmp .skip
.ext:
    inc esi
    mov edi, name83 + 8
    mov ecx, 3
.ep:
    mov al, [esi]
    test al, al
    jz .done
    call upcase
    mov [edi], al
    inc edi
    inc esi
    dec ecx
    jnz .ep
.done:
    popad
    ret

cmp83:                       ; compare [ESI..+11] with name83; ZF=1 if equal
    pushad
    mov edi, name83
    mov ecx, 11
.c:
    mov al, [esi]
    mov ah, [edi]
    cmp al, ah
    jne .ne
    inc esi
    inc edi
    dec ecx
    jnz .c
    popad
    xor eax, eax
    ret
.ne:
    popad
    mov eax, 1
    and eax, eax
    ret

; cat : ESI -> filename; print the file's contents
fat_cat:
    call name_to_83
    call fat_mount
    test al, al
    jnz .fail
    mov eax, [fs_rootclus]
    mov [cur_clus], eax
.cl:
    mov eax, [cur_clus]
    call clus_to_sector
    mov [cur_sec], eax
    mov dword [sec_i], 0
.sl:
    mov eax, [cur_sec]
    add eax, [sec_i]
    mov edi, FSDIR
    call fs_read_sector
    mov esi, FSDIR
    mov ecx, 16
.el:
    mov al, [esi]
    test al, al
    jz .notfound
    cmp al, 0xE5
    je .ne
    mov al, [esi + 11]
    cmp al, 0x0F
    je .ne
    test al, 0x08
    jnz .ne
    call cmp83
    je .found
.ne:
    add esi, 32
    dec ecx
    jnz .el
    mov eax, [sec_i]
    inc eax
    mov [sec_i], eax
    cmp eax, [fs_spc]
    jb .sl
    mov eax, [cur_clus]
    call fat_next
    cmp eax, 0x0FFFFFF8
    jae .notfound
    mov [cur_clus], eax
    jmp .cl
.found:
    movzx eax, word [esi + 20]       ; first cluster hi
    shl eax, 16
    movzx ebx, word [esi + 26]       ; first cluster lo
    or eax, ebx
    mov [cur_clus], eax
    mov eax, [esi + 28]              ; file size
    mov [file_rem], eax
.fcl:
    mov eax, [cur_clus]
    call clus_to_sector
    mov [cur_sec], eax
    mov dword [sec_i], 0
.fsl:
    cmp dword [file_rem], 0
    je .fdone
    mov eax, [cur_sec]
    add eax, [sec_i]
    mov edi, FSDIR
    call fs_read_sector
    mov esi, FSDIR
    mov ecx, 512
    cmp ecx, [file_rem]
    jbe .pgo
    mov ecx, [file_rem]
.pgo:
    sub [file_rem], ecx
.pb:
    mov al, [esi]
    cmp al, 0x0D                     ; skip CR, keep LF
    je .psk
    call gputchar
.psk:
    inc esi
    dec ecx
    jnz .pb
    mov eax, [sec_i]
    inc eax
    mov [sec_i], eax
    cmp eax, [fs_spc]
    jb .fsl
    mov eax, [cur_clus]
    call fat_next
    cmp eax, 0x0FFFFFF8
    jae .fdone
    mov [cur_clus], eax
    jmp .fcl
.fdone:
    call gnewline
    ret
.notfound:
    mov esi, gm_fs_nofile
    call gprint
    ret
.fail:
    mov esi, gm_fs_fail
    call gprint
    ret

; ================= FAT32 write (create/overwrite a file in the root dir) =================
fs_write_sector:             ; EAX = partition-relative LBA, ESI = 512-byte source
    cmp dword [vol], 0           ; never write to the USB stick (read-only)
    jne .ro
    pushad
    add eax, [part_base]
    mov bl, [0x1014]         ; write to the boot drive (holds the data partition)
    mov [inst_drive], bl
    call bios_write_lba
    popad
.ro:
    ret

fat_find_free:               ; [need_clusters] in -> clus_list[]; AL = 0 ok, 1 = full
    pushad
    mov dword [got_clus], 0
    mov dword [scan_c], 2
.next:
    mov eax, [got_clus]
    cmp eax, [need_clusters]
    jae .ok
    mov eax, [fs_fatsz]
    shl eax, 7               ; ~entries per FAT
    cmp [scan_c], eax
    jae .full
    mov eax, [scan_c]
    call fat_next            ; -> EAX = current FAT value (0 = free)
    test eax, eax
    jnz .used
    mov ecx, [got_clus]
    mov eax, [scan_c]
    mov [clus_list + ecx*4], eax
    inc dword [got_clus]
.used:
    inc dword [scan_c]
    jmp .next
.ok:
    popad
    xor al, al
    ret
.full:
    popad
    mov al, 1
    ret

fat_set_entry:               ; EAX = cluster, EDX = value -> both FAT copies
    pushad
    mov [fse_val], edx
    shl eax, 2
    xor edx, edx
    mov ecx, 512
    div ecx
    mov [fse_sec], eax
    mov [fse_off], edx
    mov dword [fse_copy], 0
.cp:
    mov eax, [fse_copy]
    cmp eax, [fs_nfat]
    jae .done
    mov eax, [fse_copy]
    imul eax, [fs_fatsz]
    add eax, [fs_rsvd]
    add eax, [fse_sec]
    mov [fse_lba], eax
    mov edi, FSFAT
    mov eax, [fse_lba]
    call fs_read_sector
    mov edi, [fse_off]
    mov edx, [fse_val]
    mov [FSFAT + edi], edx
    mov esi, FSFAT
    mov eax, [fse_lba]
    call fs_write_sector
    inc dword [fse_copy]
    jmp .cp
.done:
    popad
    ret

; add/overwrite a directory entry in directory cluster [de_dir].
; name in name83, attribute [de_attr], first cluster [de_clus], size [de_size].
; AL = 0 ok, 1 = directory full.  (single-cluster directories: 16 entries max)
dir_add_entry:
    pushad
    mov eax, [de_dir]
    call clus_to_sector
    mov [wd_sec], eax
    mov edi, FSDIR
    mov eax, [wd_sec]
    call fs_read_sector
    xor ecx, ecx
.f:
    cmp ecx, 16
    jae .full
    mov eax, ecx
    shl eax, 5
    mov esi, FSDIR
    add esi, eax
    mov al, [esi]
    test al, al
    jz .use
    cmp al, 0xE5
    je .use
    push ecx
    call cmp83               ; ESI vs name83 (overwrite same name)
    pop ecx
    je .use
    inc ecx
    jmp .f
.use:
    mov eax, ecx
    shl eax, 5
    mov edi, FSDIR
    add edi, eax
    mov [wd_slot], edi
    mov esi, name83
    mov ecx, 11
    rep movsb
    mov edi, [wd_slot]
    mov eax, [de_attr]
    mov [edi+11], al
    mov byte [edi+12], 0
    mov byte [edi+13], 0
    mov word [edi+14], 0
    mov word [edi+16], 0
    mov word [edi+18], 0
    mov word [edi+22], 0
    mov word [edi+24], 0
    mov eax, [de_clus]
    mov [edi+26], ax             ; first cluster low
    shr eax, 16
    mov [edi+20], ax             ; first cluster high
    mov eax, [de_size]
    mov [edi+28], eax            ; size
    mov eax, [wd_sec]
    mov esi, FSDIR
    call fs_write_sector
    popad
    xor al, al
    ret
.full:
    popad
    mov al, 1
    ret

; write a file: ESI = data, ECX = length, filename already in name83. AL=0 ok/1 fail
fat_write_file:
    call fat_mount
    test al, al
    jnz .fail
    mov [wf_src], esi
    mov [wf_len], ecx
    test ecx, ecx
    jnz .nz
    mov dword [need_clusters], 1
    jmp .have
.nz:
    mov eax, ecx
    mov ebx, 512
    imul ebx, [fs_spc]
    add eax, ebx
    dec eax
    xor edx, edx
    div ebx
    mov [need_clusters], eax
.have:
    cmp dword [need_clusters], 16
    ja .fail
    call fat_find_free
    test al, al
    jnz .fail
    mov dword [wf_i], 0
.wl:
    mov eax, [wf_i]
    cmp eax, [need_clusters]
    jae .dir
    ; stage one sector: zero, then copy this cluster's slice of the data
    mov edi, WSECT
    xor eax, eax
    mov ecx, 128
    rep stosd
    mov eax, [wf_i]
    shl eax, 9
    mov esi, [wf_src]
    add esi, eax
    mov ecx, [wf_len]
    sub ecx, eax
    cmp ecx, 512
    jbe .cok
    mov ecx, 512
.cok:
    mov edi, WSECT
    rep movsb
    mov ecx, [wf_i]
    mov eax, [clus_list + ecx*4]
    mov [wf_curclus], eax
    call clus_to_sector
    mov esi, WSECT
    call fs_write_sector
    ; link this cluster in the FAT
    mov eax, [wf_i]
    inc eax
    cmp eax, [need_clusters]
    jae .last
    mov ecx, [wf_i]
    mov edx, [clus_list + ecx*4 + 4]
    jmp .setf
.last:
    mov edx, 0x0FFFFFFF
.setf:
    mov eax, [wf_curclus]
    call fat_set_entry
    inc dword [wf_i]
    jmp .wl
.dir:
    mov eax, [save_dir]         ; write the entry into the current directory
    mov [de_dir], eax
    mov eax, [wf_attr]           ; 0x20 archive normally; 0x27 for system files
    mov [de_attr], eax
    mov eax, [clus_list]
    mov [de_clus], eax
    mov eax, [wf_len]
    mov [de_size], eax
    call dir_add_entry           ; AL = 0 ok / 1 full
    ret
.fail:
    mov al, 1
    ret

; create a subdirectory (name in name83) inside [cwd_cluster]. AL = 0 ok / 1 fail
fat_mkdir:
    call fat_mount
    test al, al
    jnz .fail
    mov dword [need_clusters], 1
    call fat_find_free
    test al, al
    jnz .fail
    mov eax, [clus_list]
    mov [mk_clus], eax
    mov edx, 0x0FFFFFFF          ; end-of-chain
    call fat_set_entry
    ; build the new dir's first sector: "." and ".." then zeros
    mov edi, WSECT
    xor eax, eax
    mov ecx, 128
    rep stosd
    mov edi, WSECT              ; "."  -> the new cluster
    call .dotname
    mov byte [WSECT+11], 0x10
    mov eax, [mk_clus]
    mov [WSECT+26], ax
    shr eax, 16
    mov [WSECT+20], ax
    mov edi, WSECT+32          ; ".." -> parent (0 if parent is root)
    call .dotdotname
    mov byte [WSECT+32+11], 0x10
    mov eax, [cwd_cluster]
    cmp eax, [fs_rootclus]
    jne .pnr
    xor eax, eax
.pnr:
    mov [WSECT+32+26], ax
    shr eax, 16
    mov [WSECT+32+20], ax
    mov eax, [mk_clus]
    call clus_to_sector
    mov esi, WSECT
    call fs_write_sector
    ; add the folder entry into the parent (cwd)
    mov eax, [cwd_cluster]
    mov [de_dir], eax
    mov eax, [mk_attr]           ; 0x10 normally; 0x16 for the hidden SYSTEM folder
    mov [de_attr], eax
    mov eax, [mk_clus]
    mov [de_clus], eax
    mov dword [de_size], 0
    call dir_add_entry
    ret
.fail:
    mov al, 1
    ret
.dotname:
    mov byte [edi], '.'
    push edi
    inc edi
    mov ecx, 10
    mov al, ' '
    rep stosb
    pop edi
    ret
.dotdotname:
    mov byte [edi], '.'
    mov byte [edi+1], '.'
    push edi
    add edi, 2
    mov ecx, 9
    mov al, ' '
    rep stosb
    pop edi
    ret

; read directory cluster EAX into the display arrays; captures ".." -> parent_cluster
dir_read:
    pushad
    mov [dr_clus], eax
    mov dword [dir_count], 0
    mov eax, [fs_rootclus]
    mov [parent_cluster], eax
    mov eax, [dr_clus]
    call clus_to_sector
    mov edi, FSDIR
    call fs_read_sector
    xor ebx, ebx
.e:
    cmp ebx, 16
    jae .done
    mov eax, ebx
    shl eax, 5
    lea esi, [FSDIR + eax]
    mov al, [esi]
    test al, al
    jz .done
    cmp al, 0xE5
    je .next
    mov al, [esi+11]
    cmp al, 0x0F
    je .next
    test al, 0x08
    jnz .next
    mov al, [esi]
    cmp al, '.'
    jne .store
    mov al, [esi+1]             ; ".."?  capture parent cluster
    cmp al, '.'
    jne .next
    movzx eax, word [esi+20]
    shl eax, 16
    movzx edx, word [esi+26]
    or eax, edx
    test eax, eax
    jnz .setpar
    mov eax, [fs_rootclus]     ; ".." cluster 0 means root
.setpar:
    mov [parent_cluster], eax
    jmp .next
.store:
    mov ecx, [dir_count]
    cmp ecx, 24
    jae .done
    mov eax, ecx
    imul eax, 11
    lea edi, [dir_name + eax]
    push ecx
    push ebx
    mov ecx, 11
    rep movsb
    pop ebx
    pop ecx
    mov eax, ebx
    shl eax, 5
    lea esi, [FSDIR + eax]
    mov al, [esi+11]
    mov [dir_attr + ecx], al
    movzx eax, word [esi+20]
    shl eax, 16
    movzx edx, word [esi+26]
    or eax, edx
    mov [dir_clus + ecx*4], eax
    mov eax, [esi+28]
    mov [dir_size + ecx*4], eax
    mov [dir_slot + ecx*4], ebx      ; remember the raw directory slot index
    inc dword [dir_count]
.next:
    inc ebx
    jmp .e
.done:
    popad
    ret

; load a FAT file into the editor grid.  EAX = first cluster, [fl_size] = byte size
fat_load_to_editor:
    pushad
    mov [fl_clus], eax               ; save the first cluster BEFORE AL is reused below
    mov edi, ed_buf                  ; (bug fix: 'mov al,32' used to clobber the cluster
    mov ecx, MAXCOLS*MAXROWS         ;  number, so files opened as blank spaces)
    mov al, ' '
    rep stosb
    mov edi, SAVEBUF
    mov [fl_dst], edi
    mov eax, [fl_size]
    mov [fl_rem], eax
.rc:
    cmp dword [fl_rem], 0
    je .parse
    mov eax, [fl_clus]
    cmp eax, 0x0FFFFFF8
    jae .parse
    call clus_to_sector
    mov edi, FSDIR
    call fs_read_sector
    mov ecx, [fl_rem]
    cmp ecx, 512
    jbe .cc
    mov ecx, 512
.cc:
    mov esi, FSDIR
    mov edi, [fl_dst]
    push ecx
    rep movsb
    pop ecx
    add [fl_dst], ecx
    sub [fl_rem], ecx
    mov eax, [fl_clus]
    call fat_next
    mov [fl_clus], eax
    jmp .rc
.parse:
    mov esi, SAVEBUF
    mov eax, [fl_size]
    mov [fl_total], eax
    mov dword [ed_col], 0
    mov dword [ed_row], 0
.pl:
    cmp dword [fl_total], 0
    je .pdone
    mov al, [esi]
    inc esi
    dec dword [fl_total]
    cmp al, 13
    je .pl
    cmp al, 10
    je .nl
    mov ebx, [ed_row]
    imul ebx, MAXCOLS
    add ebx, [ed_col]
    mov [ed_buf + ebx], al
    inc dword [ed_col]
    cmp dword [ed_col], MAXCOLS
    jl .pl
    mov dword [ed_col], 0
    inc dword [ed_row]
    cmp dword [ed_row], MAXROWS
    jl .pl
    dec dword [ed_row]
    jmp .pl
.nl:
    mov dword [ed_col], 0
    inc dword [ed_row]
    cmp dword [ed_row], MAXROWS
    jl .pl
    dec dword [ed_row]
    jmp .pl
.pdone:
    popad
    ret

; free a whole cluster chain (set each FAT entry to 0). EAX = first cluster
fat_free_chain:
    pushad
.l:
    cmp eax, 2
    jb .done
    cmp eax, 0x0FFFFFF8
    jae .done
    mov [fc_cur], eax
    call fat_next               ; EAX -> next cluster
    mov [fc_next], eax
    mov eax, [fc_cur]
    xor edx, edx
    call fat_set_entry          ; mark current cluster free
    mov eax, [fc_next]
    jmp .l
.done:
    popad
    ret

; rename the entry at display row [rename_row] in cwd to name83
fat_rename:
    pushad
    mov eax, [cwd_cluster]
    call clus_to_sector
    mov [wd_sec], eax
    mov edi, FSDIR
    mov eax, [wd_sec]
    call fs_read_sector
    mov ebx, [rename_row]
    mov eax, [dir_slot + ebx*4]
    shl eax, 5
    lea edi, [FSDIR + eax]
    mov esi, name83
    mov ecx, 11
    rep movsb                   ; overwrite the 11 name bytes
    mov eax, [wd_sec]
    mov esi, FSDIR
    call fs_write_sector
    popad
    ret

; is directory cluster [del_clus] empty (only . and ..)?  AL = 1 empty / 0 not
dir_is_empty:
    pushad
    mov eax, [del_clus]
    call clus_to_sector
    mov edi, FSDIR
    call fs_read_sector
    xor ebx, ebx
.e:
    cmp ebx, 16
    jae .empty
    mov eax, ebx
    shl eax, 5
    lea esi, [FSDIR + eax]
    mov al, [esi]
    test al, al
    jz .empty
    cmp al, 0xE5
    je .next
    cmp al, '.'                 ; skip "." and ".."
    je .next
    popad
    xor al, al                  ; a real entry exists -> not empty
    ret
.next:
    inc ebx
    jmp .e
.empty:
    popad
    mov al, 1
    ret

; delete the entry at display row [del_row].  AL = 0 ok / 1 = folder not empty
; delete the entry at [del_row]. Outside Trash -> move to Trash. Inside Trash
; (cwd == trash_cluster) -> permanently free. AL = 0 ok / 1 = couldn't (trash full)
fat_delete:
    pushad
    ; never delete the Trash folder itself
    mov ebx, [del_row]
    mov eax, [dir_clus + ebx*4]
    cmp eax, [trash_cluster]
    je .refuse
    mov eax, [cwd_cluster]
    cmp eax, [trash_cluster]
    je .perm
    cmp dword [trash_cluster], 0
    je .perm                    ; no trash available -> permanent
    ; ---- move to Trash ----
    mov ebx, [del_row]
    mov eax, ebx
    imul eax, 11
    lea esi, [dir_name + eax]
    mov edi, name83
    mov ecx, 11
    rep movsb
    mov eax, [trash_cluster]
    mov [de_dir], eax
    mov ebx, [del_row]
    movzx eax, byte [dir_attr + ebx]
    mov [de_attr], eax
    mov eax, [dir_clus + ebx*4]
    mov [de_clus], eax
    mov eax, [dir_size + ebx*4]
    mov [de_size], eax
    call dir_add_entry
    test al, al
    jnz .refuse
    call .unlink                ; remove from source (keep clusters)
    popad
    xor al, al
    ret
.perm:
    mov ebx, [del_row]
    mov al, [dir_attr + ebx]
    test al, 0x10
    jz .file
    mov eax, [dir_clus + ebx*4]
    xor edx, edx
    call fat_set_entry          ; free the folder's cluster
    jmp .dou
.file:
    mov ebx, [del_row]
    mov eax, [dir_clus + ebx*4]
    test eax, eax
    jz .dou
    call fat_free_chain
.dou:
    call .unlink
    popad
    xor al, al
    ret
.refuse:
    popad
    mov al, 1
    ret
.unlink:                        ; mark cwd/dir_slot[del_row] deleted, write sector
    mov eax, [cwd_cluster]
    call clus_to_sector
    mov [wd_sec], eax
    mov edi, FSDIR
    mov eax, [wd_sec]
    call fs_read_sector
    mov ebx, [del_row]
    mov eax, [dir_slot + ebx*4]
    shl eax, 5
    mov byte [FSDIR + eax], 0xE5
    mov eax, [wd_sec]
    mov esi, FSDIR
    call fs_write_sector
    ret

; ensure a TRASH folder exists in root; set [trash_cluster]
ensure_trash:
    cmp dword [has_fatfs], 0
    je .ret
    pushad
    call fat_mount
    mov edi, name83
    mov esi, trash_name
    mov ecx, 11
    rep movsb
    mov eax, [fs_rootclus]
    call clus_to_sector
    mov edi, FSDIR
    call fs_read_sector
    xor ebx, ebx
.f:
    cmp ebx, 16
    jae .create
    mov eax, ebx
    shl eax, 5
    lea esi, [FSDIR + eax]
    mov al, [esi]
    test al, al
    jz .create
    cmp al, 0xE5
    je .n
    call cmp83
    jne .n
    movzx eax, word [esi+20]
    shl eax, 16
    movzx edx, word [esi+26]
    or eax, edx
    mov [trash_cluster], eax
    jmp .done
.n:
    inc ebx
    jmp .f
.create:
    cmp dword [install_mode], 0
    je .done
    mov eax, [fs_rootclus]
    mov [cwd_cluster], eax
    mov edi, name83
    mov esi, trash_name
    mov ecx, 11
    rep movsb
    call fat_mkdir
    mov eax, [mk_clus]
    mov [trash_cluster], eax
.done:
    popad
.ret:
    ret

; permanently empty the Trash: free every item's clusters, reset to just . / ..
empty_trash:
    cmp dword [install_mode], 0
    je .ret
    cmp dword [trash_cluster], 0
    je .ret
    pushad
    mov eax, [trash_cluster]
    call clus_to_sector
    mov [wd_sec], eax
    mov edi, FSDIR
    mov eax, [wd_sec]
    call fs_read_sector
    xor ebx, ebx
.l:
    cmp ebx, 16
    jae .clear
    mov eax, ebx
    shl eax, 5
    lea esi, [FSDIR + eax]
    mov al, [esi]
    test al, al
    jz .clear
    cmp al, 0xE5
    je .n
    cmp al, '.'
    je .n
    movzx eax, word [esi+20]
    shl eax, 16
    movzx edx, word [esi+26]
    or eax, edx
    test eax, eax
    jz .n
    call fat_free_chain         ; free the item's clusters (uses FSFAT, keeps FSDIR)
.n:
    inc ebx
    jmp .l
.clear:
    mov edi, WSECT              ; rebuild the trash dir with only . and ..
    xor eax, eax
    mov ecx, 128
    rep stosd
    mov byte [WSECT+0], '.'
    mov edi, WSECT+1
    mov ecx, 10
    mov al, ' '
    rep stosb
    mov byte [WSECT+11], 0x10
    mov eax, [trash_cluster]
    mov [WSECT+26], ax
    shr eax, 16
    mov [WSECT+20], ax
    mov byte [WSECT+32], '.'
    mov byte [WSECT+33], '.'
    mov edi, WSECT+34
    mov ecx, 9
    mov al, ' '
    rep stosb
    mov byte [WSECT+32+11], 0x10
    mov word [WSECT+32+26], 0
    mov word [WSECT+32+20], 0
    mov eax, [trash_cluster]
    call clus_to_sector
    mov esi, WSECT
    call fs_write_sector
    popad
.ret:
    ret

; restore item at [fm_sel] from Trash back to the root directory
fat_restore:
    pushad
    mov ebx, [fm_sel]
    mov eax, ebx
    imul eax, 11
    lea esi, [dir_name + eax]
    mov edi, name83
    mov ecx, 11
    rep movsb
    mov eax, [fs_rootclus]
    mov [de_dir], eax
    mov ebx, [fm_sel]
    movzx eax, byte [dir_attr + ebx]
    mov [de_attr], eax
    mov eax, [dir_clus + ebx*4]
    mov [de_clus], eax
    mov eax, [dir_size + ebx*4]
    mov [de_size], eax
    call dir_add_entry
    mov eax, [cwd_cluster]      ; == trash; mark the trash entry deleted
    call clus_to_sector
    mov [wd_sec], eax
    mov edi, FSDIR
    mov eax, [wd_sec]
    call fs_read_sector
    mov ebx, [fm_sel]
    mov eax, [dir_slot + ebx*4]
    shl eax, 5
    mov byte [FSDIR + eax], 0xE5
    mov eax, [wd_sec]
    mov esi, FSDIR
    call fs_write_sector
    popad
    ret

; on icon-drag release: if dropped onto the Trash icon, move that file to Trash
drop_on_trash:
    cmp dword [install_mode], 0
    je .ret
    cmp dword [trash_cluster], 0
    je .ret
    push ebp
    xor ecx, ecx
    mov ebp, -1                 ; find the trash icon index
.ft:
    cmp ecx, [desk_count]
    jae .have
    mov eax, [desk_clus + ecx*4]
    cmp eax, [trash_cluster]
    jne .ftn
    mov ebp, ecx
.ftn:
    inc ecx
    jmp .ft
.have:
    cmp ebp, -1
    je .pret
    mov eax, [drag_icon]
    cmp eax, ebp
    je .pret                    ; can't trash the trash
    ; overlap: dragged icon centre inside the trash icon box
    mov ebx, [drag_icon]
    mov eax, [desk_ix + ebx*4]
    add eax, 32
    mov ecx, [desk_ix + ebp*4]
    cmp eax, ecx
    jl .pret
    add ecx, 64
    cmp eax, ecx
    jg .pret
    mov eax, [desk_iy + ebx*4]
    add eax, 28
    mov ecx, [desk_iy + ebp*4]
    cmp eax, ecx
    jl .pret
    add ecx, 58
    cmp eax, ecx
    jg .pret
    ; find the matching root entry and move it to Trash
    mov eax, [fs_rootclus]
    mov [cwd_cluster], eax
    call dir_read
    mov ebx, [drag_icon]
    mov edx, [desk_clus + ebx*4]
    xor ecx, ecx
.fr:
    cmp ecx, [dir_count]
    jae .pret
    mov eax, [dir_clus + ecx*4]
    cmp eax, edx
    je .found
    inc ecx
    jmp .fr
.found:
    mov [del_row], ecx
    call fat_delete
    mov dword [files_dirty], 1
    mov dword [desk_dirty], 1
.pret:
    pop ebp
.ret:
    ret

; save desktop icon positions to the reserved config sector (LBA 201)
desk_save_cfg:
    cmp dword [install_mode], 0
    je .ret
    pushad
    mov edi, WSECT
    xor eax, eax
    mov ecx, 128
    rep stosd
    mov esi, cfg_magic
    mov edi, WSECT
    mov ecx, 8
    rep movsb
    xor ebx, ebx
.l:
    cmp ebx, 12
    jae .wr
    mov eax, [desk_ix + ebx*4]
    mov [WSECT + 8 + ebx*8], eax
    mov eax, [desk_iy + ebx*4]
    mov [WSECT + 8 + ebx*8 + 4], eax
    inc ebx
    jmp .l
.wr:
    mov al, [0x1014]
    mov [inst_drive], al
    mov eax, 201
    mov esi, WSECT
    call bios_write_lba
    popad
.ret:
    ret

; load desktop icon positions from LBA 201 (if the config magic is present)
desk_load_cfg:
    cmp dword [has_fatfs], 0
    je .ret
    pushad
    mov eax, 201
    call bios_read_lba
    mov esi, DISKBUF
    mov edi, cfg_magic
    mov ecx, 8
.cmp:
    mov al, [esi]
    cmp al, [edi]
    jne .none
    inc esi
    inc edi
    dec ecx
    jnz .cmp
    xor ebx, ebx
.l:
    cmp ebx, 12
    jae .done
    mov eax, [DISKBUF + 8 + ebx*8]
    mov [desk_ix + ebx*4], eax
    mov eax, [DISKBUF + 8 + ebx*8 + 4]
    mov [desk_iy + ebx*4], eax
    inc ebx
    jmp .l
.done:
.none:
    popad
.ret:
    ret

; keyboard handler while renaming (AL = scancode)
rename_input:
    cmp al, 0x2A
    je .son
    cmp al, 0x36
    je .son
    cmp al, 0xAA
    je .soff
    cmp al, 0xB6
    je .soff
    cmp al, 0x01                ; Escape -> cancel
    je .cancel
    cmp al, 0x1C                ; Enter -> confirm
    je .confirm
    cmp al, 0x0E                ; Backspace
    je .back
    test al, 0x80
    jnz .ret
    movzx ebx, al
    cmp byte [rn_shift], 0
    je .un
    mov al, [scancodes_shift + ebx]
    jmp .have
.un:
    mov al, [scancodes + ebx]
.have:
    test al, al
    jz .ret
    mov ecx, [rename_len]
    cmp ecx, 12
    jae .ret
    call upcase
    mov [rename_buf + ecx], al
    inc dword [rename_len]
    mov ecx, [rename_len]
    mov byte [rename_buf + ecx], 0
    call recompose
    ret
.back:
    mov ecx, [rename_len]
    test ecx, ecx
    jz .ret
    dec ecx
    mov [rename_len], ecx
    mov byte [rename_buf + ecx], 0
    call recompose
    ret
.confirm:
    cmp dword [rename_len], 0
    je .cancel
    mov esi, rename_buf
    call name_to_83
    call fat_rename
    mov dword [rename_mode], 0
    mov dword [files_dirty], 1
    mov dword [desk_dirty], 1
    call recompose
    ret
.cancel:
    mov dword [rename_mode], 0
    call recompose
    ret
.son:
    mov byte [rn_shift], 1
    ret
.soff:
    mov byte [rn_shift], 0
    ret
.ret:
    ret

; TEMP self-test: write HELLO.TXT to the data partition at boot (verified offline)
fat_selftest:
    cmp dword [has_fatfs], 0
    je .r
    mov esi, st_name
    mov edi, name83
    mov ecx, 11
    rep movsb
    mov esi, st_data
    mov ecx, st_len
    call fat_write_file
.r:
    ret
st_name: db "HELLO   TXT"
st_data: db "Hi from NovaOS!", 13, 10
st_len   equ $ - st_data

; TEMP: exercise build_savetext + fat_write_file (the Save path) to the data partition
save_selftest:
    cmp dword [has_fatfs], 0
    je .r
    mov edi, ed_buf              ; blank the editor grid
    mov ecx, MAXCOLS*MAXROWS
    mov al, ' '
    rep stosb
    mov edi, ed_buf             ; put a line of text on row 0
    mov esi, save_test_str
    mov ecx, save_test_len
    rep movsb
    mov dword [ed_row], 0
    mov dword [ed_col], save_test_len
    call build_savetext          ; ECX = length, text at SAVEBUF
    push ecx
    mov edi, name83
    mov esi, savetest_name
    mov ecx, 11
    rep movsb
    pop ecx
    mov esi, SAVEBUF
    call fat_write_file
.r:
    ret
save_test_str: db "SAVE TEST LINE"
save_test_len equ $ - save_test_str
savetest_name: db "STEST   TXT"

; TEMP: run the storage scan, stash total/free at LBA 205 for verification
fm_selftest5:
    cmp dword [has_fatfs], 0
    je .r
    call count_free_clusters
    mov edi, WSECT
    xor eax, eax
    mov ecx, 128
    rep stosd
    mov eax, [stor_total]
    mov [WSECT], eax
    mov eax, [stor_free]
    mov [WSECT+4], eax
    mov al, [0x1014]
    mov [inst_drive], al
    mov eax, 205
    mov esi, WSECT
    call bios_write_lba
.r:
    ret

; TEMP: move README to trash, then restore it; also empty-trash a copy of TEST
fm_selftest4:
    cmp dword [has_fatfs], 0
    je .r
    mov dword [install_mode], 1
    call ensure_trash
    mov eax, [fs_rootclus]
    mov [cwd_cluster], eax
    call dir_read
    mov dword [del_row], 1          ; README -> trash
    call fat_delete
    mov eax, [trash_cluster]        ; go into trash, restore row 0 (README)
    mov [cwd_cluster], eax
    call dir_read
    mov dword [fm_sel], 0
    call fat_restore
.r:
    ret

; TEMP: exercise ensure_trash + move-to-trash + config save + marker write
fm_selftest3:
    cmp dword [has_fatfs], 0
    je .r
    mov dword [install_mode], 1
    call ensure_trash
    mov eax, [fs_rootclus]
    mov [cwd_cluster], eax
    call dir_read
    mov dword [del_row], 1          ; README -> trash
    call fat_delete
    call desk_read
    mov dword [desk_ix + 0], 500
    mov dword [desk_iy + 0], 300
    call desk_save_cfg
    ; marker write to LBA 200
    mov edi, WSECT
    xor eax, eax
    mov ecx, 128
    rep stosd
    mov esi, inst_magic
    mov edi, WSECT
    mov ecx, 8
    rep movsb
    mov al, [0x1014]
    mov [inst_drive], al
    mov eax, 200
    mov esi, WSECT
    call bios_write_lba
.r:
    ret

; TEMP: rename TEST.TXT -> RENAMED.TXT and delete README.TXT (in root)
fm_selftest2:
    cmp dword [has_fatfs], 0
    je .r
    mov eax, [fs_rootclus]
    mov [cwd_cluster], eax
    call dir_read
    mov edi, name83
    mov esi, fmst2_name
    mov ecx, 11
    rep movsb
    mov dword [rename_row], 0
    call fat_rename
    mov dword [del_row], 1
    call fat_delete
.r:
    ret
fmst2_name: db "RENAMED TXT"

; TEMP: mkdir MYDIR in root, then write NESTED.TXT inside it
fm_selftest:
    cmp dword [has_fatfs], 0
    je .r
    mov eax, [fs_rootclus]
    mov [cwd_cluster], eax
    mov edi, name83
    mov esi, fmst_dirname
    mov ecx, 11
    rep movsb
    call fat_mkdir
    mov eax, [mk_clus]           ; enter the new folder
    mov [cwd_cluster], eax
    mov [save_dir], eax
    mov edi, name83
    mov esi, fmst_filename
    mov ecx, 11
    rep movsb
    mov esi, fmst_data
    mov ecx, fmst_len
    call fat_write_file
.r:
    ret
fmst_dirname:  db "MYDIR      "
fmst_filename: db "NESTED  TXT"
fmst_data:     db "inside a folder!", 13, 10
fmst_len equ $ - fmst_data

; TEMP: replicate the installer's disk writes to the 2nd disk (no console I/O)
install_selftest:
    mov byte [inst_drive], 0x81
    call probe_drive
    test al, al
    jnz .r
    xor eax, eax
    mov esi, 0x7C00              ; boot sector -> LBA 0
    call bios_write_lba
    mov dword [inst_i], 0
.wk:
    mov eax, [inst_i]
    cmp eax, 199
    jae .fmt
    mov esi, 0x8000
    mov ebx, [inst_i]
    shl ebx, 9
    add esi, ebx
    mov eax, [inst_i]
    inc eax
    call bios_write_lba
    inc dword [inst_i]
    jmp .wk
.fmt:
    call fmt_fat
.r:
    ret

; format an empty FAT32 filesystem into the data partition (abs LBA 2048) of
; [inst_drive]. Stamps BPB/FSInfo/backup, zeroes both FATs + the root cluster,
; then writes the reserved FAT entries. Called by the installer.
fmt_fat:
    pushad
    mov esi, bpb_template        ; BPB -> abs 2048
    mov edi, WSECT
    mov ecx, 128
    rep movsd
    mov eax, 2048
    mov esi, WSECT
    call bios_write_lba
    mov esi, fsinfo_template     ; FSInfo -> abs 2049
    mov edi, WSECT
    mov ecx, 128
    rep movsd
    mov eax, 2049
    mov esi, WSECT
    call bios_write_lba
    mov esi, bpb_template        ; backup boot -> abs 2054
    mov edi, WSECT
    mov ecx, 128
    rep movsd
    mov eax, 2054
    mov esi, WSECT
    call bios_write_lba
    ; zero both FATs (2*512 sectors) starting at abs 2080, 64 sectors per call
    mov dword [fmt_i], 0
.zf:
    mov eax, [fmt_i]
    cmp eax, 1024
    jae .zfd
    mov eax, 2080
    add eax, [fmt_i]
    mov ecx, 64
    call bios_write_zeros
    add dword [fmt_i], 64
    jmp .zf
.zfd:
    mov eax, 3104                ; zero root dir cluster (abs 2048 + data_start 1056)
    mov ecx, 1
    call bios_write_zeros
    ; reserved FAT entries in the first sector of each FAT copy
    mov edi, WSECT
    xor eax, eax
    mov ecx, 128
    rep stosd
    mov dword [WSECT + 0], 0x0FFFFFF8
    mov dword [WSECT + 4], 0x0FFFFFFF
    mov dword [WSECT + 8], 0x0FFFFFFF
    mov eax, 2080               ; FAT copy 0
    mov esi, WSECT
    call bios_write_lba
    mov eax, 2592              ; FAT copy 1 (2080 + fatsz 512)
    mov esi, WSECT
    call bios_write_lba
    popad
    ret

; ---- FAT filesystem state ----
part_base:     dd 2048        ; FAT32 partition starts at LBA 2048 (1 MB aligned)
has_fatfs:     dd 0           ; 1 if a writable FAT data partition was found at boot
need_clusters: dd 0
got_clus:      dd 0
scan_c:        dd 0
clus_list:     times 18 dd 0
fse_val:       dd 0
fse_sec:       dd 0
fse_off:       dd 0
fse_copy:      dd 0
fse_lba:       dd 0
wf_src:        dd 0
wf_len:        dd 0
wf_i:          dd 0
wf_curclus:    dd 0
wd_sec:        dd 0
wd_slot:       dd 0
savelen:       dd 0
bs_last:       dd 0
fmt_i:         dd 0
; ---- file manager / directory state ----
de_dir:        dd 0
de_attr:       dd 0
de_clus:       dd 0
de_size:       dd 0
cwd_cluster:   dd 0
parent_cluster: dd 0
save_dir:      dd 0
mk_clus:       dd 0
dr_clus:       dd 0
dir_count:     dd 0
folder_slot:   dd 0
files_dirty:   dd 1
fm_sel:        dd 0
fmrow_y:       dd 0
fl_clus:       dd 0
fl_dst:        dd 0
fl_rem:        dd 0
fl_size:       dd 0
fl_total:      dd 0
dir_name:      times 24*11 db 0
dir_attr:      times 24 db 0
dir_clus:      times 24 dd 0
dir_size:      times 24 dd 0
dir_slot:      times 24 dd 0
rename_mode:   dd 0
rename_row:    dd 0
rename_len:    dd 0
rn_shift:      db 0
rn_tx0:        dd 0
rename_buf:    times 16 db 0
del_row:       dd 0
del_clus:      dd 0
fc_cur:        dd 0
fc_next:       dd 0
desk_count:    dd 0
desk_dirty:    dd 1
desk_pos_init: dd 0
ico_x:         dd 0
ico_y:         dd 0
drag_icon:     dd 0
icon_off_x:    dd 0
icon_off_y:    dd 0
icon_moved:    dd 0
icon_press_x:  dd 0
icon_press_y:  dd 0
desk_name:     times 12*11 db 0
desk_attr:     times 12 db 0
desk_clus:     times 12 dd 0
desk_size:     times 12 dd 0
desk_ix:       times 12 dd 0
desk_iy:       times 12 dd 0
trash_cluster: dd 0
trash_name:    db "TRASH      "
cfg_magic:     db "NOVAICON"
ata_devbit:    db 0
%include "fatboot.inc"
fs_spc:        dd 0
fs_rsvd:       dd 0
fs_nfat:       dd 0
fs_fatsz:      dd 0
fs_rootclus:   dd 0
fs_totsec:     dd 0
fs_data_start: dd 0
set_tab:       dd 0
sound_on:      dd 1
stor_total:    dd 0
stor_free:     dd 0
stor_fsec:     dd 0
stor_n:        dd 0
stor_scanned:  dd 0
stor_tmp:      dd 0
cur_clus:      dd 0
cur_sec:       dd 0
sec_i:         dd 0
fat_off:       dd 0
file_rem:      dd 0
name83:        times 11 db 0

; ===== prefix match: ZF=1 if EDI (prefix) starts ESI; ESI left past the prefix =====
strprefix:
.next:
    mov al, [edi]
    test al, al
    jz .match
    mov ah, [esi]
    cmp al, ah
    jne .nomatch
    inc esi
    inc edi
    jmp .next
.match:
    xor eax, eax
    ret
.nomatch:
    mov eax, 1
    and eax, eax
    ret

; ================= string compare =================
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

; ================= 32bpp graphics primitives =================
fillrect:                    ; [rx],[ry],[rw],[rh],[rcolor]
    pushad
    mov ebx, [ry]
    mov ecx, [rh]
.row:
    test ecx, ecx
    jz .done
    mov eax, ebx
    imul eax, [pitch]
    add eax, [lfb]
    mov edx, [rx]
    shl edx, 2
    add eax, edx
    mov edi, eax
    mov edx, [rw]
    mov eax, [rcolor]
.col:
    test edx, edx
    jz .nextrow
    mov [edi], eax
    add edi, 4
    dec edx
    jmp .col
.nextrow:
    inc ebx
    dec ecx
    jmp .row
.done:
    popad
    ret

draw_char:                   ; AL=char, [tx],[ty],[tcolor]
    pushad
    mov ebx, [tx]            ; clip: skip chars off the left/right screen edge
    cmp ebx, 0
    jl .done                 ; (prevents framebuffer wrap-around)
    add ebx, 8
    cmp ebx, [scrw]
    jg .done
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
    mov eax, [ty]
    add eax, ebx
    imul eax, [pitch]
    add eax, [lfb]
    mov edx, [tx]
    add edx, ecx
    shl edx, 2
    add eax, edx
    mov edi, eax
    mov eax, [tcolor]
    mov [edi], eax
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

draw_text:                   ; ESI string, [tx],[ty],[tcolor]
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

kbd_flush:
.f:
    in al, 0x64
    test al, 0x01
    jz .done
    in al, 0x60
    jmp .f
.done:
    ret

; ================= taskbar / Start =================
draw_taskbar:
    pushad
    mov dword [rx], 0
    mov eax, [scrh]
    sub eax, 30
    mov [ry], eax
    mov eax, [scrw]
    mov [rw], eax
    mov dword [rh], 30
    mov dword [rcolor], C_DGRAY
    call fillrect
    mov dword [rx], 4
    mov eax, [scrh]
    sub eax, 27
    mov [ry], eax
    mov dword [rw], 76
    mov dword [rh], 24
    mov dword [rcolor], C_GREEN
    call fillrect
    mov dword [tcolor], C_WHITE
    mov dword [tx], 16
    mov eax, [scrh]
    sub eax, 23
    mov [ty], eax
    mov esi, txt_start
    call draw_text
    popad
    ret

; ================= PS/2 mouse (polled) =================
ps2_wait_in:                 ; wait until controller can accept input (timeout)
    push ecx
    mov ecx, 200000
.w:
    in al, 0x64
    test al, 0x02
    jz .ok
    dec ecx
    jnz .w
.ok:
    pop ecx
    ret
ps2_wait_out:                ; wait until controller has output (timeout)
    push ecx
    mov ecx, 200000
.w:
    in al, 0x64
    test al, 0x01
    jnz .ok
    dec ecx
    jnz .w
.ok:
    pop ecx
    ret

mouse_write:                 ; AL = byte -> mouse; returns ACK in AL
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
    cmp al, 0xFA             ; enable-reporting ACK?
    jne .no
    mov byte [mouse_present], 1
    ret
.no:
    mov byte [mouse_present], 0
    ret

mouse_feed:                  ; AL = a mouse byte
    mov bl, [mouse_cycle]
    cmp bl, 1
    je .b1
    cmp bl, 2
    je .b2
.b0:
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
    call mouse_update
.ret:
    ret

mouse_update:
    pushad
    movsx eax, byte [mouse_dx]
    add eax, [mouse_x]
    cmp eax, 0
    jge .xlo
    xor eax, eax
.xlo:
    mov ebx, [scrw]
    sub ebx, CUR_W
    cmp eax, ebx
    jle .xhi
    mov eax, ebx
.xhi:
    mov [mouse_x], eax
    movsx eax, byte [mouse_dy]
    mov ebx, [mouse_y]
    sub ebx, eax
    mov eax, ebx
    cmp eax, 0
    jge .ylo
    xor eax, eax
.ylo:
    mov ebx, [scrh]
    sub ebx, CUR_H
    cmp eax, ebx
    jle .yhi
    mov eax, ebx
.yhi:
    mov [mouse_y], eax
    ; current left-button state
    mov al, [mouse_flags]
    and al, 1
    mov [curbtn], al
    ; dragging?
    cmp byte [drag_mode], 0
    jne .dragging
    ; ---- not dragging: move the cursor ----
    call restore_cursor
    mov eax, [mouse_x]
    mov [cur_x], eax
    mov eax, [mouse_y]
    mov [cur_y], eax
    call save_cursor
    call draw_cursor
    ; ---- new LEFT-press edge ----
    mov al, [curbtn]
    mov bl, [prev_btn]
    mov [prev_btn], al
    test al, al
    jz .rbtn
    test bl, bl
    jnz .rbtn
    ; click on the toast closes it
    cmp dword [notif_timer], 0
    je .ntoast
    mov eax, [mouse_x]
    mov ebx, [scrw]
    sub ebx, 320
    cmp eax, ebx
    jl .ntoast
    mov eax, [mouse_y]
    mov ebx, [scrh]
    sub ebx, 98
    cmp eax, ebx
    jl .ntoast
    mov ebx, [scrh]
    sub ebx, 40
    cmp eax, ebx
    jg .ntoast
    call toast_dismiss
    jmp .rbtn
.ntoast:
    cmp byte [startcm_open], 0
    je .nscm
    call startcm_click
    jmp .rbtn
.nscm:
    cmp byte [cmenu_open], 0
    je .ncm
    call cmenu_click
    jmp .rbtn
.ncm:
    cmp byte [menu_open], 0
    je .mc
    call menu_click
    jmp .rbtn
.mc:
    call hit_start
    test eax, eax
    jz .ns
    call open_menu
    jmp .rbtn
.ns:
    call hit_clock
    test eax, eax
    jz .ns2
    xor dword [notif_open], 1
    call recompose
    jmp .rbtn
.ns2:
    call hit_taskbar
    cmp eax, -1
    je .nt
    call focus_window
    call recompose
    jmp .rbtn
.nt:
    call find_window_at
    cmp eax, -1
    je .deskclick
    mov [drag_win], eax
    call focus_window
    call recompose
    call check_regions          ; may begin an outline drag
    jmp .rbtn
.deskclick:
    call desk_hit
    cmp eax, -1
    je .rbtn
    mov [drag_icon], eax        ; begin dragging this icon
    mov ebx, eax
    mov eax, [desk_ix + ebx*4]
    sub eax, [mouse_x]
    mov [icon_off_x], eax
    mov eax, [desk_iy + ebx*4]
    sub eax, [mouse_y]
    mov [icon_off_y], eax
    mov eax, [mouse_x]
    mov [icon_press_x], eax
    mov eax, [mouse_y]
    mov [icon_press_y], eax
    mov dword [icon_moved], 0
    mov byte [drag_mode], 4
    jmp .rbtn
.rbtn:
    ; ---- new RIGHT-press edge -> desktop context menu ----
    mov al, [mouse_flags]
    and al, 2
    mov bl, [prev_rbtn]
    mov [prev_rbtn], al
    test al, al
    jz .end
    test bl, bl
    jnz .end
    cmp byte [cmenu_open], 0
    jne .end
    cmp byte [menu_open], 0
    jne .end
    cmp byte [startcm_open], 0
    jne .end
    call hit_start               ; right-click on Start -> Device Manager / Task Manager / Admin Terminal
    test eax, eax
    jz .not_start_rc
    call open_start_cmenu
    jmp .end
.not_start_rc:
    call find_window_at
    cmp eax, -1
    jne .end
    call desk_hit               ; right-click on the Trash bin -> empty it
    cmp eax, -1
    je .opencm
    mov ebx, eax
    mov eax, [desk_clus + ebx*4]
    cmp eax, [trash_cluster]
    jne .opencm
    cmp dword [install_mode], 0
    je .opencm
    call empty_trash
    mov dword [files_dirty], 1
    mov dword [desk_dirty], 1
    mov esi, nt_emptied1
    mov edi, nt_emptied2
    call notify
    call recompose
    jmp .end
.opencm:
    call open_cmenu
    jmp .end
.dragging:
    mov al, [curbtn]
    mov [prev_btn], al
    test al, al
    jz .dragend
    cmp byte [drag_mode], 4
    je .icondrag
    cmp byte [drag_mode], 3
    je .painting
    call ol_xor                 ; erase old outline
    call ol_update              ; move/resize the outline with the mouse
    call ol_xor                 ; draw new outline
    jmp .end
.icondrag:
    mov eax, [mouse_x]          ; past the click threshold? -> it's a drag
    sub eax, [icon_press_x]
    jns .mx
    neg eax
.mx:
    cmp eax, 4
    jg .imoved
    mov eax, [mouse_y]
    sub eax, [icon_press_y]
    jns .my
    neg eax
.my:
    cmp eax, 4
    jg .imoved
    jmp .ipos
.imoved:
    mov dword [icon_moved], 1
.ipos:
    mov ebx, [drag_icon]
    mov eax, [mouse_x]
    add eax, [icon_off_x]
    mov [desk_ix + ebx*4], eax
    mov eax, [mouse_y]
    add eax, [icon_off_y]
    mov [desk_iy + ebx*4], eax
    mov eax, [mouse_x]
    mov [cur_x], eax
    mov eax, [mouse_y]
    mov [cur_y], eax
    call recompose
    jmp .end
.painting:
    call restore_cursor
    mov eax, [mouse_x]
    mov [cur_x], eax
    mov eax, [mouse_y]
    mov [cur_y], eax
    call paint_dot
    call save_cursor
    call draw_cursor
    jmp .end
.dragend:
    cmp byte [drag_mode], 4
    je .iconend
    cmp byte [drag_mode], 3
    je .paintend
    call ol_xor                 ; erase outline
    call drag_commit            ; apply new geometry to the window
    mov byte [drag_mode], 0
    call recompose
    jmp .end
.iconend:
    mov byte [drag_mode], 0
    cmp dword [icon_moved], 0
    jne .iconmoved
    mov eax, [drag_icon]        ; a click without moving -> open it
    call desk_open_icon
    jmp .end
.iconmoved:
    call drop_on_trash          ; dropped on the bin? -> move to Trash
    call desk_save_cfg          ; persist the new icon layout
    call recompose
    jmp .end
.paintend:
    mov byte [drag_mode], 0
.end:
    popad
    ret

; ---- outline drag (XOR rectangle) ----
ol_xor:
    pushad
    mov ebx, [ol_y]
    call .hline
    mov ebx, [ol_y]
    add ebx, [ol_h]
    dec ebx
    call .hline
    mov ebx, [ol_x]
    call .vline
    mov ebx, [ol_x]
    add ebx, [ol_w]
    dec ebx
    call .vline
    popad
    ret
.hline:                         ; EBX = y
    mov eax, ebx
    imul eax, [pitch]
    add eax, [lfb]
    mov edx, [ol_x]
    shl edx, 2
    add eax, edx
    mov edi, eax
    mov ecx, [ol_w]
.hp:
    mov eax, [edi]
    xor eax, 0x00FFFFFF
    mov [edi], eax
    add edi, 4
    dec ecx
    jnz .hp
    ret
.vline:                         ; EBX = x
    mov eax, [ol_y]
    imul eax, [pitch]
    add eax, [lfb]
    mov edx, ebx
    shl edx, 2
    add eax, edx
    mov edi, eax
    mov ecx, [ol_h]
.vp:
    mov eax, [edi]
    xor eax, 0x00FFFFFF
    mov [edi], eax
    add edi, [pitch]
    dec ecx
    jnz .vp
    ret

ol_begin:                       ; hide cursor, seed outline from the window
    call restore_cursor
    mov eax, [drag_win]
    mov ebx, [ws_x + eax*4]
    mov [ol_x], ebx
    mov ebx, [ws_y + eax*4]
    mov [ol_y], ebx
    mov ebx, [ws_w + eax*4]
    mov [ol_w], ebx
    mov ebx, [ws_h + eax*4]
    mov [ol_h], ebx
    call ol_xor
    ret

ol_update:
    cmp byte [drag_mode], 2
    je .resize
    ; move
    mov ebx, [mouse_x]
    sub ebx, [drag_dx]
    cmp ebx, 2
    jge .x1
    mov ebx, 2
.x1:
    mov ecx, [scrw]
    sub ecx, [ol_w]
    sub ecx, 2
    cmp ebx, ecx
    jle .x2
    mov ebx, ecx
.x2:
    mov [ol_x], ebx
    mov ebx, [mouse_y]
    sub ebx, [drag_dy]
    cmp ebx, 30
    jge .y1
    mov ebx, 30
.y1:
    mov ecx, [scrh]
    sub ecx, [ol_h]
    sub ecx, 34
    cmp ebx, ecx
    jle .y2
    mov ebx, ecx
.y2:
    mov [ol_y], ebx
    ret
.resize:
    mov ebx, [mouse_x]
    sub ebx, [ol_x]
    cmp ebx, 220
    jge .w1
    mov ebx, 220
.w1:
    mov ecx, [scrw]
    sub ecx, [ol_x]
    sub ecx, 4
    cmp ebx, ecx
    jle .w2
    mov ebx, ecx
.w2:
    mov [ol_w], ebx
    mov ebx, [mouse_y]
    sub ebx, [ol_y]
    cmp ebx, 130
    jge .h1
    mov ebx, 130
.h1:
    mov ecx, [scrh]
    sub ecx, [ol_y]
    sub ecx, 34
    cmp ebx, ecx
    jle .h2
    mov ebx, ecx
.h2:
    mov [ol_h], ebx
    ret

drag_commit:
    mov eax, [drag_win]
    mov ebx, [ol_x]
    mov [ws_x + eax*4], ebx
    mov ebx, [ol_y]
    mov [ws_y + eax*4], ebx
    mov ebx, [ol_w]
    mov [ws_w + eax*4], ebx
    mov ebx, [ol_h]
    mov [ws_h + eax*4], ebx
    ret

hit_start:                   ; -> EAX=1 if cursor over the Start button
    mov eax, [mouse_x]
    cmp eax, 4
    jl .no
    cmp eax, 80
    jg .no
    mov ebx, [mouse_y]
    mov eax, [scrh]
    sub eax, 27
    cmp ebx, eax
    jl .no
    mov eax, [scrh]
    sub eax, 3
    cmp ebx, eax
    jg .no
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

hit_clock:                   ; -> EAX=1 over the bell button or the clock chip
    mov eax, [mouse_y]
    mov ebx, [scrh]
    sub ebx, 30
    cmp eax, ebx
    jl .no
    mov eax, [mouse_x]
    mov ebx, [scrw]
    sub ebx, 108
    cmp eax, ebx
    jl .no
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

hit_title:                   ; -> EAX=1 if cursor over the window title bar
    mov eax, [mouse_x]
    cmp eax, [wx]
    jl .no
    mov ebx, [wx]
    add ebx, [ww]
    cmp eax, ebx
    jg .no
    mov eax, [mouse_y]
    cmp eax, [wy]
    jl .no
    mov ebx, [wy]
    add ebx, TITLE_H
    cmp eax, ebx
    jg .no
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

; ---------------- Start menu ----------------
toggle_start:                ; Windows key: open/close the Start menu
    cmp byte [menu_open], 0
    jne .close
    call open_menu
    ret
.close:
    call close_menu
    ret

open_menu:
    call restore_cursor
    mov eax, [scrh]
    sub eax, 534
    mov [menu_y], eax
    call menu_save
    mov dword [rx], 4
    mov eax, [menu_y]
    mov [ry], eax
    mov dword [rw], 170
    mov dword [rh], 504
    mov dword [rcolor], 0x00303A4A
    mov dword [rrad], 8
    mov dword [rround], 3
    call fill_rrect
    mov dword [rx], 5
    mov eax, [menu_y]
    inc eax
    mov [ry], eax
    mov dword [rw], 168
    mov dword [rh], 502
    mov dword [rcolor], 0x00171D27
    call fill_rrect
    xor ebx, ebx
.it:
    cmp ebx, 18
    jae .done
    mov eax, ebx
    imul eax, 26
    add eax, [menu_y]
    add eax, 4
    mov [ry], eax
    mov dword [rx], 12
    mov eax, ebx
    call draw_app_icon
    mov eax, [ry]
    add eax, 1
    mov [ty], eax
    mov dword [tx], 38
    mov dword [tcolor], C_WHITE
    mov esi, [menu_items + ebx*4]
    call draw_text
    inc ebx
    jmp .it
.done:
    mov dword [rx], 8                ; separator + "Shut Down..."
    mov eax, [menu_y]
    add eax, 470
    mov [ry], eax
    mov dword [rw], 162
    mov dword [rh], 1
    mov dword [rcolor], 0x00404A58
    call fillrect
    mov eax, [menu_y]
    add eax, 474
    mov [ry], eax
    mov dword [rh], 26
    mov dword [rcolor], 0x00702A2A
    mov dword [rrad], 6
    mov dword [rround], 3
    call fill_rrect
    mov dword [tx], 16
    mov eax, [menu_y]
    add eax, 479
    mov [ty], eax
    mov dword [tcolor], C_WHITE
    mov esi, mi_shutdown
    call draw_text
    mov byte [menu_open], 1
    call save_cursor
    call draw_cursor
    ret

close_menu:
    call restore_cursor
    call menu_restore
    mov byte [menu_open], 0
    call save_cursor
    call draw_cursor
    ret

; ---- desktop right-click context menu (150x120, 5 items) ----
open_cmenu:
    cmp byte [mouse_present], 0
    je .nc
    call restore_cursor
.nc:
    mov eax, [mouse_x]
    mov ebx, [scrw]
    sub ebx, 152
    cmp eax, ebx
    jle .xok
    mov eax, ebx
.xok:
    mov [cmenu_x], eax
    mov eax, [mouse_y]
    mov ebx, [scrh]
    sub ebx, 152
    cmp eax, ebx
    jle .yok
    mov eax, ebx
.yok:
    mov [cmenu_y], eax
    call cmenu_save
    mov dword [cmenu_mode], 0
    call cmenu_paint
    mov byte [cmenu_open], 1
    cmp byte [mouse_present], 0
    je .r
    call save_cursor
    call draw_cursor
.r:
    ret

close_cmenu:
    call restore_cursor
    call cmenu_restore
    mov byte [cmenu_open], 0
    call save_cursor
    call draw_cursor
    ret

; paint the context-menu box + items for the current cmenu_mode (0 main / 1 New)
cmenu_paint:
    pushad
    mov eax, [cmenu_x]
    mov [rx], eax
    mov eax, [cmenu_y]
    mov [ry], eax
    mov dword [rw], 150
    mov dword [rh], 120
    mov dword [rcolor], C_DGRAY
    call fillrect
    mov dword [cmenu_listp], cmenu_main
    mov dword [cmenu_cnt], 4
    cmp dword [cmenu_mode], 0
    je .go
    mov dword [cmenu_listp], cmenu_new
    mov dword [cmenu_cnt], 3
.go:
    xor ebx, ebx
.it:
    cmp ebx, [cmenu_cnt]
    jae .done
    mov eax, ebx
    imul eax, 24
    add eax, [cmenu_y]
    add eax, 5
    mov [ty], eax
    mov eax, [cmenu_x]
    add eax, 10
    mov [tx], eax
    mov dword [tcolor], C_WHITE
    mov eax, [cmenu_listp]
    mov esi, [eax + ebx*4]
    call draw_text
    inc ebx
    jmp .it
.done:
    popad
    ret

; repaint the menu in place (when switching main<->submenu)
cmenu_repaint:
    call restore_cursor
    call cmenu_paint
    call save_cursor
    call draw_cursor
    ret

cmenu_save:
    pushad
    mov edi, MENUSAVE
    mov ebx, [cmenu_y]
    mov ecx, 120
.row:
    test ecx, ecx
    jz .done
    mov eax, ebx
    imul eax, [pitch]
    add eax, [lfb]
    mov edx, [cmenu_x]
    shl edx, 2
    add eax, edx
    mov esi, eax
    push ecx
    mov ecx, 150
    rep movsd
    pop ecx
    inc ebx
    dec ecx
    jmp .row
.done:
    popad
    ret

cmenu_restore:
    pushad
    mov esi, MENUSAVE
    mov ebx, [cmenu_y]
    mov ecx, 120
.row:
    test ecx, ecx
    jz .done
    mov eax, ebx
    imul eax, [pitch]
    add eax, [lfb]
    mov edx, [cmenu_x]
    shl edx, 2
    add eax, edx
    mov edi, eax
    push ecx
    mov ecx, 150
    rep movsd
    pop ecx
    inc ebx
    dec ecx
    jmp .row
.done:
    popad
    ret

cmenu_click:
    mov eax, [mouse_x]
    mov ebx, [cmenu_x]
    cmp eax, ebx
    jl .close
    add ebx, 150
    cmp eax, ebx
    jg .close
    mov eax, [mouse_y]
    mov ebx, [cmenu_y]
    cmp eax, ebx
    jl .close
    mov ecx, ebx
    add ecx, 120
    cmp eax, ecx
    jg .close
    sub eax, ebx
    xor edx, edx
    mov ecx, 24
    div ecx
    ; dispatch by mode
    cmp dword [cmenu_mode], 0
    jne .subm
    ; ---- main menu: New >, Wallpaper, Settings, About ----
    cmp eax, 0
    je .opennew
    cmp eax, 1
    je .wall_c
    cmp eax, 2
    je .settings_c
    cmp eax, 3
    je .about_c
    jmp .close
.opennew:
    mov dword [cmenu_mode], 1   ; drill into the New submenu
    call cmenu_repaint
    ret
.wall_c:
    call close_cmenu
    call cycle_wall
    call recompose
    ret
.settings_c:
    call close_cmenu
    mov eax, 9
    call open_window
    call recompose
    ret
.about_c:
    call close_cmenu
    mov eax, 4
    call open_window
    call recompose
    ret
.subm:
    ; ---- New submenu: Text File, Folder, < Back ----
    cmp eax, 0
    je .newf
    cmp eax, 1
    je .newfolder
    cmp eax, 2
    je .back
    jmp .close
.back:
    mov dword [cmenu_mode], 0
    call cmenu_repaint
    ret
.newf:
    call close_cmenu
    cmp dword [install_mode], 0
    je .newf_blocked
    mov eax, [fs_rootclus]      ; new file on the desktop (root)
    mov [cwd_cluster], eax
    mov [save_dir], eax
    call new_file
    ret
.newfolder:
    call close_cmenu
    cmp dword [install_mode], 0
    je .newf_blocked
    mov eax, [fs_rootclus]      ; new folder on the desktop (root)
    mov [cwd_cluster], eax
    call do_newfolder
    ret
.newf_blocked:
    call long_beep
    mov esi, nt_live1
    mov edi, nt_live2
    call notify
    call recompose
    ret
.wall:
    call cycle_wall
    call recompose
    ret
.settings:
    mov eax, 9
    call open_window
    call recompose
    ret
.close:
    call close_cmenu
    ret

menu_save:
    pushad
    mov edi, MENUSAVE
    mov ebx, [menu_y]
    mov ecx, 504
.row:
    test ecx, ecx
    jz .done
    mov eax, ebx
    imul eax, [pitch]
    add eax, [lfb]
    add eax, 16
    mov esi, eax
    push ecx
    mov ecx, 170
.col:
    mov eax, [esi]
    mov [edi], eax
    add esi, 4
    add edi, 4
    dec ecx
    jnz .col
    pop ecx
    inc ebx
    dec ecx
    jmp .row
.done:
    popad
    ret

menu_restore:
    pushad
    mov esi, MENUSAVE
    mov ebx, [menu_y]
    mov ecx, 504
.row:
    test ecx, ecx
    jz .done
    mov eax, ebx
    imul eax, [pitch]
    add eax, [lfb]
    add eax, 16
    mov edi, eax
    push ecx
    mov ecx, 170
.col:
    mov eax, [esi]
    mov [edi], eax
    add esi, 4
    add edi, 4
    dec ecx
    jnz .col
    pop ecx
    inc ebx
    dec ecx
    jmp .row
.done:
    popad
    ret

menu_click:
    mov eax, [mouse_x]
    cmp eax, 4
    jl .outside
    cmp eax, 174
    jg .outside
    mov eax, [mouse_y]
    mov ebx, [menu_y]
    cmp eax, ebx
    jl .outside
    mov ecx, ebx
    add ecx, 504
    cmp eax, ecx
    jg .outside
    sub eax, ebx
    cmp eax, 470                 ; the Shut Down... row
    jb .app
    call close_menu
    call shutdown_dialog
    ret
.app:
    xor edx, edx
    mov ecx, 26
    div ecx
    cmp eax, 18
    jae .outside
    push eax
    call close_menu
    pop eax
    call open_window            ; open/raise that app's window
    call recompose
    ret
.outside:
    call close_menu
    ret

; ---------------- Calculator ----------------
draw_calc_content:
    pushad
    mov eax, [con_x0]
    mov [rx], eax
    mov eax, [con_y0]
    mov [ry], eax
    mov dword [rw], 250
    mov dword [rh], 30
    mov dword [rcolor], 0x00182230
    call fillrect
    mov eax, [con_x0]
    add eax, 6
    mov [tx], eax
    mov eax, [con_y0]
    add eax, 7
    mov [ty], eax
    mov dword [tcolor], 0x007FFF9F
    mov esi, calc_expr
    call draw_text
    xor ebx, ebx
.b:
    cmp ebx, 20
    jae .done
    movzx eax, byte [calc_btns + ebx]
    test al, al
    jz .bnext
    mov eax, ebx
    xor edx, edx
    mov ecx, 4
    div ecx
    mov ecx, edx
    imul ecx, 60
    add ecx, [con_x0]
    mov [rx], ecx
    imul eax, 42
    add eax, [con_y0]
    add eax, 44
    mov [ry], eax
    mov dword [rw], 54
    mov dword [rh], 36
    mov dword [rcolor], 0x00263040
    call fillrect
    mov eax, [rx]
    add eax, 22
    mov [tx], eax
    mov eax, [ry]
    add eax, 10
    mov [ty], eax
    mov dword [tcolor], C_WHITE
    movzx eax, byte [calc_btns + ebx]
    call draw_char
.bnext:
    inc ebx
    jmp .b
.done:
    popad
    ret

calc_click:
    mov eax, [mouse_x]
    sub eax, [con_x0]
    js .none
    xor edx, edx
    mov ecx, 60
    div ecx
    cmp eax, 4
    jae .none
    cmp edx, 54
    jae .none
    mov [calc_col], eax
    mov eax, [mouse_y]
    sub eax, [con_y0]
    sub eax, 44
    js .none
    xor edx, edx
    mov ecx, 42
    div ecx
    cmp eax, 5
    jae .none
    cmp edx, 36
    jae .none
    imul eax, 4
    add eax, [calc_col]
    movzx eax, byte [calc_btns + eax]
    test al, al
    jz .none
    call calc_do
.none:
    ret

calc_do:                     ; AL = button char
    cmp al, 'C'
    je .clear
    cmp al, '='
    je .equals
    mov edi, [calc_len]
    cmp edi, 28
    jae .refresh
    mov [calc_expr + edi], al
    inc dword [calc_len]
    mov edi, [calc_len]
    mov byte [calc_expr + edi], 0
    jmp .refresh
.clear:
    mov dword [calc_len], 0
    mov byte [calc_expr], 0
    jmp .refresh
.equals:
    call calc_eval
.refresh:
    call recompose
    ret

calc_eval:
    pushad
    mov esi, calc_expr
    call parse_num
    mov [calc_a], eax
    mov al, [esi]
    mov [calc_op], al
    inc esi
    call parse_num
    mov [calc_b], eax
    mov eax, [calc_a]
    mov ebx, [calc_b]
    mov cl, [calc_op]
    cmp cl, '+'
    je .add
    cmp cl, '-'
    je .sub
    cmp cl, '*'
    je .mul
    cmp cl, '/'
    je .div
    jmp .done
.add:
    add eax, ebx
    jmp .fmt
.sub:
    sub eax, ebx
    jmp .fmt
.mul:
    imul eax, ebx
    jmp .fmt
.div:
    test ebx, ebx
    jz .done
    xor edx, edx
    div ebx
.fmt:
    mov edi, calc_expr
    mov ebx, eax
    test ebx, ebx
    jns .pos
    mov byte [edi], '-'
    inc edi
    neg ebx
.pos:
    mov eax, ebx
    call num_to_str
    mov byte [edi], 0
    mov eax, edi
    sub eax, calc_expr
    mov [calc_len], eax
.done:
    popad
    ret

parse_num:                   ; ESI -> digits; EAX = value, ESI advanced
    xor eax, eax
.d:
    movzx ecx, byte [esi]
    cmp cl, '0'
    jb .done
    cmp cl, '9'
    ja .done
    imul eax, eax, 10
    sub ecx, '0'
    add eax, ecx
    inc esi
    jmp .d
.done:
    ret

num_to_str:                  ; EAX = num, EDI = dest; writes decimal, EDI advanced
    push ebx
    push ecx
    push edx
    mov ebx, 10
    xor ecx, ecx
    test eax, eax
    jnz .sp
    mov byte [edi], '0'
    inc edi
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
    mov [edi], dl
    inc edi
    dec ecx
    jmp .em
.done:
    pop edx
    pop ecx
    pop ebx
    ret

; ---------------- Clock / System / About apps ----------------
draw_num:                    ; EAX = number, draw at [tx],[ty] advancing tx
    pushad
    mov ebx, 10
    xor ecx, ecx
    test eax, eax
    jnz .sp
    mov al, '0'
    call draw_char
    add dword [tx], 8
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
    call draw_char
    add dword [tx], 8
    dec ecx
    jmp .em
.done:
    popad
    ret

draw_2digit:                 ; AL = 0..99
    pushad
    movzx eax, al
    mov bl, 10
    div bl
    mov bh, ah
    add al, '0'
    call draw_char
    add dword [tx], 8
    mov al, bh
    add al, '0'
    call draw_char
    add dword [tx], 8
    popad
    ret

get_cpu_brand:
    pushad
    mov eax, 0x80000000
    cpuid
    cmp eax, 0x80000004
    jb .v
    mov edi, gcpubuf
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
    jmp .done
.v:
    mov eax, 0
    cpuid
    mov edi, gcpubuf
    mov [edi], ebx
    mov [edi+4], edx
    mov [edi+8], ecx
    mov byte [edi+12], 0
.done:
    popad
    ret

read_rtc:
    pushad
    mov ecx, 100000              ; UIP normally clears in microseconds -- huge margin, but
.uip:                             ; bounded: a busy-wait with no escape at all is a real hang risk
    mov al, 0x0A
    out 0x70, al
    in al, 0x71
    test al, 0x80
    jz .uipclear
    dec ecx
    jnz .uip
.uipclear:
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
    mov al, 0x0B
    call .rd
    test al, 0x04
    jnz .done
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
.rd:
    out 0x70, al
    in al, 0x71
    ret

bcd2bin:
    push ebx
    push edx
    mov bl, al
    and al, 0x0F
    mov bh, al
    mov al, bl
    shr al, 4
    mov dl, 10
    mul dl
    add al, bh
    pop edx
    pop ebx
    ret

draw_clock_content:
    pushad
    call read_rtc
    mov eax, [con_x0]
    mov [tx], eax
    mov eax, [con_y0]
    add eax, 12
    mov [ty], eax
    mov dword [tcolor], C_TEXT
    mov al, [rtc_hour]
    call draw_2digit
    mov al, ':'
    call draw_char
    add dword [tx], 8
    mov al, [rtc_min]
    call draw_2digit
    mov al, ':'
    call draw_char
    add dword [tx], 8
    mov al, [rtc_sec]
    call draw_2digit
    mov eax, [con_x0]
    mov [tx], eax
    mov eax, [con_y0]
    add eax, 44
    mov [ty], eax
    mov al, [rtc_day]
    call draw_2digit
    mov al, '/'
    call draw_char
    add dword [tx], 8
    mov al, [rtc_month]
    call draw_2digit
    mov al, '/'
    call draw_char
    add dword [tx], 8
    mov al, '2'
    call draw_char
    add dword [tx], 8
    mov al, '0'
    call draw_char
    add dword [tx], 8
    mov al, [rtc_year]
    call draw_2digit
    mov eax, [con_x0]
    mov [tx], eax
    mov eax, [con_y0]
    add eax, 84
    mov [ty], eax
    mov esi, clock_hint
    call draw_text
    popad
    ret

draw_sys_content:
    pushad
    call get_cpu_brand
    mov eax, [con_x0]
    mov [tx], eax
    mov eax, [con_y0]
    mov [ty], eax
    mov dword [tcolor], C_TEXT
    mov esi, gm_cpu
    call draw_text
    mov esi, gcpubuf
    call draw_text
    mov eax, [con_x0]
    mov [tx], eax
    mov eax, [con_y0]
    add eax, 24
    mov [ty], eax
    mov esi, gm_mem
    call draw_text
    mov eax, [0x1000]
    mov ebx, 1024
    xor edx, edx
    div ebx
    call draw_num
    mov esi, mb_str
    call draw_text
    mov eax, [con_x0]
    mov [tx], eax
    mov eax, [con_y0]
    add eax, 48
    mov [ty], eax
    mov esi, gm_res
    call draw_text
    mov eax, [scrw]
    call draw_num
    mov al, 'x'
    call draw_char
    add dword [tx], 8
    mov eax, [scrh]
    call draw_num
    popad
    ret

draw_about_content:
    pushad
    mov eax, [con_x0]
    add eax, 60
    mov [dcx], eax
    mov eax, [con_y0]
    add eax, 60
    mov [dcy], eax
    mov dword [drad], 44
    mov dword [dcolor], 0x0022AA55
    call draw_diamond
    mov dword [drad], 20
    mov dword [dcolor], 0x00E6FFF0
    call draw_diamond
    mov eax, [con_x0]
    add eax, 140
    mov [tx], eax
    mov eax, [con_y0]
    add eax, 24
    mov [ty], eax
    mov dword [tcolor], C_WHITE
    mov esi, about_1
    call draw_text
    mov eax, [con_x0]
    add eax, 140
    mov [tx], eax
    mov eax, [con_y0]
    add eax, 50
    mov [ty], eax
    mov dword [tcolor], C_TEXT
    mov esi, about_2
    call draw_text
    mov eax, [con_x0]
    add eax, 140
    mov [tx], eax
    mov eax, [con_y0]
    add eax, 74
    mov [ty], eax
    mov esi, about_3
    call draw_text
    mov eax, [con_x0]
    add eax, 140
    mov [tx], eax
    mov eax, [con_y0]
    add eax, 96
    mov [ty], eax
%if EDITION_STORE
    mov dword [tcolor], 0x00FFC94D
    mov esi, about_store_yes
    call draw_text
%else
    mov dword [tcolor], 0x00E08A5A
    mov esi, about_store_no1
    call draw_text
    mov eax, [con_x0]
    add eax, 140
    mov [tx], eax
    mov eax, [con_y0]
    add eax, 118
    mov [ty], eax
    mov esi, about_store_no2
    call draw_text
%endif
    mov eax, [con_x0]
    add eax, 140
    mov [tx], eax
    mov eax, [con_y0]
    add eax, 142
    mov [ty], eax
    mov dword [tcolor], 0x0070D890
    mov esi, about_snd_yes
    cmp dword [hda_ok], 0
    jne .sndt
    mov dword [tcolor], 0x008A96A6
    mov esi, about_snd_no
.sndt:
    call draw_text
    cmp dword [hda_ok], 0
    jne .foundinfo
    mov eax, [con_x0]
    add eax, 140
    mov [tx], eax
    mov eax, [con_y0]
    add eax, 164
    mov [ty], eax
    mov dword [tcolor], 0x006C7686
    mov esi, about_diag_stage
    call draw_text
    mov eax, [hda_diag_stage]
    call draw_num
    cmp dword [hda_diag_class], 0xFFFFFFFF
    je .done
    mov esi, about_diag_class
    call draw_text
    mov eax, [hda_diag_class]
    shr eax, 16
    and eax, 0xFF
    call draw_num
    mov al, '.'
    call draw_char
    add dword [tx], 8
    mov eax, [hda_diag_class]
    shr eax, 8
    and eax, 0xFF
    call draw_num
    mov al, '.'
    call draw_char
    add dword [tx], 8
    mov eax, [hda_diag_class]
    and eax, 0xFF
    call draw_num
    mov esi, about_diag_bus
    call draw_text
    mov eax, [hda_diag_bus]
    call draw_num
    jmp .done
.foundinfo:                          ; where the LAST sound (of any kind) actually stopped --
    mov eax, [con_x0]                ; tells us if a clip is stopping early because of our own
    add eax, 140                     ; timer (LPIB would be at/near CBL) or a real DMA stall
    mov [tx], eax                    ; (LPIB stuck well short of CBL) or a hardware fault
    mov eax, [con_y0]                ; (SDSTS FIFOE/DESE bits set).
    add eax, 164
    mov [ty], eax
    mov dword [tcolor], 0x006C7686
    mov esi, about_lpib_lbl
    call draw_text
    mov eax, [hda_last_lpib]
    call draw_num
    mov esi, about_lpib_of
    call draw_text
    mov eax, [hda_last_cbl]
    call draw_num
    mov esi, about_lpib_sdsts
    call draw_text
    mov eax, [hda_last_sdsts]
    call draw_num
.done:
    popad
    ret
about_store_yes:  db "Store Edition (registered)", 0
about_store_no1:  db "Nova OS is not store-bought.", 0
about_store_no2:  db "Buy the full copy in stores.", 0
about_snd_yes:    db "Sound: real speakers (HD Audio found)", 0
about_snd_no:     db "Sound: PC speaker (no HD Audio chip found)", 0
about_lpib_lbl:   db "last stream stopped at byte ", 0
about_lpib_of:    db " of ", 0
about_lpib_sdsts: db "  status ", 0
about_diag_stage: db "diag: stage ", 0
about_diag_class: db "  other sound device: class ", 0
about_diag_bus:   db "  on bus ", 0

; (move_window removed - the window manager handles dragging via do_move)

; save/restore the CUR_W x CUR_H block under the cursor to scratch RAM
save_cursor:
    pushad
    mov edi, CURSAVE
    xor ebx, ebx
.row:
    cmp ebx, CUR_H
    jae .done
    mov eax, [cur_y]
    add eax, ebx
    imul eax, [pitch]
    add eax, [lfb]
    mov edx, [cur_x]
    shl edx, 2
    add eax, edx
    mov esi, eax
    mov ecx, CUR_W
.col:
    mov eax, [esi]
    mov [edi], eax
    add esi, 4
    add edi, 4
    dec ecx
    jnz .col
    inc ebx
    jmp .row
.done:
    popad
    ret

restore_cursor:
    pushad
    mov esi, CURSAVE
    xor ebx, ebx
.row:
    cmp ebx, CUR_H
    jae .done
    mov eax, [cur_y]
    add eax, ebx
    imul eax, [pitch]
    add eax, [lfb]
    mov edx, [cur_x]
    shl edx, 2
    add eax, edx
    mov edi, eax
    mov ecx, CUR_W
.col:
    mov eax, [esi]
    mov [edi], eax
    add esi, 4
    add edi, 4
    dec ecx
    jnz .col
    inc ebx
    jmp .row
.done:
    popad
    ret

draw_cursor:                 ; 8x12 arrow at 2x: black outline, white inside
    pushad
    mov dword [cur_bmp_p], cursor_bmp
    mov dword [cur_col], 0x00000000
    call draw_cursor_pass
    mov dword [cur_bmp_p], cursor_in
    mov dword [cur_col], C_WHITE
    call draw_cursor_pass
    popad
    ret
cur_bmp_p: dd 0
cur_col:   dd 0
cursor_in: db 0x00,0x00,0x40,0x60,0x70,0x78,0x7C,0x78,0x60,0x00,0x04,0x00
draw_cursor_pass:
    pushad
    xor ebx, ebx
.row:
    cmp ebx, 12
    jae .done
    mov esi, [cur_bmp_p]
    movzx edx, byte [esi + ebx]
    xor ecx, ecx
.col:
    cmp ecx, 8
    jae .next
    test dl, 0x80
    jz .skip
    push ebx
    push ecx
    push edx
    mov eax, ebx
    shl eax, 1
    add eax, [cur_y]
    imul eax, [pitch]
    add eax, [lfb]
    mov edx, ecx
    shl edx, 1
    add edx, [cur_x]
    shl edx, 2
    add eax, edx
    mov edi, eax
    mov eax, [cur_col]
    mov [edi], eax
    mov [edi+4], eax
    mov edx, [pitch]
    mov [edi+edx], eax
    mov [edi+edx+4], eax
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

; ================= boot splash (v1.0 logo) =================
delay:
    push ecx
    mov ecx, [dcount]
.d:
    dec ecx
    jnz .d
    pop ecx
    ret

; ---- PC speaker sound ----
play_note:                   ; BX = PIT divisor (pitch); plays for a short time
    cmp dword [sound_on], 0
    je .muted
    pushad
    mov al, 0xB6             ; PIT ch2, mode 3
    out 0x43, al
    mov al, bl
    out 0x42, al
    mov al, bh
    out 0x42, al
    in al, 0x61             ; enable speaker (bits 0,1)
    or al, 3
    out 0x61, al
    mov dword [dcount], 0x02800000
    call delay
    in al, 0x61             ; speaker off
    and al, 0xFC
    out 0x61, al
    mov dword [dcount], 0x00600000   ; short gap
    call delay
    popad
.muted:
    ret

play_tone:                   ; BX = PIT divisor, EBP = duration count
    cmp dword [sound_on], 0
    je .muted
    pushad
    mov al, 0xB6
    out 0x43, al
    mov al, bl
    out 0x42, al
    mov al, bh
    out 0x42, al
    in al, 0x61
    or al, 3
    out 0x61, al
    mov [dcount], ebp
    call delay
    in al, 0x61
    and al, 0xFC
    out 0x61, al
    mov dword [dcount], 0x00A00000   ; audible gap between notes
    call delay
    popad
.muted:
    ret

play_startup:                ; original NovaOS boot chime (rise + resolve)
    mov ebp, 0x03000000      ; every note long enough to hear on a fast CPU
    mov bx, 3043             ; G4
    call play_tone
    mov ebp, 0x03000000
    mov bx, 2281             ; C5
    call play_tone
    mov ebp, 0x03000000
    mov bx, 1810             ; E5
    call play_tone
    mov ebp, 0x03800000
    mov bx, 1522             ; G5
    call play_tone
    mov ebp, 0x03000000
    mov bx, 1810             ; E5
    call play_tone
    mov ebp, 0x05800000
    mov bx, 1140             ; C6 (final, long)
    call play_tone
    ret

long_beep:                   ; sustained low error tone ("cannot save")
    pushad
    mov ebp, 0x06000000
    mov bx, 6800            ; ~175 Hz
    call play_tone
    popad
    ret

err_beep:                    ; low error buzz
    mov bx, 9109             ; ~131 Hz
    call play_note
    mov bx, 11467            ; ~104 Hz
    call play_note
    ret

draw_diamond:                ; [dcx],[dcy],[drad],[dcolor]  32bpp filled diamond
    pushad
    mov ecx, [drad]
    neg ecx
.loop:
    mov eax, [drad]
    cmp ecx, eax
    jg .done
    mov esi, ecx
    test esi, esi
    jns .pos
    neg esi
.pos:
    mov ebx, [drad]
    sub ebx, esi             ; halfwidth
    mov eax, [dcy]
    add eax, ecx
    imul eax, [pitch]
    add eax, [lfb]
    mov edx, [dcx]
    sub edx, ebx
    shl edx, 2
    add eax, edx
    mov edi, eax
    mov edx, ebx
    add edx, ebx
    inc edx                  ; width
    mov eax, [dcolor]
.line:
    test edx, edx
    jz .nextrow
    mov [edi], eax
    add edi, 4
    dec edx
    jmp .line
.nextrow:
    inc ecx
    jmp .loop
.done:
    popad
    ret

draw_char_scaled:            ; AL=char, [tx],[ty],[tcolor],[tscale]
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
    jae .next
    test dl, 0x80
    jz .skip
    push ebx
    push ecx
    push edx
    mov eax, ecx
    imul eax, [tscale]
    add eax, [tx]
    mov [rx], eax
    mov eax, ebx
    imul eax, [tscale]
    add eax, [ty]
    mov [ry], eax
    mov eax, [tscale]
    mov [rw], eax
    mov [rh], eax
    mov eax, [tcolor]
    mov [rcolor], eax
    call fillrect
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

draw_text_scaled:            ; ESI string, [tx],[ty],[tcolor],[tscale]
    pushad
.n:
    mov al, [esi]
    test al, al
    jz .d
    call draw_char_scaled
    mov eax, [tscale]
    shl eax, 3
    add [tx], eax
    inc esi
    jmp .n
.d:
    popad
    ret

; ================= Sad-Mac style boot error screen (never returns) =================
sad_mac:                     ; ESI = error message line
    mov [sad_msg], esi
    mov dword [rx], 0        ; black background
    mov dword [ry], 0
    mov eax, [scrw]
    mov [rw], eax
    mov eax, [scrh]
    mov [rh], eax
    mov dword [rcolor], 0x00000000
    call fillrect
    mov eax, [scrw]
    shr eax, 1
    mov [smx], eax
    mov eax, [scrh]
    shr eax, 1
    sub eax, 20
    mov [smy], eax
    ; computer body
    mov eax, [smx]
    sub eax, 100
    mov [rx], eax
    mov eax, [smy]
    sub eax, 110
    mov [ry], eax
    mov dword [rw], 200
    mov dword [rh], 160
    mov dword [rcolor], 0x00C4C8CC
    call fillrect
    ; screen
    mov eax, [smx]
    sub eax, 78
    mov [rx], eax
    mov eax, [smy]
    sub eax, 92
    mov [ry], eax
    mov dword [rw], 156
    mov dword [rh], 112
    mov dword [rcolor], 0x00181C24
    call fillrect
    ; stand
    mov eax, [smx]
    sub eax, 24
    mov [rx], eax
    mov eax, [smy]
    add eax, 50
    mov [ry], eax
    mov dword [rw], 48
    mov dword [rh], 24
    mov dword [rcolor], 0x00C4C8CC
    call fillrect
    ; base
    mov eax, [smx]
    sub eax, 70
    mov [rx], eax
    mov eax, [smy]
    add eax, 72
    mov [ry], eax
    mov dword [rw], 140
    mov dword [rh], 14
    mov dword [rcolor], 0x00C4C8CC
    call fillrect
    ; X eyes
    mov dword [tscale], 3
    mov dword [tcolor], 0x00E8E8E8
    mov eax, [smx]
    sub eax, 52
    mov [tx], eax
    mov eax, [smy]
    sub eax, 78
    mov [ty], eax
    mov al, 'X'
    call draw_char_scaled
    mov eax, [smx]
    add eax, 28
    mov [tx], eax
    mov eax, [smy]
    sub eax, 78
    mov [ty], eax
    mov al, 'X'
    call draw_char_scaled
    ; frown (middle bar high, two corners dropping down = sad)
    mov eax, [smx]
    sub eax, 24
    mov [rx], eax
    mov eax, [smy]
    sub eax, 26
    mov [ry], eax
    mov dword [rw], 48
    mov dword [rh], 7
    mov dword [rcolor], 0x00E8E8E8
    call fillrect
    mov eax, [smx]
    sub eax, 30
    mov [rx], eax
    mov eax, [smy]
    sub eax, 24
    mov [ry], eax
    mov dword [rw], 9
    mov dword [rh], 11
    mov dword [rcolor], 0x00E8E8E8
    call fillrect
    mov eax, [smx]
    add eax, 21
    mov [rx], eax
    mov eax, [smy]
    sub eax, 24
    mov [ry], eax
    mov dword [rw], 9
    mov dword [rh], 11
    mov dword [rcolor], 0x00E8E8E8
    call fillrect
    ; text lines
    mov eax, [smx]
    sub eax, 92
    mov [tx], eax
    mov eax, [smy]
    add eax, 100
    mov [ty], eax
    mov dword [tcolor], C_WHITE
    mov esi, sad_head
    call draw_text
    mov eax, [smx]
    sub eax, 140
    mov [tx], eax
    mov eax, [smy]
    add eax, 124
    mov [ty], eax
    mov dword [tcolor], 0x00FF6B6B
    mov esi, [sad_msg]
    call draw_text
    mov eax, [smx]
    sub eax, 116
    mov [tx], eax
    mov eax, [smy]
    add eax, 148
    mov [ty], eax
    mov dword [tcolor], 0x0090A0B0
    mov esi, sad_foot
    call draw_text
    call sad_chime
.hang:
    cli
    hlt
    jmp .hang

sad_chime:                   ; slow, descending, minor "chimes of doom"
    mov ebp, 0x03800000
    mov bx, 2031
    call play_tone
    mov ebp, 0x03800000
    mov bx, 2712
    call play_tone
    mov ebp, 0x03800000
    mov bx, 3616
    call play_tone
    mov ebp, 0x07000000
    mov bx, 4832
    call play_tone
    ret

boot_splash:
    pushad
    ; background
    mov dword [rx], 0
    mov dword [ry], 0
    mov eax, [scrw]
    mov [rw], eax
    mov eax, [scrh]
    mov [rh], eax
    mov dword [rcolor], 0x00080A12
    call fillrect
    ; Nova diamond (glow rings)
    mov eax, [scrw]
    shr eax, 1
    mov [dcx], eax
    mov eax, [scrh]
    shr eax, 1
    sub eax, 90
    mov [dcy], eax
    mov dword [drad], 78
    mov dword [dcolor], 0x00186B3D
    call draw_diamond
    mov dword [drad], 58
    mov dword [dcolor], 0x0022AA55
    call draw_diamond
    mov dword [drad], 26
    mov dword [dcolor], 0x00E6FFF0
    call draw_diamond
    ; title "NOVA OS" x4
    mov dword [tscale], 4
    mov eax, [scrw]
    shr eax, 1
    sub eax, 112
    mov [tx], eax
    mov eax, [scrh]
    shr eax, 1
    add eax, 16
    mov [ty], eax
    mov dword [tcolor], C_WHITE
    mov esi, splash_title
    call draw_text_scaled
    ; subtitle "version 1.0" x2
    mov dword [tscale], 2
    mov eax, [scrw]
    shr eax, 1
    sub eax, 88
    mov [tx], eax
    mov eax, [scrh]
    shr eax, 1
    add eax, 92
    mov [ty], eax
    mov dword [tcolor], 0x0080D0FF
    mov esi, splash_sub
    call draw_text_scaled
    ; loading bar outline
    mov eax, [scrw]
    shr eax, 1
    sub eax, 160
    mov [barx], eax
    mov eax, [scrh]
    sub eax, 120
    mov [bary], eax
    mov eax, [barx]
    mov [rx], eax
    mov eax, [bary]
    mov [ry], eax
    mov dword [rw], 320
    mov dword [rh], 16
    mov dword [rcolor], 0x00283848
    call fillrect
    ; animate fill
    mov dword [step], 0
.anim:
    mov eax, [step]
    cmp eax, 32
    jae .adone
    mov eax, [step]
    imul eax, 10
    mov [rw], eax
    mov eax, [barx]
    mov [rx], eax
    mov eax, [bary]
    mov [ry], eax
    mov dword [rh], 16
    mov dword [rcolor], 0x0032C866
    call fillrect
    mov dword [dcount], 0x00A00000
    call delay
    inc dword [step]
    jmp .anim
.adone:
    mov dword [dcount], 0x06000000
    call delay
    popad
    ret

%include "setup_gui.inc"
%include "sysfiles.inc"
%include "sound_xp.inc"
%include "power.inc"
%include "readme.inc"
%include "usb.inc"
%include "music.inc"
%include "ui.inc"
%include "hda.inc"
%include "sysapps.inc"

; ================= data =================
dcx: dd 0
dcy: dd 0
drad: dd 0
dcolor: dd 0
tscale: dd 0
barx: dd 0
bary: dd 0
step: dd 0
dcount: dd 0
splash_title: db "NOVA OS", 0
splash_sub:   db "version 1.27", 0
lfb:     dd 0
pitch:   dd 0
scrw:    dd 0
scrh:    dd 0
con_x0:  dd 0
con_y0:  dd 0
con_cols: dd 0
con_rows: dd 0
rx: dd 0
ry: dd 0
rw: dd 0
rh: dd 0
rcolor: dd 0
tx: dd 0
ty: dd 0
tcolor: dd 0
gcol: dd 0
grow: dd 0
gbuf_len: dd 0
gchar: db 0
gshift: db 0
gcmd: times 64 db 0
cur_text_buf: dd tbuf        ; which grid gputchar/gscroll/etc. write into -- Admin Terminal points this at abuf
gcpubuf: times 52 db 0

mouse_present: db 0
mouse_cycle:   db 0
mouse_flags:   db 0
prev_btn:      db 0
mouse_dx:      db 0
mouse_dy:      db 0
mouse_x:   dd 0
mouse_y:   dd 0
mouse_newx: dd 0
mouse_newy: dd 0
cur_x:     dd 0
cur_y:     dd 0
wx:        dd 0
wy:        dd 0
ww:        dd 0
wh:        dd 0
dragging:  db 0
drag_dx:   dd 0
drag_dy:   dd 0
app_id:    dd 0
app_title: dd at_term
menu_open: db 0
menu_y:    dd 0
cmenu_open: db 0
cmenu_x:   dd 0
cmenu_y:   dd 0
prev_rbtn: db 0
cmenu_mode:  dd 0
cmenu_listp: dd 0
cmenu_cnt:   dd 0
cmenu_main: dd cm_new, cm_wall, cm_set2, cm_about2
cmenu_new:  dd cm_txt, cm_fold, cm_back
cm_new:   db "New           >", 0
cm_wall:  db "Change Wallpaper", 0
cm_set2:  db "Settings", 0
cm_about2: db "About Nova", 0
cm_txt:   db "  Text File", 0
cm_fold:  db "  Folder", 0
cm_back:  db "< Back", 0
calc_col:  dd 0
calc_len:  dd 0
calc_a:    dd 0
calc_b:    dd 0
calc_op:   db 0
calc_expr: times 34 db 0
rtc_sec:   db 0
rtc_min:   db 0
rtc_hour:  db 0
rtc_day:   db 0
rtc_month: db 0
rtc_year:  db 0
app_titles:  dd at_term, at_calc, at_clock, at_sys, at_about, at_edit, at_web, at_paint, at_files, at_set, at_bnc, at_sav, at_snd, at_snk, at_mus, at_devmgr, at_taskmgr, at_admin
menu_items:  dd mi_term, mi_calc, mi_clock, mi_sys, mi_about, mi_edit, mi_web, mi_paint, mi_files, mi_set, mi_bnc, mi_sav, mi_snd, mi_snk, mi_mus, mi_devmgr, mi_taskmgr, mi_admin
at_term:   db "Nova Terminal", 0
at_calc:   db "Calculator", 0
at_clock:  db "Clock", 0
at_sys:    db "System Info", 0
at_about:  db "About Nova", 0
at_edit:   db "Text Editor", 0
at_web:    db "Nova Browser", 0
mi_term:   db "Terminal", 0
mi_calc:   db "Calculator", 0
mi_clock:  db "Clock", 0
mi_sys:    db "System Info", 0
mi_about:  db "About Nova", 0
mi_edit:   db "Text Editor", 0
mi_web:    db "Nova Browser", 0
at_paint:  db "Nova Paint", 0
mi_paint:  db "Nova Paint", 0
at_files:  db "Files", 0
mi_files:  db "Files", 0
at_set:    db "Settings", 0
mi_set:    db "Settings", 0
at_bnc:    db "Bounce", 0
mi_bnc:    db "Bounce Game", 0
at_sav:    db "Screensaver", 0
mi_sav:    db "Screensaver", 0
at_snd:    db "Sound", 0
mi_snd:    db "Sound Play", 0
at_snk:    db "Snake", 0
mi_snk:    db "Snake Game", 0
at_mus:    db "Music Maker", 0
mi_mus:    db "Music Maker", 0
at_devmgr: db "Device Manager", 0
mi_devmgr: db "Device Manager", 0
at_taskmgr: db "Task Manager", 0
mi_taskmgr: db "Task Manager", 0
at_admin:  db "Administrator: Terminal", 0
mi_admin:  db "Admin Terminal", 0
mi_shutdown: db "Shut Down...", 0
; snake state (grid 28x16, 12px cells)
snx:       times 260 db 0
sny:       times 260 db 0
slen:      dd 3
sdir:      dd 3
sfx:       dd 12
sfy:       dd 8
sdead:     db 0
sk_ext:    db 0
snake_cnt: dd 0
snk_over:  db "GAME OVER - press Space", 0
; animation + game state
frame:     dd 0
ball_x:    dd 60
ball_y:    dd 40
ball_vx:   dd 5
ball_vy:   dd 4
bnc_w:     dd 0
bnc_h:     dd 0
sav_x:     dd 80
sav_y:     dd 60
sav_vx:    dd 2
sav_vy:    dd 3
sav_col:   dd 0
clx:       dd 0
cly:       dd 0
saver_cnt: dd 0
brush_sz:  dd 3
sz_lbl:    db "SML"
clr_lbl:   db "Clear", 0
ed_curfile: dd -1
install_mode: dd 0            ; set at boot: 0 = live USB (read-only), 1 = installed
new_slot:  dd 0               ; round-robin slot for "New File"
clkbuf:    times 8 db 0        ; taskbar clock "H:MMa"
clk_ap:    db 'a'              ; am/pm character
smx:       dd 0               ; sad-mac screen centre
smy:       dd 0
sad_msg:   dd 0
sad_head:  db "NovaOS could not start", 0
sad_foot:  db "Please restart your computer", 0
sad_disk:  db "Error 0x0F03 - no disk detected", 0
sad_test:  db "Error 0x0000 - error screen test", 0
notif_msg1: dd 0              ; current toast line 1
notif_msg2: dd 0              ; current toast line 2
notif_timer: dd 0            ; 1 = a toast is showing
notif_start_sec: dd 0        ; RTC seconds-of-day when the toast appeared
nhist1:    times 5 dd 0       ; notification history line 1 (newest first)
nhist2:    times 5 dd 0       ; notification history line 2
notif_open:  dd 0            ; notification center panel open?
nc_time:   times 8 db 0
nc_date:   times 12 db 0
nc_y:      dd 0
ed_cursor_on: dd 0           ; editor caret blink state
fs_err:    db 0
fm_hdr2:   db "Files - New File, then Save to keep it:", 0
fm_new:    db "+ New File", 0
fm_newf:   db "New File", 0
fm_newd:   db "New Folder", 0
fm_up:     db "Up", 0
fm_full:   db "Folder or disk is full.", 0
fm_empty:  db "(empty folder)", 0
fm_empty_btn: db "Empty Trash", 0
rn_prompt: db "New name:", 0
nt_mkdir1: db "Folder created", 0
nt_mkdir2: db "Click it to open", 0
fm_err1:   db "No writable data partition here.", 0
fm_err2:   db "Run 'install' to add persistent storage.", 0
file_names:
    db "readme.txt", 0,0,0,0,0,0
    db "notes.txt", 0,0,0,0,0,0,0
    db "todo.txt", 0,0,0,0,0,0,0,0
    db "ideas.txt", 0,0,0,0,0,0,0
    db "diary.txt", 0,0,0,0,0,0,0
    db "scratch.txt", 0,0,0,0,0
note_div:  dd 4554,4058,3616,3419,3044,2712,2415,2281
snd_lbl:   db "Click the keys to play notes:", 0
sav_txt:   db "NovaOS", 0
paint_color: dd 0x00202830
paint_pal: dd 0x00202830, 0x00FFFFFF, 0x00E05050, 0x0050C060, 0x004070E0, 0x00E0C040, 0x0040C0C0, 0x00C060C0
; ---- settings-controlled state ----
accent:    dd 0x002C6FB4
shadows_on: db 1
accent_sel: dd 0
wall_sel:   dd 0
grad_r:    dd 42
grad_g:    dd 62
grad_b:    dd 102
grad_dr:   dd -32
grad_dg:   dd -46
grad_db:   dd -74
accent_opts: dd 0x002C6FB4, 0x00268F5E, 0x00B05CC0, 0x00D07A30
; wallpaper presets: top r,g,b then delta r,g,b  (4 presets x 6)
wall_opts: dd 42,62,102,-32,-46,-74
           dd 30,50,40,-22,-38,-30
           dd 60,40,70,-48,-30,-56
           dd 30,34,44,-22,-24,-32
; file manager mock tree
fm_hdr:  db "Files  (demo - NovaOS has no disk filesystem yet)", 0
fm_l1:   db "[DIR]  home/", 0
fm_l2:   db "         welcome.txt", 0
fm_l3:   db "         readme.md", 0
fm_l4:   db "[DIR]  apps/", 0
fm_l5:   db "         terminal   paint   editor", 0
fm_l6:   db "[DIR]  docs/", 0
fm_l7:   db "         notes.txt   ideas.txt", 0
fm_l8:   db "[DIR]  system/", 0
fm_l9:   db "         nova.kernel   font.dat", 0
; settings labels
set_hdr: db "Settings", 0
set_1:   db "Accent colour", 0
set_2:   db "Wallpaper", 0
set_3:   db "Window shadows", 0
set_btn: db "Change", 0
set_on:  db "ON", 0
set_off: db "OFF", 0
set_snd: db "Sounds", 0
set_vol: db "Volume: ", 0
set_minus: db "-", 0
set_plus:  db "+", 0
set_tabs: dd st_gen, st_about, st_stor
st_gen:  db "General", 0
st_about: db "About", 0
st_stor: db "Storage", 0
stor_none: db "No data partition on this disk.", 0
stor_hdr:  db "Data partition usage:", 0
stor_total_l: db "Total:", 0
stor_used_l:  db "Used:", 0
stor_free_l:  db "Free:", 0
set_about1: db "About NovaOS", 0
set_about2: db "Version 1.27  -  from-scratch operating system", 0
set_about3: db "Hand-written in x86 assembly, no Linux.", 0
set_about4: db "14 apps  -  window manager  -  live USB mode", 0
web_url:   db "nova://home", 0
web_1:     db "Welcome to Nova Browser", 0
web_2:     db "This is a built-in offline page.", 0
web_3:     db "NovaOS has no network stack, so it", 0
web_4:     db "cannot reach the real internet yet.", 0
web_5:     db "But you're browsing it from your own", 0
web_6:     db "operating system, written in assembly!", 0
ed_hint:   db "-- Text Editor: just start typing --", 0
ed_save_lbl: db "Save", 0
calc_btns: db '7','8','9','/', '4','5','6','*', '1','2','3','-', '0','.','=','+', 'C',0,0,0
mb_str:    db " MB", 0
clock_hint: db "(reopen Clock to refresh)", 0
about_1:   db "Nova OS 1.27", 0
about_2:   db "A from-scratch operating system,", 0
about_3:   db "hand-written in x86 assembly.", 0
; ---- window manager: one window per app id (0..4) ----
ws_state:  times 18 db 0       ; 0=closed, 1=open, 2=minimized
ws_x:      times 18 dd 0
ws_y:      times 18 dd 0
ws_w:      times 18 dd 0
ws_h:      times 18 dd 0
zorder:    times 18 db 0       ; window ids, back-to-front
ws_max:    times 18 db 0
ws_sx:     times 18 dd 0
ws_sy:     times 18 dd 0
ws_sw:     times 18 dd 0
ws_sh:     times 18 dd 0
zcount:    dd 0
focus:     dd -1
cur_app:   dd 0               ; app currently being drawn
dw_foc:    dd 0
drag_mode: db 0               ; 0=none, 1=move, 2=resize
drag_win:  dd 0
curbtn:    db 0
ol_x:      dd 0
ol_y:      dd 0
ol_w:      dd 0
ol_h:      dd 0
pcx:       dd 0
pcy:       dd 0
paint_dw:  dd 0
paint_dh:  dd 0
fmline:    dd 0
setrow:    dd 0
def_x:     dd 70,150,230,120,170,100,90,110,140,180,120,60,130,100,120,150,170,90
def_y:     dd 60,92,124,84,112,70,100,60,80,90,70,50,110,70,64,86,96,66
def_w:     dd 560,300,330,430,410,540,600,600,420,420,420,600,460,372,560,480,460,560
def_h:     dd 360,320,190,210,256,360,400,440,380,300,340,440,240,286,390,380,340,360
tb_bx:     dd 0
kbd_sc:    db 0
last_sc:   db 0
ed_col:    dd 0
ed_row:    dd 0
ed_shift:  db 0
ed_buf:    times MAXCOLS*MAXROWS db 0
tbuf:      times MAXCOLS*MAXROWS db 0
cursor_bmp:                  ; 8-wide x 12-tall arrow (drawn at 2x)
    db 0x80,0xC0,0xE0,0xF0,0xF8,0xFC,0xFE,0xFF,0xF8,0xD8,0x8C,0x0C

txt_top:    db "NOVA OS", 0
txt_title:  db "Nova Terminal", 0
txt_start:  db "Start", 0
gm_start:   db 10, "== Nova Start ==", 10
            db "Commands: help cpu mem res clear ver about reboot", 10, 0
con_banner: db "Nova OS  version 1.27  --  hi-res graphical shell", 10
            db "Drag this window by its title bar. Type 'help'.", 10, 0
con_prompt: db 10, "Nova> ", 0

gs_help:   db "help", 0
gs_cpu:    db "cpu", 0
gs_mem:    db "mem", 0
gs_clear:  db "clear", 0
gs_ver:    db "ver", 0
gs_about:  db "about", 0
gs_res:    db "res", 0
gs_reboot: db "reboot", 0
gs_disk:   db "disk", 0
gs_crash:  db "crash", 0
gs_usb:    db "usb", 0
gs_beep:   db "beep", 0
gs_apps:   db "apps", 0
gs_echo:   db "echo ", 0
gs_ls:     db "ls", 0
gs_cat:    db "cat ", 0
gs_install: db "install", 0
gs_yes:    db "yes", 0
gs_pcilist: db "pcilist", 0
gs_sysdump: db "sysdump", 0

lang_names: dd lang_en, lang_es, lang_fr
lang_en:   db "English", 0
lang_es:   db "Espanol", 0
lang_fr:   db "Francais", 0

gm_setup_hdr:  db 10, "=== NovaOS Setup ===", 10
               db "Welcome! This installs NovaOS onto a disk.", 10, 0
gm_setup_lang: db "Step 1/2 - Language:  1) English  2) Espanol  3) Francais", 10
               db "Type a number and press Enter (default 1):", 10, 0
gm_setup_picked: db "Language set to ", 0
gm_setup_confirm: db "Step 2/2 - Install target: second BIOS disk (internal drive).", 10
               db "WARNING: this ERASES that disk and writes NovaOS to it.", 10
               db "Type 'yes' to install, anything else to cancel:", 10, 0
gm_setup_cancel: db "Setup cancelled. Nothing was written.", 10, 0
gm_inst_go:    db "Installing NovaOS", 0
gm_fmt:        db 10, "Creating data partition (for saving files)", 0
gm_inst_done:  db "Done! NovaOS is installed. Remove the USB and reboot", 10
               db "to start NovaOS from the disk.", 10, 0
gm_inst_nodisk: db 10, "No install target found (need a 2nd/internal disk the", 10
               db "BIOS can see). Nothing was written.", 10, 0

gm_help:   db "Commands:", 10
           db "  help  - this list        cpu   - processor name", 10
           db "  mem   - installed RAM     res   - screen resolution", 10
           db "  disk  - list disks the BIOS can see", 10
           db "  usb   - read boot USB via BIOS", 10
           db "  apps  - list built-in apps  echo <text> - print text", 10
           db "  ls    - list files on FAT32 disk", 10
           db "  cat <file> - show a file's contents", 10
           db "  install - install NovaOS to a disk (Setup wizard)", 10
           db "  crash - preview the error screen", 10
           db "  beep  - test speaker      clear - clear screen", 10
           db "  ver   - version           about - about NovaOS", 10
           db "  reboot- restart", 10
           db "  pcilist - list every PCI device found (admin)", 10
           db "  sysdump - dump internal kernel diagnostics (admin)", 10, 0
gm_disk1:  db "Disks visible to the BIOS:", 10, 0
gm_disk2:  db "Bytes 0-15: ", 0
gm_disk_boot:  db "  Boot disk       : ", 0
gm_disk_2nd:   db "  Second disk 0x81: ", 0
gm_disk_ok:    db "readable OK", 10, 0
gm_disk_bad:   db "not readable", 10, 0
gm_disk_absent: db "not present", 10, 0
gm_usb1:   db "Asking BIOS to read the boot USB (sector 0)...", 10, 0
gm_usb_ok: db "USB is readable via BIOS - boot signature 55 AA found!", 10, 0
gm_usb_read: db "USB read OK (no 55 AA in sector 0 - maybe a data stick).", 10, 0
gm_usb_fail: db "BIOS could not read the boot device.", 10, 0
gm_apps:   db "Apps: Files Terminal Editor Paint Calc Clock Browser", 10
           db "      Settings Music Snake Screensaver + more", 10, 0
gm_ls1:    db "Files on the FAT32 disk:", 10, 0
gm_fs_fail:   db "No FAT32 data disk found (plug in the USB, or read error).", 10, 0
gm_fs_inst:   db "No data partition on this installed disk yet.", 10
              db "New files you make are kept in memory for now.", 10, 0
nc_title:  db "Notification Center", 0
nc_sys1:   db "NovaOS 1.27", 0
nc_sys2:   db "from-scratch x86 OS", 0
nc_recent: db "RECENT", 0
nc_none:   db "No notifications yet.", 0
nt_save1:  db "Saved to memory", 0
nt_save2:  db "File kept until reboot", 0
nt_nosave1: db "Cannot save - live USB", 0
nt_nosave2: db "Install to keep files", 0
nt_live1:   db "Can't create files - live USB", 0
nt_live2:   db "Type install to set up", 0
nt_emptied1: db "Trash emptied", 0
nt_emptied2: db "Items deleted for good", 0
nt_trash1:  db "Moved to Trash", 0
nt_trash2:  db "Open Trash to restore", 0
nt_saved1: db "Saved to disk", 0
nt_saved2: db "Also visible in Windows", 0
nt_werr1:  db "Disk write failed", 0
nt_werr2:  db "Data partition full?", 0
nt_hda_yes1: db "Sound: real speakers", 0
nt_hda_yes2: db "HD Audio chip found and working", 0
nt_hda_no1:  db "Sound: PC speaker", 0
nt_hda_no2:  db "No HD Audio chip found on this board", 0
ed_fname:  db "NOTE0   TXT"
gm_fs_nofile: db "File not found.", 10, 0
gm_ver:    db "Nova OS 1.27 (from-scratch x86, 32bpp true colour)", 10, 0
gm_about:  db "Nova OS - a from-scratch graphical OS.", 10
           db "Own bootloader + kernel, VESA hi-res framebuffer,", 10
           db "keyboard shell. All hand-written x86 assembly.", 10, 0
gm_cpu:    db "CPU: ", 0
gm_mem:    db "RAM: ", 0
gm_mb:     db " MB", 10, 0
gm_res:    db "Resolution: ", 0
gm_reboot: db "Rebooting...", 10, 0
gm_unknown: db "Unknown command: ", 0

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

%include "font8x16.inc"
