; Single-controller I2C: write a byte, repeated START, read two bytes.
; P0=SCL, P1=SDA. External pull-ups to 3.3 V are required on the bus.
; Seven-bit target address 0x50: wire address A0 for write, A1 for read.
; At 125 MHz, T=625 gives at least 5 us LOW/HIGH phases (about 100 kHz).
; WAIT_PIN accounts for rise time and target clock stretching, then rebases
; the following HIGH interval. R0/R1 retain the two received bytes.
; P2 marks success; P3 marks target NACK. Both remain asserted until reset.
; Reference for the manually encoded i2c_write_read.hex; no assembler needed.

PIN_MODE 0x03
SET_DIR LEFT
WAIT_C 625
SHIFT_OUT R0, P1, HIGH          ; Open-drain logical HIGH releases SDA
SHIFT_OUT R0, P0, HIGH          ; Release SCL
WAIT_PIN P1, HIGH
WAIT_PIN P0, HIGH
WAIT FULL
SHIFT_OUT R0, P1, LOW           ; START
WAIT FULL
SHIFT_OUT R0, P0, LOW

MOV R0, 0xA0
write_address_bits:
    SHIFT_OUT R0, P1, SHIFT
    WAIT FULL
    SHIFT_OUT R0, P0, HIGH
    WAIT_PIN P0, HIGH
    WAIT FULL
    SHIFT_OUT R0, P0, LOW
    LOOP 8, write_address_bits
SHIFT_OUT R0, P1, HIGH
WAIT FULL
SHIFT_OUT R0, P0, HIGH
WAIT_PIN P0, HIGH
BRANCH_PIN P1, HIGH, nack
WAIT FULL
SHIFT_OUT R0, P0, LOW

MOV R0, 0x10
write_data_bits:
    SHIFT_OUT R0, P1, SHIFT
    WAIT FULL
    SHIFT_OUT R0, P0, HIGH
    WAIT_PIN P0, HIGH
    WAIT FULL
    SHIFT_OUT R0, P0, LOW
    LOOP 8, write_data_bits
SHIFT_OUT R0, P1, HIGH
WAIT FULL
SHIFT_OUT R0, P0, HIGH
WAIT_PIN P0, HIGH
BRANCH_PIN P1, HIGH, nack
WAIT FULL
SHIFT_OUT R0, P0, LOW

SHIFT_OUT R0, P1, HIGH
WAIT FULL
SHIFT_OUT R0, P0, HIGH
WAIT_PIN P0, HIGH
WAIT FULL
SHIFT_OUT R0, P1, LOW           ; Repeated START
WAIT FULL
SHIFT_OUT R0, P0, LOW

MOV R0, 0xA1
read_address_bits:
    SHIFT_OUT R0, P1, SHIFT
    WAIT FULL
    SHIFT_OUT R0, P0, HIGH
    WAIT_PIN P0, HIGH
    WAIT FULL
    SHIFT_OUT R0, P0, LOW
    LOOP 8, read_address_bits
SHIFT_OUT R0, P1, HIGH
WAIT FULL
SHIFT_OUT R0, P0, HIGH
WAIT_PIN P0, HIGH
BRANCH_PIN P1, HIGH, nack
WAIT FULL
SHIFT_OUT R0, P0, LOW

MOV R1, 0x5A                   ; Eight samples replace this seed completely
SHIFT_OUT R0, P1, HIGH
read_first_bits:
    WAIT FULL
    SHIFT_OUT R0, P0, HIGH
    WAIT_PIN P0, HIGH
    SHIFT_IN R1, P1
    WAIT FULL
    SHIFT_OUT R0, P0, LOW
    LOOP 8, read_first_bits
SHIFT_OUT R0, P1, LOW           ; Controller ACK: request another byte
WAIT FULL
SHIFT_OUT R0, P0, HIGH
WAIT_PIN P0, HIGH
WAIT FULL
SHIFT_OUT R0, P0, LOW
SHIFT_OUT R0, P1, HIGH
MOV R0, R1                     ; Save first byte

MOV R1, 0x5A
SHIFT_OUT R0, P1, HIGH
read_second_bits:
    WAIT FULL
    SHIFT_OUT R0, P0, HIGH
    WAIT_PIN P0, HIGH
    SHIFT_IN R1, P1
    WAIT FULL
    SHIFT_OUT R0, P0, LOW
    LOOP 8, read_second_bits
SHIFT_OUT R0, P1, HIGH          ; Controller NACK: final byte
WAIT FULL
SHIFT_OUT R0, P0, HIGH
WAIT_PIN P0, HIGH
WAIT FULL
SHIFT_OUT R0, P0, LOW
SHIFT_OUT R0, P1, HIGH

SHIFT_OUT R0, P0, LOW
SHIFT_OUT R0, P1, LOW
WAIT FULL
SHIFT_OUT R0, P0, HIGH
WAIT_PIN P0, HIGH
WAIT FULL
SHIFT_OUT R0, P1, HIGH          ; STOP
WAIT FULL
SHIFT_OUT R0, P2, HIGH
done:
    JMP done

nack:
    WAIT FULL                  ; Finish ninth-clock HIGH before lowering SCL
    SHIFT_OUT R0, P0, LOW
    SHIFT_OUT R0, P1, LOW
    WAIT FULL
    SHIFT_OUT R0, P0, HIGH
    WAIT_PIN P0, HIGH
    WAIT FULL
    SHIFT_OUT R0, P1, HIGH      ; STOP on target NACK
    WAIT FULL
    SHIFT_OUT R0, P3, HIGH
failed:
    JMP failed
