import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "script"))
from pricing_snapshot_codec import cache_read_is_explicit


class CacheReadProvenanceTests(unittest.TestCase):
    def test_tier_only_cache_read_remains_explicit_in_compact_snapshot(self):
        tiers = [{"cache_read_per_million": 0.2}]

        self.assertTrue(cache_read_is_explicit(None, tiers))

    def test_missing_base_and_tier_cache_read_remains_synthesized(self):
        tiers = [{"input_per_million": 1.0, "output_per_million": 2.0}]

        self.assertFalse(cache_read_is_explicit(None, tiers))

    def test_base_cache_read_remains_explicit_without_tiers(self):
        self.assertTrue(cache_read_is_explicit(0.1, []))


if __name__ == "__main__":
    unittest.main()
