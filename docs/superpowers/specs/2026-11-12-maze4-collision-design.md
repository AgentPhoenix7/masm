# MAZE4 collision correction

The reported symptoms were getting stuck and receiving no penalty. The previous
default was rotating priority: it deliberately blocks head-on swaps and adds no
penalties. Restore MAZE3's block-and-charge behavior as the default, retaining
its once-per-contact-pair +3-second charge and simultaneous exit exception.

Fix the existing additional method so its cursor rotates among racing players,
skipping empty, finished and DNF slots. Its current eight-slot rotation gives
players 0 and 1 seven versus one wins over eight repeated contests. Both
corrections are implemented and verified in the 24-test suite.

## Optional addition declined

The user chose to keep only block + penalty and rotating priority. The proposed
third method below will **not** be implemented.

The proposed **swap + penalty** method would let a head-on pair
exchange adjacent cells, charging each +3 seconds per contact episode.
Other same-destination/occupied-cell collisions use MAZE3's block-and-charge
rule. Stationary players are never moved automatically. Cancellation still
propagates before committing all moves, preventing partial swaps and overlap.
Shared exit arrivals would remain allowed. Keep the existing M toggle between
the two approved methods; do not change their head-on blocking behavior.

## Alternatives

- MAZE3 block + penalty: familiar competitive scoring, but players must back
  away from a head-on corridor encounter. This will be the default.
- Rotating priority: useful at junctions, no penalties; head-on players still
  need to back away. Retain it and repair inactive-slot bias.
- Swap + penalty: recommended additional method because head-on players can
  continue in a narrow corridor without teleporting to arbitrary positions.

The approved scope is restoring the default, fixing inactive-slot bias, and
clarifying that blocked head-on players need to back away. Verify actual 8086
behavior in installed DOSBox with the supplied dos-tools
binaries: repeated contacts, releases, head-on pairs, stationary occupants,
eight-player chains, blocked swaps, ties at the exit and sparse rosters.
No Python/JavaScript game-rule implementation is added.
