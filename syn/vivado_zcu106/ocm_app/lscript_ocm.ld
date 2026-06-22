/*
 * Linker Script for ZCU106 OCM-only baremetal application.
 *
 * Places all sections in A53 on-chip memory so the first bring-up path does not
 * depend on DDR being initialized. Keep Vitis standalone boot/vector sections at
 * the start of OCM; otherwise XSDB may start in a C runtime helper instead of
 * the ARMv8 boot code.
 */

ENTRY(_vector_table)

_STACK_SIZE = 0x4000;
_HEAP_SIZE  = 0x4000;
_stack_size = _STACK_SIZE;
_heap_size  = _HEAP_SIZE;

MEMORY
{
    psu_ocm_ram_0 (rwx) : ORIGIN = 0xFFFC0000, LENGTH = 0x00040000
}

SECTIONS
{
    .text : {
        . = ALIGN(2048);
        KEEP(*(.vectors))
        KEEP(*(.boot))
        *(.text)
        *(.text.*)
        *(.gnu.linkonce.t.*)
    } > psu_ocm_ram_0

    .init : {
        KEEP(*(.init))
    } > psu_ocm_ram_0

    .fini : {
        KEEP(*(.fini))
    } > psu_ocm_ram_0

    .rodata : {
        . = ALIGN(8);
        __rodata_start = .;
        *(.rodata)
        *(.rodata.*)
        *(.gnu.linkonce.r.*)
        __rodata_end = .;
    } > psu_ocm_ram_0

    .eh_frame : {
        . = ALIGN(8);
        __eh_frame_start = .;
        KEEP(*(.eh_frame))
        KEEP(*(.eh_frame.*))
        __eh_frame_end = .;
    } > psu_ocm_ram_0

    .init_array : {
        . = ALIGN(8);
        __preinit_array_start = .;
        KEEP(*(SORT(.preinit_array.*)))
        KEEP(*(.preinit_array))
        __preinit_array_end = .;
        __init_array_start = .;
        KEEP(*(SORT(.init_array.*)))
        KEEP(*(.init_array))
        __init_array_end = .;
    } > psu_ocm_ram_0

    .fini_array : {
        . = ALIGN(8);
        __fini_array_start = .;
        KEEP(*(SORT(.fini_array.*)))
        KEEP(*(.fini_array))
        __fini_array_end = .;
    } > psu_ocm_ram_0

    .data : {
        . = ALIGN(8);
        __data_start = .;
        __data1_start = .;
        __sdata_start = .;
        *(.data)
        *(.data.*)
        *(.data1)
        *(.sdata)
        *(.sdata.*)
        *(.gnu.linkonce.d.*)
        *(.got)
        *(.got.plt)
        __data_end = .;
    } > psu_ocm_ram_0

    .bss (NOLOAD) : {
        . = ALIGN(64);
        __sbss_start = .;
        __bss_start__ = .;
        *(.sbss)
        *(.sbss.*)
        *(.scommon)
        *(.bss)
        *(.bss.*)
        *(.gnu.linkonce.b.*)
        *(COMMON)
        . = ALIGN(64);
        __sbss_end = .;
        __bss_end__ = .;
    } > psu_ocm_ram_0

    .heap (NOLOAD) : {
        . = ALIGN(16);
        _heap = .;
        _heap_start = .;
        . += _HEAP_SIZE;
        _heap_end = .;
    } > psu_ocm_ram_0

    .stack (NOLOAD) : {
        . = ALIGN(16);
        _el3_stack_end = .;
        _stack_end = .;
        . += _STACK_SIZE;
        _stack = .;
        __stack = .;
        __el3_stack = .;
        __el2_stack = .;
        __el1_stack = .;
        __el0_stack = .;
    } > psu_ocm_ram_0

    .mmu_tbl0 : {
        . = ALIGN(4096);
        __mmu_tbl0_start = .;
        KEEP(*(.mmu_tbl0))
        . = ALIGN(4096);
    } > psu_ocm_ram_0

    .mmu_tbl1 : {
        . = ALIGN(4096);
        __mmu_tbl1_start = .;
        KEEP(*(.mmu_tbl1))
        . = ALIGN(4096);
    } > psu_ocm_ram_0

    .mmu_tbl2 : {
        . = ALIGN(4096);
        __mmu_tbl2_start = .;
        KEEP(*(.mmu_tbl2))
        . = ALIGN(4096);
    } > psu_ocm_ram_0

    _end = .;

    /DISCARD/ : {
        *(.comment)
        *(.note*)
    }
}
