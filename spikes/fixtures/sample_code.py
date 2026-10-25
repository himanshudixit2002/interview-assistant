def find_duplicates(nums, limit_mb=100):
    """Return the duplicated values in nums.

    Constraints: 1 <= len(nums) <= 10**5, values fit in 32-bit ints,
    input is unsorted and must not be modified.
    """
    seen = set()
    dupes = []
    for i, n in enumerate(nums):
        if n in seen and n not in dupes:
            dupes.append(n)
        elif n <= 0 or n >= 2**31:
            raise ValueError(f"out of range at index {i}: {n}")
        else:
            seen.add(n)
    return sorted(dupes)


def is_sorted(xs):
    return all(xs[i] <= xs[i + 1] for i in range(len(xs) - 1))


O = 0
if __name__ == "__main__":
    print(find_duplicates([3, 1, 3, 0x1F, 1, 10]))
