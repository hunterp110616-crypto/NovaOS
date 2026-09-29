; ============================================================
;  NovaOS  --  Intel HD Audio driver
;  Real sound through real speakers, instead of the PC-speaker beeper.
;  If this computer doesn't have an HD Audio chip (older boards used
;  AC'97 instead), hda_ok stays 0 and everything falls back to the beeper.
;
;  Talks to the codec through the Immediate Command interface (IC/IR/IRS at
;  MMIO+0x60/64/68) -- simpler than the CORB/RIRB command rings, and plenty
;  for the modest number of verbs discovery + setup need.
; ============================================================

HDAMEM     equ 0x00C00000
HDA_BDL    equ HDAMEM             ; buffer descriptor list (128-byte aligned)
HDA_SBUF   equ HDAMEM + 0x4000    ; the startup clip, converted to 16-bit stereo (room for ~1 MB)
HDA_NBUF   equ HDAMEM + 0x100000  ; a short looping tone buffer, for Music Maker (room for 64 KB)
HDA_LOG    equ HDAMEM + 0x110000  ; a little diagnostic log: {cmd, response} x 64
SFX_BUF    equ HDAMEM + 0x120000  ; Music Maker's SFX bank, loaded raw from disk at boot (~37 KB)

hda_ok:      dd 0
hda_bar:     dd 0                 ; MMIO base
hda_cad:     dd 0                 ; codec address that answered
hda_afg:     dd 0                 ; the audio function group's NID
hda_pin:     dd 0                 ; the output pin we chose
hda_dac:     dd 0                 ; the DAC feeding it
hda_sd:      dd 0                 ; our output stream's register base (MMIO offset)
hda_log_n:   dd 0

; where hda_ok stayed 0, so the About panel can say WHY instead of just "not found":
; 0 = no class-0x0403 PCI device on ANY bus (0-255)
; 1 = found one, but its BAR0 (MMIO) was unassigned
; 2 = hda_reset timed out (controller didn't come out of reset)
; 3 = hda_find_codec found no codec on the link
; 4 = hda_topology found no usable output pin/DAC
hda_diag_stage: dd 0
hda_diag_class: dd 0xFFFFFFFF     ; class/subclass/progif of the first non-HDA multimedia (0x04xxxx) device seen, if any
hda_diag_bus:   dd 0xFFFFFFFF     ; which PCI bus that other device was on

hda_volume: dd 80                 ; master volume, 0-100 -- Settings' volume row changes this

; ---------------- startup: find the controller, wake it up ----------------
hda_init:
    pushad
    xor esi, esi                     ; bus/dev/fn cursor -- sweeps ALL 256 buses (some boards
                                      ; route onboard audio through a bridge, off bus 0)
.scan:
    cmp esi, 256*32*8
    jae .none
    mov eax, esi
    shl eax, 8
    mov [u_pa], eax                  ; reuse usb.inc's PCI cursor var (usb_init runs later, on demand)
    call pci_rd
    cmp ax, 0xFFFF
    je .next
    mov eax, [u_pa]
    add eax, 0x08
    call pci_rd
    shr eax, 8
    cmp eax, 0x040300                ; class 04 (multimedia) / subclass 03 (HD Audio)
    je .found
    cmp eax, 0x040000                ; some other multimedia device (e.g. AC'97 = 0x040100)?
    jb .next
    cmp eax, 0x050000
    jae .next
    cmp dword [hda_diag_class], 0xFFFFFFFF
    jne .next                        ; remember only the first one
    mov [hda_diag_class], eax
    mov eax, esi
    shr eax, 8                       ; which bus it was on
    mov [hda_diag_bus], eax
.next:
    inc esi
    jmp .scan
.none:
    popad
    ret
.found:
    mov eax, [u_pa]
    add eax, 0x10                    ; BAR0 = MMIO
    call pci_rd
    and eax, 0xFFFFFFF0
    jnz .barok
    call hda_assign_bar              ; the BIOS left it unassigned -- claim an address ourselves
    jc .nobar
    mov eax, [u_pa]
    add eax, 0x10
    call pci_rd
    and eax, 0xFFFFFFF0
    jnz .barok
.nobar:
    mov dword [hda_diag_stage], 1
    jmp .none
.barok:
    mov [hda_bar], eax
    mov eax, [u_pa]                  ; enable memory space + bus mastering
    add eax, 0x04
    call pci_rd
    or eax, 0x06
    mov ebx, eax
    mov eax, [u_pa]
    add eax, 0x04
    call pci_wr
    mov eax, [u_pa]                  ; TCSEL: route to the non-snoop traffic class (some boards need this)
    add eax, 0x44
    call pci_rd
    and eax, 0xFFFFFFF8
    mov ebx, eax
    mov eax, [u_pa]
    add eax, 0x44
    call pci_wr
    call hda_reset
    jnc .rok
    mov dword [hda_diag_stage], 2
    jmp .none
.rok:
    call hda_find_codec
    jnc .cok
    mov dword [hda_diag_stage], 3
    jmp .none
.cok:
    call hda_topology
    jnc .tok
    mov dword [hda_diag_stage], 4
    jmp .none
.tok:
    call hda_configure
    mov dword [hda_ok], 1
    popad
    ret

; some BIOSes enumerate the HDA controller but never assign its BAR0 (leave it at 0),
; expecting whoever boots to hand it an MMIO address itself. Probe the BAR's size the
; standard PCI way (write all-1s, read back the mask) and place it in the conventional
; sub-4GB MMIO hole that real chipsets/BIOSes use for exactly this -- comfortably above
; any RAM this class of machine will have, and below the fixed APIC/IOAPIC region.
; CF=1 if the BAR didn't look like a real, sizeable memory BAR.
HDA_MMIO_BASE equ 0xFA000000
hda_assign_bar:
    push ebx
    push ecx
    push edx
    mov eax, [u_pa]
    add eax, 0x10
    mov ebx, 0xFFFFFFFF
    call pci_wr                       ; probe: ask the BAR how big it is
    call pci_rd
    and eax, 0xFFFFFFF0
    jz .bad                           ; 0 back = not a real 32-bit memory BAR
    not eax
    inc eax                           ; eax = BAR size (a power of two)
    dec eax
    mov ecx, eax                      ; ecx = size - 1 (alignment mask)
    mov eax, HDA_MMIO_BASE
    add eax, ecx
    not ecx
    and eax, ecx                      ; round up to a size-aligned address
    mov edx, eax                      ; the address we're choosing
    mov ebx, eax
    mov eax, [u_pa]
    add eax, 0x10
    call pci_wr                       ; commit it
    mov eax, edx
    clc
    jmp .done
.bad:
    stc
.done:
    pop edx
    pop ecx
    pop ebx
    ret

; controller reset: CRST 0 -> 1, then wait for codecs to announce themselves
hda_reset:
    mov esi, [hda_bar]
    mov dword [esi + 0x08], 0         ; GCTL.CRST = 0 (assert reset)
    mov ecx, 10
    call tsc_wait_ms
    mov dword [esi + 0x08], 1         ; CRST = 1 (release reset; hardware brings the link up)
    mov ecx, 100
.w:
    test dword [esi + 0x08], 1
    jnz .up
    push ecx
    mov ecx, 1
    call tsc_wait_ms
    pop ecx
    dec ecx
    jnz .w
    stc
    ret
.up:
    mov ecx, 10                       ; let STATESTS settle (codecs pulse it once, ~521 us min per spec)
    call tsc_wait_ms
    movzx eax, word [esi + 0x0E]
    mov [hda_statests], eax
    clc
    ret
hda_statests: dd 0

; send one verb, wait for the matching response.  EAX = NID, EBX = verb (pre-shifted,
; e.g. 0xF00), ECX = payload -> EAX = response, CF = 1 on timeout
hda_verb:
    push ebx
    push ecx
    push edx
    push esi
    push edi
    mov edx, eax
    shl edx, 20                       ; NID
    mov eax, [hda_cad]
    shl eax, 28
    or edx, eax
    shl ebx, 8
    or edx, ebx
    or edx, ecx                       ; EDX = full 32-bit command
    mov esi, [hda_bar]
    mov word [esi + 0x68], 0x0002     ; IRS: clear IRV (write-1-to-clear) before we start
    mov dword [esi + 0x60], edx       ; IC: the command
    mov word [esi + 0x68], 0x0001     ; IRS: ICB = 1 -> go
    mov ecx, 500
.wait:
    movzx eax, word [esi + 0x68]
    test eax, 0x0002                  ; IRV: response ready?
    jnz .got
    push ecx
    mov ecx, 1
    call tsc_wait_ms
    pop ecx
    dec ecx
    jnz .wait
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    stc
    ret
.got:
    mov eax, [esi + 0x64]             ; IR: the response
    mov word [esi + 0x68], 0x0002     ; IRS: clear IRV, ready for the next one
    push eax
    mov edi, [hda_log_n]              ; a little log, handy for troubleshooting on real hardware
    cmp edi, 64
    jae .nolog
    mov ebx, HDA_LOG
    mov ecx, edi
    imul ecx, 12
    add ebx, ecx
    pop eax
    push eax
    mov [ebx], edx
    mov [ebx + 4], eax
    inc dword [hda_log_n]
.nolog:
    pop eax
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    clc
    ret

; find the first codec that answers and locate its audio function group
hda_find_codec:
    pushad
    mov eax, [hda_statests]           ; which codec address(es) answered (captured right after reset)
    test eax, eax
    jz .none
    xor ecx, ecx
.f:
    bt eax, ecx
    jc .have
    inc ecx
    cmp ecx, 15
    jb .f
    jmp .none
.have:
    mov [hda_cad], ecx
    xor eax, eax                      ; NID 0 = root; Get Parameter, Node Count
    mov ebx, 0xF00
    mov ecx, 0x04
    call hda_verb
    jc .none
    movzx ebx, al                     ; number of function groups
    shr eax, 16
    movzx esi, al                     ; first function-group NID
    xor edi, edi
.fg:
    cmp edi, ebx
    jae .none
    mov eax, esi
    push ebx
    mov ebx, 0xF00
    mov ecx, 0x05                     ; Function Group Type
    call hda_verb
    pop ebx
    jc .none
    and eax, 0xFF
    cmp eax, 1                        ; 1 = Audio Function Group
    je .isafg
    inc esi
    inc edi
    jmp .fg
.isafg:
    mov [hda_afg], esi
    popad
    clc
    ret
.none:
    popad
    stc
    ret

; walk the AFG's widgets: find an output pin (speaker / line-out / HP-out) that's
; really connected, and the DAC feeding it (following at most 2 hops)
hda_topology:
    pushad
    mov eax, [hda_afg]
    mov ebx, 0xF00
    mov ecx, 0x04                     ; Node Count -> the AFG's widgets
    call hda_verb
    jc .none
    movzx ebx, al                     ; widget count
    shr eax, 16
    movzx esi, al                     ; first widget NID
    mov dword [hda_pin], 0
    xor edi, edi
.w:
    cmp edi, ebx
    jae .picked
    mov eax, esi
    push ebx
    mov ebx, 0xF00
    mov ecx, 0x09                     ; Audio Widget Capabilities
    call hda_verb
    pop ebx
    jc .none
    shr eax, 20
    and eax, 0xF                      ; widget type: 4 = Pin Complex
    cmp eax, 4
    jne .wn
    mov eax, esi                      ; a pin: is it wired to a real output?
    push ebx
    mov ebx, 0xF00
    mov ecx, 0x0C                     ; Pin Capabilities
    call hda_verb
    pop ebx
    jc .none
    test eax, 0x10                    ; bit4 = output-capable
    jz .wn
    mov eax, esi
    push ebx
    mov ebx, 0xF1C
    xor ecx, ecx                      ; Get Configuration Default
    call hda_verb
    pop ebx
    jc .none
    mov ebx, eax
    shr ebx, 30                       ; port connectivity: 1 = "no physical connection" -> skip
    cmp ebx, 1
    je .wn
    mov ebx, eax
    shr ebx, 20
    and ebx, 0xF                      ; default device: 0 line-out, 1 speaker, 2 HP-out
    cmp ebx, 0
    je .goodpin
    cmp ebx, 1
    je .goodpin
    cmp ebx, 2
    je .goodpin
    jmp .wn
.goodpin:
    mov [hda_pin], esi
    mov [hda_pin_dev], ebx
    cmp ebx, 1                        ; a speaker pin beats line-out/HP-out (built-in, always there)
    je .picked
.wn:
    inc esi
    inc edi
    jmp .w
.picked:
    cmp dword [hda_pin], 0
    je .none
    ; follow its connection list to find the DAC (through at most one mixer/selector hop)
    mov eax, [hda_pin]
    mov ebx, 0xF02
    xor ecx, ecx                      ; Get Connection List Entry, first entry
    call hda_verb
    jc .none
    movzx esi, al                     ; the widget this pin connects to
    xor edi, edi
.hop:
    mov eax, esi
    mov ebx, 0xF00
    mov ecx, 0x09
    call hda_verb
    jc .none
    shr eax, 20
    and eax, 0xF
    test eax, eax                     ; type 0 = Audio Output (DAC): found it
    jz .havedac
    inc edi
    cmp edi, 2
    jae .none
    mov eax, esi
    mov ebx, 0xF02
    xor ecx, ecx
    call hda_verb
    jc .none
    movzx esi, al
    jmp .hop
.havedac:
    mov [hda_dac], esi
    popad
    clc
    ret
.none:
    popad
    stc
    ret
hda_pin_dev: dd 0

; switch the pin + DAC on: unmute, power up, pick a stream/channel and a format
hda_configure:
    pushad
    mov eax, [hda_pin]                ; Set Pin Widget Control: output enable
    mov ebx, 0x707
    mov ecx, 0x40
    cmp dword [hda_pin_dev], 2        ; HP-out also needs the headphone amp enabled
    jne .pc
    mov ecx, 0xC0
.pc:
    call hda_verb
    mov eax, [hda_pin]                ; EAPD (external amp), if this pin has one -- harmless if not
    mov ebx, 0x70C
    mov ecx, 2
    call hda_verb
    mov eax, [hda_pin]                ; unmute the pin's own amp, if it has one
    mov ebx, 0x300
    mov ecx, 0xB07F
    call hda_verb
    mov eax, [hda_dac]                ; unmute + max gain, the DAC's output amp, both channels
    mov ebx, 0x300
    mov ecx, 0xB07F
    call hda_verb
    mov eax, [hda_afg]                ; power everything to D0 (on)
    mov ebx, 0x705
    xor ecx, ecx
    call hda_verb
    mov eax, [hda_pin]
    mov ebx, 0x705
    xor ecx, ecx
    call hda_verb
    mov eax, [hda_dac]
    mov ebx, 0x705
    xor ecx, ecx
    call hda_verb
    mov eax, [hda_dac]                ; stream tag 1, channel 0
    mov ebx, 0x706
    mov ecx, 0x10
    call hda_verb
    mov eax, [hda_dac]                ; DEBUG: what sample rates/formats does this DAC actually support?
    mov ebx, 0xF00
    mov ecx, 0x0A                     ; Supported PCM Size, Rates
    call hda_verb
    mov [hda_dbg_rates], eax
    mov eax, [hda_dac]
    mov ebx, 0xF00
    mov ecx, 0x0B                     ; Supported Stream Formats
    call hda_verb
    mov [hda_dbg_sformats], eax
    ; find the first OUTPUT stream descriptor (GCAP tells us how many input streams come before it)
    mov esi, [hda_bar]
    movzx eax, word [esi + 0x00]      ; GCAP
    shr eax, 8
    and eax, 0xF                      ; ISS: number of input streams
    shl eax, 5                        ; x 0x20 bytes per descriptor
    add eax, 0x80                     ; SD_BASE
    mov [hda_sd], eax
    popad
    ret

; play a 16-bit stereo PCM buffer, looping until hda_stop (or the next hda_play)
; -- the caller can just overwrite the buffer's contents to change what's playing,
; with no restart needed.  EAX = buffer, ECX = length in bytes, EDX = HDA format word
hda_play:
    inc dword [hda_gen]               ; something new is taking over the stream
    mov dword [hda_clip_on], 0        ; (the startup-clip watchdog, if any, no longer applies)
    inc dword [hda_play_calls]
    mov [hda_dbg_len], ecx
    mov [hda_dbg_fmt], edx
    pushad
    mov ebp, eax
    mov [hda_pbuf], eax
    mov [hda_plen], ecx
    mov [hda_pfmt], edx
    mov esi, [hda_bar]
    mov edi, [hda_sd]
    add edi, esi                      ; edi = this stream's register base
    and dword [edi + 0x00], ~2        ; RUN = 0 (stop first, in case it's already going)
    or dword [edi + 0x00], 1          ; SRST = 1 (stream reset)
    mov ecx, 5
.rw:
    test dword [edi + 0x00], 1
    jnz .rd
    push ecx
    mov ecx, 1
    call tsc_wait_ms
    pop ecx
    dec ecx
    jnz .rw
.rd:
    mov eax, [hda_pfmt]               ; FORMAT: this controller only accepts it while still in
    mov [edi + 0x12], ax              ; reset (SD_FORMAT = 0x12, confirmed against a register dump)
    and dword [edi + 0x00], ~1        ; SRST = 0 (come out of reset)
    mov ecx, 5
.rw2:
    test dword [edi + 0x00], 1
    jz .setup
    push ecx
    mov ecx, 1
    call tsc_wait_ms
    pop ecx
    dec ecx
    jnz .rw2
.setup:                               ; ...but CBL/LVI/BDL only stick once reset has cleared again
    mov dword [HDA_BDL], ebp          ; one BDL entry covering the whole buffer, looped
    mov dword [HDA_BDL + 4], 0
    mov ecx, [hda_plen]
    mov [HDA_BDL + 8], ecx
    mov dword [HDA_BDL + 12], 1       ; IOC (we don't use it, but set it anyway)
    mov [edi + 0x08], ecx             ; CBL = the whole buffer
    mov word [edi + 0x0C], 0          ; LVI = 0 (one BDL entry -- it just loops)
    mov dword [edi + 0x18], HDA_BDL
    mov dword [edi + 0x1C], 0
    mov eax, [edi + 0x00]
    and eax, ~0x00F00000
    or eax, 1 << 20                   ; stream number = 1 (matches the DAC's Set Channel/StreamID)
    or eax, (1 << 2)                  ; IOCE
    mov [edi + 0x00], eax
    or dword [edi + 0x00], 2          ; RUN = 1
    mov eax, [edi + 0x00]
    mov [hda_dbg_ctl], eax
    mov eax, [edi + 0x08]
    mov [hda_dbg_cbl], eax
    movzx eax, word [edi + 0x0C]
    mov [hda_dbg_lvi], eax
    movzx eax, word [edi + 0x12]
    mov [hda_dbg_sfmt], eax
    mov eax, [edi + 0x18]
    mov [hda_dbg_bdpl], eax
    popad
    ret
hda_pbuf: dd 0
hda_plen: dd 0
hda_pfmt: dd 0
hda_play_calls: dd 0
hda_dbg_len: dd 0
hda_dbg_fmt: dd 0
hda_note_calls: dd 0
hda_dbg_ctl: dd 0
hda_dbg_cbl: dd 0
hda_dbg_lvi: dd 0
hda_dbg_sfmt: dd 0
hda_dbg_bdpl: dd 0
hda_dbg_rates: dd 0
hda_dbg_sformats: dd 0

hda_stop:
    inc dword [hda_gen]
    mov dword [hda_clip_on], 0
    cmp dword [hda_ok], 0
    je .r
    pushad
    mov esi, [hda_bar]
    mov edi, [hda_sd]
    add edi, esi
    mov eax, [edi + 0x04]              ; LPIB -- how far the DMA actually got, before we touch anything
    mov [hda_last_lpib], eax
    mov eax, [edi + 0x08]              ; CBL -- the full buffer length, for comparison
    mov [hda_last_cbl], eax
    movzx eax, byte [edi + 0x03]       ; SDSTS -- FIFOE/DESE would mean a real DMA fault, not just "stopped"
    mov [hda_last_sdsts], eax
    and dword [edi + 0x00], ~2        ; RUN = 0
    popad
.r:
    ret
hda_gen:      dd 0
hda_clip_on:  dd 0                    ; 1 while a "play once" watchdog is pending
hda_clip_end: dd 0                    ; the RTC second (since midnight) to stop it by (safety net only)
hda_clip_maxlpib: dd 0                ; highest LPIB seen this play-through, for jitter-proof wrap detection
hda_clip_start_tsc: dd 0              ; when this clip started -- LPIB isn't trusted for ~200ms after this
hda_last_lpib:  dd 0                  ; snapshotted every time ANY stream stops -- see About Nova
hda_last_cbl:   dd 0
hda_last_sdsts: dd 0
hda_clip_gen: dd 0                    ; ...but only if nothing else has used the stream meanwhile

; called from the idle loop: is it time to stop a clip that's played its once-through length?
; (RTC seconds, not the CPU clock -- a modern CPU's TSC wraps its low 32 bits in well under
; a second, so it can't safely time an interval as long as the startup clip on its own.)
hda_watchdog:
    cmp dword [hda_beep_on], 0
    je .checkclip
    mov eax, [hda_gen]
    cmp eax, [hda_beep_gen]
    jne .beepclear                    ; something else took the stream over already
    rdtsc
    sub eax, [hda_beep_end]
    js .checkclip                     ; not yet
    call hda_stop
.beepclear:
    mov dword [hda_beep_on], 0
.checkclip:
    cmp dword [hda_clip_on], 0
    je .r
    mov eax, [hda_gen]
    cmp eax, [hda_clip_gen]
    jne .clear                        ; something else (Music Maker...) took the stream over already
    ; sample-accurate stop: hardware always loops a BDL until software clears RUN
    ; (there's no "play once" mode), so watch LPIB (the DMA's own read position)
    ; and stop once it wraps back to the start -- i.e. once one pass finishes --
    ; rather than waiting on a once-a-second clock check that could let it run up
    ; to a second into a second pass before stopping (which is exactly what a user
    ; hearing "it plays, then a restart cuts off" was seeing).
    ; LPIB is real hardware and is explicitly NOT guaranteed to update smoothly --
    ; real-hardware testing caught it dipping backward well before the buffer
    ; actually finished, which a naive "any decrease = wrap" check mistook for the
    ; real wrap and stopped the clip far too early. Tracking the running MAXIMUM
    ; (below) instead of just the last reading was meant to filter that out, but
    ; real-hardware testing STILL showed an early, consistently ~20%-through stop
    ; even with that guard -- which points at something more specific than random
    ; jitter: LPIB likely reads a bogus/transient value for a brief moment right as
    ; the stream starts (before the DMA position has actually settled), spuriously
    ; satisfying the "got near the end" half of the check almost immediately. Guard
    ; against THAT by ignoring LPIB entirely for a short grace period right after
    ; starting (TSC-timed -- safe for a window this short, well under the ~1s+
    ; 32-bit-wrap danger zone that rules out TSC for the clip's own full duration).
    rdtsc
    sub eax, [hda_clip_start_tsc]
    mov ecx, [tsc_per_ms]
    imul ecx, 200
    cmp eax, ecx
    jb .nowrap                        ; still warming up -- don't trust LPIB yet
    mov esi, [hda_bar]
    mov edi, [hda_sd]
    add edi, esi
    mov eax, [edi + 0x04]             ; current LPIB
    mov ebx, [edi + 0x08]             ; CBL -- the full buffer length
    cmp eax, [hda_clip_maxlpib]
    jbe .notnewmax
    mov [hda_clip_maxlpib], eax
.notnewmax:
    mov ecx, ebx
    shr ecx, 2                        ; CBL/4 -- "near the start"
    cmp eax, ecx
    jae .nowrap                       ; current reading isn't near the start -- not a wrap
    mov ecx, [hda_clip_maxlpib]
    shl ecx, 2
    mov edx, ebx
    imul edx, 3                       ; compare maxlpib*4 against CBL*3 (i.e. maxlpib > CBL*3/4)
    cmp ecx, edx
    jb .nowrap                        ; never got near the end -- this dip is just jitter
    call hda_stop                     ; genuinely wrapped: was near the end, now near the start
    jmp .r
.nowrap:
    ; RTC-second deadline kept as a safety net in case LPIB ever misbehaves
    push eax
    call now_seconds
    mov ebx, eax
    pop eax
    mov eax, [hda_clip_end]
    sub eax, ebx
    jg .r                             ; not yet
    cmp eax, -10                      ; (a midnight wrap looks like a huge negative -- ignore it, not due)
    jl .r
    call hda_stop
.clear:
    mov dword [hda_clip_on], 0
.r:
    ret

; sample-rate / bit-depth / channel-count -> the 16-bit format word the hardware wants.
; EAX = Hz (22050, 44100 or 48000), EBX = channels (1 or 2) -> EAX = format word
hda_fmt:
    push ebx
    push ecx
    push edx
    xor ecx, ecx                      ; ECX = format bits so far
    cmp eax, 48000
    je .f48
    cmp eax, 44100
    je .f44
    or ecx, 0x4100                    ; 22050 = 44100-family, /2
    jmp .bits
.f44:
    or ecx, 0x4000                    ; 44100-family, x1
    jmp .bits
.f48:
                                       ; 48000-family, x1 (base bits already 0)
.bits:
    or ecx, 0x10                      ; 16 bits per sample
    dec ebx
    and ebx, 0xF
    or ecx, ebx                       ; channels - 1
    mov eax, ecx
    pop edx
    pop ecx
    pop ebx
    ret

; play the recorded startup clip through real speakers: convert SNDBUF (8-bit unsigned
; PCM, as the PC-speaker path already uses) into 16-bit stereo in HDA_SBUF, then kick
; off DMA playback and return immediately -- the desktop appears right away, no more
; waiting out the whole clip before NovaOS is usable.
hda_play_startup:
    pushad
    mov esi, SNDBUF
    mov edi, HDA_SBUF
    mov ecx, [snd_len]
.c:
    test ecx, ecx
    jz .done
    movzx eax, byte [esi]
    sub eax, 128                      ; signed sample, -128..127
    imul eax, [hda_volume]            ; scale by master volume (0..100); range fits easily in 32 bits
    cdq
    mov ebx, 100
    idiv ebx
    shl eax, 8                        ; 8-bit unsigned -> 16-bit signed
    stosw                             ; left
    stosw                             ; right
    inc esi
    dec ecx
    jmp .c
.done:
    mov eax, [snd_rate]
    mov ebx, 2
    call hda_fmt
    mov edx, eax
    mov eax, HDA_SBUF
    mov ecx, [snd_len]
    shl ecx, 2                        ; samples -> bytes (x2 channels x2 bytes)
    call hda_play                     ; (this also bumps hda_gen and clears any old watchdog)
    mov eax, [snd_len]                ; how long the clip runs, in whole seconds (rounded up) --
    add eax, [snd_rate]                ; play it once, not forever
    dec eax
    xor edx, edx
    div dword [snd_rate]
    push eax
    call now_seconds
    pop ebx
    add eax, ebx
    mov [hda_clip_end], eax
    mov eax, [hda_gen]
    mov [hda_clip_gen], eax
    mov dword [hda_clip_maxlpib], 0
    rdtsc
    mov [hda_clip_start_tsc], eax
    mov dword [hda_clip_on], 1
    popad
    ret

; Music Maker: a FIXED-length buffer (always HDA_NFIXLEN frames, never resized) filled
; with repeating cycles of a square wave at the given note.  Because the length never
; changes, changing pitch is just a rewrite of the buffer's CONTENTS -- the DMA keeps
; looping over the same address/length the whole time a song plays, so a note change
; needs no SRST/FORMAT/CBL reprogramming at all (that per-note reset dance is what made
; the earlier attempt at this unreliable).  The stream itself is started once (on the
; first note of a play-through, or if something else -- a beep, an SFX -- stole it
; since) and left running; BX = 0 just fills the buffer with silence rather than
; stopping the stream, so the next real note can resume instantly.
HDA_NFIXLEN equ 0x1000            ; frames -- big enough that even a low note's cycle fits many times over
hda_note_gen: dd 0xFFFFFFFF       ; hda_gen the last time WE (not something else) owned the stream
hda_note:
    inc dword [hda_note_calls]
    pushad
    call hda_note_wave
    mov eax, [hda_gen]
    cmp eax, [hda_note_gen]
    je .running                       ; still ours -- buffer rewrite alone is enough
    mov eax, 44100                    ; the plain base rate -- no divisor bit some real codecs
    mov ebx, 2                        ; may not honour (that's what made 22050 play back 2x fast)
    call hda_fmt
    mov edx, eax
    mov eax, HDA_NBUF
    mov ecx, HDA_NFIXLEN
    shl ecx, 2                        ; frames -> bytes (x2 channels x2 bytes)
    call hda_play                     ; bumps hda_gen
    mov eax, [hda_gen]
    mov [hda_note_gen], eax
.running:
    popad
    ret

; fills HDA_NBUF (fixed HDA_NFIXLEN frames) with the waveform for BX (0 = silence),
; WITHOUT touching any playback registers -- safe to call while the stream is live.
hda_note_wave:
    pushad
    test bx, bx
    jz .silent
    movzx ebx, bx                     ; divisor -> Hz (same table Music Maker already uses)
    mov eax, 1193182
    xor edx, edx
    div ebx
    mov ecx, eax                      ; ECX = Hz
    mov eax, 44100                    ; samples per cycle at 44100 Hz = rate / Hz
    xor edx, edx
    div ecx
    test eax, eax
    jnz .haveper
    inc eax
.haveper:
    mov [hda_nper], eax
    mov edi, HDA_NBUF
    xor esi, esi
.s:
    cmp esi, HDA_NFIXLEN
    jae .done
    mov eax, esi
    xor edx, edx
    div dword [hda_nper]
    mov eax, edx                      ; position within this cycle
    shl eax, 1
    cmp eax, [hda_nper]
    jae .lo
    mov ax, 9000
    jmp .wr
.lo:
    mov ax, -9000
.wr:
    stosw
    stosw
    inc esi
    jmp .s
.done:
    popad
    ret
.silent:
    mov edi, HDA_NBUF
    mov ecx, HDA_NFIXLEN * 2          ; L+R words
    xor eax, eax
    rep stosw
    popad
    ret
hda_nper: dd 0
hda_nlen: dd 0                    ; hda_beep's own one-shot buffer length (separate from hda_note's fixed length)
HDA_NCYC equ 8                    ; how many wave cycles hda_beep's loop buffer holds

; a short, volume-scaled beep -- used by Settings' volume control for live feedback
; ("how loud is this now"). BX = PIT-style pitch divisor, EAX = volume 0-100.
; Auto-stops itself after ~130ms via a TSC deadline (safe for a duration this
; short -- the 32-bit TSC-wrap problem only bites intervals over ~1s, see hda_watchdog).
hda_beep:
    cmp dword [hda_ok], 0
    je .out
    pushad
    mov ecx, eax
    imul ecx, 9000
    mov eax, ecx
    xor edx, edx
    mov ecx, 100
    idiv ecx
    mov [hda_beep_amp], eax           ; target peak amplitude (0..9000)
    test bx, bx
    jz .silent
    movzx ebx, bx
    mov eax, 1193182
    xor edx, edx
    div ebx
    mov ecx, eax                      ; Hz
    mov eax, 44100
    xor edx, edx
    div ecx
    test eax, eax
    jnz .haveper
    inc eax
.haveper:
    mov [hda_nper], eax
    imul eax, HDA_NCYC
    cmp eax, 0x4000
    jbe .lenok
    mov eax, 0x4000
.lenok:
    mov [hda_nlen], eax
    mov edi, HDA_NBUF
    xor esi, esi
.s:
    cmp esi, [hda_nlen]
    jae .filled
    mov eax, esi
    xor edx, edx
    div dword [hda_nper]
    mov eax, edx
    shl eax, 1
    mov ecx, [hda_beep_amp]
    cmp eax, [hda_nper]
    jae .lo
    mov eax, ecx
    jmp .wr
.lo:
    neg ecx
    mov eax, ecx
.wr:
    stosw
    stosw
    inc esi
    jmp .s
.filled:
    mov eax, 44100
    mov ebx, 2
    call hda_fmt
    mov edx, eax
    mov eax, HDA_NBUF
    mov ecx, [hda_nlen]
    shl ecx, 2
    call hda_play                     ; bumps hda_gen, cancels any other watchdog
    mov eax, [hda_gen]
    mov [hda_beep_gen], eax
    rdtsc
    mov ecx, [tsc_per_ms]
    imul ecx, 130
    add eax, ecx
    mov [hda_beep_end], eax
    mov dword [hda_beep_on], 1
    popad
    ret
.silent:
    call hda_stop
    popad
    ret
.out:
    ret
hda_beep_amp: dd 0
hda_beep_gen: dd 0
hda_beep_end: dd 0
hda_beep_on:  dd 0

; Music Maker's SFX bank -- 6 one-shot samples, all mono 8-bit unsigned @ 44100 Hz,
; generated offline and loaded as one raw blob by sfx_load (power.inc).  EAX = index
; (0..NSFX-1) -> converts that slice into HDA_SBUF (volume-scaled, like the startup
; clip) and plays it once, auto-stopping via the same short TSC-deadline watchdog
; hda_beep uses (safe: even the longest clip here is well under a second).
NSFX equ 6
sfx_off: dd 0, 9702, 16758, 35280, 37926, 45864
sfx_len: dd 9702, 7056, 18522, 2646, 7938, 28665
sfx_tmp_len: dd 0
hda_play_sfx:
    cmp eax, NSFX
    jae .out
    cmp dword [hda_ok], 0             ; no real sound chip -- nothing sane to fall back to for these
    je .out                           ; (unlike the startup clip/beep, these aren't simple tones)
    pushad
    mov ebx, eax
    shl ebx, 2
    mov eax, [sfx_len + ebx]
    mov [sfx_tmp_len], eax
    mov esi, [sfx_off + ebx]
    add esi, SFX_BUF
    mov edi, HDA_SBUF
    mov ecx, [sfx_tmp_len]
.c:
    test ecx, ecx
    jz .cdone
    movzx eax, byte [esi]
    sub eax, 128
    imul eax, [hda_volume]
    cdq
    push ecx
    mov ecx, 100
    idiv ecx
    pop ecx
    shl eax, 8
    stosw
    stosw
    inc esi
    dec ecx
    jmp .c
.cdone:
    mov eax, 44100
    mov ebx, 2
    call hda_fmt
    mov edx, eax
    mov eax, HDA_SBUF
    mov ecx, [sfx_tmp_len]
    shl ecx, 2
    call hda_play
    mov eax, [hda_gen]
    mov [hda_beep_gen], eax
    rdtsc
    push eax                          ; save the current TSC
    mov eax, [sfx_tmp_len]
    imul eax, 1000
    xor edx, edx
    mov ebx, 44100
    div ebx                           ; eax = clip duration in ms
    imul eax, [tsc_per_ms]
    mov ecx, eax                      ; ecx = clip duration in TSC ticks
    pop eax                           ; restore the TSC
    add eax, ecx
    mov [hda_beep_end], eax
    mov dword [hda_beep_on], 1
    popad
.out:
    ret
