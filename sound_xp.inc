; ============================================================
;  NovaOS  --  XP-style startup chime (an ORIGINAL melody, not Microsoft's)
;  (included into kernel_vesa.asm)
;
;  PC speaker = one square-wave tone at a time, so the "chord" at the end
;  is a fast arpeggio (notes swapped every ~18 ms) that blends into a shimmer.
;  Timing uses the CPU time-stamp counter, calibrated once against the PIT,
;  so the chime plays at the same speed on every computer.
; ============================================================

tsc_calibrate:                   ; measure TSC ticks per millisecond (call once at boot)
    pushad
    rdtsc
    mov [tsc_a], eax
    mov [tsc_a+4], edx
    mov ecx, 50
    call pit_wait_ms
    rdtsc
    sub eax, [tsc_a]
    sbb edx, [tsc_a+4]
    mov ecx, 50
    cmp edx, ecx                 ; would overflow the divide? (absurdly fast) -> keep default
    jae .bad
    div ecx
    cmp eax, 1000                ; sanity: at least ~1 MHz
    jb .bad
    mov [tsc_per_ms], eax
.bad:
    popad
    ret

tsc_wait_ms:                     ; ECX = milliseconds (does not touch the PIT)
    pushad
.ms:
    test ecx, ecx
    jz .done
    rdtsc
    mov ebx, eax
.w:
    rdtsc
    sub eax, ebx
    cmp eax, [tsc_per_ms]
    jb .w
    dec ecx
    jmp .ms
.done:
    popad
    ret

tone_ms:                         ; BX = PIT divisor, ECX = ms.  Leaves the speaker ON (legato)
    pushad
    mov al, 0xB6                 ; PIT channel 2, square wave
    out 0x43, al
    mov al, bl
    out 0x42, al
    mov al, bh
    out 0x42, al
    in al, 0x61
    or al, 3                     ; speaker on
    out 0x61, al
    call tsc_wait_ms
    popad
    ret

spk_off:
    push eax
    in al, 0x61
    and al, 0xFC
    out 0x61, al
    pop eax
    ret

; ESI = list of divisors (word, 0-terminated), ECX = total ms, EDX = ms per note
shimmer:
    pushad
    mov [sh_left], ecx
    mov [sh_step], edx
    mov [sh_list], esi
.again:
    mov esi, [sh_list]
.n:
    cmp dword [sh_left], 0
    jle .done
    movzx ebx, word [esi]
    test ebx, ebx
    jz .again
    mov ecx, [sh_step]
    call tone_ms
    mov eax, [sh_step]
    sub [sh_left], eax
    add esi, 2
    jmp .n
.done:
    popad
    ret

; warm rise -> held note -> shimmering chord -> soft high "sparkle" -> settle
play_startup_xp:
    cmp dword [sound_on], 0
    je .muted
    pushad
    mov esi, xp_rise
.r:
    movzx ebx, word [esi]
    test ebx, ebx
    jz .rise_done
    movzx ecx, word [esi+2]
    call tone_ms
    add esi, 4
    jmp .r
.rise_done:
    mov esi, xp_chord            ; big shimmering Eb-major chord
    mov ecx, 1150
    mov edx, 18
    call shimmer
    mov esi, xp_sparkle          ; bright top notes, slower = the "ring-out"
    mov ecx, 420
    mov edx, 35
    call shimmer
    mov bx, 1917                 ; settle on a low Eb
    mov ecx, 380
    call tone_ms
    call spk_off
    popad
.muted:
    ret

tsc_a:       dd 0, 0
tsc_per_ms:  dd 2000000          ; default (~2 GHz) until calibrated
sh_left:     dd 0
sh_step:     dd 0
sh_list:     dd 0
; divisors = 1193182 / Hz.   (note, ms)
xp_rise:     dw 2873, 170        ; Ab4
             dw 1917, 170        ; Eb5
             dw 1436, 170        ; Ab5
             dw 1522, 320        ; G5  (held)
             dw 0
xp_chord:    dw 1917, 1522, 1280, 0      ; Eb5  G5  Bb5
xp_sparkle:  dw 959, 1016, 1280, 0       ; Eb6  D6  Bb5
