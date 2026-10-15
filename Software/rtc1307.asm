	TITLE	RTC - DS1307 real-time clock via PCF8584 I2C controller
;
; RTC.MAC - program for CP/M 2.2 / 3.0, Z80 CPU, ZSM4 assembler
;
; Reads and sets the date/time of a DS1307 RTC connected to
; an I2C bus driven by a PCF8584 controller.
;
; Usage:
;   RTC                         - show date and time
;   RTC yyyy-mm-dd              - set date (ISO 8601, yy also accepted)
;   RTC hh:mm:ss                - set time (24h, seconds optional)
;   RTC yyyy-mm-dd hh:mm:ss     - set date and time
;   RTC ?                       - help
; Day of week is calculated automatically (1=Mon ... 7=Sun).
; The clock is operated in 24h mode only.
;
; Assembly (example):
;   ZSM4 =RTC
;   L80 RTC,RTC/N/E          (or DRLINK RTC)
;
	.Z80
	ASEG
	ORG	100H

; ------------------------------------------------------------------
; HARDWARE CONFIGURATION - adjust to your board
; ------------------------------------------------------------------
PCFBAS	EQU	40H		; PCF8584 I/O base address
PCFS0	EQU	PCFBAS		; A0=0 : register S0 (data / S0' / S2)
PCFS1	EQU	PCFBAS+1	; A0=1 : register S1 (control/status)
PCFOWN	EQU	55H		; PCF8584 own address (S0')
;
; Register S2: bits 4..2 = chip clock, bits 1..0 = SCL frequency
;   clock: 000=3MHz 100=4.43MHz 101=6MHz 110=8MHz 111=12MHz
;   SCL  : 00=90kHz 01=45kHz 10=11kHz 11=1.5kHz
PCFCLK	EQU	1CH		; 12 MHz, SCL = 90 kHz (DS1307 max 100kHz)

; ------------------------------------------------------------------
; PCF8584 register S1 bits
; ------------------------------------------------------------------
I2PIN	EQU	80H		; PIN
I2ES0	EQU	40H		; ES0 - serial interface enable
I2ES1	EQU	20H		; ES1 - S2/S3 select
I2STA	EQU	04H		; START
I2STO	EQU	02H		; STOP
I2ACK	EQU	01H		; ACK
; status bits
I2BER	EQU	10H		; bus error
I2LRB	EQU	08H		; last received bit (1 = no ACK)
I2LAB	EQU	02H		; lost arbitration
I2NBB	EQU	01H		; /BB (1 = bus free)

CIDLE	EQU	I2PIN+I2ES0+I2ACK		; C1h - idle
CSTART	EQU	I2PIN+I2ES0+I2STA+I2ACK	; C5h - START + address
CSTOP	EQU	I2PIN+I2ES0+I2STO+I2ACK	; C3h - STOP
CRSTA	EQU	I2ES0+I2STA+I2ACK		; 45h - repeated START
CNACK	EQU	I2ES0				; 40h - next byte without ACK

DS1307	EQU	0D0H		; DS1307 address (write), +1 = read
; ------------------------------------------------------------------
BDOS	EQU	0005H
; ------------------------------------------------------------------
; ASCII Characters
CR	EQU	0DH
LF	EQU	0AH

; ==================================================================
; MAIN PROGRAM
; ==================================================================
START:	LD	(OLDSP),SP	; Save CP/M SP, create local stack
	LD	SP,STACK
; terminate the command tail (80h) with a zero byte
	LD	HL,80H
	LD	E,(HL)
	LD	D,0
	INC	HL
	PUSH	HL
	ADD	HL,DE
	LD	(HL),0
	POP	HL
	XOR	A
	LD	(FLAGS),A
	CALL	SKIPSP
	CP	'?'
	JP	Z,HELP
	CP	'/'
	JP	Z,HELP
; parse arguments
PLOOP:	CALL	SKIPSP
	OR	A
	JR	Z,PDONE
	CALL	PTOKEN
	JP	C,ERRSYN
	JR	PLOOP
; validate date
PDONE:	LD	A,(FLAGS)
	BIT	1,A
	JR	Z,PD1
	LD	A,(VMON)
	DEC	A
	CP	12
	JP	NC,ERRDAT	; month outside 1..12
	CALL	MDAYS
	LD	B,A
	LD	A,(VDATE)
	DEC	A
	CP	B
	JP	NC,ERRDAT	; day outside 1..month length
; initialize PCF8584
PD1:	CALL	I2CINIT
	JP	C,ERRPCF
	LD	A,(FLAGS)
	OR	A
	JR	Z,SHOW		; no arguments - read only
; --- prepare date data (registers 3..6) ---
	BIT	1,A
	JR	Z,PD2
	CALL	CALCDOW
	LD	A,(VDOW)
	LD	(REGBUF+3),A
	LD	A,(VDATE)
	CALL	BIN2BCD
	LD	(REGBUF+4),A
	LD	A,(VMON)
	CALL	BIN2BCD
	LD	(REGBUF+5),A
	LD	A,(VYEAR)
	CALL	BIN2BCD
	LD	(REGBUF+6),A
; --- prepare time data (registers 0..2) ---
PD2:	LD	A,(FLAGS)
	BIT	0,A
	JR	Z,PD3
	LD	A,(VSEC)
	CALL	BIN2BCD
	AND	7FH		; CH=0 - start oscillator
	LD	(REGBUF),A
	LD	A,(VMIN)
	CALL	BIN2BCD
	LD	(REGBUF+1),A
	LD	A,(VHOUR)
	CALL	BIN2BCD		; bit 6 = 0 -> 24h mode
	LD	(REGBUF+2),A
; --- write to DS1307 ---
PD3:	LD	A,(FLAGS)
	CP	3
	JR	Z,WRALL
	CP	1
	JR	Z,WRTIM
	LD	C,3		; date only: registers 3..6
	LD	B,4
	LD	HL,REGBUF+3
	JR	DOWR
WRTIM:	LD	C,0		; time only: registers 0..2
	LD	B,3
	LD	HL,REGBUF
	JR	DOWR
WRALL:	LD	C,0		; date and time: registers 0..6
	LD	B,7
	LD	HL,REGBUF
DOWR:	CALL	RTCWR
	JP	C,ERRI2C
	LD	DE,MSET
	CALL	PRSTR
; --- read and display ---
SHOW:	LD	C,0
	LD	B,7
	LD	HL,REGBUF
	CALL	RTCRD
	JP	C,ERRI2C
	CALL	DISP
EXIT:	LD	SP,(OLDSP)
	RET

; --- error messages ---
HELP:	LD	DE,MHELP
	JR	ERROUT
ERRSYN:	LD	DE,MESYN
	CALL	PRSTR
	JR	HELP
ERRDAT:	LD	DE,MEDAT
	JR	ERROUT
ERRPCF:	LD	DE,MEPCF
	JR	ERROUT
ERRI2C:	LD	DE,MEI2C
ERROUT:	CALL	PRSTR
	JR	EXIT

; ==================================================================
; ARGUMENT PARSING
; ==================================================================

; SKIPSP - skip spaces and tabs. HL=pointer, out: A=char
SKIPSP:	LD	A,(HL)
	CP	' '
	JR	Z,SK1
	CP	9
	RET	NZ
SK1:	INC	HL
	JR	SKIPSP

; ISEND - Z=1 if A ends a word (0, space, TAB)
ISEND:	OR	A
	RET	Z
	CP	' '
	RET	Z
	CP	9
	RET

; GETNUM - read a decimal number (1..4 digits) at (HL)
; out: DE=value, A=terminating char, HL past number, CF=1 on error
GETNUM:	LD	DE,0
	LD	B,0
GNLOOP:	LD	A,(HL)
	SUB	'0'
	JR	C,GNEND
	CP	10
	JR	NC,GNEND
	PUSH	HL
	LD	H,D
	LD	L,E
	ADD	HL,HL		; *2
	ADD	HL,HL		; *4
	ADD	HL,DE		; *5
	ADD	HL,HL		; *10
	LD	E,A
	LD	D,0
	ADD	HL,DE
	EX	DE,HL
	POP	HL
	INC	HL
	INC	B
	LD	A,B
	CP	5
	JR	C,GNLOOP
	SCF			; too many digits
	RET
GNEND:	LD	A,B
	OR	A
	LD	A,(HL)
	SCF
	RET	Z		; no digits
	OR	A		; CF=0
	RET

; GETB - like GETNUM, but value 0..255 in E
GETB:	CALL	GETNUM
	RET	C
	LD	C,A
	LD	A,D
	OR	A
	SCF
	RET	NZ
	LD	A,C
	OR	A
	RET

; PTOKEN - recognize a date (yyyy-mm-dd) or time (hh:mm[:ss]) word
PTOKEN:	CALL	GETNUM
	RET	C
	CP	':'
	JR	Z,PTIME
	CP	'-'
	JR	Z,PDATE
	SCF
	RET

PTIME:	LD	A,D
	OR	A
	SCF
	RET	NZ
	LD	A,E
	CP	24
	CCF
	RET	C
	LD	(VHOUR),A
	INC	HL
	CALL	GETB
	RET	C
	LD	C,A
	LD	A,E
	CP	60
	CCF
	RET	C
	LD	(VMIN),A
	XOR	A
	LD	(VSEC),A
	LD	A,C
	CP	':'
	JR	NZ,PTIME2
	INC	HL
	CALL	GETB
	RET	C
	LD	C,A
	LD	A,E
	CP	60
	CCF
	RET	C
	LD	(VSEC),A
	LD	A,C
PTIME2:	CALL	ISEND
	SCF
	RET	NZ
	LD	A,(FLAGS)
	OR	1		; bit 0 = set time
	LD	(FLAGS),A
	OR	A
	RET

; DE = year (2 or 4 digits), HL points to '-'
PDATE:	PUSH	HL
	EX	DE,HL
	LD	DE,2000
	OR	A
	SBC	HL,DE
	JR	NC,PDY1		; year >= 2000
	ADD	HL,DE		; 2-digit year
PDY1:	LD	A,H
	OR	A
	JR	NZ,PDYERR
	LD	A,L
	CP	100
	JR	NC,PDYERR
	LD	(VYEAR),A
	POP	HL
	INC	HL
	CALL	GETB		; month
	RET	C
	CP	'-'
	SCF
	RET	NZ
	LD	A,E
	LD	(VMON),A
	INC	HL
	CALL	GETB		; day
	RET	C
	CALL	ISEND
	SCF
	RET	NZ
	LD	A,E
	LD	(VDATE),A
	LD	A,(FLAGS)
	OR	2		; bit 1 = set date
	LD	(FLAGS),A
	OR	A
	RET
PDYERR:	POP	HL
	SCF
	RET

; ==================================================================
; CALENDAR
; ==================================================================

; MDAYS - A = number of days in month (VMON, VYEAR), years 2000..2099
MDAYS:	LD	A,(VMON)
	LD	E,A
	LD	D,0
	LD	HL,MTAB-1
	ADD	HL,DE
	LD	A,(HL)
	CP	28
	RET	NZ
	LD	A,(VYEAR)
	AND	3
	LD	A,28
	RET	NZ
	INC	A		; February in a leap year
	RET

; CALCDOW - compute day of week -> VDOW (1=Mon ... 7=Sun)
; days since 2000-01-01 (Saturday):
; d = yy*365 + (yy+3)/4 + days_before_month + leap + day-1
CALCDOW:
	LD	A,(VYEAR)
	LD	DE,365
	CALL	MUL8		; HL = yy*365
	LD	A,(VYEAR)
	ADD	A,3
	SRL	A
	SRL	A
	CALL	ADDA		; + leap days of previous years
	LD	A,(VMON)
	DEC	A
	ADD	A,A
	LD	E,A
	LD	D,0
	PUSH	HL
	LD	HL,CUMTAB
	ADD	HL,DE
	LD	E,(HL)
	INC	HL
	LD	D,(HL)
	POP	HL
	ADD	HL,DE		; + days of previous months
	LD	A,(VMON)
	CP	3
	JR	C,CD1
	LD	A,(VYEAR)
	AND	3
	JR	NZ,CD1
	INC	HL		; Feb 29th in the current year
CD1:	LD	A,(VDATE)
	DEC	A
	ADD	A,5		; 2000-01-01 = Saturday (index 5, Mon=0)
	CALL	ADDA
	LD	E,7
	CALL	DIV8		; A = remainder mod 7
	INC	A
	LD	(VDOW),A
	RET

; ADDA - HL = HL + A
ADDA:	ADD	A,L
	LD	L,A
	RET	NC
	INC	H
	RET

; MUL8 - HL = A * DE
MUL8:	LD	HL,0
	LD	B,8
MUL1:	ADD	HL,HL
	ADD	A,A
	JR	NC,MUL2
	ADD	HL,DE
MUL2:	DJNZ	MUL1
	RET

; DIV8 - HL = HL / E, A = remainder
DIV8:	XOR	A
	LD	B,16
DIV1:	ADD	HL,HL
	RLA
	CP	E
	JR	C,DIV2
	SUB	E
	INC	L
DIV2:	DJNZ	DIV1
	RET

; BIN2BCD - A (0..99) -> BCD
BIN2BCD:
	LD	B,0
B2B1:	SUB	10
	JR	C,B2B2
	INC	B
	JR	B2B1
B2B2:	ADD	A,10
	LD	C,A
	LD	A,B
	RLCA
	RLCA
	RLCA
	RLCA
	OR	C
	RET

; ==================================================================
; DISPLAY
; ==================================================================
; Format: "Date: 2026-10-15 Thu" / "Time: 10:03:00"
DISP:	LD	DE,MDATE	; "Date: 20"
	CALL	PRSTR
	LD	A,(REGBUF+6)
	CALL	PRBCD		; year
	LD	A,'-'
	CALL	PRCH
	LD	A,(REGBUF+5)
	AND	1FH
	CALL	PRBCD		; month
	LD	A,'-'
	CALL	PRCH
	LD	A,(REGBUF+4)
	AND	3FH
	CALL	PRBCD		; day
	LD	A,' '
	CALL	PRCH
	LD	A,(REGBUF+3)
	AND	7
	JR	Z,DBAD
	DEC	A
	ADD	A,A
	ADD	A,A		; 4 bytes per entry
	LD	E,A
	LD	D,0
	LD	HL,DAYTAB
	ADD	HL,DE
	EX	DE,HL
	JR	DPR
DBAD:	LD	DE,DQUEST
DPR:	CALL	PRSTR
	LD	DE,MTIME
	CALL	PRSTR
	LD	A,(REGBUF+2)
	AND	3FH
	CALL	PRBCD		; hours (24h)
	LD	A,':'
	CALL	PRCH
	LD	A,(REGBUF+1)
	AND	7FH
	CALL	PRBCD		; minutes
	LD	A,':'
	CALL	PRCH
	LD	A,(REGBUF)
	AND	7FH
	CALL	PRBCD		; seconds
	LD	DE,MCRLF
	CALL	PRSTR
	LD	A,(REGBUF)
	BIT	7,A		; CH - oscillator stopped?
	LD	DE,MSTOP
	CALL	NZ,PRSTR
	RET

; PRBCD - print A as 2 digits (BCD/hex)
PRBCD:	PUSH	AF
	RRCA
	RRCA
	RRCA
	RRCA
	CALL	PRNIB
	POP	AF
PRNIB:	AND	0FH
	ADD	A,'0'
	CP	'9'+1
	JR	C,PRCH
	ADD	A,7
PRCH:	PUSH	BC
	PUSH	DE
	PUSH	HL
	LD	E,A
	LD	C,2
	CALL	BDOS
	POP	HL
	POP	DE
	POP	BC
	RET

; PRSTR - print '$'-terminated string at DE
PRSTR:	PUSH	BC
	PUSH	HL
	LD	C,9
	CALL	BDOS
	POP	HL
	POP	BC
	RET

; ==================================================================
; PCF8584 DRIVER
; All routines: CF=1 means error
; ==================================================================

; I2CINIT - initialize PCF8584 and check its presence
I2CINIT:
	LD	A,I2PIN
	OUT	(PCFS1),A	; ES0=0: S0 addresses S0' (own address)
	IN	A,(PCFS1)
	AND	7FH
	SCF
	RET	NZ
	LD	A,PCFOWN
	OUT	(PCFS0),A	; write own address
	IN	A,(PCFS0)
	CP	PCFOWN
	SCF
	RET	NZ
	LD	A,I2PIN+I2ES1
	OUT	(PCFS1),A	; select clock register S2
	LD	A,PCFCLK
	OUT	(PCFS0),A
	IN	A,(PCFS0)
	AND	1FH
	CP	PCFCLK
	SCF
	RET	NZ
	LD	A,CIDLE
	OUT	(PCFS1),A	; interface enabled, idle
	IN	A,(PCFS1)
	AND	0FEH		; ignore /BB
	CP	I2PIN
	SCF
	RET	NZ
	OR	A
	RET

; WAITBB - wait until the bus is free
WAITBB:	PUSH	HL
	LD	HL,0
WBB1:	IN	A,(PCFS1)
	AND	I2NBB
	JR	NZ,WBB2		; free
	DEC	HL
	LD	A,H
	OR	L
	JR	NZ,WBB1
	POP	HL
	SCF			; timeout
	RET
WBB2:	POP	HL
	OR	A
	RET

; WAITPIN - wait for PIN=0 (byte transfer complete)
; out: A=S1 status, CF=1 on timeout, BER or LAB
WAITPIN:
	PUSH	HL
	LD	HL,0
WP1:	IN	A,(PCFS1)
	BIT	7,A
	JR	Z,WP2
	DEC	HL
	LD	A,H
	OR	L
	JR	NZ,WP1
	POP	HL
	SCF
	RET
WP2:	POP	HL
	BIT	4,A		; BER
	JR	NZ,WPERR
	BIT	1,A		; LAB
	JR	NZ,WPERR
	OR	A
	RET
WPERR:	SCF
	RET

; I2CSTA - START + address (A); CF=1 if no ACK
I2CSTA:	OUT	(PCFS0),A
	LD	A,CSTART
	OUT	(PCFS1),A
	JR	I2CACK

; I2CRST - repeated START + address (A)
I2CRST:	PUSH	AF
	LD	A,CRSTA
	OUT	(PCFS1),A
	POP	AF
	OUT	(PCFS0),A
	JR	I2CACK

; I2CWR - send byte A; CF=1 if no ACK
I2CWR:	OUT	(PCFS0),A
I2CACK:	CALL	WAITPIN
	RET	C
	AND	I2LRB
	RET	Z
	SCF
	RET

; I2CSTP - STOP
I2CSTP:	LD	A,CSTOP
	OUT	(PCFS1),A
	RET

; ==================================================================
; DS1307 DRIVER
; ==================================================================

; RTCWR - write B bytes from HL starting at register C
RTCWR:	CALL	WAITBB
	RET	C
	LD	A,DS1307
	CALL	I2CSTA
	JR	C,RTCERR
	LD	A,C
	CALL	I2CWR		; register pointer
	JR	C,RTCERR
RW1:	LD	A,(HL)
	CALL	I2CWR
	JR	C,RTCERR
	INC	HL
	DJNZ	RW1
	CALL	I2CSTP
	OR	A
	RET
RTCERR:	CALL	I2CSTP
	SCF
	RET

; RTCRD - read B (>=1) bytes starting at register C into buffer HL
RTCRD:	CALL	WAITBB
	RET	C
	LD	A,DS1307
	CALL	I2CSTA
	JR	C,RTCERR
	LD	A,C
	CALL	I2CWR		; register pointer
	JR	C,RTCERR
	LD	A,DS1307+1
	CALL	I2CRST		; repeated START, read mode
	JR	C,RTCERR
	LD	A,B
	DEC	A
	JR	NZ,RR1
	LD	A,CNACK		; single byte - no ACK right away
	OUT	(PCFS1),A
RR1:	IN	A,(PCFS0)	; dummy read - starts reception of 1st byte
RR2:	DEC	B
	JR	Z,RRLAST
	CALL	WAITPIN
	JR	C,RTCERR
	LD	A,B
	DEC	A
	JR	NZ,RR3
	LD	A,CNACK		; last byte will be received without ACK
	OUT	(PCFS1),A
RR3:	IN	A,(PCFS0)	; read byte + start reception of next one
	LD	(HL),A
	INC	HL
	JR	RR2
RRLAST:	CALL	WAITPIN
	JR	C,RTCERR
	CALL	I2CSTP		; STOP before reading the last byte
	IN	A,(PCFS0)
	LD	(HL),A
	OR	A
	RET

; ==================================================================
; DATA
; ==================================================================
MTAB:	DB	31,28,31,30,31,30,31,31,30,31,30,31
CUMTAB:	DW	0,31,59,90,120,151,181,212,243,273,304,334

; day-of-week abbreviations - 4 bytes each (DS1307: 1=Mon ... 7=Sun)
DAYTAB:	DB	'Mon$','Tue$','Wed$','Thu$','Fri$','Sat$','Sun$'
DQUEST:	DB	'???$'

MDATE:	DB	'Date: 20$'
MTIME:	DB	CR,LF,'Time: $'
MCRLF:	DB	CR,LF,'$'
MSTOP:	DB	'Warning: DS1307 oscillator stopped (CH=1) - set the time.'
	DB	CR,LF,'$'
MSET:	DB	'Clock set.',CR,LF,'$'
MEPCF:	DB	'Error: PCF8584 not found.',CR,LF,'$'
MEI2C:	DB	'I2C error: DS1307 not responding.',CR,LF,'$'
MEDAT:	DB	'Error: invalid date.',CR,LF,'$'
MESYN:	DB	'Syntax error.',CR,LF,'$'
MHELP:	DB	'RTC - DS1307 real-time clock via PCF8584 (I2C)',CR,LF
	DB	'Usage:',CR,LF
	DB	'  RTC                      - show date and time',CR,LF
	DB	'  RTC yyyy-mm-dd           - set date',CR,LF
	DB	'  RTC hh:mm:ss             - set time (24h)',CR,LF
	DB	'  RTC yyyy-mm-dd hh:mm:ss  - set date and time',CR,LF,'$'

OLDSP:	DS	2
FLAGS:	DS	1		; bit0 = time, bit1 = date
VSEC:	DS	1
VMIN:	DS	1
VHOUR:	DS	1
VDOW:	DS	1
VDATE:	DS	1
VMON:	DS	1
VYEAR:	DS	1
REGBUF:	DS	8
	DS	64
STACK	EQU	$

	END	START
