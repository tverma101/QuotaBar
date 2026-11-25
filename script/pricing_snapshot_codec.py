"""Small serialization rules shared by the pricing snapshot generator and its tests."""


def cache_read_provenance(base_cache_read, has_override):
    """Keep tier-only cache prices usable by older compact-cache readers."""
    if base_cache_read is not None:
        return {}
    return {"crb": False} if has_override else {"cre": False}
