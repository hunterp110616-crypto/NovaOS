; ============================================================
;  NovaOS  --  README.TXT on the desktop after a fresh install / upgrade
;  (included into kernel_vesa.asm)
;
;  LBA 203 on the boot disk remembers which version last wrote the README,
;  so it appears once per install/upgrade and stays deleted if you delete it.
; ============================================================
README_LBA equ 203

ensure_readme:
    cmp dword [has_fatfs], 0
    je .ret
    pushad
    mov eax, README_LBA              ; already written for this version?
    call bios_read_lba
    test al, al
    jnz .done
    cld
    mov esi, DISKBUF
    mov edi, rd_magic
    mov ecx, 8
    repe cmpsb
    jne .write
    mov esi, DISKBUF + 8
    mov edi, nova_ver
    mov ecx, 16
    repe cmpsb
    je .done
.write:
    call fat_mount
    mov edi, name83
    mov esi, rd_name
    mov ecx, 11
    rep movsb
    mov eax, [fs_rootclus]           ; an old README.TXT in the root? free it first
    call clus_to_sector
    mov edi, FSDIR
    call fs_read_sector
    xor ebx, ebx
.f:
    cmp ebx, 16
    jae .new
    mov eax, ebx
    shl eax, 5
    lea esi, [FSDIR + eax]
    cmp byte [esi], 0
    je .new
    cmp byte [esi], 0xE5
    je .n
    call cmp83
    jne .n
    movzx eax, word [esi+20]
    shl eax, 16
    movzx edx, word [esi+26]
    or eax, edx
    call fat_free_chain
    jmp .new
.n:
    inc ebx
    jmp .f
.new:
    mov eax, [fs_rootclus]
    mov [save_dir], eax
    mov dword [wf_attr], 0x20
    mov esi, rd_text
    mov ecx, rd_text_len
    call fat_write_file              ; overwrites the old entry (same name)
    test al, al
    jnz .done
    mov edi, WSECT                   ; remember: README written for this version
    xor eax, eax
    mov ecx, 128
    rep stosd
    mov esi, rd_magic
    mov edi, WSECT
    mov ecx, 8
    rep movsb
    mov esi, nova_ver
    mov edi, WSECT + 8
    mov ecx, 16
    rep movsb
    mov al, [0x1014]
    mov [inst_drive], al
    mov eax, README_LBA
    mov esi, WSECT
    call bios_write_lba
    mov dword [desk_dirty], 1
    mov dword [files_dirty], 1
.done:
    popad
.ret:
    ret

rd_magic: db "NOVARDME"
rd_name:  db "README  TXT"
rd_text:
    db "NOVAOS 1.27 - README       (click [] to see it all)", 13, 10
    db "Welcome! NovaOS is an operating system written from", 13, 10
    db "scratch in x86 assembly - no Windows or Linux inside.", 13, 10
    db "THE DESKTOP", 13, 10
    db "- Start (bottom-left) or the Windows key opens the apps.", 13, 10
    db "- Drag a window by its title bar; drag the corner to resize.", 13, 10
    db "- Title buttons: [] maximise   _ minimise   X close.", 13, 10
    db "- Click the clock for the Notification Center.", 13, 10
    db "- Right-click the desktop: New file/folder, Wallpaper.", 13, 10, 13, 10
    db "APPS", 13, 10
    db "Terminal, Calculator, Clock, System Info, Text Editor,", 13, 10
    db "Nova Browser (offline), Nova Paint, Files, Settings,", 13, 10
    db "Bounce, Screensaver, Sound Play, Snake, Music Maker.", 13, 10, 13, 10
    db "FILES", 13, 10
    db "- Files: New File / New Folder, R = rename, X = Trash.", 13, 10
    db "- Right-click the Trash bin to empty it.", 13, 10
    db "- Text Editor: type, then press Save. Files stay after a", 13, 10
    db "  restart, and Windows can read them from the disk too.", 13, 10
    db "- USB sticks: plug in, Files > USB Drive (Refresh looks", 13, 10
    db "  again). Read-only FAT32, when started from the disk.", 13, 10, 13, 10
    db "TERMINAL  (type help for the full list)", 13, 10
    db "  ls   cat NAME   cpu   mem   time   date   calc 2+3", 13, 10
    db "  color green   disk   usb   echo   beep   apps   reboot", 13, 10, 13, 10
    db "SHUT DOWN AND UPDATES", 13, 10
    db "- Start > Shut Down...: Shut down, Restart or Update.", 13, 10
    db "- Update: plug in a newer NovaOS USB, then Shut Down...", 13, 10
    db "  > Update from USB. Your files are kept.", 13, 10
    db "- Settings > General > Sounds turns sounds on or off.", 13, 10
rd_text_len equ $ - rd_text
