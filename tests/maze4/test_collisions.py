"""Collision regressions run against real 8086 code in installed DOSBox."""

import struct
import unittest

from support import build


def collision_harness(cases):
    """Each case supplies frames; record positions, penalties and states."""
    lines = [
        "M4_TEST EQU 1",
        "INCLUDE MAZE4.ASM",
        ".DATA",
        "FN DB 'CONTACT.BIN',0",
        "FD DW 0",
        ".CODE",
        "TEST_MAIN PROC",
        "MOV AX,@DATA",
        "MOV DS,AX",
        "MOV ES,AX",
        "CLD",
        "MOV AX,3C00H",
        "LEA DX,FN",
        "XOR CX,CX",
        "INT 21H",
        "MOV FD,AX",
        "LEA DI,MAZE",
        "MOV CX,CELLS",
        "MOV AL,' '",
        "REP STOSB",
        "MOV EXIT_POS,650",
        "MOV MAZE[650],'E'",
    ]
    for case in cases:
        lines += ["CALL RESET_GAME"]
        if "mode" in case:
            lines += [f"MOV COLLISION_MODE,{case['mode']}"]
        for slot, state in case.get("inactive", {}).items():
            lines += [f"MOV PLAYER_STATE[{slot}],{state}"]
        for frame in case["frames"]:
            for slot, pos, direction in frame:
                lines += [
                    f"MOV POSITIONS[{2 * slot}],{pos}",
                    f"MOV PLAYER_STATE[{slot}],1",
                    f"MOV DIRECTIONS[{slot}],{direction}",
                ]
            lines += [
                "CALL BUILD_INTENTS",
                "CALL RESOLVE_MOVES",
                "CALL COMMIT_MOVES",
                "LEA DX,POSITIONS",
                "MOV CX,16",
                "CALL WRITE_RECORD",
                "LEA DX,PENALTIES",
                "MOV CX,32",
                "CALL WRITE_RECORD",
                "LEA DX,PLAYER_STATE",
                "MOV CX,8",
                "CALL WRITE_RECORD",
            ]
    lines += [
        "MOV BX,FD",
        "MOV AH,3EH",
        "INT 21H",
        "MOV AX,4C00H",
        "INT 21H",
        "TEST_MAIN ENDP",
        "WRITE_RECORD PROC",
        "MOV BX,FD",
        "MOV AH,40H",
        "INT 21H",
        "RET",
        "WRITE_RECORD ENDP",
        "END TEST_MAIN",
    ]
    return "\n".join(lines) + "\n"


def run_cases(name, cases):
    stage = build(name, collision_harness(cases))
    data = (stage / "CONTACT.BIN").read_bytes()
    count = sum(len(c["frames"]) for c in cases)
    if len(data) != count * 56:
        raise AssertionError(f"{len(data)} bytes for {count} frames")
    return [struct.unpack_from("<8H8I8B", data, i * 56) for i in range(count)]


class CollisionTest(unittest.TestCase):
    def test_default_charges_maze3_penalty_once_until_contact_ends(self):
        # Catches a default mode that silently disables collision scoring.
        contact = [(0, 315, 4), (1, 317, 3)]
        idle = [(0, 315, 0), (1, 317, 0)]
        records = run_cases("DEFHIT", [{"frames": [contact, contact, idle, contact]}])
        self.assertEqual([r[:2] for r in records], [(315, 317)] * 4)
        self.assertEqual(
            [r[8:10] for r in records], [(30, 30), (30, 30), (30, 30), (60, 60)]
        )

    def test_priority_rotates_between_racers_skipping_unused_and_done_slots(self):
        # Catches rotation through eight slots when only two are racing.
        cases = []
        pairs = [(0, 1), (2, 5), (0, 7)]
        for n, (a, b) in enumerate(pairs):
            inactive = (
                {}
                if n == 0
                else {i: (2 if i % 2 else 3) for i in range(8) if i not in (a, b)}
            )
            cases.append(
                {
                    "mode": 1,
                    "inactive": inactive,
                    "frames": [[(a, 315, 4), (b, 317, 3)]] * 8,
                }
            )
        records = run_cases("FAIRHIT", cases)
        for n, (a, b) in enumerate(pairs):
            with self.subTest(slots=(a, b)):
                winners = []
                for r in records[n * 8 : (n + 1) * 8]:
                    self.assertEqual(r[8:16], (0,) * 8)
                    self.assertNotEqual(r[a], r[b])
                    winners.append(a if r[a] == 316 else b)
                self.assertEqual(winners, [a, b] * 4)

    def test_stationary_head_on_chains_junctions_and_shared_exit(self):
        # Literal outcomes cover cancellation propagation and pairwise charging.
        fixtures = [
            ([(0, 315, 4), (1, 316, 0)], [315, 316], [30, 30]),
            ([(0, 315, 4), (1, 316, 3)], [315, 316], [30, 30]),
            (
                [(i, 315 + i, 4 if i < 7 else 0) for i in range(8)],
                list(range(315, 323)),
                [30, 60, 60, 60, 60, 60, 60, 30],
            ),
            ([(i, 315 + i, 4) for i in range(8)], list(range(316, 324)), [0] * 8),
            (
                [(0, 255, 2), (1, 377, 1), (2, 315, 4), (3, 317, 3)],
                [255, 377, 315, 317],
                [90] * 4,
            ),
            ([(0, 649, 4), (1, 589, 2)], [650, 650], [0, 0]),
        ]
        cases = [{"mode": 0, "frames": [frame]} for frame, _, _ in fixtures]
        records = run_cases("BLOCKHIT", cases)
        for (frame, positions, penalties), r in zip(fixtures, records):
            with self.subTest(frame=frame):
                n = len(frame)
                self.assertEqual(list(r[:n]), positions)
                self.assertEqual(list(r[8 : 8 + n]), penalties)
        self.assertEqual(records[-1][16:18], (2, 2))

    def test_head_on_players_can_back_away_and_resume_in_both_modes(self):
        contact = [(0, 315, 4), (1, 316, 3)]
        frames = [
            contact,
            contact,
            [(0, 315, 3), (1, 316, 0)],
            [(0, 314, 3), (1, 316, 3)],
        ]
        records = run_cases("BACKHIT", [{"mode": m, "frames": frames} for m in (0, 1)])
        for mode in (0, 1):
            rows = records[mode * 4 : (mode + 1) * 4]
            self.assertEqual(
                [r[:2] for r in rows], [(315, 316), (315, 316), (314, 316), (313, 315)]
            )
            self.assertEqual(
                [r[8:10] for r in rows], [(30, 30) if mode == 0 else (0, 0)] * 4
            )

    def test_last_finishers_and_no_racers_do_not_hang_priority_scan(self):
        records = run_cases(
            "ENDHIT", [{"mode": 1, "frames": [[(0, 649, 4), (1, 589, 2)], []]}]
        )
        self.assertEqual([r[:2] for r in records], [(650, 650)] * 2)
        self.assertEqual([r[16:18] for r in records], [(2, 2)] * 2)


if __name__ == "__main__":
    unittest.main()
