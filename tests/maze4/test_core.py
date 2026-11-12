import collections
import struct
import unittest

from support import SOURCE, build

CELLS = 17 * 61
# (mode, priority, positions, directions, expected positions, penalties)
CASES = [
    (0, 0, [315, 317], [4, 3], [315, 317], [30, 30]),
    (1, 0, [315, 317], [4, 3], [316, 317], [0, 0]),
    (1, 1, [315, 317], [4, 3], [315, 316], [0, 0]),
    (1, 0, [315, 316], [4, 0], [315, 316], [0, 0]),
    (1, 0, [315, 316], [4, 3], [315, 316], [0, 0]),
    (1, 0, [315, 316, 317], [4, 4, 0], [315, 316, 317], [0, 0, 0]),
    (1, 0, [315, 316, 317], [4, 4, 4], [316, 317, 318], [0, 0, 0]),
    (1, 0, [649, 589], [4, 2], [650, 650], [0, 0]),
]


def harness():
    h = [
        "M4_TEST EQU 1",
        "INCLUDE MAZE4.ASM",
        ".DATA",
        "FILE1 DB 'MAZES.BIN',0",
        "FILE2 DB 'CASES.BIN',0",
        "HANDLE DW 0",
        "SEED DW 1",
        ".CODE",
        "TEST_MAIN PROC",
        "MOV AX,@DATA",
        "MOV DS,AX",
        "MOV ES,AX",
        "CLD",
        "LEA DX,FILE1",
        "CALL CREATE_FILE",
        "GENERATE_LOOP:",
        "MOV AX,SEED",
        "MOV RNG_SEED,AX",
        "CALL GENERATE_MAZE",
        "LEA DX,MAZE",
        f"MOV CX,{CELLS}",
        "CALL WRITE_FILE",
        "LEA DX,EXIT_POS",
        "MOV CX,23",
        "CALL WRITE_FILE",
        "INC SEED",
        "CMP SEED,129",
        "JB GENERATE_LOOP",
        "CALL CLOSE_FILE",
        "LEA DX,FILE2",
        "CALL CREATE_FILE",
    ]
    for mode, priority, positions, dirs, _, _ in CASES:
        h += [
            "CALL RESET_GAME",
            "PUSH DS",
            "POP ES",
            "LEA DI,MAZE",
            f"MOV CX,{CELLS}",
            "MOV AL,'#'",
            "REP STOSB",
        ]
        for row in range(1, 16):
            h += [f"LEA DI,MAZE+{row * 61 + 1}", "MOV CX,59", "MOV AL,' '", "REP STOSB"]
        h += [
            "MOV EXIT_POS,650",
            "MOV MAZE[650],'E'",
            f"MOV COLLISION_MODE,{mode}",
            f"MOV PRIORITY,{priority}",
        ]
        for i, (pos, d) in enumerate(zip(positions, dirs)):
            h += [
                f"MOV POSITIONS[{i * 2}],{pos}",
                f"MOV PLAYER_STATE[{i}],1",
                f"MOV DIRECTIONS[{i}],{d}",
            ]
        h += [
            "CALL BUILD_INTENTS",
            "CALL RESOLVE_MOVES",
            "CALL COMMIT_MOVES",
            "CALL UPDATE_WARNINGS",
            "LEA DX,POSITIONS",
            "MOV CX,16",
            "CALL WRITE_FILE",
            "LEA DX,PENALTIES",
            "MOV CX,32",
            "CALL WRITE_FILE",
            "LEA DX,PLAYER_STATE",
            "MOV CX,8",
            "CALL WRITE_FILE",
            "LEA DX,WARNINGS",
            "MOV CX,8",
            "CALL WRITE_FILE",
        ]
    h += [
        "CALL CLOSE_FILE",
        "MOV AX,4C00H",
        "INT 21H",
        "TEST_MAIN ENDP",
        "CREATE_FILE PROC",
        "MOV AH,3CH",
        "XOR CX,CX",
        "INT 21H",
        "MOV HANDLE,AX",
        "RET",
        "CREATE_FILE ENDP",
        "WRITE_FILE PROC",
        "MOV AH,40H",
        "MOV BX,HANDLE",
        "INT 21H",
        "RET",
        "WRITE_FILE ENDP",
        "CLOSE_FILE PROC",
        "MOV AH,3EH",
        "MOV BX,HANDLE",
        "INT 21H",
        "RET",
        "CLOSE_FILE ENDP",
        "END TEST_MAIN",
    ]
    return "\n".join(h) + "\n"


class CoreTest(unittest.TestCase):
    def test_actual_8086_rules(self):
        self.assertTrue((SOURCE / "MAZE4.ASM").exists(), "MAZE4 source does not exist")
        stage = build("CORETEST", harness())
        data = (stage / "MAZES.BIN").read_bytes()
        self.assertEqual(len(data), 128 * (CELLS + 23))
        maps = set()
        for offset in range(0, len(data), CELLS + 23):
            maze = data[offset : offset + CELLS]
            exit, distance, floor, cap = struct.unpack_from(
                "<HHHB", data, offset + CELLS
            )
            starts = struct.unpack_from("<8H", data, offset + CELLS + 7)
            maps.add(maze)
            self.assertTrue(
                all(maze[r * 61] == maze[r * 61 + 60] == 35 for r in range(17))
            )
            self.assertTrue(all(x == 35 for x in maze[:61] + maze[-61:]))
            ds = {exit: 0}
            q = collections.deque([exit])
            while q:
                p = q.popleft()
                for n in (p - 61, p + 61, p - 1, p + 1):
                    if 0 <= n < CELLS and maze[n] != 35 and n not in ds:
                        ds[n] = ds[p] + 1
                        q.append(n)
            self.assertEqual(len(ds) - 1, floor)
            layer = [p for p, d in ds.items() if d == distance]
            self.assertEqual(cap, min(8, floor // 20, len(layer)))
            self.assertGreaterEqual(cap, 2)
            self.assertGreaterEqual(distance, 12)
            self.assertEqual(len(set(starts[:cap])), cap)
            self.assertTrue(all(ds[p] == distance for p in starts[:cap]))
        self.assertGreater(len(maps), 120)
        data = (stage / "CASES.BIN").read_bytes()
        self.assertEqual(len(data), 64 * len(CASES))
        for i, (_, _, positions, _, expected, penalties) in enumerate(CASES):
            with self.subTest(case=i):
                record = data[i * 64 : (i + 1) * 64]
                self.assertEqual(
                    list(struct.unpack_from("<8H", record)[: len(positions)]), expected
                )
                self.assertEqual(
                    list(struct.unpack_from("<8I", record, 16)[: len(positions)]),
                    penalties,
                )
                if i == 7:
                    self.assertEqual(list(record[48:50]), [2, 2])
        print(
            f"PASS: 128 real 8086 mazes, {len(maps)} distinct, {len(CASES)} collision cases"
        )


if __name__ == "__main__":
    unittest.main()
