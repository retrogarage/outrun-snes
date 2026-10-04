"""Minimal two-pass SPC700 assembler.

Syntax (classic): mnemonic operands, `;` comments, `label:`, `name = expr`,
`.org addr`, `.byte ...`, `.word ...`, `.ascii "..."`, `.incbin "file"`.
Addressing: #imm, a, x, y, ya, sp, psw, (x), (x)+, (y), dp, dp+x, dp+y,
!abs, !abs+x, !abs+y, [dp+x], [dp]+y, dp.bit, [!abs+x] (jmp), rel.
Direct page operands are plain expressions (< $100); absolute ones use '!'.
Expressions: + - * / & | ^ << >> ~, parentheses, <lo >hi, $hex %bin 'c', labels,
local labels (.name, scoped to the last global label).

usage: spcasm.py in.s out.bin [symbols.inc]
"""
import re
import sys

# ---------------------------------------------------------------------------
# opcode table: (mnemonic, operand pattern) -> (opcode, operand encoding)
# patterns use: A X Y YA SP PSW C #i (X) (X)+ (Y) d d+X d+Y !a !a+X !a+Y [d+X] [d]+Y d.b r
# encodings: '' none, 'i' imm8, 'd' dp8, 'a' abs16, 'r' rel8, 'dd' dp dst,src order,
# 'di' dp,imm, 'dr' dp,rel, 'db' dp.bit (opcode | bit<<5), 'dbr' dp.bit,rel
OPS = {}


def op(m, pat, code, enc=''):
    OPS[(m, pat)] = (code, enc)


# 8-bit arithmetic / logic groups
for m, base in (("or", 0x00), ("and", 0x20), ("eor", 0x40), ("cmp", 0x60), ("adc", 0x80), ("sbc", 0xA0)):
    op(m, "A,#i", base + 0x08, 'i')
    op(m, "A,(X)", base + 0x06)
    op(m, "A,d", base + 0x04, 'd')
    op(m, "A,d+X", base + 0x14, 'd')
    op(m, "A,!a", base + 0x05, 'a')
    op(m, "A,!a+X", base + 0x15, 'a')
    op(m, "A,!a+Y", base + 0x16, 'a')
    op(m, "A,[d+X]", base + 0x07, 'd')
    op(m, "A,[d]+Y", base + 0x17, 'd')
    op(m, "(X),(Y)", base + 0x19)
    op(m, "d,d", base + 0x09, 'dd')
    op(m, "d,#i", base + 0x18, 'di')
op("cmp", "X,#i", 0xC8, 'i'); op("cmp", "X,d", 0x3E, 'd'); op("cmp", "X,!a", 0x1E, 'a')
op("cmp", "Y,#i", 0xAD, 'i'); op("cmp", "Y,d", 0x7E, 'd'); op("cmp", "Y,!a", 0x5E, 'a')
# mov
op("mov", "A,#i", 0xE8, 'i'); op("mov", "A,(X)", 0xE6); op("mov", "A,(X)+", 0xBF)
op("mov", "A,d", 0xE4, 'd'); op("mov", "A,d+X", 0xF4, 'd'); op("mov", "A,!a", 0xE5, 'a')
op("mov", "A,!a+X", 0xF5, 'a'); op("mov", "A,!a+Y", 0xF6, 'a'); op("mov", "A,[d+X]", 0xE7, 'd')
op("mov", "A,[d]+Y", 0xF7, 'd')
op("mov", "X,#i", 0xCD, 'i'); op("mov", "X,d", 0xF8, 'd'); op("mov", "X,d+Y", 0xF9, 'd'); op("mov", "X,!a", 0xE9, 'a')
op("mov", "Y,#i", 0x8D, 'i'); op("mov", "Y,d", 0xEB, 'd'); op("mov", "Y,d+X", 0xFB, 'd'); op("mov", "Y,!a", 0xEC, 'a')
op("mov", "(X),A", 0xC6); op("mov", "(X)+,A", 0xAF); op("mov", "d,A", 0xC4, 'd'); op("mov", "d+X,A", 0xD4, 'd')
op("mov", "!a,A", 0xC5, 'a'); op("mov", "!a+X,A", 0xD5, 'a'); op("mov", "!a+Y,A", 0xD6, 'a')
op("mov", "[d+X],A", 0xC7, 'd'); op("mov", "[d]+Y,A", 0xD7, 'd')
op("mov", "d,X", 0xD8, 'd'); op("mov", "d+Y,X", 0xD9, 'd'); op("mov", "!a,X", 0xC9, 'a')
op("mov", "d,Y", 0xCB, 'd'); op("mov", "d+X,Y", 0xDB, 'd'); op("mov", "!a,Y", 0xCC, 'a')
op("mov", "A,X", 0x7D); op("mov", "A,Y", 0xDD); op("mov", "X,A", 0x5D); op("mov", "Y,A", 0xFD)
op("mov", "X,SP", 0x9D); op("mov", "SP,X", 0xBD)
op("mov", "d,d", 0xFA, 'dd'); op("mov", "d,#i", 0x8F, 'di')
# 16-bit
op("movw", "YA,d", 0xBA, 'd'); op("movw", "d,YA", 0xDA, 'd')
op("incw", "d", 0x3A, 'd'); op("decw", "d", 0x1A, 'd')
op("addw", "YA,d", 0x7A, 'd'); op("subw", "YA,d", 0x9A, 'd'); op("cmpw", "YA,d", 0x5A, 'd')
op("mul", "YA", 0xCF); op("div", "YA,X", 0x9E)
# inc / dec / shifts
for m, a, d, dx, ab in (("inc", 0xBC, 0xAB, 0xBB, 0xAC), ("dec", 0x9C, 0x8B, 0x9B, 0x8C),
                        ("asl", 0x1C, 0x0B, 0x1B, 0x0C), ("lsr", 0x5C, 0x4B, 0x5B, 0x4C),
                        ("rol", 0x3C, 0x2B, 0x3B, 0x2C), ("ror", 0x7C, 0x6B, 0x7B, 0x6C)):
    op(m, "A", a); op(m, "d", d, 'd'); op(m, "d+X", dx, 'd'); op(m, "!a", ab, 'a')
op("inc", "X", 0x3D); op("inc", "Y", 0xFC); op("dec", "X", 0x1D); op("dec", "Y", 0xDC)
op("xcn", "A", 0x9F); op("daa", "A", 0xDF); op("das", "A", 0xBE)
# branches / jumps
for m, c in (("bra", 0x2F), ("beq", 0xF0), ("bne", 0xD0), ("bcs", 0xB0), ("bcc", 0x90),
             ("bvs", 0x70), ("bvc", 0x50), ("bmi", 0x30), ("bpl", 0x10)):
    op(m, "r", c, 'r')
op("cbne", "d,r", 0x2E, 'dr'); op("cbne", "d+X,r", 0xDE, 'dr')
op("dbnz", "Y,r", 0xFE, 'r'); op("dbnz", "d,r", 0x6E, 'dr')
op("jmp", "!a", 0x5F, 'a'); op("jmp", "[!a+X]", 0x1F, 'a')
op("call", "!a", 0x3F, 'a'); op("ret", "", 0x6F); op("reti", "", 0x7F)
op("pcall", "d", 0x4F, 'd')
# stack / flags / misc
op("push", "A", 0x2D); op("push", "X", 0x4D); op("push", "Y", 0x6D); op("push", "PSW", 0x0D)
op("pop", "A", 0xAE); op("pop", "X", 0xCE); op("pop", "Y", 0xEE); op("pop", "PSW", 0x8E)
op("set1", "d.b", 0x02, 'db'); op("clr1", "d.b", 0x12, 'db')
op("bbs", "d.b,r", 0x03, 'dbr'); op("bbc", "d.b,r", 0x13, 'dbr')
op("tset1", "!a", 0x0E, 'a'); op("tclr1", "!a", 0x4E, 'a')
for m, c in (("clrc", 0x60), ("setc", 0x80), ("notc", 0xED), ("clrv", 0xE0), ("clrp", 0x20),
             ("setp", 0x40), ("ei", 0xA0), ("di", 0xC0), ("nop", 0x00), ("sleep", 0xEF), ("stop", 0xFF)):
    op(m, "", c)


class AsmError(Exception):
    pass


class Assembler:
    def __init__(self):
        self.syms = {}
        self.glob = ""

    # ---- expressions ----
    def value(self, text, pass2):
        t = text.strip()
        t = re.sub(r"\$([0-9A-Fa-f]+)", lambda m: str(int(m.group(1), 16)), t)
        t = re.sub(r"%([01]+)", lambda m: str(int(m.group(1), 2)), t)
        t = re.sub(r"'(.)'", lambda m: str(ord(m.group(1))), t)
        # <expr / >expr prefixes (low/high byte) at the start
        lo = hi = False
        if t.startswith("<"):
            lo, t = True, t[1:]
        elif t.startswith(">"):
            hi, t = True, t[1:]

        def sym(m):
            n = m.group(0)
            if n.startswith("."):
                n = self.glob + n
            if n in self.syms:
                return str(self.syms[n])
            if pass2:
                raise AsmError("undefined symbol %s" % n)
            return "0"
        t = re.sub(r"\.?[A-Za-z_][A-Za-z_0-9]*", sym, t)
        try:
            v = int(eval(t, {"__builtins__": {}}))
        except Exception:
            raise AsmError("bad expression %r" % text)
        if lo:
            v &= 0xFF
        if hi:
            v = (v >> 8) & 0xFF
        return v

    # ---- operand classification ----
    def classify(self, o):
        s = o.strip()
        u = s.upper().replace(" ", "")
        for reg in ("A", "X", "Y", "YA", "SP", "PSW", "C"):
            if u == reg:
                return reg, []
        if u in ("(X)", "(X)+", "(Y)"):
            return u, []
        if s.startswith("#"):
            return "#i", [s[1:]]
        m = re.match(r"^\[\s*!(.*)\+\s*[xX]\s*\]$", s)
        if m:
            return "[!a+X]", [m.group(1)]
        m = re.match(r"^\[(.*)\+\s*[xX]\s*\]$", s)
        if m:
            return "[d+X]", [m.group(1)]
        m = re.match(r"^\[(.*)\]\s*\+\s*[yY]$", s)
        if m:
            return "[d]+Y", [m.group(1)]
        if s.startswith("!"):
            m = re.match(r"^!(.*)\+\s*([xXyY])$", s)
            if m:
                return "!a+" + m.group(2).upper(), [m.group(1)]
            return "!a", [s[1:]]
        m = re.match(r"^(.*)\.([0-7])$", s)
        if m and not re.match(r"^\.[A-Za-z_]", s):
            return "d.b", [m.group(1), m.group(2)]
        m = re.match(r"^(.*)\+\s*([xXyY])$", s)
        if m:
            return "d+" + m.group(2).upper(), [m.group(1)]
        return "d", [s]

    def split_ops(self, text):
        out, depth, cur = [], 0, ""
        for ch in text:
            if ch in "([":
                depth += 1
            elif ch in ")]":
                depth -= 1
            if ch == "," and depth == 0:
                out.append(cur)
                cur = ""
            else:
                cur += ch
        if cur.strip():
            out.append(cur)
        return out

    def encode(self, mn, ops, pc, pass2):
        pats, args = [], []
        for o in ops:
            p, a = self.classify(o)
            pats.append(p)
            args.append(a)
        # a lone expression operand may be a rel target
        key = (mn, ",".join(pats))
        cands = [key]
        if pats and pats[-1] == "d":
            cands.append((mn, ",".join(pats[:-1] + ["r"])))
        for k in cands:
            if k in OPS:
                code, enc = OPS[k]
                break
        else:
            raise AsmError("bad instruction %s %s (%s)" % (mn, ",".join(ops), ",".join(pats)))
        v = [[self.value(x, pass2) for x in a] for a in args]

        def rel(target, size):
            d = target - (pc + size)
            if pass2 and not -128 <= d <= 127:
                raise AsmError("branch out of range (%d)" % d)
            return d & 0xFF
        if enc == '':
            return bytes([code])
        if enc == 'i':
            return bytes([code, v[-1][0] & 0xFF])
        if enc == 'd':
            dv = [x for x in v if x][0][0]
            return bytes([code, dv & 0xFF])
        if enc == 'a':
            av = [x for x in v if x][0][0]
            return bytes([code, av & 0xFF, (av >> 8) & 0xFF])
        if enc == 'r':
            return bytes([code, rel(v[-1][0], 2)])
        if enc == 'dd':            # mov/op dst,src -> opcode src dst
            return bytes([code, v[1][0] & 0xFF, v[0][0] & 0xFF])
        if enc == 'di':            # op dp,#imm -> opcode imm dp
            return bytes([code, v[1][0] & 0xFF, v[0][0] & 0xFF])
        if enc == 'dr':
            return bytes([code, v[0][0] & 0xFF, rel(v[1][0], 3)])
        if enc == 'db':
            return bytes([code | (v[0][1] << 5), v[0][0] & 0xFF])
        if enc == 'dbr':
            return bytes([code | (v[0][1] << 5), v[0][0] & 0xFF, rel(v[1][0], 3)])
        raise AsmError("encoding")

    def assemble(self, src, base_dir="."):
        lines = src.split("\n")
        for pss in (1, 2):
            pc = 0
            org = None
            out = {}
            self.glob = ""
            for ln, raw in enumerate(lines, 1):
                line = re.sub(r";.*", "", raw).rstrip()
                if not line.strip():
                    continue
                try:
                    m = re.match(r"^\s*([A-Za-z_][A-Za-z_0-9]*)\s*=\s*(.+)$", line)
                    if m:
                        self.syms[m.group(1)] = self.value(m.group(2), pss == 2)
                        continue
                    m = re.match(r"^\s*(\.?[A-Za-z_][A-Za-z_0-9]*):\s*(.*)$", line)
                    if m:
                        name = m.group(1)
                        if name.startswith("."):
                            name = self.glob + name
                        else:
                            self.glob = name
                        self.syms[name] = pc
                        line = m.group(2)
                        if not line.strip():
                            continue
                    parts = line.strip().split(None, 1)
                    mn = parts[0].lower()
                    rest = parts[1] if len(parts) > 1 else ""
                    if mn == ".org":
                        pc = self.value(rest, pss == 2)
                        if org is None:
                            org = pc
                        continue
                    if mn in (".byte", ".db"):
                        data = bytes(self.value(x, pss == 2) & 0xFF for x in self.split_ops(rest))
                    elif mn in (".word", ".dw"):
                        data = b"".join(bytes([self.value(x, pss == 2) & 0xFF, (self.value(x, pss == 2) >> 8) & 0xFF])
                                        for x in self.split_ops(rest))
                    elif mn == ".ascii":
                        data = rest.strip().strip('"').encode()
                    elif mn == ".res":
                        data = bytes(self.value(rest, pss == 2))
                    elif mn == ".incbin":
                        data = open(base_dir + "/" + rest.strip().strip('"'), "rb").read()
                    else:
                        ops = self.split_ops(rest) if rest else []
                        data = self.encode(mn, ops, pc, pss == 2)
                    for i, b in enumerate(data):
                        out[pc + i] = b
                    pc += len(data)
                except AsmError as e:
                    raise AsmError("line %d: %s\n  %s" % (ln, e, raw))
        lo = min(out) if out else 0
        hi = max(out) + 1 if out else 0
        img = bytearray(hi - lo)
        for a, b in out.items():
            img[a - lo] = b
        return lo, bytes(img)


if __name__ == "__main__":
    A = Assembler()
    import os
    src = open(sys.argv[1]).read()
    base, img = A.assemble(src, os.path.dirname(os.path.abspath(sys.argv[1])))
    open(sys.argv[2], "wb").write(img)
    if len(sys.argv) > 3:
        with open(sys.argv[3], "w") as f:
            for n, v in sorted(A.syms.items()):
                if "." not in n:
                    f.write("SPC_%s = $%04X\n" % (n, v))
    print("spc: $%04X-$%04X (%d bytes)" % (base, base + len(img) - 1, len(img)))
