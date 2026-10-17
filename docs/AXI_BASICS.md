# AXI Basics — explained simply

Notes I wrote while learning. If you are new to AXI too, start here.

## 1. The handshake: VALID and READY

Every AXI channel has two control wires:

* **VALID** — set by the *sender*: "my data on the wires is real, take it"
* **READY** — set by the *receiver*: "I can accept something right now"

A transfer happens **only on a rising clock edge where VALID = 1 and READY = 1**.

Analogy: handing over a cup of tea. You hold the cup out (VALID). Your friend
reaches out a hand (READY). The tea changes hands only when both are true.

Three rules:

1. **The sender must not wait for READY before raising VALID.**
   If both people wait for the other to move first, nobody moves — deadlock.
2. **Once VALID is 1, the sender keeps it 1 and keeps the data the same until
   the transfer happens.** You can't swap the cup while holding it out.
3. The receiver *may* wait to see VALID before raising READY.

## 2. The five channels

| Channel | Direction | Carries |
|---------|-----------|---------|
| AW (write address)  | processor → memory | address, burst length, size, burst type, ID |
| W  (write data)     | processor → memory | data, byte strobes, LAST |
| B  (write response) | memory → processor | OKAY / SLVERR, ID |
| AR (read address)   | processor → memory | address, burst length, size, burst type, ID |
| R  (read data)      | memory → processor | data, OKAY / SLVERR, LAST, ID |

Writes use AW + W + B. Reads use AR + R.

## 3. Bursts

One address, many data beats.

* **AxLEN** = number of beats − 1 (so AxLEN = 3 means 4 beats)
* **AxSIZE** = bytes per beat as a power of 2 (0 → 1 byte, 1 → 2 bytes, 2 → 4 bytes)
* **LAST** is 1 only on the final beat (WLAST, RLAST)
* A write burst gets **only one B response**, after the last beat

Burst types — how the address moves from beat to beat:

| Type  | Address pattern (4-byte beats, start 0x08, 4 beats) | Used for |
|-------|------------------------------------------------------|----------|
| FIXED | 08, 08, 08, 08                                        | a FIFO at one address |
| INCR  | 08, 0C, 10, 14                                        | normal memory |
| WRAP  | 08, 0C, 00, 04  (wraps inside a 16-byte block)        | cache lines |

## 4. Write strobes (WSTRB)

One bit per byte of the data bus. WSTRB = 4'b0011 on a 32-bit bus means
"write only the lower 2 bytes, leave the other 2 untouched".

## 5. Responses

* **OKAY (00)** — done
* **SLVERR (10)** — the memory could not do it (in this design: reserved burst
  type, size larger than the bus, or an illegal WRAP length / address)

## 6. Reading a write burst in a waveform

```
clk      _|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_
awvalid  __|‾‾‾|______________________     address handshake (once)
awready  ‾‾‾‾‾‾|______________|‾‾‾‾‾‾‾
wvalid   ______|‾‾‾‾‾‾‾‾‾‾‾‾‾‾|________     4 data beats
wlast    __________________|‾‾|________     only on the last beat
bvalid   ______________________|‾‾‾‾|__     response waits...
bready   ___________________________|‾|_   ...until the processor is ready
```
