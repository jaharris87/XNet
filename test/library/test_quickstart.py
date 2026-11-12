"""Check that selection cannot silently lose or duplicate the named example."""

import unittest
from pathlib import Path

from extract_quickstart import extract_quickstart


SOURCE = "Program quickstart\n  Implicit None\nEnd Program quickstart\n"
FENCE = f"```fortran\n{SOURCE}```\n"


class QuickstartSelectionTests(unittest.TestCase):
    def test_current_guide(self):
        guide = Path(__file__).resolve().parents[2] / "docs/development/embedding.md"
        source = extract_quickstart(guide.read_text())
        self.assertTrue(source.startswith("Program quickstart\n"))
        self.assertTrue(source.endswith("End Program quickstart\n"))

    def test_unrelated_fences_are_ignored(self):
        text = "```sh\nProgram quickstart\n```\n" + FENCE + "```fortran\nProgram other\n```\n"
        self.assertEqual(extract_quickstart(text), SOURCE)

    def test_case_insensitive_program_name(self):
        self.assertEqual(extract_quickstart(FENCE.lower()), SOURCE.lower())

    def test_missing_example(self):
        with self.assertRaisesRegex(ValueError, "found 0"):
            extract_quickstart(FENCE.replace("quickstart", "other"))

    def test_duplicate_fence(self):
        with self.assertRaisesRegex(ValueError, "found 2"):
            extract_quickstart(FENCE + FENCE)

    def test_duplicate_program_in_one_fence(self):
        with self.assertRaisesRegex(ValueError, "one complete Program"):
            extract_quickstart(f"```fortran\n{SOURCE}{SOURCE}```\n")

    def test_missing_end_program(self):
        with self.assertRaisesRegex(ValueError, "one complete Program"):
            extract_quickstart("```fortran\nProgram quickstart\n```\n")

    def test_unclosed_fence_at_eof(self):
        with self.assertRaisesRegex(ValueError, "fence is not closed"):
            extract_quickstart(f"```fortran\n{SOURCE}")

    def test_unclosed_fence_before_next_example(self):
        with self.assertRaisesRegex(ValueError, "fence is not closed"):
            extract_quickstart(f"```fortran\n{SOURCE}```make\nall:\n```\n")


if __name__ == "__main__":
    unittest.main()
