; ============================================================
;  NovaOS  --  Music Maker (app 14)
;  A 16-step melody grid over one octave (C4..C5), played through
;  the PC speaker in the background while NovaOS keeps running.
;  Click a square to place / remove a note; the keyboard is a piano:
;     A S D F G H J K  = C D E F G A B C      W E T Y U = the sharps
;  Arrows move the cursor, Space plays / stops, Backspace clears a step.
;  Save / Load keep the song in SONG.NTR on the disk (a small text file).
; ============================================================

MUS_STEPS equ 16
MUS_CW    equ 28              ; cell width
MUS_RH    equ 17              ; row height
MUS_GX    equ 46              ; grid offset inside the window
MUS_GY    equ 34

; ---------------- drawing ----------------
draw_music_content:
    pushad
    ; buttons along the top
    xor ebx, ebx
.b:
    cmp ebx, 6
    jae .bdone
    mov eax, [mus_bx + ebx*4]
    add eax, [con_x0]
    mov [rx], eax
    mov eax, [con_y0]
    add eax, 2
    mov [ry], eax
    mov eax, [mus_bw + ebx*4]
    mov [rw], eax
    mov dword [rh], 22
    mov dword [rcolor], 0x00283C58
    test ebx, ebx
    jnz .bc
    cmp dword [mus_playing], 0
    je .bc
    mov dword [rcolor], 0x00286048          ; Play button is green while playing
.bc:
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
    mov esi, [mus_bl + ebx*4]
    test ebx, ebx
    jnz .bt
    cmp dword [mus_playing], 0
    je .bt
    mov esi, mus_l_stop
.bt:
    call draw_text
    inc ebx
    jmp .b
.bdone:
    ; tempo
    mov eax, [con_x0]
    add eax, 272
    mov [tx], eax
    mov eax, [con_y0]
    add eax, 5
    mov [ty], eax
    mov dword [tcolor], 0x008B93A7
    mov esi, mus_l_tempo
    call draw_text
    mov eax, [con_x0]
    add eax, 324
    mov [tx], eax
    mov dword [tcolor], C_WHITE
    mov eax, [mus_tempo]
    call draw_num
    call mus_draw_grid
    cmp dword [mus_ask], 0
    je .noask
    call mus_draw_ask
    popad
    ret
.noask:
    ; how to play
    mov eax, [con_x0]
    add eax, 8
    mov [tx], eax
    mov eax, [con_y0]
    add eax, MUS_GY + 13*MUS_RH + 12
    mov [ty], eax
    mov dword [tcolor], 0x008B93A7
    mov esi, mus_help1
    call draw_text
    mov eax, [con_x0]
    add eax, 8
    mov [tx], eax
    add dword [ty], 18
    mov esi, mus_help2
    call draw_text
    ; SFX row: 6 one-shot sample buttons (needs a real sound chip)
    mov eax, [con_x0]
    add eax, 8
    mov [tx], eax
    add dword [ty], 22
    mov dword [tcolor], 0x008B93A7
    mov esi, mus_l_sfx
    call draw_text
    xor ebx, ebx
.sb:
    cmp ebx, NSFX
    jae .sbdone
    mov eax, ebx
    imul eax, MUS_SFXW + 4
    add eax, [con_x0]
    add eax, 8
    mov [rx], eax
    mov eax, [con_y0]
    add eax, MUS_SFXY + 16
    mov [ry], eax
    mov dword [rw], MUS_SFXW
    mov dword [rh], 22
    mov dword [rcolor], 0x00283C58
    cmp dword [hda_ok], 0
    jne .sfxcol
    mov dword [rcolor], 0x001A222E    ; greyed out -- no real sound chip to play these through
.sfxcol:
    mov dword [rrad], 4
    mov dword [rround], 3
    call fill_rrect
    mov eax, [rx]
    add eax, 6
    mov [tx], eax
    mov eax, [ry]
    add eax, 3
    mov [ty], eax
    mov dword [tcolor], C_WHITE
    cmp dword [hda_ok], 0
    jne .sfxtc
    mov dword [tcolor], 0x00566072
.sfxtc:
    mov esi, [mus_sfxl + ebx*4]
    call draw_text
    inc ebx
    jmp .sb
.sbdone:
    popad
    ret

mus_draw_grid:                   ; the note grid + the cursor bar (uses con_x0/con_y0)
    pushad
    xor edx, edx                 ; row 0 = C5 (top) ... row 12 = C4
.row:
    cmp edx, 13
    jae .rdone
    mov eax, edx
    imul eax, MUS_RH
    add eax, [con_y0]
    add eax, MUS_GY
    mov [mus_ry], eax
    ; row label
    mov eax, [con_x0]
    add eax, 4
    mov [tx], eax
    mov eax, [mus_ry]
    add eax, 1
    mov [ty], eax
    mov dword [tcolor], 0x00C9D1E0
    movzx ecx, byte [mus_black + edx]
    test ecx, ecx
    jz .lw
    mov dword [tcolor], 0x008B93A7
.lw:
    mov esi, [mus_rlbl + edx*4]
    call draw_text
    ; cells
    mov ebp, 12
    sub ebp, edx                 ; the note this row plays
    xor ecx, ecx
.col:
    cmp ecx, MUS_STEPS
    jae .cdone
    mov eax, ecx
    imul eax, MUS_CW
    add eax, [con_x0]
    add eax, MUS_GX + 1
    mov [rx], eax
    mov eax, [mus_ry]
    inc eax
    mov [ry], eax
    mov dword [rw], MUS_CW - 2
    mov dword [rh], MUS_RH - 2
    ; background: darker rows for the black keys, a lighter stripe every 4 steps
    mov dword [rcolor], 0x00202A38
    movzx eax, byte [mus_black + edx]
    test eax, eax
    jz .bg1
    mov dword [rcolor], 0x00171E29
.bg1:
    test ecx, 3
    jnz .bg2
    add dword [rcolor], 0x00060808
.bg2:
    cmp dword [mus_playing], 0
    je .np
    cmp ecx, [mus_shown]
    jne .np
    mov dword [rcolor], 0x0032486A           ; the step that's sounding now
.np:
    movzx eax, byte [mus_notes + ecx]
    cmp eax, ebp
    jne .nn
    mov dword [rcolor], 0x006FE3B4           ; a note
    cmp dword [mus_playing], 0
    je .nn
    cmp ecx, [mus_shown]
    jne .nn
    mov dword [rcolor], 0x00FFE14A           ; a note being played right now
.nn:
    call fillrect
    inc ecx
    jmp .col
.cdone:
    inc edx
    jmp .row
.rdone:
    ; cursor bar under the grid
    mov eax, [con_x0]
    add eax, MUS_GX
    mov [rx], eax
    mov eax, [con_y0]
    add eax, MUS_GY + 13*MUS_RH + 1
    mov [ry], eax
    mov dword [rw], MUS_STEPS * MUS_CW
    mov dword [rh], 4
    mov dword [rcolor], C_CONBG
    call fillrect
    mov eax, [mus_cur]
    imul eax, MUS_CW
    add eax, [con_x0]
    add eax, MUS_GX + 1
    mov [rx], eax
    mov dword [rw], MUS_CW - 2
    mov dword [rcolor], 0x00FFE14A
    call fillrect
    popad
    ret

;  "Open SONG.NTR? This replaces the tune on the grid."  [Load] [Cancel]
mus_draw_ask:
    pushad
    mov eax, [con_x0]
    add eax, 70
    mov [rx], eax
    mov eax, [con_y0]
    add eax, 80
    mov [ry], eax
    mov dword [rw], 380
    mov dword [rh], 120
    mov dword [rcolor], 0x00E6ECF2
    call fillrect
    add dword [rx], 2
    add dword [ry], 2
    mov dword [rw], 376
    mov dword [rh], 116
    mov dword [rcolor], 0x00182030
    call fillrect
    mov eax, [con_x0]
    add eax, 92
    mov [tx], eax
    mov eax, [con_y0]
    add eax, 96
    mov [ty], eax
    mov dword [tcolor], C_WHITE
    mov esi, mus_ask1
    call draw_text
    mov esi, mus_pend_name           ; NAME.EXT
    call print_83_at
    mov al, '?'
    call draw_char
    mov eax, [con_x0]
    add eax, 92
    mov [tx], eax
    add dword [ty], 22
    mov dword [tcolor], 0x008B93A7
    mov esi, mus_ask2
    call draw_text
    ; buttons
    mov eax, [con_x0]
    add eax, MUSA_LX
    mov [rx], eax
    mov eax, [con_y0]
    add eax, MUSA_BY
    mov [ry], eax
    mov dword [rw], MUSA_BW
    mov dword [rh], 24
    mov dword [rcolor], 0x00286048
    call fillrect
    mov eax, [rx]
    add eax, 18
    mov [tx], eax
    mov eax, [ry]
    add eax, 4
    mov [ty], eax
    mov dword [tcolor], C_WHITE
    mov esi, mus_l_load
    call draw_text
    mov eax, [con_x0]
    add eax, MUSA_CX
    mov [rx], eax
    mov dword [rcolor], 0x003A4658
    call fillrect
    mov eax, [rx]
    add eax, 14
    mov [tx], eax
    mov esi, mus_l_cancel
    call draw_text
    popad
    ret

; open a song file that was double-clicked: EAX = first cluster, ESI = its 8.3 name, EDX = volume
music_open_file:
    pushad
    mov [mus_pend_clus], eax
    mov [mus_pend_vol], edx
    mov edi, mus_pend_name
    mov ecx, 11
    rep movsb
    mov dword [mus_ask], 1
    mov eax, 14
    call open_window
    call recompose
    popad
    ret

music_answer:                    ; EAX = 1 load / 0 cancel
    mov dword [mus_ask], 0
    test eax, eax
    jz .no
    mov eax, [mus_pend_clus]
    mov edx, [mus_pend_vol]
    call music_load_clus
    ret
.no:
    call recompose
    ret

music_anim:                      ; redraw just the grid (the playhead moved) -- flicker-free
    pushad
    cmp byte [mouse_present], 0
    je .nc
    call restore_cursor
.nc:
    mov eax, 14
    call load_win_geom
    mov dword [cur_app], 14
    call mus_draw_grid
    cmp byte [mouse_present], 0
    je .done
    call save_cursor
    call draw_cursor
.done:
    popad
    ret

; ---------------- playing ----------------
music_start:
    pushad
    mov eax, 30000               ; one step = an eighth note: 30000 / BPM ms
    xor edx, edx
    div dword [mus_tempo]
    mov ebx, eax                 ; ms per step
    mov eax, [tsc_per_ms]
    mul ebx
    mov [mus_step_ticks], eax
    mov eax, [mus_step_ticks]
    shr eax, 2
    imul eax, 3                  ; each note sounds for 3/4 of its step (a little gap between notes)
    mov [mus_gate_ticks], eax
    mov dword [mus_step], 0
    mov dword [mus_shown], -1
    rdtsc
    mov [mus_next_t], eax
    mov dword [mus_gate], 0
    mov dword [mus_playing], 1
    popad
    ret

music_stop:
    mov dword [mus_playing], 0
    mov dword [mus_gate], 0
    mov dword [mus_shown], -1
    call spk_off
    cmp dword [hda_ok], 0
    je .r
    call hda_stop
.r:
    ret

music_tick:                      ; called on every idle turn of the main loop
    cmp dword [mus_playing], 0
    jne .go
    ret
.go:
    pushad
    cmp byte [ws_state + 14], 0  ; window closed -> stop
    jne .open
    call music_stop
    jmp .done
.open:
    rdtsc
    mov ebx, eax
    cmp dword [mus_gate], 0      ; end of this note's sound?
    je .ng
    mov eax, ebx
    sub eax, [mus_off_t]
    js .ng
    mov dword [mus_gate], 0
    cmp dword [hda_ok], 0
    je .goff_spk
    xor bx, bx
    call hda_note                ; silence the loop buffer (stream stays running)
    jmp .ng
.goff_spk:
    call spk_off
.ng:
    mov eax, ebx
    sub eax, [mus_next_t]
    js .done                     ; not time for the next step yet
    mov eax, [mus_step_ticks]
    add [mus_next_t], eax
    mov eax, ebx                 ; fell far behind (a long disk job)? start timing again from now
    sub eax, [mus_next_t]
    js .ontime
    mov [mus_next_t], ebx
    mov eax, [mus_step_ticks]
    add [mus_next_t], eax
.ontime:
    mov ecx, [mus_step]
    mov [mus_shown], ecx
    movzx eax, byte [mus_notes + ecx]
    cmp eax, 0xFF
    je .rest
    cmp dword [sound_on], 0
    je .rest
    mov bx, [mus_div + eax*2]
    cmp dword [hda_ok], 0
    je .note_spk
    call hda_note                 ; real speakers: rewrite the loop buffer, no register resets
    jmp .noted
.note_spk:
    mov al, 0xB6                 ; PIT channel 2, square wave
    out 0x43, al
    mov al, bl
    out 0x42, al
    mov al, bh
    out 0x42, al
    in al, 0x61
    or al, 3                     ; speaker on
    out 0x61, al
.noted:
    rdtsc
    add eax, [mus_gate_ticks]
    mov [mus_off_t], eax
    mov dword [mus_gate], 1
    jmp .adv
.rest:
    cmp dword [hda_ok], 0
    je .rest_spk
    xor bx, bx
    call hda_note
    jmp .rested
.rest_spk:
    call spk_off
.rested:
    mov dword [mus_gate], 0
.adv:
    mov eax, [mus_step]
    inc eax
    and eax, MUS_STEPS - 1
    mov [mus_step], eax
    cmp dword [focus], 14        ; show the playhead when she's looking at it
    jne .done
    call music_anim
.done:
    popad
    ret

; ---------------- mouse ----------------
music_click:                     ; (con_* already set for window 14)
    pushad
    mov eax, [mouse_x]
    sub eax, [con_x0]
    mov ebx, [mouse_y]
    sub ebx, [con_y0]
    cmp dword [mus_ask], 0
    je .noask
    cmp ebx, MUSA_BY
    jl .done
    cmp ebx, MUSA_BY + 24
    jg .done
    cmp eax, MUSA_LX
    jl .done
    cmp eax, MUSA_LX + MUSA_BW
    jl .askload
    cmp eax, MUSA_CX
    jl .done
    cmp eax, MUSA_CX + MUSA_BW
    jg .done
    xor eax, eax
    call music_answer
    jmp .done
.askload:
    mov eax, 1
    call music_answer
    jmp .done
.noask:
    cmp ebx, 2                   ; the button row?
    jl .done
    cmp ebx, 24
    jg .checksfx
    xor ecx, ecx
.bl:
    cmp ecx, 6
    jae .done
    mov edx, [mus_bx + ecx*4]
    cmp eax, edx
    jl .bn
    add edx, [mus_bw + ecx*4]
    cmp eax, edx
    jge .bn
    call music_button
    jmp .done
.bn:
    inc ecx
    jmp .bl
.checksfx:
    cmp ebx, MUS_SFXY + 16
    jl .grid
    cmp ebx, MUS_SFXY + 38
    jge .grid
    sub eax, 8
    js .grid
    xor edx, edx
    mov ecx, MUS_SFXW + 4
    div ecx
    cmp eax, NSFX
    jae .done
    call hda_play_sfx
    jmp .done
.grid:
    sub eax, MUS_GX
    js .done
    sub ebx, MUS_GY
    js .done
    xor edx, edx
    mov ecx, MUS_CW
    div ecx
    cmp eax, MUS_STEPS
    jae .done
    mov esi, eax                 ; column
    mov eax, ebx
    xor edx, edx
    mov ecx, MUS_RH
    div ecx
    cmp eax, 13
    jae .done
    mov ebx, 12
    sub ebx, eax                 ; note
    mov [mus_cur], esi
    movzx eax, byte [mus_notes + esi]
    cmp eax, ebx
    jne .set
    mov byte [mus_notes + esi], 0xFF          ; click the same note again = remove it
    jmp .redraw
.set:
    mov [mus_notes + esi], bl
    cmp dword [mus_playing], 0
    jne .redraw
    mov eax, ebx
    call mus_preview
.redraw:
    call recompose
.done:
    popad
    ret

music_button:                    ; ECX = which button
    cmp ecx, 0
    jne .n1
    cmp dword [mus_playing], 0
    je .play
    call music_stop
    jmp .rc
.play:
    call music_start
    jmp .rc
.n1:
    cmp ecx, 1
    jne .n2
    push edi
    mov edi, mus_notes
    mov ecx, MUS_STEPS
    mov al, 0xFF
    rep stosb
    pop edi
    mov dword [mus_cur], 0
    jmp .rc
.n2:
    cmp ecx, 2
    jne .n3
    call music_save
    ret
.n3:
    cmp ecx, 3
    jne .n4
    call music_load
    ret
.n4:
    cmp ecx, 4                   ; tempo -
    jne .n5
    cmp dword [mus_tempo], 60
    jle .rc
    sub dword [mus_tempo], 10
    jmp .tempo
.n5:
    cmp dword [mus_tempo], 240   ; tempo +
    jge .rc
    add dword [mus_tempo], 10
.tempo:
    cmp dword [mus_playing], 0
    je .rc
    call music_start             ; new speed right away
.rc:
    call recompose
    ret

mus_preview:                     ; EAX = note: a short beep so you hear what you placed
    pushad
    mov bx, [mus_div + eax*2]
    cmp dword [hda_ok], 0
    je .spk
    mov eax, [hda_volume]
    call hda_beep
    jmp .done
.spk:
    call play_note
.done:
    popad
    ret

; ---------------- keyboard ----------------
handle_music_scancode:           ; AL = scancode
    test al, 0x80                ; key released
    jnz .r
    cmp dword [mus_ask], 0       ; the "open this song?" box: Enter = Load, Esc = Cancel
    je .noask
    cmp al, 0x1C
    je .yes
    cmp al, 0x01
    jne .r
    xor eax, eax
    call music_answer
    ret
.yes:
    mov eax, 1
    call music_answer
    ret
.noask:
    cmp al, 0xE0
    je .r
    cmp al, 0x4B                 ; left
    jne .k1
    mov eax, [mus_cur]
    add eax, MUS_STEPS - 1
    and eax, MUS_STEPS - 1
    mov [mus_cur], eax
    jmp .redraw
.k1:
    cmp al, 0x4D                 ; right
    jne .k2
    mov eax, [mus_cur]
    inc eax
    and eax, MUS_STEPS - 1
    mov [mus_cur], eax
    jmp .redraw
.k2:
    cmp al, 0x39                 ; Space: play / stop
    jne .k3
    xor ecx, ecx
    call music_button
    ret
.k3:
    cmp al, 0x0E                 ; Backspace
    je .clear
    cmp al, 0x53                 ; Delete
    jne .k4
.clear:
    mov eax, [mus_cur]
    mov byte [mus_notes + eax], 0xFF
    jmp .redraw
.k4:
    mov esi, mus_keymap          ; a piano key?
.km:
    mov ah, [esi]
    test ah, ah
    jz .r
    cmp ah, al
    je .note
    add esi, 2
    jmp .km
.note:
    movzx eax, byte [esi + 1]
    mov ecx, [mus_cur]
    mov [mus_notes + ecx], al
    inc ecx
    and ecx, MUS_STEPS - 1
    mov [mus_cur], ecx
    cmp dword [mus_playing], 0
    jne .redraw
    call mus_preview
.redraw:
    call recompose
.r:
    ret

; ---------------- saving (SONG.NTR, a little text file) ----------------
music_save:
    pushad
    push dword [mus_playing]         ; pause while the disk works (a note left sounding would drone on)
    cmp dword [mus_playing], 0
    je .q0
    call music_stop
.q0:
    call mus_save_inner
    pop eax
    test eax, eax
    jz .q1
    call music_start
    call recompose
.q1:
    popad
    ret

mus_save_inner:
    pushad
    cmp dword [install_mode], 0
    jne .fs
    call long_beep
    mov esi, nt_nosave1
    mov edi, nt_nosave2
    call notify
    call recompose
    jmp .done
.fs:
    ; tempo as 3 digits
    mov eax, [mus_tempo]
    xor edx, edx
    mov ecx, 100
    div ecx
    add al, '0'
    mov [mus_file + MUSF_TEMPO], al
    mov eax, edx
    xor edx, edx
    mov ecx, 10
    div ecx
    add al, '0'
    mov [mus_file + MUSF_TEMPO + 1], al
    add dl, '0'
    mov [mus_file + MUSF_TEMPO + 2], dl
    ; the notes: '.' = rest, 'a'..'m' = C4..C5
    xor ecx, ecx
.nl:
    cmp ecx, MUS_STEPS
    jae .ndone
    movzx eax, byte [mus_notes + ecx]
    mov bl, '.'
    cmp eax, 0xFF
    je .ns
    lea ebx, [eax + 'a']
.ns:
    mov [mus_file + MUSF_NOTES + ecx], bl
    inc ecx
    jmp .nl
.ndone:
    push dword [save_dir]
    push dword [wf_attr]
    call fat_mount               ; the system disk
    mov eax, [fs_rootclus]
    mov [save_dir], eax          ; into the top folder (it shows on the desktop too)
    mov dword [wf_attr], 0x20
    mov esi, mus_name83
    mov edi, name83
    mov ecx, 11
    rep movsb
    mov esi, mus_file
    mov ecx, MUSF_LEN
    call fat_write_file
    pop dword [wf_attr]
    pop dword [save_dir]
    test al, al
    jnz .err
    mov dword [files_dirty], 1
    mov dword [desk_dirty], 1
    mov esi, nt_mus_saved1
    mov edi, nt_mus_saved2
    call notify
    call recompose
    jmp .done
.err:
    call err_beep
    mov esi, nt_werr1
    mov edi, nt_werr2
    call notify
    call recompose
.done:
    popad
    ret

music_load:                      ; the Load button: SONG.NTR from the top folder of the disk
    pushad
    cmp dword [install_mode], 0
    je .none
    call fat_mount
    test al, al
    jnz .none
    mov esi, mus_name83
    mov edi, name83
    mov ecx, 11
    rep movsb
    mov eax, [fs_rootclus]
    call clus_to_sector
    mov [mus_sec], eax
    mov dword [mus_si], 0
.sec:
    mov eax, [mus_si]
    cmp eax, [fs_spc]
    jae .none
    mov eax, [mus_sec]
    add eax, [mus_si]
    mov edi, FSDIR
    call fs_read_sector
    xor ebx, ebx
.ent:
    cmp ebx, 16
    jae .nsec
    mov eax, ebx
    shl eax, 5
    lea esi, [FSDIR + eax]
    cmp byte [esi], 0            ; end of the folder
    je .none
    cmp byte [esi], 0xE5         ; deleted entry
    je .nent
    call cmp83
    jne .nent
    movzx eax, word [esi + 20]   ; found it: first cluster
    shl eax, 16
    mov ax, [esi + 26]
    xor edx, edx                 ; on the system disk
    call music_load_clus
    popad
    ret
.nent:
    inc ebx
    jmp .ent
.nsec:
    inc dword [mus_si]
    jmp .sec
.none:
    call err_beep
    mov esi, nt_mus_none1
    mov edi, nt_mus_none2
    call notify
    call recompose
    popad
    ret

music_load_clus:                 ; EAX = the song file's first cluster, EDX = volume (0 disk, 1 USB stick)
    pushad
    mov [mus_lclus], eax
    push dword [mus_playing]
    cmp dword [mus_playing], 0
    je .q0
    call music_stop
.q0:
    mov [vol], edx
    call fat_mount
    mov eax, [mus_lclus]
    call clus_to_sector
    mov edi, FSDIR
    call fs_read_sector
    mov esi, FSDIR                ; keep a copy: mounting the disk again reuses that buffer
    mov edi, mus_buf
    mov ecx, 64
    cld
    rep movsb
    mov dword [vol], 0           ; back to the system disk for everything else
    call fat_mount
    ; check it's a song and read it
    mov esi, mus_buf
    mov edi, mus_file
    mov ecx, 10
    cld
    repe cmpsb
    jne .bad
    movzx eax, byte [mus_buf + MUSF_TEMPO]
    sub eax, '0'
    imul eax, 100
    mov ecx, eax
    movzx eax, byte [mus_buf + MUSF_TEMPO + 1]
    sub eax, '0'
    imul eax, 10
    add ecx, eax
    movzx eax, byte [mus_buf + MUSF_TEMPO + 2]
    sub eax, '0'
    add ecx, eax
    cmp ecx, 60
    jl .bad
    cmp ecx, 240
    jg .bad
    mov [mus_tempo], ecx
    xor ecx, ecx
.rn:
    cmp ecx, MUS_STEPS
    jae .loaded
    movzx eax, byte [mus_buf + MUSF_NOTES + ecx]
    sub eax, 'a'
    cmp eax, 12
    jbe .okn
    mov eax, 0xFF
.okn:
    mov [mus_notes + ecx], al
    inc ecx
    jmp .rn
.loaded:
    mov dword [mus_cur], 0
    pop eax
    test eax, eax
    jz .lq
    call music_start
.lq:
    mov esi, nt_mus_load1
    mov edi, nt_mus_load2
    call notify
    call recompose
    popad
    ret
.bad:
    pop eax
    call err_beep
    mov esi, nt_mus_bad1
    mov edi, nt_mus_bad2
    call notify
    call recompose
    popad
    ret

mus_quiet:                       ; before a long disk job: never leave a note droning on
    cmp dword [mus_gate], 0
    je .r
    mov dword [mus_gate], 0
    call spk_off
.r:
    ret

; ---------------- data ----------------
mus_playing:    dd 0
mus_tempo:      dd 120
mus_step:       dd 0
mus_shown:      dd -1
mus_cur:        dd 0
mus_next_t:     dd 0
mus_off_t:      dd 0
mus_gate:       dd 0
mus_step_ticks: dd 0
mus_gate_ticks: dd 0
mus_ry:         dd 0
mus_sec:        dd 0
mus_si:         dd 0
mus_lclus:      dd 0
mus_buf:        times 64 db 0
mus_ask:        dd 0
mus_pend_clus:  dd 0
mus_pend_vol:   dd 0
mus_pend_name:  times 11 db ' '
MUSA_BY equ 160                  ; the "open this song?" box buttons (relative to the window content)
MUSA_LX equ 150
MUSA_CX equ 270
MUSA_BW equ 96
; a little tune to start with ("Twinkle"-ish opening), 0xFF = rest
mus_notes:      db 0, 0xFF, 0, 0xFF, 7, 0xFF, 7, 0xFF, 9, 0xFF, 9, 0xFF, 7, 0xFF, 0xFF, 0xFF
; PIT divisors for C4 .. C5 (1193182 / frequency)
mus_div:        dw 4561, 4305, 4063, 3835, 3620, 3417, 3225, 3044, 2873, 2712, 2560, 2416, 2280
mus_black:      db 0, 0, 1, 0, 1, 0, 1, 0, 0, 1, 0, 1, 0      ; per row, top (C5) to bottom (C4)
mus_rlbl:       dd mr0, mr1, mr2, mr3, mr4, mr5, mr6, mr7, mr8, mr9, mr10, mr11, mr12
mr0:  db "C5", 0
mr1:  db "B4", 0
mr2:  db "A#4", 0
mr3:  db "A4", 0
mr4:  db "G#4", 0
mr5:  db "G4", 0
mr6:  db "F#4", 0
mr7:  db "F4", 0
mr8:  db "E4", 0
mr9:  db "D#4", 0
mr10: db "D4", 0
mr11: db "C#4", 0
mr12: db "C4", 0
mus_bx:  dd 0, 66, 132, 198, 360, 390
mus_bw:  dd 60, 60, 60, 60, 26, 26
mus_bl:  dd mus_l_play, mus_l_clear, mus_l_save, mus_l_load, mus_l_minus, mus_l_plus
mus_l_play:  db "Play", 0
mus_l_stop:  db "Stop", 0
mus_l_clear: db "Clear", 0
mus_l_save:  db "Save", 0
mus_l_load:  db "Load", 0
mus_l_minus: db "-", 0
mus_l_plus:  db "+", 0
mus_l_tempo: db "Tempo", 0
mus_help1:   db "Keys: A S D F G H J K = C D E F G A B C   W E T Y U = sharps", 0
mus_help2:   db "Arrows move   Space play/stop   Backspace clears a step", 0
MUS_SFXY equ 307                 ; SFX row, relative to con_y0
MUS_SFXW equ 54
mus_l_sfx: db "SFX:", 0
mus_sfxl:  dd mus_l_laser, mus_l_coin, mus_l_boing, mus_l_pop, mus_l_kick, mus_l_chime
mus_l_laser: db "Laser", 0
mus_l_coin:  db "Coin", 0
mus_l_boing: db "Boing", 0
mus_l_pop:   db "Pop", 0
mus_l_kick:  db "Kick", 0
mus_l_chime: db "Chime", 0
; scancode -> note
mus_keymap:  db 0x1E,0, 0x11,1, 0x1F,2, 0x12,3, 0x20,4, 0x21,5, 0x14,6, 0x22,7, 0x15,8, 0x23,9, 0x16,10, 0x24,11, 0x25,12, 0
mus_name83:  db "SONG    NTR"
; the song file: "NOVA MUSIC FILE" / "TEMPO 120" / "NOTES a.a.h.h.j.j.h..."
mus_file:    db "NOVA MUSIC FILE", 13, 10
MUSF_TEMPO equ $ - mus_file + 6
             db "TEMPO 120", 13, 10
MUSF_NOTES equ $ - mus_file + 6
             db "NOTES ................", 13, 10
MUSF_LEN   equ $ - mus_file
nt_mus_saved1: db "Song saved", 0
nt_mus_saved2: db "SONG.NTR on the desktop", 0
nt_mus_load1:  db "Song loaded", 0
nt_mus_load2:  db "Press Play to hear it", 0
nt_mus_bad1:   db "Not a Music Maker song", 0
nt_mus_bad2:   db "It can't be opened here", 0
mus_ask1:      db "Open ", 0
mus_ask2:      db "This replaces the tune on the grid.", 0
mus_l_cancel:  db "Cancel", 0
nt_mus_none1:  db "No song saved yet", 0
nt_mus_none2:  db "Press Save first", 0
