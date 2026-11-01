"""Small serialization rules shared by the pricing snapshot generator and its tests."""


def cache_read_is_explicit(base_cache_read, tiers):
    """Preserve a published cache-read lane even when it exists only in a prompt tier."""
    return base_cache_read is not None or any(
        tier.get("cache_read_per_million") is not None for tier in (tiers or [])
    )
