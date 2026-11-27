; SPI controller, mode 0, MSB first, full duplex, one byte.
; P0=SCLK, P1=MOSI, P2=MISO, P3=active-low CS.
; At 125 MHz, each half-period is 64 clocks / 512 ns: 976.5625 kHz.
; Reference for the manually encoded spi_mode0.hex; no assembler is required.
SHIFT_OUT R0, P3, HIGH           ; Deselect before initializing SCLK
SHIFT_OUT R0, P0, LOW
SHIFT_OUT R0, P1, LOW
SET_DIR LEFT
MOV R0, 0xA5
MOV R1, 0x00
WAIT_C 64                       ; T is the HALF-period; both waits use FULL
WAIT FULL                       ; Establish timing reference
SHIFT_OUT R0, P3, LOW

bits:
    SHIFT_OUT R0, P1, SHIFT
    WAIT FULL
    SHIFT_OUT R0, P0, HIGH       ; Peripheral samples MOSI
    SHIFT_IN R1, P2             ; Read synchronized, previously stable MISO
    WAIT FULL
    SHIFT_OUT R0, P0, LOW        ; Peripheral prepares its next MISO bit
    LOOP 8, bits

WAIT FULL                       ; Hold CS through the final trailing edge
SHIFT_OUT R0, P3, HIGH
done:
    JMP done
