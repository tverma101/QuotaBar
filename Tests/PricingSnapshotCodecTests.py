import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "script"))
from pricing_snapshot_codec import cache_read_provenance


class CacheReadProvenanceTests(unittest.TestCase):
    def test_missing_base_without_tier_marks_legacy_synthesized(self):
        self.assertEqual(cache_read_provenance(None, False), {"cre": False})

    def test_missing_base_with_tier_override_uses_base_only_flag(self):
        self.assertEqual(cache_read_provenance(None, True), {"crb": False})

    def test_published_zero_base_rate_needs_no_marker(self):
        self.assertEqual(cache_read_provenance(0.0, True), {})


if __name__ == "__main__":
    unittest.main()
