// Runtime pointers live in writable data. No instructions change after signing.
.section __TEXT,__text,regular,pure_instructions
.p2align 2
.globl _madeira_signed_probe_entry
_madeira_signed_probe_entry:
    adrp x8, _madeira_signed_probe_slots@PAGE
    add x8, x8, _madeira_signed_probe_slots@PAGEOFF
    ldp x9, x10, [x8]
    add x0, x0, x9
    br x10
.globl _madeira_signed_probe_entry_end
_madeira_signed_probe_entry_end:

.section __DATA,__data
.p2align 3
.globl _madeira_signed_probe_slots
_madeira_signed_probe_slots:
    .quad 0
    .quad 0
