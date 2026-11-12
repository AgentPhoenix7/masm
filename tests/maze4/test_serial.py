import unittest

from support import SOURCE, build


class SerialTest(unittest.TestCase):
    def test_build_phone_game(self):
        self.assertTrue(
            (SOURCE / "M4SER.INC").exists(), "MASM serial/lifecycle module missing"
        )
        stage = build()
        self.assertGreater((stage / "MAZE4.EXE").stat().st_size, 5000)


if __name__ == "__main__":
    unittest.main()
