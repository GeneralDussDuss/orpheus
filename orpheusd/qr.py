"""A small QR code encoder: byte mode, error correction M, versions 1 to 10.

Enough for a pairing URL (version 10-M carries 213 bytes) without a new
dependency. Follows ISO/IEC 18004 the way Project Nayuki's reference encoder
lays it out: Reed-Solomon over GF(256)/0x11D, the interleaved block layout,
all eight masks scored by the four penalty rules.
"""

# version -> (EC codewords per block, [(blocks, data codewords per block), ...]) at level M
_M = {
    1: (10, [(1, 16)]), 2: (16, [(1, 28)]), 3: (26, [(1, 44)]), 4: (18, [(2, 32)]),
    5: (24, [(2, 43)]), 6: (16, [(4, 27)]), 7: (18, [(4, 31)]), 8: (22, [(2, 38), (2, 39)]),
    9: (22, [(3, 36), (2, 37)]), 10: (26, [(4, 43), (1, 44)]),
}
_ALIGN = {1: [], 2: [6, 18], 3: [6, 22], 4: [6, 26], 5: [6, 30], 6: [6, 34],
          7: [6, 22, 38], 8: [6, 24, 42], 9: [6, 26, 46], 10: [6, 28, 50]}
_FORMAT_M = 0   # the level's two format bits: L=1, M=0, Q=3, H=2

# GF(256) tables
_EXP = [0] * 512
_LOG = [0] * 256
_x = 1
for _i in range(255):
    _EXP[_i] = _x
    _LOG[_x] = _i
    _x <<= 1
    if _x & 0x100:
        _x ^= 0x11D
for _i in range(255, 512):
    _EXP[_i] = _EXP[_i - 255]


def _mul(a: int, b: int) -> int:
    return 0 if a == 0 or b == 0 else _EXP[_LOG[a] + _LOG[b]]


def _rs_generator(n: int) -> list[int]:
    g = [1]
    for i in range(n):
        nxt = [0] * (len(g) + 1)
        for j, c in enumerate(g):
            nxt[j] ^= c
            nxt[j + 1] ^= _mul(c, _EXP[i])
        g = nxt
    return g


def _rs_remainder(data: list[int], n: int) -> list[int]:
    gen = _rs_generator(n)
    rem = [0] * n
    for b in data:
        factor = b ^ rem[0]
        rem = rem[1:] + [0]
        for i in range(n):
            rem[i] ^= _mul(gen[i + 1], factor)
    return rem


def _codewords(data: bytes) -> tuple[int, list[int]]:
    for version in range(1, 11):
        ec, groups = _M[version]
        capacity = sum(n * k for n, k in groups)
        count_bits = 8 if version < 10 else 16
        if 4 + count_bits + len(data) * 8 <= capacity * 8:
            break
    else:
        raise ValueError(f"too long for a version 10 QR code: {len(data)} bytes")
    bits = []

    def put(value, n):
        bits.extend((value >> (n - 1 - i)) & 1 for i in range(n))

    put(0b0100, 4)
    put(len(data), count_bits)
    for b in data:
        put(b, 8)
    put(0, min(4, capacity * 8 - len(bits)))
    put(0, (-len(bits)) % 8)
    words = [int("".join(map(str, bits[i:i + 8])), 2) for i in range(0, len(bits), 8)]
    pad = 0xEC
    while len(words) < capacity:
        words.append(pad)
        pad ^= 0xEC ^ 0x11
    blocks, k = [], 0
    for n, size in groups:
        for _ in range(n):
            blocks.append(words[k:k + size])
            k += size
    eccs = [_rs_remainder(b, ec) for b in blocks]
    out = []
    for i in range(max(len(b) for b in blocks)):
        out.extend(b[i] for b in blocks if i < len(b))
    for i in range(ec):
        out.extend(e[i] for e in eccs)
    return version, out


class _Grid:
    def __init__(self, version: int):
        self.version = version
        self.size = version * 4 + 17
        self.m = [[False] * self.size for _ in range(self.size)]
        self.fn = [[False] * self.size for _ in range(self.size)]

    def set(self, x, y, dark):
        self.m[y][x] = bool(dark)
        self.fn[y][x] = True

    def functions(self):
        s = self.size
        for i in range(s):
            self.set(6, i, i % 2 == 0)
            self.set(i, 6, i % 2 == 0)
        for cx, cy in ((3, 3), (s - 4, 3), (3, s - 4)):
            for dy in range(-4, 5):
                for dx in range(-4, 5):
                    x, y = cx + dx, cy + dy
                    if 0 <= x < s and 0 <= y < s:
                        d = max(abs(dx), abs(dy))
                        self.set(x, y, d not in (2, 4))
        pos = _ALIGN[self.version]
        last = len(pos) - 1
        for i, ax in enumerate(pos):
            for j, ay in enumerate(pos):
                if (i, j) in ((0, 0), (0, last), (last, 0)):
                    continue
                for dy in range(-2, 3):
                    for dx in range(-2, 3):
                        self.set(ax + dx, ay + dy, max(abs(dx), abs(dy)) != 1)
        self.format_bits(0)   # reserve; redrawn per mask
        if self.version >= 7:
            rem = self.version
            for _ in range(12):
                rem = (rem << 1) ^ ((rem >> 11) * 0x1F25)
            bits = self.version << 12 | rem
            for i in range(18):
                bit = (bits >> i) & 1
                a, b = s - 11 + i % 3, i // 3
                self.set(a, b, bit)
                self.set(b, a, bit)

    def format_bits(self, mask: int):
        data = _FORMAT_M << 3 | mask
        rem = data
        for _ in range(10):
            rem = (rem << 1) ^ ((rem >> 9) * 0x537)
        bits = (data << 10 | rem) ^ 0x5412
        s = self.size
        b = lambda i: (bits >> i) & 1
        for i in range(6):
            self.set(8, i, b(i))
        self.set(8, 7, b(6))
        self.set(8, 8, b(7))
        self.set(7, 8, b(8))
        for i in range(9, 15):
            self.set(14 - i, 8, b(i))
        for i in range(8):
            self.set(s - 1 - i, 8, b(i))
        for i in range(8, 15):
            self.set(8, s - 15 + i, b(i))
        self.set(8, s - 8, True)

    def place(self, words: list[int]):
        s, i, total = self.size, 0, len(words) * 8
        right = s - 1
        while right >= 1:
            if right == 6:
                right = 5
            for vert in range(s):
                for j in range(2):
                    x = right - j
                    upward = ((right + 1) & 2) == 0
                    y = s - 1 - vert if upward else vert
                    if not self.fn[y][x] and i < total:
                        self.m[y][x] = bool((words[i >> 3] >> (7 - (i & 7))) & 1)
                        i += 1
            right -= 2

    def apply_mask(self, mask: int):
        f = [lambda x, y: (x + y) % 2 == 0, lambda x, y: y % 2 == 0, lambda x, y: x % 3 == 0,
             lambda x, y: (x + y) % 3 == 0, lambda x, y: (x // 3 + y // 2) % 2 == 0,
             lambda x, y: x * y % 2 + x * y % 3 == 0, lambda x, y: (x * y % 2 + x * y % 3) % 2 == 0,
             lambda x, y: ((x + y) % 2 + x * y % 3) % 2 == 0][mask]
        for y in range(self.size):
            for x in range(self.size):
                if not self.fn[y][x] and f(x, y):
                    self.m[y][x] = not self.m[y][x]

    def penalty(self) -> int:
        s, m, score = self.size, self.m, 0
        lines = [m[y] for y in range(s)] + [[m[y][x] for y in range(s)] for x in range(s)]
        pat1 = [True, False, True, True, True, False, True, False, False, False, False]
        pat2 = pat1[::-1]
        for line in lines:
            run, prev = 0, None
            for v in line:
                if v == prev:
                    run += 1
                else:
                    if run >= 5:
                        score += run - 2
                    run, prev = 1, v
            if run >= 5:
                score += run - 2
            for i in range(s - 10):
                seg = line[i:i + 11]
                if seg == pat1 or seg == pat2:
                    score += 40
        for y in range(s - 1):
            for x in range(s - 1):
                if m[y][x] == m[y][x + 1] == m[y + 1][x] == m[y + 1][x + 1]:
                    score += 3
        dark = sum(sum(r) for r in m)
        total = s * s
        k = (abs(dark * 20 - total * 10) + total - 1) // total - 1
        return score + max(0, k) * 10


def matrix(text: str, mask: int | None = None) -> list[list[bool]]:
    """The QR code for `text` as rows of booleans (True = dark), no quiet zone."""
    version, words = _codewords(text.encode("utf-8"))
    best, best_score = None, None
    for mk in ([mask] if mask is not None else range(8)):
        g = _Grid(version)
        g.functions()
        g.place(words)
        g.apply_mask(mk)
        g.format_bits(mk)
        sc = g.penalty()
        if best_score is None or sc < best_score:
            best, best_score = g, sc
    return best.m


def rows(text: str) -> list[str]:
    """The same as strings of '1' and '0', which travel well in JSON."""
    return ["".join("1" if v else "0" for v in r) for r in matrix(text)]


def svg(text: str, scale: int = 8, quiet: int = 4, dark: str = "#000", light: str = "#fff") -> str:
    m = matrix(text)
    n = len(m) + quiet * 2
    path = "".join(f"M{x + quiet},{y + quiet}h1v1h-1z" for y, r in enumerate(m) for x, v in enumerate(r) if v)
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {n} {n}" width="{n * scale}" '
            f'height="{n * scale}" shape-rendering="crispEdges"><rect width="{n}" height="{n}" fill="{light}"/>'
            f'<path d="{path}" fill="{dark}"/></svg>')
