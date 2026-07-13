/*
 * SPDX-License-Identifier: Apache-2.0
 * Derived from the CROC platform (ETH Zurich / University of Bologna), Apache-2.0.
 * Adapted for the MX fault-injection artifact by:
 *   Dillibabu Shanmugam, Patrick Schaumont - Worcester Polytechnic Institute (WPI), USA
 */

/* Copyright (c) 2024 ETH Zurich and University of Bologna.
 * Licensed under the Apache License, Version 2.0, see LICENSE for details.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Authors:
 * - Paul Scheffler <paulsc@iis.ee.ethz.ch>
 * - Philippe Sauter <phsauter@iis.ee.ethz.ch> 
 */

OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
   IMEM (rxail)  : ORIGIN = 0x10000000, LENGTH = 4K   /* Bank 0: instruction memory */
   DMEM (rwail)  : ORIGIN = 0x10001000, LENGTH = 4K   /* Bank 1: data memory */
}

SECTIONS
{
  /DISCARD/ : { *(.riscv.attributes) *(.comment) }

  /* Code in IMEM (Bank 0) */
  .text._start : {
      *(.text._start)
  } >IMEM

  .text : ALIGN(4) {
      *(.text)
      *(.text.*)
  } >IMEM

  /* Data in DMEM (Bank 1) */
  .misc : ALIGN(4) {
      *(.sdata)
      *(.sbss)
      *(.*data*)
      *(.*bss*)
      *(COMMON)
  } >DMEM

  .rodata : ALIGN(4) {
      *(.rodata)
      *(.rodata.*)
      *(.srodata)
      *(.srodata.*)
  } >DMEM
}

/* Global absolute symbols */
PROVIDE(__global_pointer$ = ADDR(.misc) + SIZEOF(.misc)/2);
PROVIDE(__stack_pointer$ = ORIGIN(DMEM) + LENGTH(DMEM));
PROVIDE(status = 0x03000008);
