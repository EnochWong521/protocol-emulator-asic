; UART RX on P1, 8N1, 100 MHz / 868 clocks per bit.
; R1 accumulates data; R0 retains the last valid byte.
; P2 is a sticky valid-frame marker; P3 is a sticky framing-error marker.
; No DATA_IO/PUSH is used: host transport remains unimplemented.
WAIT_C 868
SET_DIR RIGHT
rx_start:
    WAIT_PIN P1, FALLING
    WAIT HALF
    BRANCH_PIN P1, HIGH, rx_start ; Reject a false start
rx_bits:
    WAIT FULL
    SHIFT_IN R1, P1
    LOOP 8, rx_bits
    WAIT FULL
    BRANCH_PIN P1, LOW, framing_error
    MOV R0, R1
    SHIFT_OUT R0, P2, HIGH
    JMP rx_start
framing_error:
    SHIFT_OUT R0, P3, HIGH
    WAIT_PIN P1, HIGH
    JMP rx_start
