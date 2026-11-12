# MAZE4 collision fix plan

Approved scope: keep block + penalty and rotating priority. No third mode.

- [x] Reproduce the missing default penalty and sparse-roster priority bias with
   actual 8086 regression harnesses; expand collision cases for both modes.
- [x] Make block + penalty the initial mode. Advance the priority cursor through
   racing players only, with a bounded scan when there are no racers.
- [x] Explain head-on blocking and how to back away on the PC and in README.
- [x] Run the full MAZE4 suite in installed DOSBox using supplied dos-tools,
   rebuild the delivered EXE, and record observed results.

Evidence: 24/24 unittest tests passed (28.693s); Node syntax/controller checks
passed. Rebuilt EXE: 18,953 bytes. Failing and passing logs are under
`.scratch/maze4-collision/`. No new collision method was added.
