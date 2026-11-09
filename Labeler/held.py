def held(name: str) -> bool:
    """Whether a capture is held out of training to score on, the same as Finder.isHeldOut: a fifth of them, by a
    hash of the name."""
    h = 14695981039346656037
    for b in name.encode():
        h = ((h ^ b) * 1099511628211) % 2**64
    return h % 5 == 0
