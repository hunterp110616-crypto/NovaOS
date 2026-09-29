; ============================================================
;  NovaOS -- Device Manager (15), Task Manager (16),
;            Admin Terminal (17), and the Start button's
;            right-click menu that opens them.
; ============================================================

; ---------------- Device Manager ----------------
; a full PCI bus scan (same technique hda_init proved out: bus 0-255,
; device 0-31, function 0-7 -- some boards route hardware off bus 0)
; run once at boot, kept around so the app just displays it instantly.
DEVMGR_LIST equ HDAMEM + 0x200000   ; {classword, scan-cursor} pairs, 8 bytes each
DEVMGR_MAX  equ 48
DEVMGR_SHOWN equ 20
devmgr_count: dd 0                   ; how many are actually stored (capped at DEVMGR_MAX)
devmgr_total: dd 0                   ; how many were really found (usually == count)
dm_bus:   dd 0
dm_dev:   dd 0
dm_fn:    dd 0
dm_class: dd 0

devmgr_scan:
    pushad
    mov dword [devmgr_count], 0
    mov dword [devmgr_total], 0
    xor esi, esi
.scan:
    cmp esi, 256*32*8
    jae .done
    mov eax, esi
    shl eax, 8
    mov [u_pa], eax
    call pci_rd
    cmp ax, 0xFFFF
    je .next
    inc dword [devmgr_total]
    mov ecx, [devmgr_count]
    cmp ecx, DEVMGR_MAX
    jae .next
    mov eax, [u_pa]
    add eax, 0x08
    call pci_rd
    shr eax, 8                       ; class<<16 | subclass<<8 | progif
    mov edi, DEVMGR_LIST
    imul ecx, 8
    add edi, ecx
    mov [edi], eax
    mov [edi + 4], esi
    inc dword [devmgr_count]
.next:
    inc esi
    jmp .scan
.done:
    popad
    ret

; EAX = classword -> ESI = driver-name string
devmgr_driver_name:
    cmp eax, 0x040300
    je .hda
    cmp eax, 0x0C0300
    je .uhci
    cmp eax, 0x0C0310
    je .ohci
    cmp eax, 0x0C0320
    je .ehci
    mov ecx, eax                     ; ECX, not EBX -- callers use EBX as a loop counter
    shr ecx, 16
    cmp ecx, 0x01
    je .storage
    cmp ecx, 0x03
    je .vga
    cmp ecx, 0x06
    je .bridge
    cmp ecx, 0x04
    je .mm
    mov esi, dm_none
    ret
.hda:
    mov esi, dm_hda
    ret
.uhci:
    mov esi, dm_uhci
    ret
.ohci:
    mov esi, dm_ohci
    ret
.ehci:
    mov esi, dm_ehci
    ret
.storage:
    mov esi, dm_storage
    ret
.vga:
    mov esi, dm_vga
    ret
.bridge:
    mov esi, dm_bridge
    ret
.mm:
    mov esi, dm_mm
    ret

draw_devmgr_content:
    pushad
    mov eax, [con_x0]
    add eax, 10
    mov [tx], eax
    mov eax, [con_y0]
    add eax, 8
    mov [ty], eax
    mov dword [tcolor], C_WHITE
    mov esi, dm_header
    call draw_text
    mov eax, [devmgr_total]
    call draw_num
    xor ebx, ebx
.row:
    cmp ebx, [devmgr_count]
    jae .done
    cmp ebx, DEVMGR_SHOWN
    jae .more
    mov edi, DEVMGR_LIST
    mov eax, ebx
    imul eax, 8
    add edi, eax
    mov eax, [edi]
    mov [dm_class], eax
    mov eax, [edi + 4]
    mov ecx, eax
    shr ecx, 8
    mov [dm_bus], ecx
    mov ecx, eax
    shr ecx, 3
    and ecx, 0x1F
    mov [dm_dev], ecx
    mov ecx, eax
    and ecx, 7
    mov [dm_fn], ecx
    mov eax, [con_x0]
    add eax, 10
    mov [tx], eax
    mov eax, [con_y0]
    add eax, 32
    mov ecx, ebx
    imul ecx, 16
    add eax, ecx
    mov [ty], eax
    mov dword [tcolor], 0x008FE9B6
    mov esi, dm_row_b
    call draw_text
    mov eax, [dm_bus]
    call draw_num
    mov esi, dm_row_d
    call draw_text
    mov eax, [dm_dev]
    call draw_num
    mov esi, dm_row_f
    call draw_text
    mov eax, [dm_fn]
    call draw_num
    mov esi, dm_row_cls
    call draw_text
    mov eax, [dm_class]
    shr eax, 16
    and eax, 0xFF
    call draw_num
    mov al, '.'
    call draw_char
    add dword [tx], 8
    mov eax, [dm_class]
    shr eax, 8
    and eax, 0xFF
    call draw_num
    mov al, '.'
    call draw_char
    add dword [tx], 8
    mov eax, [dm_class]
    and eax, 0xFF
    call draw_num
    mov esi, dm_row_sep
    call draw_text
    mov dword [tcolor], C_TEXT
    mov eax, [dm_class]
    call devmgr_driver_name
    call draw_text
    inc ebx
    jmp .row
.more:
    mov eax, [con_x0]
    add eax, 10
    mov [tx], eax
    mov eax, [con_y0]
    add eax, 32
    mov ecx, DEVMGR_SHOWN
    imul ecx, 16
    add eax, ecx
    mov [ty], eax
    mov dword [tcolor], 0x008A96A6
    mov esi, dm_andmore
    call draw_text
    mov eax, [devmgr_count]
    sub eax, DEVMGR_SHOWN
    call draw_num
    mov esi, dm_more2
    call draw_text
.done:
    popad
    ret

dm_header:  db "PCI devices found: ", 0
dm_row_b:   db "  B", 0
dm_row_d:   db " D", 0
dm_row_f:   db " F", 0
dm_row_cls: db "  class ", 0
dm_row_sep: db "  ", 0
dm_andmore: db "  ...and ", 0
dm_more2:   db " more not shown", 0
dm_hda:     db "Intel HD Audio (hda.inc)", 0
dm_uhci:    db "USB UHCI (usb.inc)", 0
dm_ohci:    db "USB OHCI (usb.inc)", 0
dm_ehci:    db "USB EHCI (usb.inc)", 0
dm_storage: db "Storage (BIOS disk access)", 0
dm_vga:     db "Display (BIOS VESA)", 0
dm_bridge:  db "PCI bridge", 0
dm_mm:      db "Multimedia (no NovaOS driver)", 0
dm_none:    db "No NovaOS driver", 0

; ---------------- Task Manager ----------------
TASKMGR_ROWH equ 24
tm_row: dd 0

draw_taskmgr_content:
    pushad
    mov eax, [con_x0]
    add eax, 10
    mov [tx], eax
    mov eax, [con_y0]
    add eax, 8
    mov [ty], eax
    mov dword [tcolor], C_WHITE
    mov esi, tm_header
    call draw_text
    mov eax, [0x1000]
    mov ebx, 1024
    xor edx, edx
    div ebx
    call draw_num
    mov esi, tm_mb
    call draw_text
    xor ebx, ebx
    mov dword [tm_row], 0
.l:
    cmp ebx, 18
    jae .done
    cmp byte [ws_state + ebx], 0
    je .next
    mov eax, [con_x0]
    add eax, 10
    mov [tx], eax
    mov eax, [con_y0]
    add eax, 38
    mov ecx, [tm_row]
    imul ecx, TASKMGR_ROWH
    add eax, ecx
    mov [ty], eax
    mov dword [tcolor], C_TEXT
    mov esi, [app_titles + ebx*4]
    call draw_text
    mov eax, [con_x0]
    add eax, 240
    mov [tx], eax
    mov dword [tcolor], 0x008A96A6
    mov esi, tm_open
    cmp byte [ws_state + ebx], 2
    jne .st
    mov esi, tm_min
.st:
    call draw_text
    mov eax, [con_x0]
    add eax, 320
    mov [rx], eax
    mov eax, [con_y0]
    add eax, 38
    mov ecx, [tm_row]
    imul ecx, TASKMGR_ROWH
    add eax, ecx
    mov [ry], eax
    mov dword [rw], 80
    mov dword [rh], 20
    mov dword [rcolor], 0x00702A2A
    mov dword [rrad], 4
    mov dword [rround], 3
    call fill_rrect
    mov eax, [rx]
    add eax, 8
    mov [tx], eax
    mov eax, [ry]
    add eax, 3
    mov [ty], eax
    mov dword [tcolor], C_WHITE
    mov esi, tm_endtask
    call draw_text
    inc dword [tm_row]
.next:
    inc ebx
    jmp .l
.done:
    popad
    ret

; a click inside the Task Manager body (con_* already loaded)
taskmgr_click:
    mov eax, [mouse_x]
    mov ebx, [con_x0]
    add ebx, 320
    cmp eax, ebx
    jl .r
    add ebx, 80
    cmp eax, ebx
    jg .r
    mov eax, [mouse_y]
    sub eax, [con_y0]
    sub eax, 38
    js .r
    xor edx, edx
    mov ecx, TASKMGR_ROWH
    div ecx
    mov edx, eax                     ; the visible-row index clicked
    xor ebx, ebx                     ; app id
    xor ecx, ecx                     ; visible-row counter
.find:
    cmp ebx, 18
    jae .r
    cmp byte [ws_state + ebx], 0
    je .fnext
    cmp ecx, edx
    je .hit
    inc ecx
.fnext:
    inc ebx
    jmp .find
.hit:
    mov eax, ebx
    call close_window
    call recompose
    ret
.r:
    ret

tm_header:  db "Task Manager   RAM: ", 0
tm_mb:      db " MB", 0
tm_open:    db "Running", 0
tm_min:     db "Minimized", 0
tm_endtask: db "End Task", 0

; ---------------- Admin Terminal ----------------
; Reuses the EXACT same shell (handle_scancode/grun_command/gputchar/gprint/...)
; as the normal Terminal -- those all read a handful of shared globals
; (gcol/grow/gbuf_len/gshift/cur_text_buf/gcmd), so a second, independent
; terminal just needs its own shadow copies of those globals and a swap
; routine that trades them with the live ones before/after using the shared
; machinery. Two extra commands (pcilist, sysdump) are added to the shared
; command set itself, so they work from either terminal.
admin_gcol: dd 0
admin_grow: dd 0
admin_gbuf_len: dd 0
admin_gshift: db 0
abuf: times MAXCOLS*MAXROWS db 0

; swap the shared terminal-cursor/buffer globals with Admin Terminal's shadow
; copies (and back again on the next call) -- called once to enter Admin
; Terminal's context, once more to leave it.
admin_ctx_swap:
    pushad
    mov eax, [gcol]
    mov ebx, [admin_gcol]
    mov [gcol], ebx
    mov [admin_gcol], eax
    mov eax, [grow]
    mov ebx, [admin_grow]
    mov [grow], ebx
    mov [admin_grow], eax
    mov eax, [gbuf_len]
    mov ebx, [admin_gbuf_len]
    mov [gbuf_len], ebx
    mov [admin_gbuf_len], eax
    movzx eax, byte [gshift]
    movzx ebx, byte [admin_gshift]
    mov [gshift], bl
    mov [admin_gshift], al
    mov eax, [cur_text_buf]
    cmp eax, tbuf
    je .toa
    mov dword [cur_text_buf], tbuf
    jmp .done
.toa:
    mov dword [cur_text_buf], abuf
.done:
    popad
    ret

handle_admin_scancode:
    call admin_ctx_swap
    call handle_scancode
    call admin_ctx_swap
    ret

draw_admin_content:
    mov esi, abuf
    call draw_grid
    ret

admin_banner: db "NovaOS Administrator Terminal", 10
              db "Same commands as Nova Terminal, plus:", 10
              db "  pcilist - list every PCI device found", 10
              db "  sysdump - dump internal kernel diagnostics", 10, 0

; ---- the two admin-only shell commands (available from either terminal) ----
gprint_pcilist:
    pushad
    mov esi, pl_header
    call gprint
    mov eax, [devmgr_total]
    call gprint_dec
    call gnewline
    xor ebx, ebx
.l:
    cmp ebx, [devmgr_count]
    jae .done
    mov edi, DEVMGR_LIST
    mov eax, ebx
    imul eax, 8
    add edi, eax
    mov eax, [edi]
    mov [dm_class], eax
    mov eax, [edi + 4]
    mov ecx, eax
    shr ecx, 8
    mov [dm_bus], ecx
    mov ecx, eax
    shr ecx, 3
    and ecx, 0x1F
    mov [dm_dev], ecx
    mov ecx, eax
    and ecx, 7
    mov [dm_fn], ecx
    mov esi, pl_b
    call gprint
    mov eax, [dm_bus]
    call gprint_dec
    mov esi, pl_d
    call gprint
    mov eax, [dm_dev]
    call gprint_dec
    mov esi, pl_f
    call gprint
    mov eax, [dm_fn]
    call gprint_dec
    mov esi, pl_cls
    call gprint
    mov eax, [dm_class]
    shr eax, 16
    and eax, 0xFF
    call gprint_dec
    mov al, '.'
    call gputchar
    mov eax, [dm_class]
    shr eax, 8
    and eax, 0xFF
    call gprint_dec
    mov al, '.'
    call gputchar
    mov eax, [dm_class]
    and eax, 0xFF
    call gprint_dec
    mov esi, pl_sep
    call gprint
    mov eax, [dm_class]
    call devmgr_driver_name
    call gprint
    call gnewline
    inc ebx
    jmp .l
.done:
    popad
    ret

pl_header: db "PCI devices found: ", 0
pl_b:      db "  bus ", 0
pl_d:      db " dev ", 0
pl_f:      db " fn ", 0
pl_cls:    db "  class ", 0
pl_sep:    db "  ", 0

gprint_sysdump:
    pushad
    mov esi, syd_l1
    call gprint
    mov eax, [hda_ok]
    call gprint_dec
    mov esi, syd_l2
    call gprint
    mov eax, [hda_diag_stage]
    call gprint_dec
    mov esi, syd_l3
    call gprint
    mov eax, [hda_last_lpib]
    call gprint_dec
    mov esi, syd_l3b
    call gprint
    mov eax, [hda_last_cbl]
    call gprint_dec
    mov esi, syd_l4
    call gprint
    mov eax, [hda_last_sdsts]
    call gprint_dec
    call gnewline
    mov esi, syd_l5
    call gprint
    mov eax, [devmgr_total]
    call gprint_dec
    mov esi, syd_l6
    call gprint
    mov eax, [frame]
    call gprint_dec
    call gnewline
    popad
    ret

syd_l1:  db "hda_ok: ", 0
syd_l2:  db 10, "hda_diag_stage: ", 0
syd_l3:  db 10, "last audio stream stopped at byte ", 0
syd_l3b: db " of ", 0
syd_l4:  db "  status ", 0
syd_l5:  db "PCI devices found: ", 0
syd_l6:  db 10, "frame counter: ", 0

; ---------------- Start button right-click menu ----------------
; Device Manager / Task Manager / Admin Terminal -- opened by right-clicking
; the Start button, modelled closely on the existing desktop right-click
; menu (cmenu_*), but with its own tiny save/restore buffer so it never
; risks clobbering a not-yet-restored Start menu or desktop menu.
STARTCM_W equ 170
STARTCM_H equ 96
STARTCMSAVE equ HDAMEM + 0x210000
startcm_open: db 0
startcm_x: dd 0
startcm_y: dd 0
sc_devmgr:  db "Device Manager", 0
sc_taskmgr: db "Task Manager", 0
sc_admin:   db "Admin Terminal", 0
startcm_list: dd sc_devmgr, sc_taskmgr, sc_admin

open_start_cmenu:
    cmp byte [mouse_present], 0
    je .nc
    call restore_cursor
.nc:
    mov dword [startcm_x], 4
    mov eax, [scrh]
    sub eax, 27
    sub eax, STARTCM_H
    mov [startcm_y], eax
    call startcm_save
    mov eax, [startcm_x]
    mov [rx], eax
    mov eax, [startcm_y]
    mov [ry], eax
    mov dword [rw], STARTCM_W
    mov dword [rh], STARTCM_H
    mov dword [rcolor], 0x00303A4A
    mov dword [rrad], 8
    mov dword [rround], 3
    call fill_rrect
    xor ebx, ebx
.it:
    cmp ebx, 3
    jae .done
    mov eax, ebx
    imul eax, 28
    add eax, [startcm_y]
    add eax, 10
    mov [ty], eax
    mov eax, [startcm_x]
    add eax, 14
    mov [tx], eax
    mov dword [tcolor], C_WHITE
    mov esi, [startcm_list + ebx*4]
    call draw_text
    inc ebx
    jmp .it
.done:
    mov byte [startcm_open], 1
    cmp byte [mouse_present], 0
    je .r
    call save_cursor
    call draw_cursor
.r:
    ret

close_start_cmenu:
    call restore_cursor
    call startcm_restore
    mov byte [startcm_open], 0
    call save_cursor
    call draw_cursor
    ret

startcm_save:
    pushad
    mov edi, STARTCMSAVE
    mov ebx, [startcm_y]
    mov ecx, STARTCM_H
.row:
    test ecx, ecx
    jz .done
    mov eax, ebx
    imul eax, [pitch]
    add eax, [lfb]
    mov edx, [startcm_x]
    shl edx, 2
    add eax, edx
    mov esi, eax
    push ecx
    mov ecx, STARTCM_W
    rep movsd
    pop ecx
    inc ebx
    dec ecx
    jmp .row
.done:
    popad
    ret

startcm_restore:
    pushad
    mov esi, STARTCMSAVE
    mov ebx, [startcm_y]
    mov ecx, STARTCM_H
.row:
    test ecx, ecx
    jz .done
    mov eax, ebx
    imul eax, [pitch]
    add eax, [lfb]
    mov edx, [startcm_x]
    shl edx, 2
    add eax, edx
    mov edi, eax
    push ecx
    mov ecx, STARTCM_W
    rep movsd
    pop ecx
    inc ebx
    dec ecx
    jmp .row
.done:
    popad
    ret

startcm_click:
    mov eax, [mouse_x]
    mov ebx, [startcm_x]
    cmp eax, ebx
    jl .close
    add ebx, STARTCM_W
    cmp eax, ebx
    jg .close
    mov eax, [mouse_y]
    mov ebx, [startcm_y]
    cmp eax, ebx
    jl .close
    mov ecx, ebx
    add ecx, STARTCM_H
    cmp eax, ecx
    jg .close
    sub eax, ebx
    xor edx, edx
    mov ecx, 28
    div ecx
    cmp eax, 3
    jae .close
    add eax, 15                       ; item 0 -> app 15, 1 -> 16, 2 -> 17
    push eax
    call close_start_cmenu
    pop eax
    call open_window
    call recompose
    ret
.close:
    call close_start_cmenu
    ret
