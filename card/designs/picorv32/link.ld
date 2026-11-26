MEMORY { ram : ORIGIN = 0, LENGTH = 8K }
SECTIONS {
    .text : { *(.text.start) *(.text*) *(.rodata*) } > ram
    .data : { *(.data*) *(.sdata*) } > ram
    .bss : { . = ALIGN(4); _bss_start = .; *(.bss*) *(.sbss*) *(COMMON) . = ALIGN(4); _bss_end = .; } > ram
}
