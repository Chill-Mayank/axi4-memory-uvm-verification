# Glossary — words used in this project

One line each, in plain words. Alphabetical.

| Word | Meaning | Everyday analogy |
|------|---------|------------------|
| **Agent** (UVM) | a box holding the sequencer, driver and monitor for one interface | a delivery team: dispatcher + driver + CCTV |
| **Assertion** (SVA) | a rule checked automatically on every clock; prints an error if broken | a traffic camera that flags rule-breakers |
| **AXI4** | ARM's standard rules for a processor to talk to memory/peripherals | the rules of a courier service |
| **Beat** | one data transfer inside a burst (one VALID+READY clock) | one parcel |
| **Burst** | many beats sent for one address | one delivery with several parcels |
| **Coverage (code)** | which lines/conditions/states of the RTL actually ran | which roads the delivery van drove on |
| **Coverage (functional)** | which *kinds* of transactions the tests created | which chapters the exam asked about |
| **Covergroup** | SystemVerilog code that counts functional coverage | the syllabus checklist |
| **Directed test** | a hand-written test for one specific situation | a teacher's chosen question |
| **Driver** (UVM) | turns a transaction into 0s and 1s on the wires | the student writing the answer |
| **DUT** | Design Under Test — the RTL being checked (`axi_mem.sv`) | the student taking the exam |
| **FSM** | Finite State Machine — the design's "mode" (idle, data, response) | a traffic light's red/yellow/green |
| **ID** (AWID, BID…) | a tag so a response can be matched to its request | a token number at a bank |
| **Interface** (SV) | a bundle of related wires passed around as one thing | a multi-pin cable |
| **LAST** (WLAST, RLAST) | 1 only on the final beat of a burst | "this is the last parcel" |
| **Monitor** (UVM) | only watches the wires and reports what happened | a CCTV camera |
| **Random test** | the computer picks the transactions (within rules) | a surprise quiz |
| **READY** | receiver says "I can take it now" | holding your hand out |
| **Reference model** | simple code that computes the correct answer | the answer key |
| **Regression** | running many tests/seeds together to check nothing broke | a full mock exam series |
| **RTL** | Register Transfer Level — the hardware description (Verilog) | the blueprint of the machine |
| **Scoreboard** (UVM) | compares the DUT's output with the reference model | the examiner |
| **Seed** | the number that decides the random choices; same seed = same test again | the shuffle of a deck of cards |
| **Sequence** (UVM) | generates a list of transactions to send | the question paper |
| **SLVERR** | "slave error" — the memory says it cannot do this request | "sorry, wrong address" |
| **SVA** | SystemVerilog Assertions | — |
| **Testbench (TB)** | all the code that tests the DUT (not part of the chip) | the exam hall |
| **UVM** | Universal Verification Methodology — the industry-standard way to build testbenches | a standard exam format every college follows |
| **VALID** | sender says "my data is real, take it" | holding the cup out |
| **WSTRB** | write strobe — which bytes of a word to actually write | ticking which boxes on a form to fill |
| **X** | unknown value in simulation (e.g. never driven, or wrong direction) | a blank answer |
