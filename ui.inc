; ============================================================
;  NovaOS  --  modern drawing helpers (rounded rectangles, circles, app icons)
; ============================================================

; rounded rectangle: [rx],[ry],[rw],[rh],[rcolor], [rrad] = 4/6/8, [rround] bits: 1 = round the top, 2 = the bottom
fill_rrect:
    pushad
    mov esi, rr_t0
    mov ebp, 0
    mov eax, [rrad]
    cmp eax, 4
    jne .r6
    mov esi, rr_t4
    mov ebp, 4
.r6:
    cmp eax, 6
    jne .r8
    mov esi, rr_t6
    mov ebp, 6
.r8:
    cmp eax, 8
    jne .go
    mov esi, rr_t8
    mov ebp, 8
.go:
    push dword [rx]
    push dword [ry]
    push dword [rw]
    push dword [rh]
    mov eax, [rx]
    mov [rr_x], eax
    mov eax, [ry]
    mov [rr_y], eax
    mov eax, [rw]
    mov [rr_w], eax
    mov ecx, [rh]
    mov [rr_h], ecx
    xor edx, edx                 ; row
.row:
    cmp edx, [rr_h]
    jae .done
    xor ebx, ebx                 ; inset for this row
    test dword [rround], 1
    jz .nt
    cmp edx, ebp
    jae .nt
    movzx ebx, byte [esi + edx]
.nt:
    test dword [rround], 2
    jz .nb
    mov eax, [rr_h]
    sub eax, edx
    dec eax                      ; rows from the bottom
    cmp eax, ebp
    jae .nb
    movzx eax, byte [esi + eax]
    cmp eax, ebx
    jbe .nb
    mov ebx, eax
.nb:
    mov eax, [rr_x]
    add eax, ebx
    mov [rx], eax
    mov eax, [rr_y]
    add eax, edx
    mov [ry], eax
    mov eax, [rr_w]
    sub eax, ebx
    sub eax, ebx
    jle .skip
    mov [rw], eax
    mov dword [rh], 1
    call fillrect
.skip:
    inc edx
    jmp .row
.done:
    pop dword [rh]
    pop dword [rw]
    pop dword [ry]
    pop dword [rx]
    popad
    ret

; filled circle: [ccx],[ccy] centre, [ccr] radius, [rcolor]
fill_circle:
    pushad
    push dword [rx]
    push dword [ry]
    push dword [rw]
    push dword [rh]
    mov ecx, [ccr]
    mov edi, ecx
    imul edi, ecx
    add edi, ecx                 ; r*r + r  (rounder edge)
    mov edx, ecx
    neg edx                      ; dy from -r to r
.row:
    cmp edx, ecx
    jg .done
    mov eax, edx
    imul eax, edx
    mov ebx, ecx                 ; half-width: largest h with h*h + dy*dy <= r*r + r
.h:
    mov esi, ebx
    imul esi, ebx
    add esi, eax
    cmp esi, edi
    jle .hok
    dec ebx
    jns .h
    jmp .nextrow
.hok:
    mov eax, [ccx]
    sub eax, ebx
    mov [rx], eax
    mov eax, [ccy]
    add eax, edx
    mov [ry], eax
    lea eax, [ebx*2 + 1]
    mov [rw], eax
    mov dword [rh], 1
    call fillrect
.nextrow:
    inc edx
    jmp .row
.done:
    pop dword [rh]
    pop dword [rw]
    pop dword [ry]
    pop dword [rx]
    popad
    ret

; a little app icon: EAX = app id, at [rx],[ry] (18x18): a coloured rounded tile with the app's letter
draw_app_icon:
    pushad
    mov ebx, eax
    mov dword [rw], 18
    mov dword [rh], 18
    mov eax, [app_color + ebx*4]
    mov [rcolor], eax
    mov dword [rrad], 4
    mov dword [rround], 3
    call fill_rrect
    mov eax, [rx]
    add eax, 5
    mov [tx], eax
    mov eax, [ry]
    add eax, 1
    mov [ty], eax
    mov dword [tcolor], 0x00FFFFFF
    mov al, [app_letter + ebx]
    call draw_char
    popad
    ret

rr_t0:  db 0, 0, 0, 0, 0, 0, 0, 0
rr_t4:  db 2, 1, 0, 0
rr_t6:  db 4, 2, 1, 1, 0, 0
rr_t8:  db 5, 3, 2, 1, 1, 0, 0, 0
rrad:   dd 0
rround: dd 3
rr_x:   dd 0
rr_y:   dd 0
rr_w:   dd 0
rr_h:   dd 0
ccx:    dd 0
ccy:    dd 0
ccr:    dd 0
;            Term      Calc      Clock     SysInfo   About     Editor    Browser   Paint
app_color: dd 0x00334155, 0x00E08A1E, 0x002F7FD8, 0x0056657A, 0x005B5BD6, 0x00119F75, 0x000C8FC7, 0x00D9468F
;            Files     Settings  Bounce    Saver     Sound     Snake     Music     DevMgr    TaskMgr   Admin
           dd 0x00C99A0E, 0x00606B7B, 0x00E4682A, 0x00138F86, 0x009A4FE0, 0x001FA64F, 0x00C43BD6, 0x005D6D7E, 0x00E67E22, 0x00B94A48
app_letter: db ">", "=", "O", "i", "N", "T", "W", "P", "F", "*", "B", "S", "~", "s", "M", "D", "K", "A"
