; ============================================================
;  NovaOS  --  protected, hidden SYSTEM folder (like Windows' system files)
;  (included into kernel_vesa.asm)
;
;  \SYSTEM (attr hidden+system+dir) holds NOVACORE.SYS, BOOT.CFG and
;  DRIVERS.SYS (attr read-only+hidden+system).  Files shows a warning
;  before listing it; system items can't be deleted, renamed or saved over.
; ============================================================

; make sure \SYSTEM and its files exist on the data partition; sets [sys_cluster]
ensure_system:
    cmp dword [has_fatfs], 0
    je .ret
    pushad
    call fat_mount
    mov edi, name83
    mov esi, sys_dirname
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
    mov [sys_cluster], eax
    jmp .files
.n:
    inc ebx
    jmp .f
.create:
    mov eax, [fs_rootclus]
    mov [cwd_cluster], eax
    mov dword [mk_attr], 0x16        ; directory + system + hidden
    call fat_mkdir
    mov dword [mk_attr], 0x10
    test al, al
    jnz .restore
    mov eax, [mk_clus]
    mov [sys_cluster], eax
.files:
    mov eax, [sys_cluster]
    mov [save_dir], eax
    mov dword [wf_attr], 0x27        ; archive + system + hidden + read-only
    mov esi, sys_f1
    mov edx, sys_t1
    mov ecx, sys_t1_len
    call .one
    mov esi, sys_f2
    mov edx, sys_t2
    mov ecx, sys_t2_len
    call .one
    mov esi, sys_f3
    mov edx, sys_t3
    mov ecx, sys_t3_len
    call .one
    mov dword [wf_attr], 0x20
.restore:
    mov eax, [fs_rootclus]
    mov [cwd_cluster], eax
    mov [save_dir], eax
.done:
    popad
.ret:
    ret
.one:                                ; ESI = 8.3 name, EDX = text, ECX = length
    mov [sf_text], edx               ; write it only if missing or different (e.g. after an upgrade)
    mov [sf_len], ecx
    mov edi, name83
    mov ecx, 11
    rep movsb
    mov eax, [sys_cluster]
    call clus_to_sector
    mov edi, FSDIR
    call fs_read_sector
    xor ebx, ebx
.s:
    cmp ebx, 16
    jae .write
    mov eax, ebx
    shl eax, 5
    lea esi, [FSDIR + eax]
    cmp byte [esi], 0
    je .write
    cmp byte [esi], 0xE5
    je .sn
    call cmp83
    je .found
.sn:
    inc ebx
    jmp .s
.found:
    movzx eax, word [esi+20]
    shl eax, 16
    movzx edx, word [esi+26]
    or eax, edx
    mov [sf_clus], eax
    mov eax, [esi+28]
    cmp eax, [sf_len]
    jne .stale
    mov eax, [sf_clus]               ; same size: compare the text (all < 512 bytes)
    call clus_to_sector
    mov edi, STORBUF
    call fs_read_sector
    mov esi, STORBUF
    mov edi, [sf_text]
    mov ecx, [sf_len]
    cld
    repe cmpsb
    je .same
.stale:
    mov eax, [sf_clus]               ; out of date: free the old copy, then rewrite
    call fat_free_chain
.write:
    mov esi, [sf_text]
    mov ecx, [sf_len]
    call fat_write_file
.same:
    ret

; Files window: SYSTEM folder is locked behind a warning until "Show files anyway"
; Called from draw_file_content before the rows.  AL = 1 if it drew the warning.
sys_warn_draw:
    mov eax, [cwd_cluster]
    cmp eax, [sys_cluster]
    je .in
    mov dword [sys_shown], 0         ; left the folder -> lock it again
    xor al, al
    ret
.in:
    cmp dword [sys_shown], 0
    je .warn
    xor al, al
    ret
.warn:
    pushad
    mov eax, [con_x0]                ; warning sign
    add eax, 12
    mov [rx], eax
    mov eax, [con_y0]
    add eax, 44
    mov [ry], eax
    mov dword [rw], 30
    mov dword [rh], 30
    mov dword [rcolor], 0x00E0A020
    call fillrect
    mov eax, [rx]
    add eax, 11
    mov [tx], eax
    mov eax, [ry]
    add eax, 7
    mov [ty], eax
    mov dword [tcolor], 0x00101010
    mov al, '!'
    call draw_char
    mov esi, sw_1
    mov edx, 0x00FFD070
    mov ebx, 46
    call .line
    mov esi, sw_2
    mov edx, C_WHITE
    mov ebx, 76
    call .line
    mov esi, sw_3
    mov ebx, 96
    call .line
    mov esi, sw_4
    mov ebx, 116
    call .line
    mov eax, [con_x0]                ; [ Show files anyway ]
    add eax, 56
    mov [rx], eax
    mov eax, [con_y0]
    add eax, 146
    mov [ry], eax
    mov dword [rw], 168
    mov dword [rh], 24
    mov eax, [accent]
    mov [rcolor], eax
    call fillrect
    mov eax, [rx]
    add eax, 12
    mov [tx], eax
    mov eax, [ry]
    add eax, 4
    mov [ty], eax
    mov dword [tcolor], C_WHITE
    mov esi, sw_btn
    call draw_text
    popad
    mov al, 1
    ret
.line:                               ; ESI text, EDX colour, EBX y offset
    mov eax, [con_x0]
    add eax, 56
    mov [tx], eax
    mov eax, [con_y0]
    add eax, ebx
    mov [ty], eax
    mov [tcolor], edx
    call draw_text
    ret

; click inside Files while the warning is up.  AL = 1 if consumed.
sys_warn_click:
    mov eax, [cwd_cluster]
    cmp eax, [sys_cluster]
    jne .no
    cmp dword [sys_shown], 0
    jne .no
    mov eax, [mouse_y]
    sub eax, [con_y0]
    cmp eax, 146
    jl .yes
    cmp eax, 170
    jg .yes
    mov eax, [mouse_x]
    sub eax, [con_x0]
    cmp eax, 56
    jl .yes
    cmp eax, 224
    jg .yes
    mov dword [sys_shown], 1
    call recompose
.yes:
    mov al, 1                        ; eat every body click while locked
    ret
.no:
    xor al, al
    ret

; refuse to delete / rename a system item.  AL = 1 if refused (toast shown)
sys_protect:
    cmp dword [fm_vol], 0
    je .disk
    call err_beep
    mov esi, nt_usbro1
    mov edi, nt_usbro2
    call notify
    call recompose
    mov al, 1
    ret
.disk:
    mov ebx, [fm_sel]
    test byte [dir_attr + ebx], 0x04
    jz .ok
    call err_beep
    mov esi, nt_sys1
    mov edi, nt_sys2
    call notify
    call recompose
    mov al, 1
    ret
.ok:
    xor al, al
    ret

sys_cluster: dd 0
sf_text:     dd 0
sf_len:      dd 0
sf_clus:     dd 0
sys_shown:   dd 0
mk_attr:     dd 0x10
wf_attr:     dd 0x20
ed_ro:       dd 0
sys_dirname: db "SYSTEM     "
sys_f1:      db "NOVACORESYS"
sys_f2:      db "BOOT    CFG"
sys_f3:      db "DRIVERS SYS"
sw_1:        db "These files are hidden.", 0
sw_2:        db "They keep NovaOS running. Changing or", 0
sw_3:        db "deleting them could stop NovaOS from", 0
sw_4:        db "starting.", 0
sw_btn:      db "Show files anyway", 0
nt_sys1:     db "Protected system file", 0
nt_sys2:     db "NovaOS needs this to run", 0
nt_ro1:      db "This file is read-only", 0
nt_ro2:      db "System files can't be changed", 0
sys_t1:
    db "NOVACORE.SYS - the Nova Core", 13, 10, 13, 10
    db "NovaOS 1.27  (build 2026-09-29)", 13, 10, 13, 10
    db "The Nova Core is the heart of NovaOS: it runs", 13, 10
    db "the desktop, windows, apps, files, keyboard", 13, 10
    db "and mouse. It is written from scratch in", 13, 10
    db "assembly and lives in the disk's reserved", 13, 10
    db "boot sectors (1-200), before this partition.", 13, 10, 13, 10
    db "New in 1.27: Device Manager, Task Manager, and an Admin", 13, 10
    db "Terminal -- right-click the Start button to open them.", 13, 10
    db "New in 1.26: a new startup chime -- a royalty-free", 13, 10
    db "bell logo sound, licensed for free use and modification.", 13, 10
    db "New in 1.25: a brand new original startup chime -- a", 13, 10
    db "bright arpeggio and chord, under one second long.", 13, 10
    db "New in 1.24: the sound chip's position reading is now", 13, 10
    db "ignored for a brief moment right as playback starts,", 13, 10
    db "since it can read bogus values until it settles.", 13, 10
    db "New in 1.23: fixed the sound chip's position reading", 13, 10
    db "being noisy on real hardware, which could stop the", 13, 10
    db "startup chime early on some boards.", 13, 10
    db "New in 1.22: the startup chime stops the instant it", 13, 10
    db "finishes instead of possibly restarting and cutting", 13, 10
    db "off partway through the repeat.", 13, 10
    db "New in 1.21: About Nova now shows where the last sound", 13, 10
    db "stopped, to help track down clips cutting off early.", 13, 10
    db "New in 1.20: all real-speaker audio now plays at a", 13, 10
    db "plain 44100 Hz -- some real sound chips didn't honour", 13, 10
    db "the half-rate mode, playing everything twice as fast.", 13, 10
    db "New in 1.19: a new Windows 98 startup sound; the", 13, 10
    db "clock-reading code can no longer freeze the whole", 13, 10
    db "system if the real-time clock ever misbehaves.", 13, 10
    db "New in 1.18: Music Maker plays through real speakers", 13, 10
    db "when this board has them, and a real-hardware RTC", 13, 10
    db "glitch that could cut the startup chime short is fixed.", 13, 10
    db "New in 1.17: the startup chime is sped up to fit", 13, 10
    db "under 2 seconds, so it doesn't hold up the boot.", 13, 10
    db "New in 1.16: a Volume control in Settings, a", 13, 10
    db "smoother startup chime, and sample SFX buttons", 13, 10
    db "in Music Maker (laser, coin, boing, pop, kick, chime).", 13, 10
    db "New in 1.15: sound hardware can now be found even", 13, 10
    db "when the BIOS doesn't assign it a memory address.", 13, 10
    db "New in 1.12: real sound! The startup chime plays through HD Audio.", 13, 10
    db "New in 1.4: README on the desktop, cleaner sound.", 13, 10
    db "New in 1.3: Shut Down menu, Update from USB,", 13, 10
    db "and a recorded startup sound.", 13, 10
    db "New in 1.2: an XP-style startup chime.", 13, 10
    db "New in 1.1: Setup can Upgrade NovaOS and", 13, 10
    db "keep your files.", 13, 10, 13, 10
    db "Protected system file. Do not delete.", 13, 10
sys_t1_len equ $ - sys_t1
sys_t2:
    db "[boot]", 13, 10
    db "system  = NovaOS 1.27", 13, 10
    db "loader  = sector 0 (MBR)", 13, 10
    db "core    = sectors 1-200", 13, 10
    db "data    = FAT32, sector 2048", 13, 10
    db "display = VESA 32-bit colour", 13, 10
    db "splash  = xp", 13, 10
sys_t2_len equ $ - sys_t2
sys_t3:
    db "NovaOS drivers (built into the Nova Core)", 13, 10, 13, 10
    db "keyboard   PS/2", 13, 10
    db "mouse      PS/2", 13, 10
    db "disk       BIOS int 13h", 13, 10
    db "display    VESA linear framebuffer", 13, 10
    db "sound      PC speaker", 13, 10
    db "timer      PIT 8254", 13, 10
    db "clock      CMOS real-time clock", 13, 10
sys_t3_len equ $ - sys_t3
