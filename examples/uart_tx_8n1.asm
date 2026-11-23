; UART TX on P0: 0x55, least-significant bit first, 8N1.
; 100 MHz clock / 868 clocks per bit = approximately 115200 baud.
; Reference source for uart_tx_8n1.hex; the repository has no assembler yet.
WAIT_C 868
SET_DIR RIGHT
MOV R0, 0x55

WAIT FULL                       ; Establish the first timing reference
SHIFT_OUT R0, P0, HIGH           ; Idle for one complete bit period
WAIT FULL
SHIFT_OUT R0, P0, LOW            ; Start bit

tx_bits:
    WAIT FULL
    SHIFT_OUT R0, P0, SHIFT      ; Send old R0[0], then shift R0 right
    LOOP 8, tx_bits

WAIT FULL
SHIFT_OUT R0, P0, HIGH           ; Stop bit
WAIT FULL
SHIFT_OUT R0, P0, HIGH           ; Finish the full stop interval, remain idle

done:
    JMP done
