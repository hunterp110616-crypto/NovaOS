; ============================================================
;  NovaOS  --  USB driver: hot-plug a USB stick and read it (read-only)
;  (included into kernel_vesa.asm)
;
;  PCI scan -> take EHCI (USB 2.0) away from the BIOS and route every
;  port to its UHCI (USB 1.1) companions (CONFIGFLAG = 0) -> UHCI driver
;  polls its root ports for plug / unplug -> enumerate the device ->
;  USB Mass Storage (Bulk-Only) + SCSI READ(10) -> FAT32 via the Files app.
;
;  Only started when NovaOS runs from the internal disk (on the live USB the
;  BIOS must keep driving that stick).  Taking the chips over also stops the
;  BIOS's USB keyboard/mouse emulation until the next restart.
; ============================================================

USBMEM    equ 0x00A00000
U_FRAMES  equ USBMEM            ; 1024-entry frame list (4 KB aligned)
U_QH      equ USBMEM + 0x1000   ; the one queue head we schedule
U_TD      equ USBMEM + 0x1100   ; transfer descriptors (32 x 16 bytes)
U_SETUP   equ USBMEM + 0x1400   ; 8-byte SETUP packet
U_CBW     equ USBMEM + 0x1500   ; 31-byte command block wrapper
U_CSW     equ USBMEM + 0x1600   ; 13-byte command status wrapper
U_DATA    equ USBMEM + 0x2000   ; data buffer (4 KB)
MAX_UHCI  equ 12                ; USB 1.1 controllers of either kind (UHCI = Intel/VIA, OHCI = AMD/nVidia/SiS)
OHCI_HCCA equ USBMEM + 0x4000   ; one 256-byte HCCA per OHCI controller
OED_CTL   equ USBMEM + 0x3100   ; OHCI endpoint descriptors: control, bulk IN, bulk OUT
OED_BIN   equ USBMEM + 0x3110
OED_BOUT  equ USBMEM + 0x3120
OTD       equ USBMEM + 0x3200   ; OHCI transfer descriptors (up to 4 + the empty tail)
HCFG      equ USBMEM + 0x5000   ; copy of a config descriptor (HID parsing)
UFL       equ USBMEM + 0x10000  ; a 4 KB frame list per UHCI controller
UANC      equ USBMEM + 0x20000  ; per UHCI controller: anchor QH (+0) -> [HID QHs] -> storage QH (+0x20)
HMEM      equ USBMEM + 0x21000  ; per USB mouse / keyboard: 256-byte block (QH, TDs, ED, buffer)
MAX_HID   equ 4

%macro SQH_EL 1                 ; storage queue head of the current UHCI controller: element = %1
    push eax
    mov eax, [u_qhs]
    mov dword [eax + 4], %1
    pop eax
%endmacro

; ---------------- PCI configuration space ----------------
pci_addr:                        ; EAX = bus<<16 | dev<<11 | fn<<8 | reg  -> CF8
    push eax
    and al, 0xFC
    or eax, 0x80000000
    push edx
    mov dx, 0xCF8
    out dx, eax
    pop edx
    pop eax
    ret
pci_rd:                          ; EAX = address -> EAX = dword
    call pci_addr
    push edx
    mov dx, 0xCFC
    in eax, dx
    pop edx
    ret
pci_wr:                          ; EAX = address, EBX = dword
    call pci_addr
    push edx
    push eax
    mov dx, 0xCFC
    mov eax, ebx
    out dx, eax
    pop eax
    pop edx
    ret

; ---------------- start-up: find + claim the controllers ----------------
usb_init:
    cmp dword [install_mode], 0      ; live USB: leave USB to the BIOS
    je .ret
    cmp dword [u_inited], 0          ; only once: this takes USB over from the BIOS
    jne .ret
    mov dword [u_inited], 1
    pushad
    mov byte [mouse_cycle], 0        ; (a BIOS-emulated USB mouse stops mid-packet)
    mov dword [u_nctl], 0
    xor esi, esi                     ; esi = bus/dev/fn cursor (bus 0)
.scan:
    cmp esi, 32*8
    jae .scanned
    mov eax, esi
    shl eax, 8                       ; dev<<11 | fn<<8
    mov [u_pa], eax
    call pci_rd
    cmp ax, 0xFFFF
    je .next
    test esi, 7                      ; function 0: is this a multi-function device?
    jnz .fnok
    mov eax, [u_pa]
    add eax, 0x0C
    call pci_rd
    shr eax, 23
    and eax, 1
    mov [u_mf], eax
    jmp .fn0
.fnok:
    cmp dword [u_mf], 0              ; functions 1-7 of a single-function device are ghosts
    je .next
.fn0:
    mov eax, [u_pa]
    add eax, 0x08
    call pci_rd                      ; class / subclass / prog-if
    shr eax, 8
    cmp eax, 0x0C0320                ; EHCI
    je .ehci
    cmp eax, 0x0C0300                ; UHCI
    je .uhci
    cmp eax, 0x0C0310                ; OHCI
    je .ohci
    jmp .next
.ohci:
    mov ecx, [u_nctl]
    cmp ecx, MAX_UHCI
    jae .next
    mov eax, [u_pa]
    add eax, 0x10                    ; BAR0 = MMIO registers
    call pci_rd
    and eax, 0xFFFFF000
    jz .next
    mov [u_io + ecx*4], eax
    mov dword [u_kind + ecx*4], 1
    mov eax, [u_pa]
    mov [u_pci + ecx*4], eax
    mov eax, [u_pa]                  ; enable memory + bus mastering
    add eax, 0x04
    call pci_rd
    or eax, 0x06
    mov ebx, eax
    mov eax, [u_pa]
    add eax, 0x04
    call pci_wr
    inc dword [u_nctl]
    jmp .next
.ehci:
    mov eax, [u_pa]
    call ehci_release
    jmp .next
.uhci:
    mov ecx, [u_nctl]
    cmp ecx, MAX_UHCI
    jae .next
    mov eax, [u_pa]
    add eax, 0x20                    ; BAR4 = I/O base
    call pci_rd
    and eax, 0xFFE0
    jz .next
    mov [u_io + ecx*4], eax
    mov dword [u_kind + ecx*4], 0
    mov eax, [u_pa]
    mov [u_pci + ecx*4], eax
    mov eax, [u_pa]                  ; enable I/O + bus mastering
    add eax, 0x04
    call pci_rd
    or eax, 0x05
    mov ebx, eax
    mov eax, [u_pa]
    add eax, 0x04
    call pci_wr
    mov eax, [u_pa]                  ; LEGSUP (0xC0): stop the BIOS's SMI legacy emulation
    add eax, 0xC0
    call pci_rd
    and eax, 0xFFFF0000
    or eax, 0x8F00
    mov ebx, eax
    mov eax, [u_pa]
    add eax, 0xC0
    call pci_wr
    inc dword [u_nctl]
.next:
    inc esi
    jmp .scan
.scanned:
    xor ecx, ecx                     ; reset every UHCI (halted, frame list set)
.r:
    cmp ecx, [u_nctl]
    jae .ok
    mov edx, [u_io + ecx*4]
    cmp dword [u_kind + ecx*4], 1
    je .ro
    mov eax, ecx                     ; this controller's own frame list
    shl eax, 12
    add eax, UFL
    mov [u_flb], eax
    call uhci_reset
    jmp .rn
.ro:
    call ohci_init                   ; (after every EHCI has handed its ports over)
.rn:
    inc ecx
    jmp .r
.ok:
    xor ebx, ebx                     ; UHCI schedules: every frame -> anchor -> (HID) -> storage QH
.sc:
    cmp ebx, [u_nctl]
    jae .scd
    cmp dword [u_kind + ebx*4], 0
    jne .scn
    mov esi, ebx
    shl esi, 6
    add esi, UANC                    ; anchor QH
    lea eax, [esi + 0x20]
    or eax, 2
    mov [esi], eax                   ; anchor -> storage QH
    mov dword [esi + 4], 1
    mov dword [esi + 0x20], 1
    mov dword [esi + 0x24], 1
    mov edi, ebx
    shl edi, 12
    add edi, UFL
    mov eax, esi
    or eax, 2
    mov ecx, 1024
    rep stosd
    mov edx, [u_io + ebx*4]          ; and run it (SOFs flowing; nothing scheduled yet)
    call uhci_run
.scn:
    inc ebx
    jmp .sc
.scd:
    cmp dword [u_nctl], 0
    je .none
    mov dword [usb_active], 1
.none:
    popad
.ret:
    ret

ehci_release:                    ; EAX = PCI address of an EHCI controller
    pushad
    mov [u_ea], eax
    add eax, 0x04                    ; memory + bus master on
    call pci_rd
    or eax, 0x06
    mov ebx, eax
    mov eax, [u_ea]
    add eax, 0x04
    call pci_wr
    mov eax, [u_ea]
    add eax, 0x10                    ; BAR0 = MMIO
    call pci_rd
    and eax, 0xFFFFFF00
    jz .done
    mov [u_ebar], eax
    mov ebx, [eax + 8]               ; HCCPARAMS -> EECP
    shr ebx, 8
    and ebx, 0xFF
    cmp ebx, 0x40
    jb .noleg
    mov [u_eecp], ebx
    mov eax, [u_ea]
    add eax, ebx
    call pci_rd
    cmp al, 1                        ; USBLEGSUP capability?
    jne .noleg
    or eax, 1 << 24                  ; "the OS owns this controller now"
    mov ebx, eax
    mov eax, [u_ea]
    add eax, [u_eecp]
    call pci_wr
    mov ecx, 100                     ; wait up to 1 s for the BIOS to let go
.w:
    mov eax, [u_ea]
    add eax, [u_eecp]
    call pci_rd
    test eax, 1 << 16
    jz .freed
    push ecx
    mov ecx, 10
    call tsc_wait_ms
    pop ecx
    dec ecx
    jnz .w
.freed:
    xor ebx, ebx                     ; no more USB SMIs
    mov eax, [u_ea]
    add eax, [u_eecp]
    add eax, 4
    call pci_wr
.noleg:
    mov esi, [u_ebar]
    movzx eax, byte [esi]            ; CAPLENGTH -> operational registers
    add esi, eax
    and dword [esi], ~1              ; USBCMD: stop
    mov ecx, 100
.h:
    test dword [esi + 4], 1 << 12    ; USBSTS.HCHalted
    jnz .halted
    push ecx
    mov ecx, 1
    call tsc_wait_ms
    pop ecx
    dec ecx
    jnz .h
.halted:
    mov dword [esi + 0x40], 0        ; CONFIGFLAG = 0: every port goes to the USB 1.1 companions
    mov edi, [u_ebar]                ; ...and hand each port over explicitly (PORT_OWNER, bit 13)
    mov ecx, [edi + 4]               ; HCSPARAMS: number of ports
    and ecx, 0x0F
    jz .done
    lea edi, [esi + 0x44]            ; PORTSC(0)
.po:
    mov eax, [edi]
    and eax, ~0x2A                   ; don't write-1-to-clear the change bits
    or eax, 1 << 13
    mov [edi], eax
    add edi, 4
    dec ecx
    jnz .po
.done:
    popad
    ret

uhci_reset:                      ; EDX = I/O base
    pushad
    mov ax, 0x0004                   ; global reset
    out dx, ax
    mov ecx, 20
    call tsc_wait_ms
    xor ax, ax
    out dx, ax
    mov ax, 0x0002                   ; host controller reset
    out dx, ax
    mov ecx, 100
.w:
    in ax, dx
    test ax, 2
    jz .ok
    push ecx
    mov ecx, 1
    call tsc_wait_ms
    pop ecx
    dec ecx
    jnz .w
.ok:
    push edx
    add dx, 4                        ; USBINTR = 0 (we poll)
    xor ax, ax
    out dx, ax
    pop edx
    push edx
    add dx, 2                        ; USBSTS: clear
    mov ax, 0xFFFF
    out dx, ax
    pop edx
    push edx
    add dx, 6                        ; FRNUM = 0
    xor ax, ax
    out dx, ax
    pop edx
    push edx
    add dx, 8                        ; FRBASEADD
    mov eax, [u_flb]
    out dx, eax
    pop edx
    push edx
    add dx, 0x0C                     ; SOF timing (default)
    mov al, 0x40
    out dx, al
    pop edx
    popad
    ret

uhci_run:                        ; EDX = I/O base: start the schedule
    push eax
    mov ax, 0x0081                   ; RS + 64-byte max packet
    out dx, ax
    pop eax
    ret
uhci_stop:
    push eax
    xor ax, ax
    out dx, ax
    pop eax
    ret

; ---------------- on demand: look for a USB stick (Files > USB Drive / Refresh, Update) ----------------
; No background polling: the M750 has built-in USB gadgets (camera / fingerprint / Bluetooth)
; that showed up as "new devices" forever.  We only look when the user asks, and quietly skip
; anything that isn't a FAT32 storage stick.   [u_best]: 0 nothing, 2 a stick we can't read,
; 3 only other USB devices.   Leaves [usb_ready] = 1 if a stick is ready.
usb_scan:
    cmp dword [install_mode], 0
    je .ret
    pushad
    mov dword [u_best], 0
    mov dword [u_seen], 0
    mov dword [u_step], 0
    call usb_init                    ; first use: take the USB chips over from the BIOS
    cmp dword [usb_active], 0
    je .out
    mov dword [u_hidonly], 0
    cmp dword [usb_ready], 0
    je .look
    call ctx_save                    ; the stick we already have: still plugged in?
    mov edx, [u_portreg]
    call port_ccs
    jnz .look
    call usb_forget
.look:
    xor ecx, ecx
.c:
    cmp ecx, [u_nctl]
    jae .done
    call ctl_select                  ; ECX -> u_kcur / u_iob / u_qhs / u_np / u_pstep, EDX = port 0
    xor ebx, ebx
.p:
    cmp ebx, [u_np]
    jae .nc
    call port_ccs                    ; something plugged into this port?
    jz .np
    inc dword [u_seen]
    call port_owned                  ; our stick or a USB mouse/keyboard already running there
    jnz .np
    mov [u_ctl], ecx
    mov [u_port], ebx
    mov [u_portreg], edx
    push ecx
    push edx
    push ebx
    call usb_attach
    pop ebx
    pop edx
    pop ecx
    mov eax, [u_at]                  ; furthest step any device reached (for the diagnostic)
    cmp eax, [u_step]
    jbe .st
    mov [u_step], eax
.st:
    mov eax, [u_result]
    cmp eax, 1
    jne .nr
    call ctx_save                    ; a readable stick: remember it, keep looking for mice / keyboards
    jmp .np
.nr:
    cmp eax, 5                       ; a USB mouse / keyboard: now running
    je .np
    cmp eax, 2                       ; remember the most useful "why not"
    jne .o
    mov dword [u_best], 2
    jmp .np
.o:
    cmp dword [u_best], 0
    jne .np
    mov dword [u_best], 3
.np:
    add edx, [u_pstep]
    inc ebx
    jmp .p
.nc:
    inc ecx
    jmp .c
.done:
    cmp dword [usb_ready], 0
    je .out
    call ctx_load                    ; back to the stick for reads
.out:
    popad
.ret:
    ret

ctl_select:                      ; ECX = controller index -> set up the "current controller"; EDX = port 0 register
    push eax
    mov eax, [u_kind + ecx*4]
    mov [u_kcur], eax
    mov edx, [u_io + ecx*4]
    mov [u_iob], edx
    mov eax, ecx
    shl eax, 6
    add eax, UANC + 0x20
    mov [u_qhs], eax
    mov dword [u_np], 2              ; UHCI: 2 root ports, 16-bit I/O registers from +0x10
    mov dword [u_pstep], 2
    add edx, 0x10
    cmp dword [u_kcur], 0
    je .u
    mov eax, [edx - 0x10 + 0x48]     ; OHCI: HcRhDescriptorA.NDP ports, 32-bit MMIO from +0x54
    and eax, 0x0F
    mov [u_np], eax
    mov dword [u_pstep], 4
    add edx, 0x44
.u:
    pop eax
    ret

port_owned:                      ; EDX = port register -> ZF = 0 if our stick or a HID device uses it
    push eax
    push ecx
    cmp dword [usb_ready], 0
    je .h
    cmp edx, [s_portreg]
    je .yes
.h:
    xor ecx, ecx
.l:
    cmp ecx, MAX_HID
    jae .no
    cmp dword [h_on + ecx*4], 0
    je .n
    cmp edx, [h_port + ecx*4]
    je .yes
.n:
    inc ecx
    jmp .l
.yes:
    or ecx, 1                        ; ZF = 0
    jmp .r
.no:
    xor ecx, ecx                     ; ZF = 1
.r:
    pop ecx
    pop eax
    ret

; the stick's transfer state, kept while other devices are set up
%macro CTX 1
    mov eax, [%1]
    mov [s_%1], eax
%endmacro
%macro UNCTX 1
    mov eax, [s_%1]
    mov [%1], eax
%endmacro
ctx_save:
    push eax
    CTX u_kcur
    CTX u_iob
    CTX u_qhs
    CTX u_portreg
    CTX u_ctl
    CTX u_port
    CTX u_addr
    CTX u_mp0
    CTX u_ls
    CTX u_ep_in
    CTX u_ep_out
    CTX u_mp_in
    CTX u_mp_out
    CTX u_tog_in
    CTX u_tog_out
    CTX usb_part
    CTX usb_last_lba
    pop eax
    ret
ctx_load:
    push eax
    UNCTX u_kcur
    UNCTX u_iob
    UNCTX u_qhs
    UNCTX u_portreg
    UNCTX u_ctl
    UNCTX u_port
    UNCTX u_addr
    UNCTX u_mp0
    UNCTX u_ls
    UNCTX u_ep_in
    UNCTX u_ep_out
    UNCTX u_mp_in
    UNCTX u_mp_out
    UNCTX u_tog_in
    UNCTX u_tog_out
    UNCTX usb_part
    UNCTX usb_last_lba
    pop eax
    ret

usb_forget:                      ; the stick is gone (or unreadable): stop its controller
    mov dword [usb_ready], 0
    mov dword [u_ep_in], 0
    mov dword [u_ep_out], 0
    call ctl_idle
    ret

port_ccs:                        ; EDX = port register of controller kind [u_kcur] -> ZF = 0 if connected
    push eax
    cmp dword [u_kcur], 1
    je .o
    in ax, dx
    test ax, 1
    pop eax
    ret
.o:
    mov eax, [edx]
    test eax, 1
    pop eax
    ret

ctl_idle:                        ; stop using the current controller
    push edx
    mov edx, [u_iob]
    cmp dword [u_kcur], 1
    je .o
    SQH_EL 1
    pop edx
    ret
.o:
    mov dword [edx + 0x20], 0        ; OHCI: empty control + bulk lists
    mov dword [edx + 0x28], 0
    pop edx
    ret

; ---------------- enumerate + set up one device (quietly).  [u_result]: 1 ok, 2 storage but
; not readable, 3 not a storage device, 4 didn't respond ----------------
usb_attach:
    mov dword [u_ep_in], 0
    mov dword [u_ep_out], 0
    mov dword [u_result], 4
    mov dword [u_at], 1              ; step 1: switching the port on
    cmp dword [u_kcur], 1
    je .ohci_up
    mov edx, [u_iob]                 ; run the controller FIRST: real chips need SOF packets
    call uhci_run                    ; flowing the moment the port is on, or the stick sleeps
    mov ecx, 100                     ; let it settle after plug-in (USB spec: 100 ms)
    call tsc_wait_ms
    mov edx, [u_portreg]             ; port reset (50 ms)
    mov ax, 0x0200
    out dx, ax
    mov ecx, 60
    call tsc_wait_ms
    xor ax, ax
    out dx, ax
    mov ecx, 1
    call tsc_wait_ms
    mov dword [u_try], 10            ; enable it (real chips can need a few goes)
.en:
    mov ecx, 10
    call tsc_wait_ms
    in ax, dx
    test ax, 1                       ; unplugged meanwhile?
    jz .fail
    test ax, 0x000A                  ; clear any change bits first
    jz .nochg
    and ax, 0x000E
    or ax, 0x000A
    out dx, ax
    jmp .ent
.nochg:
    test ax, 4
    jnz .enabled
    mov ax, 0x0004
    out dx, ax
.ent:
    dec dword [u_try]
    jnz .en
    in ax, dx
    test ax, 4
    jz .fail
.enabled:
    mov ecx, 20                      ; reset recovery (spec: 10 ms)
    call tsc_wait_ms
    in ax, dx
    xor ebx, ebx                     ; low-speed device? (flash drives never are)
    test ax, 0x0100
    jz .fs
    mov ebx, 1 << 26
    jmp .fs
.ohci_up:                            ; OHCI root port: reset, it enables itself
    mov ecx, 100                     ; let it settle after plug-in
    call tsc_wait_ms
    mov edx, [u_portreg]
    mov dword [edx], 0x001F0000      ; clear old change bits
    mov dword [edx], 0x10            ; SetPortReset
    mov dword [u_try], 60
.orw:
    mov ecx, 1
    call tsc_wait_ms
    test dword [edx], 1 << 20        ; reset finished?
    jnz .ord
    dec dword [u_try]
    jnz .orw
.ord:
    mov dword [edx], 0x001F0000
    mov ecx, 10
    call tsc_wait_ms
    mov eax, [edx]
    test eax, 1
    jz .fail
    test eax, 2                      ; enabled?
    jnz .oen
    mov dword [edx], 2               ; SetPortEnable
    mov ecx, 10
    call tsc_wait_ms
    test dword [edx], 2
    jz .fail
.oen:
    mov ecx, 20                      ; reset recovery
    call tsc_wait_ms
    xor ebx, ebx
    test dword [edx], 1 << 9         ; low-speed device -> ED "S" bit
    jz .fs
    mov ebx, 1 << 13
.fs:
    mov [u_ls], ebx
    mov dword [u_at], 2              ; step 2: first hello (device descriptor)
    mov dword [u_addr], 0
    mov dword [u_mp0], 8
    mov dword [u_try], 3
.gd:
    mov esi, sp_getdev8              ; device descriptor (8 bytes) -> endpoint-0 packet size
    mov ecx, 8
    call usb_ctrl_in
    jnc .gdok
    mov ecx, 20
    call tsc_wait_ms
    dec dword [u_try]
    jnz .gd
    jmp .fail
.gdok:
    movzx eax, byte [U_DATA + 7]
    test eax, eax
    jz .fail
    mov [u_mp0], eax
    mov dword [u_at], 3              ; step 3: give it an address (each device its own)
    mov eax, [u_nextaddr]
    mov [sp_setaddr + 2], al
    mov esi, sp_setaddr              ; SET_ADDRESS
    call usb_ctrl_nodata
    jc .fail
    mov ecx, 20
    call tsc_wait_ms
    mov eax, [u_nextaddr]
    mov [u_addr], eax
    inc eax
    cmp eax, 127
    jbe .na
    mov eax, 1
.na:
    mov [u_nextaddr], eax
    mov dword [u_at], 4              ; step 4: what kind of device?
    mov esi, sp_getcfg9              ; configuration descriptor (9 bytes, then all of it)
    mov ecx, 9
    call usb_ctrl_in
    jc .fail
    movzx ecx, word [U_DATA + 2]
    cmp ecx, 255
    jbe .cl
    mov ecx, 255
.cl:
    mov [sp_getcfg + 6], cx
    mov esi, sp_getcfg
    call usb_ctrl_in
    jc .fail
    movzx eax, byte [U_DATA + 5]
    mov [sp_setcfg + 2], al
    call usb_find_msd                ; a mass-storage interface with bulk endpoints?
    jc .notmsd
    cmp dword [usb_ready], 0         ; we already have a stick (or only looking for mice now)
    jne .extra
    cmp dword [u_hidonly], 0
    jne .extra
    mov dword [u_result], 2          ; it's storage from here on
    mov dword [u_at], 6              ; step 6: storage, switching it on
    mov esi, sp_setcfg
    call usb_ctrl_nodata
    jc .fail
    mov dword [u_tog_in], 0
    mov dword [u_tog_out], 0
    mov dword [OED_BIN + 8], 0       ; (OHCI keeps its toggles in the EDs)
    mov dword [OED_BOUT + 8], 0
    mov ecx, 50
    call tsc_wait_ms
    mov dword [u_at], 7              ; step 7: waiting for it to be ready
    mov dword [u_try], 12            ; SCSI: wait until it's ready
.tur:
    mov byte [cb_buf], 0x00          ; TEST UNIT READY
    mov dword [u_xlen], 0
    call bot_command
    jnc .ready
    mov byte [cb_buf], 0x03          ; REQUEST SENSE (clears "not ready")
    mov byte [cb_buf + 4], 18
    mov dword [u_xlen], 18
    call bot_command
    mov byte [cb_buf + 4], 0
    mov ecx, 150
    call tsc_wait_ms
    dec dword [u_try]
    jnz .tur
    jmp .fail
.ready:
    mov dword [u_at], 8              ; step 8: size / reading
    mov byte [cb_buf], 0x25          ; READ CAPACITY (10)
    mov dword [u_xlen], 8
    call bot_command
    jc .fail
    mov eax, [U_DATA]
    bswap eax
    mov [usb_last_lba], eax
    mov eax, [U_DATA + 4]
    bswap eax
    cmp eax, 512                     ; 512-byte sectors only
    jne .fail
    xor eax, eax                     ; LBA 0: MBR or a bare FAT32 boot sector?
    mov edi, U_DATA + 0x800
    call usb_read_sector
    jc .fail
    mov dword [usb_part], 0
    mov dword [u_at], 9              ; step 9: read it, but it's not FAT32
    cmp word [U_DATA + 0x800 + 510], 0xAA55
    jne .fail
    cmp dword [U_DATA + 0x800 + 82], 'FAT3'
    je .fat
    mov al, [U_DATA + 0x800 + 446 + 4]
    cmp al, 0x0B
    je .p
    cmp al, 0x0C
    jne .fail
.p:
    mov eax, [U_DATA + 0x800 + 446 + 8]
    mov [usb_part], eax
    mov edi, U_DATA + 0x800
    call usb_read_sector
    jc .fail
    cmp dword [U_DATA + 0x800 + 82], 'FAT3'
    jne .fail
.fat:
    mov dword [usb_ready], 1
    mov dword [u_result], 1
    ret
.notmsd:
    call usb_try_hid                 ; a USB keyboard or mouse? -> keep it running
    jc .nothid
    mov dword [u_result], 5
    ret
.nothid:
.extra:
    mov dword [u_result], 3
    mov dword [u_at], 5              ; step 5: a USB device, but not storage
.fail:
    mov dword [u_ep_in], 0           ; not usable: stop and switch the port off again
    mov dword [u_ep_out], 0
    cmp dword [u_kcur], 1
    jne .ufail
    call ctl_idle
    mov edx, [u_portreg]
    mov dword [edx], 1               ; ClearPortEnable
    mov dword [edx], 0x001F0000      ; (and forget the plug-in)
    ret
.ufail:
    SQH_EL 1
    mov edx, [u_portreg]
    mov ax, 0x000A
    out dx, ax
    ret

usb_find_msd:                    ; walk the config descriptor in U_DATA.  CF = 0 found
    pushad
    movzx ecx, word [U_DATA + 2]
    cmp ecx, 255
    jbe .l
    mov ecx, 255
.l:
    mov esi, U_DATA
    lea ebp, [esi + ecx]
    xor edi, edi                     ; 1 while inside the mass-storage interface
    mov dword [u_ep_in], 0
    mov dword [u_ep_out], 0
.d:
    cmp esi, ebp
    jae .end
    movzx eax, byte [esi]
    test eax, eax
    jz .end
    mov bl, [esi + 1]
    cmp bl, 4                        ; interface
    jne .ep
    xor edi, edi
    mov al, [esi + 5]
    cmp al, 0x08                     ; class: mass storage
    jne .nx
    mov al, [esi + 6]
    cmp al, 0x06                     ; subclass: SCSI
    jne .nx
    mov al, [esi + 7]
    cmp al, 0x50                     ; protocol: bulk-only
    jne .nx
    mov edi, 1
    jmp .nx
.ep:
    cmp bl, 5                        ; endpoint
    jne .nx
    test edi, edi
    jz .nx
    mov al, [esi + 3]
    and al, 3
    cmp al, 2                        ; bulk
    jne .nx
    movzx eax, byte [esi + 2]
    movzx edx, word [esi + 4]
    and edx, 0x7FF
    test al, 0x80
    jz .out
    and eax, 0x0F
    mov [u_ep_in], eax
    mov [u_mp_in], edx
    jmp .nx
.out:
    and eax, 0x0F
    mov [u_ep_out], eax
    mov [u_mp_out], edx
.nx:
    movzx eax, byte [esi]
    add esi, eax
    jmp .d
.end:
    cmp dword [u_ep_in], 0
    je .no
    cmp dword [u_ep_out], 0
    je .no
    popad
    clc
    ret
.no:
    popad
    stc
    ret

; ---------------- UHCI transfer descriptors ----------------
; build one TD.  EDI = TD address, EAX = token, EBX = buffer.  Linked to the next TD.
td_make:
    lea ecx, [edi + 16]
    or ecx, 4                        ; depth-first
    mov [edi], ecx
    mov ecx, [u_ls]
    or ecx, (3 << 27) | (1 << 23)    ; 3 retries, active
    mov [edi + 4], ecx
    mov [edi + 8], eax
    mov [edi + 12], ebx
    ret

; token for a packet.  AL = PID, ECX = length, EDX = endpoint, EBP = toggle
td_token:
    push ecx
    push edx
    movzx eax, al
    dec ecx
    and ecx, 0x7FF                   ; length-1 (0 bytes -> 0x7FF)
    shl ecx, 21
    or eax, ecx
    mov ecx, [u_addr]
    shl ecx, 8
    or eax, ecx
    shl edx, 15
    or eax, edx
    mov ecx, ebp
    and ecx, 1
    shl ecx, 19
    or eax, ecx
    pop edx
    pop ecx
    ret

; run the TD chain at U_TD with ECX TDs; wait for it.  CF = 1 on error/timeout
td_run:
    pushad
    mov eax, ecx
    dec eax
    shl eax, 4
    mov dword [U_TD + eax], 1        ; last TD terminates the chain
    mov [u_last], eax
    SQH_EL U_TD                      ; hand the chain to the controller
    mov dword [u_tmo], 800
.w:
    mov eax, [u_last]
    mov ebx, [U_TD + eax + 4]
    test ebx, 1 << 23
    jz .check                        ; last one done
    mov esi, U_TD                    ; any TD stopped with an error?
    mov ecx, [u_last]
    shr ecx, 4
    inc ecx
.e:
    mov ebx, [esi + 4]
    test ebx, 1 << 23
    jnz .en
    test ebx, 0x760000               ; stall / buffer / babble / timeout / bitstuff (NAK = just retry)
    jnz .err
.en:
    add esi, 16
    dec ecx
    jnz .e
    push ecx
    mov ecx, 1
    call tsc_wait_ms
    pop ecx
    dec dword [u_tmo]
    jnz .w
.err:
    SQH_EL 1
    popad
    stc
    ret
.check:
    test ebx, 0x760000
    jnz .err
    SQH_EL 1
    popad
    clc
    ret

; control transfer with an IN data stage.  ESI = 8-byte setup, ECX = length (-> U_DATA)
usb_ctrl_in:
    cmp dword [u_kcur], 1
    je ohci_ctrl
    pushad
    mov [u_clen], ecx
    mov edi, U_SETUP
    mov ecx, 8
    rep movsb
    mov edi, U_TD
    mov al, 0x2D                     ; SETUP, DATA0
    mov ecx, 8
    xor edx, edx
    xor ebp, ebp
    call td_token
    mov ebx, U_SETUP
    call td_make
    add edi, 16
    mov esi, U_DATA                  ; IN data packets, DATA1, DATA0, ...
    mov ebp, 1
    mov [u_left], ecx
    mov ecx, [u_clen]
    mov [u_left], ecx
    mov dword [u_ntd], 1
.dp:
    cmp dword [u_left], 0
    jle .st
    mov ecx, [u_left]
    cmp ecx, [u_mp0]
    jbe .ln
    mov ecx, [u_mp0]
.ln:
    mov al, 0x69
    xor edx, edx
    call td_token
    mov ebx, esi
    push ecx
    call td_make
    pop ecx
    add edi, 16
    add esi, ecx
    sub [u_left], ecx
    xor ebp, 1
    inc dword [u_ntd]
    jmp .dp
.st:
    mov al, 0xE1                     ; status: zero-length OUT, DATA1
    xor ecx, ecx
    xor edx, edx
    mov ebp, 1
    call td_token
    xor ebx, ebx
    call td_make
    mov ecx, [u_ntd]
    inc ecx
    call td_run
    popad
    ret                              ; CF from td_run survives popad

; control transfer without data.  ESI = setup
usb_ctrl_nodata:
    cmp dword [u_kcur], 1
    jne .u
    push ecx
    xor ecx, ecx
    call ohci_ctrl
    pop ecx
    ret
.u:
    pushad
    mov edi, U_SETUP
    mov ecx, 8
    rep movsb
    mov edi, U_TD
    mov al, 0x2D
    mov ecx, 8
    xor edx, edx
    xor ebp, ebp
    call td_token
    mov ebx, U_SETUP
    call td_make
    add edi, 16
    mov al, 0x69                     ; status: zero-length IN, DATA1
    xor ecx, ecx
    xor edx, edx
    mov ebp, 1
    call td_token
    xor ebx, ebx
    call td_make
    mov ecx, 2
    call td_run
    popad
    ret

; bulk transfer.  AL = 0x69 IN / 0xE1 OUT, ESI = buffer, ECX = length.  CF on error
usb_bulk:
    cmp dword [u_kcur], 1
    je ohci_bulk
    pushad
    mov [u_pid], al
    mov [u_left], ecx
    mov edi, U_TD
    mov dword [u_ntd], 0
    mov ebp, [u_tog_out]
    mov edx, [u_ep_out]
    mov ebx, [u_mp_out]
    cmp al, 0x69
    jne .s
    mov ebp, [u_tog_in]
    mov edx, [u_ep_in]
    mov ebx, [u_mp_in]
.s:
    mov [u_bmp], ebx
.l:
    cmp dword [u_left], 0
    jle .go
    mov ecx, [u_left]
    cmp ecx, [u_bmp]
    jbe .ln
    mov ecx, [u_bmp]
.ln:
    mov al, [u_pid]
    call td_token
    mov ebx, esi
    push ecx
    call td_make
    pop ecx
    add edi, 16
    add esi, ecx
    sub [u_left], ecx
    xor ebp, 1
    inc dword [u_ntd]
    cmp dword [u_ntd], 30
    jb .l
.go:
    mov ecx, [u_ntd]
    test ecx, ecx
    jz .ok
    call td_run
    jc .err
    cmp byte [u_pid], 0x69           ; remember the data toggle for next time
    jne .to
    mov [u_tog_in], ebp
    jmp .ok
.to:
    mov [u_tog_out], ebp
.ok:
    popad
    clc
    ret
.err:
    popad
    stc
    ret

; ---------------- Bulk-Only Transport: one SCSI command ----------------
; cb_buf = command (10 bytes, rest zero), [u_xlen] = bytes to read into U_DATA.  CF on failure
bot_command:
    pushad
    mov edi, U_CBW
    mov dword [edi], 0x43425355      ; "USBC"
    inc dword [u_tag]
    mov eax, [u_tag]
    mov [edi + 4], eax
    mov eax, [u_xlen]
    mov [edi + 8], eax
    mov byte [edi + 12], 0x80        ; data comes to us
    mov byte [edi + 13], 0           ; LUN 0
    mov byte [edi + 14], 10          ; 10-byte command
    lea edi, [U_CBW + 15]
    mov esi, cb_buf
    mov ecx, 16
    rep movsb
    mov al, 0xE1
    mov esi, U_CBW
    mov ecx, 31
    call usb_bulk
    jc .fail
    mov ecx, [u_xlen]
    test ecx, ecx
    jz .csw
    mov al, 0x69
    mov esi, U_DATA
    call usb_bulk
    jc .fail
.csw:
    mov al, 0x69
    mov esi, U_CSW
    mov ecx, 13
    call usb_bulk
    jc .fail
    cmp dword [U_CSW], 0x53425355    ; "USBS"
    jne .fail
    cmp byte [U_CSW + 12], 0         ; command passed?
    jne .fail
    popad
    clc
    ret
.fail:
    popad
    stc
    ret

; read one 512-byte sector of the stick.  EAX = LBA (whole device), EDI = buffer.  CF on error
usb_read_sector:
    cmp dword [usb_ready], 0
    jne .go
    cmp dword [u_ep_in], 0           ; (also used while attaching, before usb_ready)
    je .bad
.go:
    pushad
    mov [u_rlba], eax
    mov [u_rdst], edi
    mov dword [u_try2], 3
.again:
    mov edi, cb_buf
    xor eax, eax
    mov ecx, 4
    rep stosd
    mov byte [cb_buf], 0x28          ; READ (10)
    mov eax, [u_rlba]
    bswap eax
    mov [cb_buf + 2], eax
    mov byte [cb_buf + 8], 1         ; one block
    mov dword [u_xlen], 512
    call bot_command
    jnc .ok
    dec dword [u_try2]
    jnz .again
    mov byte [cb_buf], 0
    mov dword [usb_ready], 0         ; gone (unplugged?) -> a Refresh will look again
    popad
    stc
    ret
.ok:
    mov byte [cb_buf], 0
    mov esi, U_DATA
    mov edi, [u_rdst]
    mov ecx, 128
    rep movsd
    popad
    clc
    ret
.bad:
    stc
    ret

; ================= OHCI (USB 1.1 on AMD / nVidia / SiS / ALi chipsets) =================
ohci_init:                       ; EDX = MMIO base, ECX = controller index
    pushad
    mov [u_ob], edx
    mov edi, OHCI_HCCA               ; this controller's HCCA (256 bytes, no periodic work)
    mov eax, ecx
    shl eax, 8
    add edi, eax
    mov [u_hcca], edi
    push edi
    xor eax, eax
    mov ecx, 64
    rep stosd
    pop edi
    mov esi, [u_ob]
    test dword [esi + 4], 1 << 8     ; HcControl.IR: the BIOS (SMM) owns it -> ask for it
    jz .own
    mov dword [esi + 8], 1 << 3      ; OwnershipChangeRequest
    mov ecx, 500
.ow:
    test dword [esi + 4], 1 << 8
    jz .own
    push ecx
    mov ecx, 1
    call tsc_wait_ms
    pop ecx
    dec ecx
    jnz .ow
.own:
    mov dword [esi + 0x14], 0xC000007F   ; no interrupts (we poll)
    mov ebx, [esi + 0x34]            ; frame interval (keep the BIOS value)
    and ebx, 0x3FFF
    jnz .fi
    mov ebx, 0x2EDF
.fi:
    mov dword [esi + 8], 1           ; HostControllerReset
    mov ecx, 10
.rw:
    test dword [esi + 8], 1
    jz .rd
    push ecx
    mov ecx, 1
    call tsc_wait_ms
    pop ecx
    dec ecx
    jnz .rw
.rd:
    mov [esi + 0x18], edi            ; HcHCCA
    mov dword [esi + 0x20], 0        ; empty control + bulk lists
    mov dword [esi + 0x28], 0
    mov eax, ebx                     ; HcFmInterval: FI | FSMPS << 16 | FIT
    sub eax, 210
    imul eax, 6
    xor edx, edx
    push ebx
    mov ebx, 7
    div ebx
    pop ebx
    shl eax, 16
    or eax, ebx
    or eax, 1 << 31
    mov [esi + 0x34], eax
    mov eax, ebx                     ; HcPeriodicStart = 90 %
    imul eax, 9
    xor edx, edx
    push ebx
    mov ebx, 10
    div ebx
    pop ebx
    mov [esi + 0x40], eax
    mov dword [esi + 0x44], 0x628    ; low-speed threshold
    mov dword [esi + 4], 0xB7        ; USBOPERATIONAL + periodic (HID), control & bulk lists (CBSR 4:1)
    mov dword [esi + 0x50], 1 << 16  ; root hub: power every port (global)...
    mov eax, [esi + 0x48]
    and eax, 0x0F
    lea edi, [esi + 0x54]
.pp:
    test eax, eax
    jz .ppd
    mov dword [edi], 1 << 8          ; ...and each port (per-port power switching)
    add edi, 4
    dec eax
    jmp .pp
.ppd:
    popad
    ret

; run the TD chain at OTD (ECX TDs) on ED EBX.  EDX = 0 control list / 1 bulk list.  CF on error
ohci_run:
    pushad
    mov eax, ecx
    shl eax, 4
    add eax, OTD                     ; empty tail TD after the last real one
    mov dword [eax], 0
    mov dword [eax + 4], 0
    mov dword [eax + 8], 0
    mov dword [eax + 12], 0
    mov [u_otail], eax
    or dword [ebx], 1 << 14          ; skip the ED while we point it at the new TDs
    mov [ebx + 4], eax               ; TailP
    mov ecx, [ebx + 8]
    and ecx, 2                       ; keep the toggle carry
    or ecx, OTD
    mov [ebx + 8], ecx               ; HeadP -> the first TD
    and dword [ebx], ~(1 << 14)
    mov esi, [u_iob]
    test edx, edx
    jnz .bulk
    mov [esi + 0x20], ebx            ; HcControlHeadED
    mov dword [esi + 8], 1 << 1      ; ControlListFilled
    jmp .w0
.bulk:
    mov [esi + 0x28], ebx            ; HcBulkHeadED
    mov dword [esi + 8], 1 << 2      ; BulkListFilled
.w0:
    mov dword [u_tmo], 800
.w:
    mov eax, [ebx + 8]
    test eax, 1                      ; halted = a TD failed
    jnz .err
    and eax, ~0x0F
    cmp eax, [u_otail]
    je .done
    mov ecx, 1
    call tsc_wait_ms
    dec dword [u_tmo]
    jnz .w
    or dword [ebx], 1 << 14          ; timed out: skip the ED while we empty it
    mov ecx, 2
    call tsc_wait_ms
    jmp .err
.done:
    mov esi, OTD                     ; every TD must have finished with CC = 0
.c:
    cmp esi, [u_otail]
    jae .ok
    mov eax, [esi]
    shr eax, 28
    jnz .err
    add esi, 16
    jmp .c
.ok:
    popad
    clc
    ret
.err:
    mov eax, [ebx + 8]
    and eax, 2
    or eax, [u_otail]
    mov [ebx + 8], eax               ; empty + un-halt it (toggle kept)
    and dword [ebx], ~(1 << 14)
    popad
    stc
    ret

; EDI = TD, EAX = flags (DP / T / R), EBX = buffer, ECX = length
ohci_td:
    push eax
    or eax, (7 << 21) | (0x0F << 28) ; no interrupt, "not accessed"
    mov [edi], eax
    lea eax, [edi + 16]
    mov [edi + 8], eax               ; next TD
    xor eax, eax
    mov [edi + 4], eax
    mov [edi + 12], eax
    test ecx, ecx
    jz .z
    mov [edi + 4], ebx               ; CBP
    lea eax, [ebx + ecx - 1]
    mov [edi + 12], eax              ; BE = last byte
.z:
    pop eax
    add edi, 16
    ret

; control transfer: ESI = 8-byte setup, ECX = IN data length (0 = none) -> U_DATA.  CF on error
ohci_ctrl:
    pushad
    mov [u_clen], ecx
    mov edi, U_SETUP
    mov ecx, 8
    rep movsb
    mov eax, [u_mp0]                 ; ED: address, endpoint 0, direction from TDs
    shl eax, 16
    or eax, [u_addr]
    or eax, [u_ls]
    mov [OED_CTL], eax
    mov dword [OED_CTL + 12], 0
    mov edi, OTD
    mov eax, (0 << 19) | (2 << 24)   ; SETUP, DATA0
    mov ebx, U_SETUP
    mov ecx, 8
    call ohci_td
    mov edx, 2                       ; TD count so far + status
    mov ecx, [u_clen]
    test ecx, ecx
    jz .st
    mov eax, (2 << 19) | (3 << 24) | (1 << 18) ; IN, DATA1, short OK
    mov ebx, U_DATA
    call ohci_td
    inc edx
    mov eax, (1 << 19) | (3 << 24)   ; status: zero-length OUT, DATA1
    jmp .s2
.st:
    mov eax, (2 << 19) | (3 << 24)   ; status: zero-length IN, DATA1
.s2:
    xor ecx, ecx
    xor ebx, ebx
    call ohci_td
    mov ecx, edx
    mov ebx, OED_CTL
    xor edx, edx
    call ohci_run
    popad
    ret                              ; CF from ohci_run survives popad

; bulk transfer: AL = 0x69 IN / 0xE1 OUT, ESI = buffer, ECX = length.  CF on error
ohci_bulk:
    pushad
    test ecx, ecx
    jz .ok
    mov ebx, OED_BOUT
    mov edx, [u_ep_out]
    mov ebp, [u_mp_out]
    mov edi, 1 << 19                 ; OUT, toggle from the ED
    cmp al, 0x69
    jne .s
    mov ebx, OED_BIN
    mov edx, [u_ep_in]
    mov ebp, [u_mp_in]
    mov edi, (2 << 19) | (1 << 18)   ; IN, short OK
.s:
    mov eax, ebp
    shl eax, 16
    shl edx, 7
    or eax, edx
    or eax, [u_addr]
    or eax, [u_ls]
    mov [ebx], eax
    mov dword [ebx + 12], 0
    mov eax, edi
    mov edi, OTD
    push ebx
    mov ebx, esi
    call ohci_td
    pop ebx
    mov ecx, 1
    mov edx, 1
    call ohci_run
    jc .err
.ok:
    popad
    clc
    ret
.err:
    popad
    stc
    ret

; ================= USB keyboards + mice (HID boot protocol) =================
; Once NovaOS takes USB over, the BIOS stops pretending USB keyboards/mice are PS/2 ones.
; So we run them ourselves and turn their reports back into PS/2 bytes (scan code set 1 and
; 3-byte mouse packets) - every input loop reads those through kbc_poll.

usb_try_hid:                     ; U_DATA = config descriptor.  CF = 1 if no boot keyboard / mouse
    pushad
    movzx ecx, word [U_DATA + 2]
    cmp ecx, 255
    jbe .l
    mov ecx, 255
.l:
    mov esi, U_DATA
    mov edi, HCFG
    push ecx
    rep movsb
    pop ecx
    mov esi, HCFG
    lea ebp, [esi + ecx]
    mov dword [hc_n], 0
    mov dword [hc_boot], 0
.d:
    cmp esi, ebp
    jae .end
    movzx eax, byte [esi]
    test eax, eax
    jz .end
    cmp byte [esi + 1], 4            ; interface
    jne .ep
    mov dword [hc_boot], 0
    cmp byte [esi + 3], 0            ; alternate setting 0 only
    jne .nx
    cmp byte [esi + 5], 3            ; HID
    jne .nx
    cmp byte [esi + 6], 1            ; boot interface
    jne .nx
    movzx ebx, byte [esi + 7]        ; 1 keyboard, 2 mouse
    cmp ebx, 1
    jb .nx
    cmp ebx, 2
    ja .nx
    mov [hc_proto], ebx
    movzx ebx, byte [esi + 2]
    mov [hc_if], ebx
    mov dword [hc_boot], 1
    jmp .nx
.ep:
    cmp byte [esi + 1], 5            ; endpoint of that interface: interrupt IN
    jne .nx
    cmp dword [hc_boot], 0
    je .nx
    test byte [esi + 2], 0x80
    jz .nx
    mov bl, [esi + 3]
    and bl, 3
    cmp bl, 3
    jne .nx
    mov dword [hc_boot], 0           ; one endpoint per interface
    mov ebx, [hc_n]
    cmp ebx, 2
    jae .nx
    mov edx, [hc_proto]
    mov [hc_cp + ebx*4], edx
    mov edx, [hc_if]
    mov [hc_ci + ebx*4], edx
    movzx edx, byte [esi + 2]
    and edx, 0x0F
    mov [hc_ce + ebx*4], edx
    movzx edx, word [esi + 4]
    and edx, 0x7FF
    mov [hc_cm + ebx*4], edx
    inc dword [hc_n]
.nx:
    add esi, eax
    jmp .d
.end:
    cmp dword [hc_n], 0
    je .no
    mov esi, sp_setcfg               ; switch it on
    call usb_ctrl_nodata
    jc .no
    xor ebx, ebx
.a:
    cmp ebx, [hc_n]
    jae .yes
    mov eax, [hc_ci + ebx*4]
    mov [sp_setproto + 4], al
    mov [sp_setidle + 4], al
    mov esi, sp_setproto             ; boot protocol (simple fixed reports)
    call usb_ctrl_nodata
    mov esi, sp_setidle              ; only report changes (some mice refuse - fine)
    call usb_ctrl_nodata
    mov eax, [hc_cp + ebx*4]
    mov edx, [hc_ce + ebx*4]
    mov ecx, [hc_cm + ebx*4]
    call hid_add
    inc ebx
    jmp .a
.yes:
    popad
    clc
    ret
.no:
    popad
    stc
    ret

hid_add:                         ; EAX = 1 kbd / 2 mouse, EDX = endpoint, ECX = max packet (current device)
    pushad
    xor ebp, ebp
.f:
    cmp ebp, MAX_HID
    jae .full
    cmp dword [h_on + ebp*4], 0
    je .got
    inc ebp
    jmp .f
.got:
    mov [h_proto + ebp*4], eax
    mov [h_ep + ebp*4], edx
    mov [h_mps + ebp*4], ecx
    cmp ecx, 32
    jbe .m
    mov ecx, 32
.m:
    cmp ecx, 3
    jae .m2
    mov ecx, 3
.m2:
    mov [h_len + ebp*4], ecx
    mov eax, [u_kcur]
    mov [h_kind + ebp*4], eax
    mov eax, [u_ctl]
    mov [h_ctl + ebp*4], eax
    mov eax, [u_portreg]
    mov [h_port + ebp*4], eax
    mov eax, [u_addr]
    mov [h_addr + ebp*4], eax
    mov eax, [u_ls]
    mov [h_ls + ebp*4], eax
    mov dword [h_tog + ebp*4], 0
    mov dword [h_err + ebp*4], 0
    mov edi, ebp                     ; zero its memory block
    shl edi, 8
    add edi, HMEM
    mov ebx, edi
    push ecx
    xor eax, eax
    mov ecx, 64
    rep stosd
    pop ecx
    cmp dword [u_kcur], 1
    je .o
    mov dword [ebx], 1               ; UHCI: QH (linked in by hid_link) -> TD
    mov dword [ebx + 4], 1
    call hid_arm_u
    jmp .lk
.o:
    mov eax, [h_mps + ebp*4]         ; OHCI: ED  addr | ep << 7 | S | MPS << 16
    shl eax, 16
    mov edx, [h_ep + ebp*4]
    shl edx, 7
    or eax, edx
    or eax, [u_addr]
    or eax, [u_ls]
    mov [ebx + 0x40], eax
    call hid_arm_o
.lk:
    mov dword [h_on + ebp*4], 1
    inc dword [hid_n]
    call hid_link
    cmp dword [h_proto + ebp*4], 2   ; the first mouse on a PC with no PS/2 mouse: show a cursor
    jne .ok
    cmp byte [mouse_present], 0
    jne .ok
    mov byte [mouse_present], 1
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
.ok:
    popad
    ret
.full:
    popad
    ret

hid_arm_u:                       ; EBP = device, EBX = its block: (re)queue one interrupt-IN TD
    push eax
    push edx
    mov dword [ebx + 0x20], 1        ; TD: no next
    mov eax, [h_ls + ebp*4]
    or eax, (3 << 27) | (1 << 23)    ; 3 retries, active
    mov [ebx + 0x24], eax
    mov eax, [h_len + ebp*4]         ; token: IN | addr | ep | toggle | length-1
    dec eax
    shl eax, 21
    or eax, 0x69
    mov edx, [h_addr + ebp*4]
    shl edx, 8
    or eax, edx
    mov edx, [h_ep + ebp*4]
    shl edx, 15
    or eax, edx
    mov edx, [h_tog + ebp*4]
    and edx, 1
    shl edx, 19
    or eax, edx
    mov [ebx + 0x28], eax
    lea eax, [ebx + 0xC0]
    mov [ebx + 0x2C], eax
    lea eax, [ebx + 0x20]
    mov [ebx + 4], eax               ; QH element -> the TD (last: now the chip sees it)
    pop edx
    pop eax
    ret

hid_arm_o:                       ; EBP = device, EBX = its block: (re)queue one TD on its ED
    push eax
    push ecx
    or dword [ebx + 0x40], 1 << 14   ; skip while we change it
    mov dword [ebx + 0x60], (2 << 19) | (1 << 18) | (7 << 21) | (0x0F << 28)
    lea eax, [ebx + 0xC0]
    mov [ebx + 0x64], eax            ; CBP
    lea eax, [ebx + 0x80]
    mov [ebx + 0x68], eax            ; next = the empty tail
    mov eax, [h_len + ebp*4]
    lea eax, [ebx + 0xC0 + eax - 1]
    mov [ebx + 0x6C], eax            ; BE
    xor eax, eax
    mov [ebx + 0x80], eax
    mov [ebx + 0x84], eax
    mov [ebx + 0x88], eax
    mov [ebx + 0x8C], eax
    lea eax, [ebx + 0x80]
    mov [ebx + 0x44], eax            ; TailP
    mov eax, [ebx + 0x48]
    and eax, 2                       ; keep the toggle carry
    lea ecx, [ebx + 0x60]
    or eax, ecx
    mov [ebx + 0x48], eax            ; HeadP
    and dword [ebx + 0x40], ~(1 << 14)
    pop ecx
    pop eax
    ret

hid_link:                        ; rebuild every controller's HID schedule
    pushad
    xor ecx, ecx
.c:
    cmp ecx, [u_nctl]
    jae .d
    cmp dword [u_kind + ecx*4], 1
    je .o
    mov esi, ecx                     ; UHCI: anchor -> HID QHs -> storage QH
    shl esi, 6
    add esi, UANC
    lea edx, [esi + 0x20]
    or edx, 2                        ; the storage QH (end of the chain)
    mov edi, esi                     ; previous
    xor ebp, ebp
.ul:
    cmp ebp, MAX_HID
    jae .ue
    cmp dword [h_on + ebp*4], 0
    je .un
    cmp [h_ctl + ebp*4], ecx
    jne .un
    mov ebx, ebp
    shl ebx, 8
    add ebx, HMEM
    mov [ebx], edx                   ; this QH -> storage (for now)
    mov eax, ebx
    or eax, 2
    mov [edi], eax                   ; previous -> this QH
    mov edi, ebx
.un:
    inc ebp
    jmp .ul
.ue:
    mov [edi], edx
    jmp .n
.o:
    xor edx, edx                     ; OHCI: chain the EDs, all 32 interrupt slots -> the first
    mov ebp, MAX_HID
.ol:
    dec ebp
    js .oe
    cmp dword [h_on + ebp*4], 0
    je .ol
    cmp [h_ctl + ebp*4], ecx
    jne .ol
    mov ebx, ebp
    shl ebx, 8
    add ebx, HMEM + 0x40
    mov [ebx + 12], edx
    mov edx, ebx
    jmp .ol
.oe:
    mov edi, ecx
    shl edi, 8
    add edi, OHCI_HCCA
    push ecx
    mov eax, edx
    mov ecx, 32
    rep stosd
    pop ecx
.n:
    inc ecx
    jmp .c
.d:
    popad
    ret

hid_remove:                      ; EBP = device (unplugged / broken)
    pushad
    mov ebx, ebp
    shl ebx, 8
    add ebx, HMEM
    mov dword [ebx + 4], 1           ; UHCI: nothing queued
    or dword [ebx + 0x40], 1 << 14   ; OHCI: skip
    mov dword [h_on + ebp*4], 0
    dec dword [hid_n]
    mov dword [rep_use], 0
    call hid_link
    popad
    ret

; called all the time from kbc_poll (only once USB is ours)
hid_poll:
    pushad
    xor ebp, ebp
.dv:
    cmp ebp, MAX_HID
    jae .rep
    cmp dword [h_on + ebp*4], 0
    je .nx
    mov ebx, ebp
    shl ebx, 8
    add ebx, HMEM
    mov edx, [h_port + ebp*4]        ; unplugged?
    cmp dword [h_kind + ebp*4], 1
    je .oc
    in ax, dx
    test ax, 1
    jz .gone
    mov eax, [ebx + 0x24]            ; UHCI: TD finished?
    test eax, 1 << 23
    jnz .nx
    test eax, 0x760000               ; error (NAK just means "nothing yet")
    jnz .uerr
    xor dword [h_tog + ebp*4], 1
    call hid_report
    jmp .uarm
.uerr:
    call hid_bad
    jc .nx
.uarm:
    call hid_arm_u
    jmp .nx
.oc:
    test dword [edx], 1
    jz .gone
    mov eax, [ebx + 0x48]            ; OHCI: ED emptied (or halted)?
    test eax, 1
    jnz .oerr
    and eax, ~0x0F
    lea ecx, [ebx + 0x80]
    cmp eax, ecx
    jne .nx
    mov eax, [ebx + 0x60]
    shr eax, 28
    jnz .oerr
    call hid_report
    jmp .oarm
.oerr:
    call hid_bad
    jc .nx
.oarm:
    call hid_arm_o
    jmp .nx
.gone:
    call hid_remove
.nx:
    inc ebp
    jmp .dv
.rep:
    cmp dword [rep_use], 0           ; key repeat (USB keyboards leave that to us)
    je .hp
    rdtsc
    sub eax, [rep_t0]
    cmp eax, [rep_wait]
    jb .hp
    rdtsc
    mov [rep_t0], eax
    mov eax, [tsc_per_ms]
    imul eax, 33
    mov [rep_wait], eax
    mov eax, [rep_use]
    xor bl, bl
    call hid_key
.hp:
    rdtsc                            ; twice a second: a keyboard / mouse plugged in?
    sub eax, [hp_t0]
    mov ecx, [tsc_per_ms]
    imul ecx, 500
    cmp eax, ecx
    jb .out
    rdtsc
    mov [hp_t0], eax
    call hid_hotplug
.out:
    popad
    ret

hid_bad:                         ; a failed poll: CF = 1 if the device was dropped
    inc dword [h_err + ebp*4]
    cmp dword [h_err + ebp*4], 200
    jb .k
    call hid_remove
    stc
    ret
.k:
    clc
    ret

hid_report:                      ; EBP = device, report at EBX + 0xC0
    mov dword [h_err + ebp*4], 0
    cmp dword [h_proto + ebp*4], 2
    je .mouse
    ; ---- keyboard: modifiers byte, reserved, 6 key usages
    cmp byte [ebx + 0xC2], 1         ; "too many keys" report
    je .r
    pushad
    mov esi, ebx
    movzx eax, byte [esi + 0xC0]     ; modifier bits that changed
    movzx edx, byte [esi + 0xE0]
    xor edx, eax
    xor ecx, ecx
.mb:
    bt edx, ecx
    jnc .mn
    mov bl, 0x80
    bt eax, ecx
    jnc .mk
    xor bl, bl
.mk:
    push eax
    movzx eax, word [hid_modsc + ecx*2]
    call hid_sc
    pop eax
.mn:
    inc ecx
    cmp ecx, 8
    jb .mb
    xor ecx, ecx                     ; released keys
.rb:
    movzx eax, byte [esi + 0xE2 + ecx]
    cmp eax, 4
    jb .rn
    lea edi, [esi + 0xC2]
    call hid_in6
    jz .rn
    cmp eax, [rep_use]
    jne .rnr
    mov dword [rep_use], 0
.rnr:
    mov bl, 0x80
    call hid_key
.rn:
    inc ecx
    cmp ecx, 6
    jb .rb
    xor ecx, ecx                     ; newly pressed keys
.pb:
    movzx eax, byte [esi + 0xC2 + ecx]
    cmp eax, 4
    jb .pn
    lea edi, [esi + 0xE2]
    call hid_in6
    jz .pn
    xor bl, bl
    call hid_key
    mov [rep_use], eax               ; held -> repeats after 0.5 s
    push eax
    rdtsc
    mov [rep_t0], eax
    mov eax, [tsc_per_ms]
    imul eax, 500
    mov [rep_wait], eax
    pop eax
.pn:
    inc ecx
    cmp ecx, 6
    jb .pb
    mov eax, [esi + 0xC0]            ; remember this report
    mov [esi + 0xE0], eax
    mov eax, [esi + 0xC4]
    mov [esi + 0xE4], eax
    popad
.r:
    ret
.mouse:                              ; ---- mouse: buttons, dx, dy  ->  a PS/2 packet
    pushad
    movzx ecx, byte [ebx + 0xC0]
    and ecx, 7
    or ecx, 8
    movsx eax, byte [ebx + 0xC1]
    movsx edx, byte [ebx + 0xC2]
    neg edx                          ; PS/2 counts "up" as positive
    cmp edx, 127
    jle .y
    mov edx, 127
.y:
    test eax, eax
    jns .xs
    or ecx, 0x10
.xs:
    test edx, edx
    jns .ys
    or ecx, 0x20
.ys:
    mov ah, 2
    push eax
    mov al, cl
    call kq_push
    pop eax
    call kq_push
    mov al, dl
    call kq_push
    popad
    ret

hid_in6:                         ; is usage EAX in the 6 bytes at EDI?  ZF = 1 yes
    push ecx
    xor ecx, ecx
.l:
    cmp al, [edi + ecx]
    je .y
    inc ecx
    cmp ecx, 6
    jb .l
    or ecx, 1                        ; ZF = 0 (not there)
.y:
    pop ecx
    ret

hid_key:                         ; EAX = key usage, BL = 0 press / 0x80 release
    cmp eax, 0x65
    ja .r
    push eax
    movzx eax, word [hid_sc1 + eax*2]
    test eax, eax
    jz .p
    call hid_sc
.p:
    pop eax
.r:
    ret

hid_sc:                          ; AX = set-1 code (AH = 1: E0 prefix), BL = 0x80 for release
    push eax
    test ah, ah
    jz .n
    push eax
    mov al, 0xE0
    mov ah, 1
    call kq_push
    pop eax
.n:
    or al, bl
    mov ah, 1
    call kq_push
    pop eax
    ret

kq_push:                         ; AL = byte, AH = 1 key / 2 mouse
    push ebx
    push ecx
    movzx ebx, byte [kq_h]
    lea ecx, [ebx + 1]
    and ecx, 127
    cmp cl, [kq_t]
    je .full
    mov [kq_d + ebx], al
    mov [kq_k + ebx], ah
    mov [kq_h], cl
.full:
    pop ecx
    pop ebx
    ret

; the one place every input loop reads from:  ZF = 1 nothing;  else AL = byte, AH = 1 key / 2 mouse
kbc_poll:
    cmp dword [usb_active], 0
    je .hw
    call hid_poll
    push ebx
    movzx ebx, byte [kq_t]
    cmp bl, [kq_h]
    je .hwp
    mov al, [kq_d + ebx]
    mov ah, [kq_k + ebx]
    inc bl
    and bl, 127
    mov [kq_t], bl
    pop ebx
    test ah, ah                      ; ZF = 0
    ret
.hwp:
    pop ebx
.hw:
    in al, 0x64
    test al, 1
    jz .none
    mov ah, 1
    cmp byte [mouse_present], 0
    je .rd
    test al, 0x20
    jz .rd
    mov ah, 2
.rd:
    in al, 0x60
    test ah, ah                      ; ZF = 0
    ret
.none:
    xor ah, ah                       ; ZF = 1
    ret

hid_hotplug:                     ; a newly plugged USB keyboard / mouse -> start it (4 tries per port)
    pushad
    cmp dword [usb_ready], 0
    je .c0
    call ctx_save                    ; (the globals are the stick's right now)
.c0:
    xor ecx, ecx
.c:
    cmp ecx, [u_nctl]
    jae .d
    call ctl_select
    xor ebx, ebx
.p:
    cmp ebx, [u_np]
    jae .nc
    cmp dword [u_kcur], 1
    je .o
    in ax, dx                        ; UHCI: connect status change?
    test ax, 2
    jz .np
    test ax, 1
    jz .clru
    jmp .chk
.clru:
    and ax, 0x000E
    or ax, 0x0002
    out dx, ax
    jmp .np
.o:
    mov eax, [edx]
    test eax, 1 << 16
    jz .np
    test eax, 1
    jnz .chk
    mov dword [edx], 1 << 16
    jmp .np
.chk:
    call port_owned
    jnz .clr
    mov eax, ecx
    shl eax, 4
    add eax, ebx
    cmp byte [hp_tries + eax], 4
    jae .clr
    inc byte [hp_tries + eax]
    mov [u_ctl], ecx
    mov [u_port], ebx
    mov [u_portreg], edx
    mov dword [u_hidonly], 1         ; (sticks wait until Files asks)
    push ecx
    push edx
    push ebx
    call usb_attach
    pop ebx
    pop edx
    pop ecx
    mov dword [u_hidonly], 0
    cmp dword [usb_ready], 0
    je .clr
    call ctx_load
    call ctl_select                  ; (ctx_load changed the current controller)
    push ecx
    mov ecx, ebx
.adv:
    jecxz .advd
    add edx, [u_pstep]
    dec ecx
    jmp .adv
.advd:
    pop ecx
.clr:
    cmp dword [u_kcur], 1
    je .clro
    in ax, dx
    and ax, 0x000E
    or ax, 0x0002
    out dx, ax
    jmp .np
.clro:
    mov dword [edx], 1 << 16
.np:
    add edx, [u_pstep]
    inc ebx
    jmp .p
.nc:
    inc ecx
    jmp .c
.d:
    cmp dword [usb_ready], 0
    je .x
    call ctx_load
.x:
    popad
    ret

; HID usage -> scan code set 1 (high byte 1 = E0 prefix)
hid_sc1:
    dw 0, 0, 0, 0
    dw 0x1E, 0x30, 0x2E, 0x20, 0x12, 0x21, 0x22, 0x23, 0x17, 0x24, 0x25, 0x26, 0x32, 0x31   ; a..n
    dw 0x18, 0x19, 0x10, 0x13, 0x1F, 0x14, 0x16, 0x2F, 0x11, 0x2D, 0x15, 0x2C               ; o..z
    dw 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B                           ; 1..0
    dw 0x1C, 0x01, 0x0E, 0x0F, 0x39, 0x0C, 0x0D, 0x1A, 0x1B, 0x2B, 0x2B, 0x27, 0x28, 0x29   ; Enter..`
    dw 0x33, 0x34, 0x35, 0x3A                                                               ; , . / Caps
    dw 0x3B, 0x3C, 0x3D, 0x3E, 0x3F, 0x40, 0x41, 0x42, 0x43, 0x44, 0x57, 0x58               ; F1..F12
    dw 0x137, 0x46, 0, 0x152, 0x147, 0x149, 0x153, 0x14F, 0x151, 0x14D, 0x14B, 0x150, 0x148 ; PrtSc..Up
    dw 0x45, 0x135, 0x37, 0x4A, 0x4E, 0x11C, 0x4F, 0x50, 0x51, 0x4B, 0x4C, 0x4D, 0x47, 0x48 ; keypad
    dw 0x49, 0x52, 0x53, 0x56, 0x15D                                                        ; KP9 KP0 KP. \ Menu
hid_modsc:
    dw 0x1D, 0x2A, 0x38, 0x15B, 0x11D, 0x36, 0x138, 0x15C

; ---------------- state ----------------
usb_active:   dd 0              ; our driver owns the USB chips
u_inited:     dd 0
u_flb:        dd 0
u_qhs:        dd UANC + 0x20
u_nextaddr:   dd 1
u_hidonly:    dd 0
s_u_kcur:     dd 0
s_u_iob:      dd 0
s_u_qhs:      dd 0
s_u_portreg:  dd 0
s_portreg     equ s_u_portreg
s_u_ctl:      dd 0
s_u_port:     dd 0
s_u_addr:     dd 0
s_u_mp0:      dd 0
s_u_ls:       dd 0
s_u_ep_in:    dd 0
s_u_ep_out:   dd 0
s_u_mp_in:    dd 0
s_u_mp_out:   dd 0
s_u_tog_in:   dd 0
s_u_tog_out:  dd 0
s_usb_part:   dd 0
s_usb_last_lba: dd 0
hid_n:        dd 0
h_on:         times MAX_HID dd 0
h_proto:      times MAX_HID dd 0
h_kind:       times MAX_HID dd 0
h_ctl:        times MAX_HID dd 0
h_port:       times MAX_HID dd 0
h_addr:       times MAX_HID dd 0
h_ep:         times MAX_HID dd 0
h_len:        times MAX_HID dd 0
h_mps:        times MAX_HID dd 0
h_ls:         times MAX_HID dd 0
h_tog:        times MAX_HID dd 0
h_err:        times MAX_HID dd 0
hc_n:         dd 0
hc_boot:      dd 0
hc_proto:     dd 0
hc_if:        dd 0
hc_cp:        dd 0, 0
hc_ci:        dd 0, 0
hc_ce:        dd 0, 0
hc_cm:        dd 0, 0
rep_use:      dd 0
rep_t0:       dd 0
rep_wait:     dd 0
hp_t0:        dd 0
hp_tries:     times MAX_UHCI * 16 db 0
kq_h:         db 0
kq_t:         db 0
kq_d:         times 128 db 0
kq_k:         times 128 db 0
sp_setproto:  db 0x21, 0x0B, 0, 0, 0, 0, 0, 0
sp_setidle:   db 0x21, 0x0A, 0, 0, 0, 0, 0, 0
usb_ready:    dd 0              ; a FAT32 stick is attached and readable
usb_part:     dd 0              ; its FAT32 partition's first LBA
usb_last_lba: dd 0
u_nctl:       dd 0
u_io:         times MAX_UHCI dd 0
u_kind:       times MAX_UHCI dd 0   ; 0 = UHCI, 1 = OHCI
u_kcur:       dd 0
u_np:         dd 2
u_pstep:      dd 2
u_mf:         dd 0
u_ob:         dd 0
u_hcca:       dd 0
u_otail:      dd 0
u_pci:        times MAX_UHCI dd 0
u_pa:         dd 0
u_ea:         dd 0
u_ebar:       dd 0
u_eecp:       dd 0
u_ctl:        dd 0
u_port:       dd 0
u_portreg:    dd 0
u_iob:        dd 0
u_result:     dd 0
u_best:       dd 0
u_seen:       dd 0
u_step:       dd 0
u_at:         dd 0
nt_usb_diag:  times 48 db 0
u_ls:         dd 0
u_addr:       dd 0
u_mp0:        dd 8
u_ep_in:      dd 0
u_ep_out:     dd 0
u_mp_in:      dd 64
u_mp_out:     dd 64
u_bmp:        dd 64
u_tog_in:     dd 0
u_tog_out:    dd 0
u_pid:        db 0
u_clen:       dd 0
u_left:       dd 0
u_ntd:        dd 0
u_last:       dd 0
u_tmo:        dd 0
u_tag:        dd 0
u_xlen:       dd 0
u_try:        dd 0
u_try2:       dd 0
u_rlba:       dd 0
u_rdst:       dd 0
cb_buf:       times 16 db 0
sp_getdev8:   db 0x80, 6, 0, 1, 0, 0, 8, 0
sp_setaddr:   db 0x00, 5, 1, 0, 0, 0, 0, 0
sp_getcfg9:   db 0x80, 6, 0, 2, 0, 0, 9, 0
sp_getcfg:    db 0x80, 6, 0, 2, 0, 0, 0, 0
sp_setcfg:    db 0x00, 9, 1, 0, 0, 0, 0, 0
nt_usb_none1: db "No USB drive found", 0
nt_usb_none2: db "Plug one in, then try again", 0
nt_usb_out1:  db "USB drive removed", 0
nt_usb_out2:  db "It's safe - it was read-only", 0
nt_usb_fmt1:  db "USB drive not readable", 0
nt_usb_fmt2:  db "NovaOS needs a FAT32 stick", 0
nt_usb_dev1:  db "USB device connected", 0
nt_usb_dev2:  db "It isn't a storage drive", 0
nt_usb_bad1:  db "USB drive didn't respond", 0
nt_usb_bad2:  db "Unplug it and try again", 0

; ---------------- Files app: browse the stick as a second, read-only volume ----------------
fm_mount:                        ; point the FAT code at the volume Files is showing
    push eax
    mov eax, [fm_vol]
    mov [vol], eax
    pop eax
    jmp fat_mount
fm_unmount:                      ; ...and back at the system disk for everything else
    push eax
    mov dword [vol], 0
    call fat_mount
    pop eax
    ret
fm_use_usb:
    pushad
    cmp dword [usb_ready], 0
    je .r
    mov dword [fm_vol], 1
    call fm_mount
    mov eax, [fs_rootclus]
    mov [cwd_cluster], eax
    mov [fm_usb_root], eax
    mov eax, [sys_cluster]           ; the disk's SYSTEM cluster number means nothing on the stick
    mov [fm_sys_s], eax
    mov dword [sys_cluster], -1
    call fm_unmount
    mov dword [files_dirty], 1
.r:
    popad
    ret
fm_use_disk:
    pushad
    cmp dword [fm_vol], 0
    je .r
    mov dword [fm_vol], 0
    mov eax, [fm_sys_s]
    mov [sys_cluster], eax
    call fm_unmount
    mov eax, [fs_rootclus]
    mov [cwd_cluster], eax
    mov dword [files_dirty], 1
.r:
    popad
    ret
vol:          dd 0              ; 0 = system disk (BIOS), 1 = USB stick (our driver)
fm_vol:       dd 0              ; which volume the Files window shows
fm_usb_root:  dd 0
fm_trash_s:   dd 0
fm_sys_s:     dd 0
fm_usb_lbl:   db "USB Drive", 0
fm_usb_ref:   db "Refresh", 0
fm_usb_ro:    db "USB drive (read-only)", 0
nt_usbro1:    db "The USB drive is read-only", 0
nt_usbro2:    db "Copy files to the disk first", 0

usb_diag_text:                   ; -> ESI = "chips 6 / plugged 2 / step 2"
    push eax
    push edi
    mov edi, nt_usb_diag
    mov esi, .s1
    call .cp
    mov eax, [u_nctl]
    call num_to_str
    mov esi, .s2
    call .cp
    mov eax, [u_seen]
    call num_to_str
    mov esi, .s3
    call .cp
    mov eax, [u_step]
    call num_to_str
    mov byte [edi], 0
    pop edi
    pop eax
    mov esi, nt_usb_diag
    ret
.cp:
    lodsb
    test al, al
    jz .cpd
    stosb
    jmp .cp
.cpd:
    ret
.s1: db "chips ", 0
.s2: db " / plugged ", 0
.s3: db " / step ", 0
