#!/usr/bin/env python3
"""
test_asm.py  –  Unit tests for tmept_asm.py
============================================
Run:  python3 test_asm.py [-v]
"""

import sys, os, unittest
sys.path.insert(0, os.path.dirname(__file__))

from tmept_asm import (
    Preprocessor, pass1, pass2, eval_expr,
    parse_register, split_operands, AsmError,
    encode_3std, encode_2reg, encode_2noreg, encode_lmar,
    encode_cmp4, encode_djn4, write_binary, OPCODES,
)
import tempfile, textwrap

def asm(src, defines=None):
    """Assemble a source string, return memory dict."""
    pp = Preprocessor(defines=defines or {})
    lines = pp.process_string(textwrap.dedent(src))
    syms, located = pass1(lines, predefined=defines)
    syms.update({k: v for k, v in pp.defines.items() if k not in syms})
    mem, _ = pass2(located, syms)
    return mem

def mem_bytes(src, defines=None):
    """Assemble and return sorted list of (addr, byte)."""
    return sorted(asm(src, defines).items())

def flat(src, org=0, defines=None):
    """Assemble, return bytes starting at org as a bytearray."""
    m = asm(src, defines)
    if not m:
        return bytearray()
    end = max(m) + 1
    ba = bytearray(end - org)
    for addr, b in m.items():
        if addr >= org:
            ba[addr - org] = b
    return ba


# ─────────────────────────────────────────────────────────────────────────────
class TestExprEval(unittest.TestCase):

    def ev(self, s, syms=None):
        return eval_expr(s, syms or {})

    def test_decimal(self):        self.assertEqual(self.ev('42'), 42)
    def test_hex(self):            self.assertEqual(self.ev('0xFF'), 255)
    def test_binary(self):         self.assertEqual(self.ev('0b1010'), 10)
    def test_octal(self):          self.assertEqual(self.ev('0o17'), 15)
    def test_add(self):            self.assertEqual(self.ev('3+4'), 7)
    def test_sub(self):            self.assertEqual(self.ev('10-3'), 7)
    def test_mul(self):            self.assertEqual(self.ev('3*4'), 12)
    def test_div(self):            self.assertEqual(self.ev('12//4'), 3)
    def test_bitwise_or(self):     self.assertEqual(self.ev('0xF0|0x0F'), 0xFF)
    def test_bitwise_and(self):    self.assertEqual(self.ev('0xFF&0x0F'), 0x0F)
    def test_bitwise_xor(self):    self.assertEqual(self.ev('0xFF^0x0F'), 0xF0)
    def test_shift_left(self):     self.assertEqual(self.ev('1<<4'), 16)
    def test_shift_right(self):    self.assertEqual(self.ev('0x80>>3'), 16)
    def test_parens(self):         self.assertEqual(self.ev('(2+3)*4'), 20)
    def test_lo(self):             self.assertEqual(self.ev('lo(0x1234)'), 0x34)
    def test_hi(self):             self.assertEqual(self.ev('hi(0x1234)'), 0x12)
    def test_lo_expr(self):        self.assertEqual(self.ev('lo(0x100+5)'), 5)
    def test_symbol(self):         self.assertEqual(self.ev('FOO+1', {'FOO': 9}), 10)
    def test_nested_lo_hi(self):   self.assertEqual(self.ev('hi(0xABCD)', {}), 0xAB)
    def test_error(self):
        with self.assertRaises(AsmError):
            self.ev('undefined_sym')


# ─────────────────────────────────────────────────────────────────────────────
class TestParseRegister(unittest.TestCase):

    def test_r0(self):   self.assertEqual(parse_register('R0'), 0)
    def test_r15(self):  self.assertEqual(parse_register('R15'), 15)
    def test_lower(self): self.assertEqual(parse_register('r7'), 7)
    def test_spaces(self): self.assertEqual(parse_register(' R3 '), 3)
    def test_bad(self):
        with self.assertRaises(AsmError): parse_register('X3')
    def test_out_of_range(self):
        with self.assertRaises(AsmError): parse_register('R16')


# ─────────────────────────────────────────────────────────────────────────────
class TestSplitOperands(unittest.TestCase):

    def test_single(self):   self.assertEqual(split_operands('R1'), ['R1'])
    def test_two(self):      self.assertEqual(split_operands('R1, R2'), ['R1', 'R2'])
    def test_three(self):    self.assertEqual(split_operands('R1,R2,R3'), ['R1','R2','R3'])
    def test_parens(self):   self.assertEqual(split_operands('R1, lo(X+1)'), ['R1', 'lo(X+1)'])
    def test_nested(self):   self.assertEqual(split_operands('lo(a,b)'), ['lo(a,b)'])


# ─────────────────────────────────────────────────────────────────────────────
class TestArithmeticEncoding(unittest.TestCase):
    """3-byte standard instruction encoding."""

    def test_add_3addr(self):
        # ADD R1, R2, R3  →  0x00  {00,01,00}  {0010,0011}  0x00
        b = flat('ADD R1, R2, R3')
        self.assertEqual(b[0], 0x00)                     # opcode
        self.assertEqual(b[1], (0b00 << 6) | (1 << 2))  # mode=00, dst=1
        self.assertEqual(b[2], (2 << 4) | 3)             # src1=2, src2=3
        self.assertEqual(b[3], 0x00)

    def test_add_2addr(self):
        # ADD R5, R6  → mode=01
        b = flat('ADD R5, R6')
        self.assertEqual(b[0], 0x00)
        self.assertEqual(b[1], (0b01 << 6) | (5 << 2))  # mode=01, dst=5
        self.assertEqual(b[2], (5 << 4) | 6)             # src1=dst=5, src2=6

    def test_add_imm(self):
        # ADD R2, #0x11  → mode=10
        b = flat('ADD R2, #0x11')
        self.assertEqual(b[0], 0x00)
        self.assertEqual(b[1], (0b10 << 6) | (2 << 2))  # mode=10, dst=2
        self.assertEqual(b[2], 0x11)                      # imm

    def test_sub(self):
        b = flat('SUB R1, R2, R3')
        self.assertEqual(b[0], 0x02)

    def test_xor_self(self):
        # XOR R1, R1, R1  (zero idiom)
        b = flat('XOR R1, R1, R1')
        self.assertEqual(b[0], 0x08)
        self.assertEqual(b[1], (0b00 << 6) | (1 << 2))
        self.assertEqual(b[2], (1 << 4) | 1)

    def test_cmp(self):
        b = flat('CMP R3, R4')
        self.assertEqual(b[0], 0x09)

    def test_adc(self):
        b = flat('ADC R1, R2, R3')
        self.assertEqual(b[0], 0x01)

    def test_and_imm(self):
        b = flat('AND R7, #0xF0')
        self.assertEqual(b[0], 0x04)
        self.assertEqual(b[2], 0xF0)

    def test_or(self):
        b = flat('OR R1, R2, R3')
        self.assertEqual(b[0], 0x05)

    def test_nor(self):
        b = flat('NOR R1, R2, R3')
        self.assertEqual(b[0], 0x06)

    def test_nad(self):
        b = flat('NAD R1, R2, R3')
        self.assertEqual(b[0], 0x07)


# ─────────────────────────────────────────────────────────────────────────────
class TestShiftEncoding(unittest.TestCase):

    def test_rol(self):
        b = flat('ROL R3, R4')
        self.assertEqual(b[0], 0x0A)

    def test_ror(self):
        b = flat('ROR R3, R4')
        self.assertEqual(b[0], 0x0E)

    def test_sol(self):
        b = flat('SOL R1, R2')
        self.assertEqual(b[0], 0x0B)

    def test_szl(self):
        b = flat('SZL R1, R2')
        self.assertEqual(b[0], 0x0C)

    def test_ril(self):
        b = flat('RIL R1, R2')
        self.assertEqual(b[0], 0x0D)

    def test_sor(self):
        b = flat('SOR R1, R2')
        self.assertEqual(b[0], 0x0F)

    def test_szr(self):
        b = flat('SZR R1, R2')
        self.assertEqual(b[0], 0x10)

    def test_rir(self):
        b = flat('RIR R1, R2')
        self.assertEqual(b[0], 0x11)


# ─────────────────────────────────────────────────────────────────────────────
class TestBitManipEncoding(unittest.TestCase):

    def test_inv(self):
        b = flat('INV R5')
        self.assertEqual(b[0], 0x12)
        # mode=01 (2-addr single-operand)
        self.assertEqual(b[1], (0b01 << 6) | (5 << 2))

    def test_rev(self):
        b = flat('REV R2')
        self.assertEqual(b[0], 0x1D)

    def test_inh(self):  b = flat('INH R1'); self.assertEqual(b[0], 0x13)
    def test_inl(self):  b = flat('INL R1'); self.assertEqual(b[0], 0x14)
    def test_ine(self):  b = flat('INE R1'); self.assertEqual(b[0], 0x15)
    def test_ino(self):  b = flat('INO R1'); self.assertEqual(b[0], 0x16)
    def test_ieh(self):  b = flat('IEH R1'); self.assertEqual(b[0], 0x17)
    def test_ioh(self):  b = flat('IOH R1'); self.assertEqual(b[0], 0x18)
    def test_iel(self):  b = flat('IEL R1'); self.assertEqual(b[0], 0x19)
    def test_iol(self):  b = flat('IOL R1'); self.assertEqual(b[0], 0x1A)
    def test_ifb(self):  b = flat('IFB R1'); self.assertEqual(b[0], 0x1B)
    def test_ilb(self):  b = flat('ILB R1'); self.assertEqual(b[0], 0x1C)
    def test_rvl(self):  b = flat('RVL R1'); self.assertEqual(b[0], 0x1E)
    def test_rvh(self):  b = flat('RVH R1'); self.assertEqual(b[0], 0x1F)
    def test_rve(self):  b = flat('RVE R1'); self.assertEqual(b[0], 0x20)
    def test_rvo(self):  b = flat('RVO R1'); self.assertEqual(b[0], 0x21)
    def test_rle(self):  b = flat('RLE R1'); self.assertEqual(b[0], 0x22)
    def test_rhe(self):  b = flat('RHE R1'); self.assertEqual(b[0], 0x23)
    def test_rlo(self):  b = flat('RLO R1'); self.assertEqual(b[0], 0x24)
    def test_rho(self):  b = flat('RHO R1'); self.assertEqual(b[0], 0x25)


# ─────────────────────────────────────────────────────────────────────────────
class TestBranchEncoding(unittest.TestCase):

    def _check_branch(self, mnem, opc, reg=5):
        b = flat(f'{mnem} R{reg}')
        self.assertEqual(len(b), 2)
        self.assertEqual(b[0], opc)
        self.assertEqual(b[1], reg << 2)

    def test_jmp(self):  self._check_branch('JMP', 0x26)
    def test_jmz(self):  self._check_branch('JMZ', 0x27)
    def test_jmn(self):  self._check_branch('JMN', 0x28)
    def test_jmg(self):  self._check_branch('JMG', 0x29)
    def test_jmo(self):  self._check_branch('JMO', 0x2A)
    def test_jie(self):  self._check_branch('JIE', 0x2B)
    def test_jio(self):  self._check_branch('JIO', 0x2C)
    def test_jne(self):  self._check_branch('JNE', 0x38)
    def test_jge(self):  self._check_branch('JGE', 0x39)
    def test_jle(self):  self._check_branch('JLE', 0x3A)

    def test_r0_target(self):
        b = flat('JMP R0')
        self.assertEqual(b[1], 0x00)

    def test_r15_target(self):
        b = flat('JMP R15')
        self.assertEqual(b[1], 15 << 2)


# ─────────────────────────────────────────────────────────────────────────────
class TestDataMovementEncoding(unittest.TestCase):

    def test_mov_reg(self):
        # MOV R2, R7  →  3-byte mode=01
        b = flat('MOV R2, R7')
        self.assertEqual(b[0], 0x2D)
        self.assertEqual(b[1], (0b01 << 6) | (2 << 2))

    def test_mov_mar(self):
        # MOV R3, [MAR]  →  3-byte mode=11
        b = flat('MOV R3, [MAR]')
        self.assertEqual(b[0], 0x2D)
        self.assertEqual(b[1], (0b11 << 6) | (3 << 2))
        self.assertEqual(b[2], 0x00)

    def test_lmar_literal(self):
        b = flat('LMAR 0x1234')
        self.assertEqual(b[0], 0x2E)
        self.assertEqual(b[1], 0x12)  # high byte
        self.assertEqual(b[2], 0x34)  # low byte

    def test_lmar_zero(self):
        b = flat('LMAR 0')
        self.assertEqual(b, bytearray([0x2E, 0x00, 0x00]))

    def test_smar(self):
        b = flat('SMAR R4')
        self.assertEqual(b[0], 0x2F)
        self.assertEqual(b[1], 4 << 2)

    def test_load(self):
        b = flat('LOAD R1')
        self.assertEqual(b[0], 0x30)
        self.assertEqual(b[1], 1 << 2)

    def test_stor(self):
        b = flat('STOR R2')
        self.assertEqual(b[0], 0x31)
        self.assertEqual(b[1], 2 << 2)

    def test_imar(self):
        b = flat('IMAR')
        self.assertEqual(b, bytearray([0x32, 0x00]))

    def test_dmar(self):
        b = flat('DMAR')
        self.assertEqual(b, bytearray([0x33, 0x00]))


# ─────────────────────────────────────────────────────────────────────────────
class TestStackEncoding(unittest.TestCase):

    def test_push(self):
        b = flat('PUSH R3')
        self.assertEqual(b[0], 0x3B)
        self.assertEqual(b[1], 3 << 2)

    def test_pop(self):
        b = flat('POP R5')
        self.assertEqual(b[0], 0x3C)
        self.assertEqual(b[1], 5 << 2)

    def test_call(self):
        b = flat('CALL R6')
        self.assertEqual(b[0], 0x3D)
        self.assertEqual(b[1], 6 << 2)

    def test_ret(self):
        b = flat('RET')
        self.assertEqual(b, bytearray([0x3E, 0x00]))


# ─────────────────────────────────────────────────────────────────────────────
class TestCompoundEncoding(unittest.TestCase):

    def test_djn(self):
        # DJN R1, R5  →  0x35 {0001,0000} {0001,0000} {0101,0000}
        b = flat('DJN R1, R5')
        self.assertEqual(len(b), 4)
        self.assertEqual(b[0], 0x35)
        self.assertEqual(b[1], (1 << 4) | 0)   # src1=1, src2=0
        self.assertEqual(b[2], (1 << 4))        # dst=1
        self.assertEqual(b[3], (5 << 4))        # jmp=5

    def test_ale(self):
        # ALE R1, R2, R3, R4
        b = flat('ALE R1, R2, R3, R4')
        self.assertEqual(b[0], 0x34)
        self.assertEqual(b[1], (1 << 4) | 2)   # src1=1, src2=2
        self.assertEqual(b[2], (3 << 4))        # dst=3
        self.assertEqual(b[3], (4 << 4))        # jmp=4

    def test_sle(self):
        b = flat('SLE R2, R3, R4, R5')
        self.assertEqual(b[0], 0x36)
        self.assertEqual(b[1], (2 << 4) | 3)

    def test_sjn(self):
        b = flat('SJN R1, R2, R3, R4')
        self.assertEqual(b[0], 0x37)


# ─────────────────────────────────────────────────────────────────────────────
class TestLabels(unittest.TestCase):

    def test_label_defines_address(self):
        src = """
        .org 0x10
        start:
          NOP_DUMMY:  ; just a label, no instruction
          ADD R1, #1
        """
        # We don't have NOP, use RET as stand-in
        src = ".org 0x10\nstart:\nRET\n"
        m = asm(src)
        # start should be at 0x10
        pp = Preprocessor()
        lines = pp.process_string(src)
        syms, _ = pass1(lines)
        self.assertEqual(syms['start'], 0x10)

    def test_label_used_in_lmar(self):
        src = """
        .org 0x0000
          LMAR target
          RET
        target:
          ADD R1, #1
        """
        b = flat(src)
        # LMAR at 0x0000 should encode address of target
        # RET is 2 bytes, so target = 0x0000 + 3 (LMAR) + 2 (RET) = 0x0005
        self.assertEqual(b[0], 0x2E)
        self.assertEqual(b[1], 0x00)
        self.assertEqual(b[2], 0x05)

    def test_forward_reference_in_lmar(self):
        src = """
        LMAR forward
        RET
        forward:
        ADD R1, #0
        """
        b = flat(src)
        self.assertEqual(b[1], 0x00)
        self.assertEqual(b[2], 0x05)  # 3 + 2 = 5

    def test_duplicate_label_error(self):
        src = "start:\nstart:\nRET\n"
        with self.assertRaises(AsmError):
            asm(src)

    def test_label_in_expression(self):
        src = ".equ BASE, 0x100\nLMAR BASE+0x10\n"
        b = flat(src)
        self.assertEqual(b[1], 0x01)
        self.assertEqual(b[2], 0x10)


# ─────────────────────────────────────────────────────────────────────────────
class TestDirectives(unittest.TestCase):

    def test_org(self):
        src = ".org 0x200\nRET\n"
        m = asm(src)
        self.assertIn(0x200, m)
        self.assertEqual(m[0x200], 0x3E)

    def test_org_gap(self):
        src = ".org 0x00\nRET\n.org 0x10\nRET\n"
        m = asm(src)
        self.assertIn(0x00, m)
        self.assertIn(0x10, m)
        self.assertNotIn(0x02, m)

    def test_equ(self):
        src = ".equ ANSWER, 42\nADD R1, #ANSWER\n"
        b = flat(src)
        self.assertEqual(b[2], 42)

    def test_equ_expression(self):
        src = ".equ BASE, 0x100\n.equ OFFSET, 0x20\nLMAR BASE+OFFSET\n"
        b = flat(src)
        self.assertEqual(b[1], 0x01)
        self.assertEqual(b[2], 0x20)

    def test_byte_single(self):
        src = ".byte 0xAB\n"
        m = asm(src)
        self.assertEqual(list(m.values()), [0xAB])

    def test_byte_multiple(self):
        src = ".byte 1, 2, 3\n"
        m = asm(src)
        self.assertEqual(sorted(m.items()), [(0,1),(1,2),(2,3)])

    def test_word_little_endian(self):
        src = ".word 0x1234\n"
        m = asm(src)
        self.assertEqual(m[0], 0x34)
        self.assertEqual(m[1], 0x12)

    def test_word_multiple(self):
        src = ".word 0x0001, 0x0200\n"
        m = asm(src)
        self.assertEqual(m[0], 0x01); self.assertEqual(m[1], 0x00)
        self.assertEqual(m[2], 0x00); self.assertEqual(m[3], 0x02)

    def test_resetvec(self):
        src = ".resetvec 0x0200\n"
        m = asm(src)
        self.assertEqual(m[0xFFFC], 0x00)
        self.assertEqual(m[0xFFFD], 0x02)

    def test_resetvec_does_not_advance_lc(self):
        src = ".org 0x00\n.resetvec 0x0200\nRET\n"
        m = asm(src)
        self.assertIn(0x00, m)   # RET is at 0x0000, not displaced

    def test_byte_expression(self):
        src = ".equ X, 10\n.byte X*2\n"
        m = asm(src)
        self.assertEqual(list(m.values()), [20])


# ─────────────────────────────────────────────────────────────────────────────
class TestMacros(unittest.TestCase):

    def test_user_macro_no_params(self):
        src = """
        .macro HALT
          JMP R0
        .endm
        HALT
        """
        b = flat(src)
        self.assertEqual(b[0], 0x26)  # JMP
        self.assertEqual(b[1], 0x00)  # R0

    def test_user_macro_with_params(self):
        src = """
        .macro ZERO \\reg
          XOR \\reg, \\reg, \\reg
        .endm
        ZERO R5
        """
        b = flat(src)
        self.assertEqual(b[0], 0x08)  # XOR
        # dst=5, src1=5, src2=5
        self.assertEqual(b[1], (0b00 << 6) | (5 << 2))
        self.assertEqual(b[2], (5 << 4) | 5)

    def test_macro_label_on_invocation(self):
        src = """
        .macro NOP_MACRO
          ADD R0, #0
        .endm
        entry:  NOP_MACRO
        """
        pp = Preprocessor()
        lines = pp.process_string(textwrap.dedent(src))
        syms, _ = pass1(lines)
        self.assertEqual(syms.get('entry'), 0)

    def test_user_macro_two_params(self):
        src = """
        .macro COPY \\dst, \\src
          MOV \\dst, \\src
        .endm
        COPY R3, R7
        """
        b = flat(src)
        self.assertEqual(b[0], 0x2D)
        self.assertEqual(b[1], (0b01 << 6) | (3 << 2))

    def test_unterminated_macro_error(self):
        src = ".macro NOEND\nRET\n"
        with self.assertRaises(AsmError):
            Preprocessor().process_string(src)

    def test_macro_wrong_arg_count(self):
        src = ".macro M \\a, \\b\nADD \\a, \\b\n.endm\nM R1\n"
        with self.assertRaises(AsmError):
            asm(src)


# ─────────────────────────────────────────────────────────────────────────────
class TestBuiltinMacros(unittest.TestCase):

    def test_loadaddr_small(self):
        # LOADADDR R3, 0x42  →  XOR R3,R3,R3  +  ADD R3,#0x42
        src = "LOADADDR R3, 0x42\n"
        b = flat(src)
        # XOR R3,R3,R3 = 3 bytes
        self.assertEqual(b[0], 0x08)
        self.assertEqual(b[1], (0b00 << 6) | (3 << 2))
        self.assertEqual(b[2], (3 << 4) | 3)
        # ADD R3,#0x42 = 3 bytes
        self.assertEqual(b[3], 0x00)
        self.assertEqual(b[4], (0b10 << 6) | (3 << 2))
        self.assertEqual(b[5], 0x42)

    def test_loadaddr_label(self):
        src = "LOADADDR R1, target\ntarget:\nRET\n"
        b = flat(src)
        # XOR(3) + ADD(3) = 6 bytes before target, so target=6
        self.assertEqual(b[5], 6)  # imm in ADD

    def test_jmp_l(self):
        src = "JMP_L R2, dest\ndest:\nRET\n"
        b = flat(src)
        # XOR(3) + ADD(3) + JMP(2) = 8 bytes, dest=8
        self.assertEqual(b[0], 0x08)  # XOR
        self.assertEqual(b[3], 0x00)  # ADD opcode
        self.assertEqual(b[6], 0x26)  # JMP
        self.assertEqual(b[7], 2 << 2)  # R2

    def test_call_l(self):
        src = "CALL_L R4, sub\nsub:\nRET\n"
        b = flat(src)
        self.assertEqual(b[6], 0x3D)  # CALL
        self.assertEqual(b[7], 4 << 2)


# ─────────────────────────────────────────────────────────────────────────────
class TestIncludes(unittest.TestCase):

    def test_include_basic(self):
        with tempfile.TemporaryDirectory() as td:
            lib = os.path.join(td, 'lib.asm')
            with open(lib, 'w') as f:
                f.write('.equ MAGIC, 0xBE\n')
            main = os.path.join(td, 'main.asm')
            with open(main, 'w') as f:
                f.write(f'.include "lib.asm"\nADD R1, #MAGIC\n')
            pp = Preprocessor()
            lines = pp.process_file(main)
            syms, located = pass1(lines)
            syms.update(pp.defines)
            mem, _ = pass2(located, syms)
            # ADD R1, #MAGIC: bytes at 0x0000..0x0002
            # b[2] is the immediate value = MAGIC = 0xBE
            self.assertIn(2, mem)
            self.assertEqual(mem[2], 0xBE)

    def test_circular_include_error(self):
        with tempfile.TemporaryDirectory() as td:
            a = os.path.join(td, 'a.asm')
            with open(a, 'w') as f:
                f.write('.include "a.asm"\n')
            with self.assertRaises(AsmError):
                Preprocessor().process_file(a)

    def test_missing_include_error(self):
        with tempfile.TemporaryDirectory() as td:
            main = os.path.join(td, 'main.asm')
            with open(main, 'w') as f:
                f.write('.include "missing.asm"\n')
            with self.assertRaises(AsmError):
                Preprocessor().process_file(main)


# ─────────────────────────────────────────────────────────────────────────────
class TestBinaryWriter(unittest.TestCase):

    def test_empty_memory(self):
        with tempfile.TemporaryDirectory() as td:
            path = os.path.join(td, 'out.bin')
            write_binary({}, path)
            self.assertEqual(os.path.getsize(path), 0)

    def test_single_byte(self):
        with tempfile.TemporaryDirectory() as td:
            path = os.path.join(td, 'out.bin')
            write_binary({0: 0xAB}, path)
            with open(path, 'rb') as f:
                self.assertEqual(f.read(), bytes([0xAB]))

    def test_contiguous(self):
        with tempfile.TemporaryDirectory() as td:
            path = os.path.join(td, 'out.bin')
            write_binary({0: 0x11, 1: 0x22, 2: 0x33}, path)
            with open(path, 'rb') as f:
                self.assertEqual(f.read(), bytes([0x11, 0x22, 0x33]))

    def test_gap_zero_padded(self):
        """Addresses 0 and 4 written; bytes 1-3 should be 0x00."""
        with tempfile.TemporaryDirectory() as td:
            path = os.path.join(td, 'out.bin')
            write_binary({0: 0xAA, 4: 0xBB}, path)
            with open(path, 'rb') as f:
                data = f.read()
            self.assertEqual(len(data), 5)
            self.assertEqual(data[0], 0xAA)
            self.assertEqual(data[1:4], bytes(3))   # zero-padded gap
            self.assertEqual(data[4], 0xBB)

    def test_file_size_equals_max_addr_plus_one(self):
        with tempfile.TemporaryDirectory() as td:
            path = os.path.join(td, 'out.bin')
            write_binary({0x00: 0x3E, 0x01: 0x00}, path)
            self.assertEqual(os.path.getsize(path), 2)

    def test_reset_vector_at_fffc(self):
        """Reset vector bytes at 0xFFFC/0xFFFD produce a 65536-byte image."""
        with tempfile.TemporaryDirectory() as td:
            path = os.path.join(td, 'out.bin')
            mem = {0x0000: 0x3E, 0x0001: 0x00,
                   0xFFFC: 0x00, 0xFFFD: 0x02}
            write_binary(mem, path)
            self.assertEqual(os.path.getsize(path), 0xFFFE)
            with open(path, 'rb') as f:
                data = f.read()
            self.assertEqual(data[0x0000], 0x3E)
            self.assertEqual(data[0xFFFC], 0x00)
            self.assertEqual(data[0xFFFD], 0x02)

    def test_large_contiguous(self):
        with tempfile.TemporaryDirectory() as td:
            path = os.path.join(td, 'out.bin')
            mem = {i: i & 0xFF for i in range(256)}
            write_binary(mem, path)
            with open(path, 'rb') as f:
                data = f.read()
            self.assertEqual(len(data), 256)
            for i in range(256):
                self.assertEqual(data[i], i & 0xFF)

    def test_binary_round_trip_via_assembler(self):
        """Assemble a RET instruction and verify binary output."""
        with tempfile.TemporaryDirectory() as td:
            src_path = os.path.join(td, 'test.asm')
            bin_path = os.path.join(td, 'test.bin')
            with open(src_path, 'w') as f:
                f.write('.org 0x0000\nRET\n')
            import subprocess, sys
            result = subprocess.run(
                [sys.executable,
                 os.path.join(os.path.dirname(__file__), 'tmept_asm.py'),
                 src_path, '-o', bin_path, '--no-reset-vec'],
                capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            with open(bin_path, 'rb') as f:
                data = f.read()
            self.assertEqual(data, bytes([0x3E, 0x00]))


# ─────────────────────────────────────────────────────────────────────────────
class TestCommandLineDefines(unittest.TestCase):

    def test_define_used_in_expr(self):
        src = "ADD R1, #VERSION\n"
        b = flat(src, defines={'VERSION': 7})
        self.assertEqual(b[2], 7)

    def test_define_overrides_equ(self):
        src = ".equ X, 10\nADD R1, #X\n"
        # -D X=99 should win
        b = flat(src, defines={'X': 99})
        self.assertEqual(b[2], 99)


# ─────────────────────────────────────────────────────────────────────────────
class TestErrorHandling(unittest.TestCase):

    def test_unknown_mnemonic(self):
        with self.assertRaises(AsmError):
            asm('FOOBAR R1\n')

    def test_wrong_operand_count_ret(self):
        with self.assertRaises(AsmError):
            asm('RET R1\n')

    def test_wrong_operand_count_djn(self):
        with self.assertRaises(AsmError):
            asm('DJN R1\n')

    def test_lmar_out_of_range(self):
        with self.assertRaises(AsmError):
            asm('LMAR 0x10000\n')

    def test_register_out_of_range(self):
        with self.assertRaises(AsmError):
            asm('ADD R16, R1\n')

    def test_bad_register_name(self):
        with self.assertRaises(AsmError):
            asm('JMP X5\n')

    def test_duplicate_label(self):
        with self.assertRaises(AsmError):
            asm('foo:\nfoo:\nRET\n')


# ─────────────────────────────────────────────────────────────────────────────
class TestMultiInstructionProgram(unittest.TestCase):
    """Assemble a small complete program and verify the full byte stream."""

    def test_sum_loop(self):
        """Mirrors cpu_tb.v Program 1: sum 1..5 in R2, loop counter in R1."""
        src = """
        .org 0x0000
          .equ COUNT, 5

          XOR  R1, R1, R1        ; R1 = 0
          ADD  R1, #COUNT        ; R1 = 5
          XOR  R2, R2, R2        ; R2 = 0
          XOR  R5, R5, R5        ; R5 = 0 (halt address)
          ADD  R3, #lo(loop)     ; R3 = loop address

        loop:
          ADD  R2, R1            ; R2 += R1
          DJN  R1, R3            ; R1--; if R1!=0 jump to loop

        done:
          JMP  R5                ; halt (jump to 0)
        """
        b = flat(src)
        # First instruction is XOR R1,R1,R1 at 0x00
        self.assertEqual(b[0], 0x08)  # XOR opcode
        # ADD R1, #5 at offset 3
        self.assertEqual(b[3], 0x00)  # ADD opcode
        self.assertEqual(b[5], 5)     # immediate = 5

    def test_stack_call_ret(self):
        """PUSH / CALL / RET round-trip."""
        src = """
        .org 0x0000
          XOR  R1, R1, R1
          ADD  R1, #0x11          ; R1 = 0x11
          LOADADDR R3, sub        ; R3 = address of sub
          PUSH R1
          CALL R3
          POP  R4
          JMP  R0

        sub:
          XOR  R6, R6, R6
          ADD  R6, #0xAB
          RET
        """
        b = flat(src)
        # PUSH should appear as 0x3B
        push_pos = None
        for i in range(len(b)):
            if b[i] == 0x3B:
                push_pos = i
                break
        self.assertIsNotNone(push_pos)
        # CALL should follow shortly after
        call_pos = None
        for i in range(push_pos, len(b)):
            if b[i] == 0x3D:
                call_pos = i
                break
        self.assertIsNotNone(call_pos)


# ─────────────────────────────────────────────────────────────────────────────
class TestOpcodeTableCompleteness(unittest.TestCase):
    """Every opcode in the table should assemble without errors."""

    SINGLE_OPERAND_MNEMS = {
        'INV','INH','INL','INE','INO','IEH','IOH','IEL','IOL','IFB','ILB',
        'REV','RVL','RVH','RVE','RVO','RLE','RHE','RLO','RHO',
    }

    def test_all_opcodes_assemble(self):
        for mnem, (opc, enc) in OPCODES.items():
            with self.subTest(mnem=mnem):
                if enc == '3std':
                    if mnem in self.SINGLE_OPERAND_MNEMS:
                        src = f'{mnem} R1\n'
                    elif mnem == 'MOV':
                        src = f'MOV R1, R2\n'
                    elif mnem == 'CMP':
                        src = f'CMP R1, R2\n'
                    else:
                        src = f'{mnem} R1, R2, R3\n'
                elif enc == '2reg':
                    src = f'{mnem} R1\n'
                elif enc == '2noreg':
                    src = f'{mnem}\n'
                elif enc == 'lmar':
                    src = f'{mnem} 0x1000\n'
                elif enc == 'cmp4':
                    src = f'{mnem} R1, R2, R3, R4\n'
                elif enc == 'djn4':
                    src = f'{mnem} R1, R2\n'
                else:
                    continue
                m = asm(src)
                # Verify opcode byte is present
                if m:
                    first_byte = m[min(m.keys())]
                    self.assertEqual(first_byte, opc,
                        f'{mnem}: expected opcode 0x{opc:02X}, got 0x{first_byte:02X}')


# ─────────────────────────────────────────────────────────────────────────────
class TestNewSyntax(unittest.TestCase):
    """Tests for 6502-style syntax additions."""

    # ── $ hex literals ────────────────────────────────────────────────────────
    def test_dollar_hex_literal(self):
        b = flat('ADD R1, $42\n')
        self.assertEqual(b[2], 0x42)

    def test_dollar_hex_in_org(self):
        src = '.org $0100\nRET\n'
        m = asm(src)
        self.assertIn(0x100, m)
        self.assertEqual(m[0x100], 0x3E)

    def test_dollar_hex_in_lmar(self):
        b = flat('LMAR $1234\n')
        self.assertEqual(b[1], 0x12)
        self.assertEqual(b[2], 0x34)

    def test_dollar_hex_in_constant(self):
        src = 'ADDR = $BEEF\nLMAR ADDR\n'
        b = flat(src)
        self.assertEqual(b[1], 0xBE)
        self.assertEqual(b[2], 0xEF)

    def test_dollar_hex_expression(self):
        b = flat('ADD R1, $10+$02\n')
        self.assertEqual(b[2], 0x12)

    def test_dollar_two_digit(self):
        b = flat('ADD R1, $FF\n')
        self.assertEqual(b[2], 0xFF)

    # ── NAME = value constant assignment ──────────────────────────────────────
    def test_name_equals_decimal(self):
        src = 'COUNT = 7\nADD R1, COUNT\n'
        b = flat(src)
        self.assertEqual(b[2], 7)

    def test_name_equals_hex(self):
        src = 'MASK = $F0\nADD R2, MASK\n'
        b = flat(src)
        self.assertEqual(b[2], 0xF0)

    def test_name_equals_expression(self):
        src = 'BASE = $10\nOFFSET = 4\nLMAR BASE+OFFSET\n'
        b = flat(src)
        self.assertEqual(b[2], 0x14)

    def test_name_equals_forward_label(self):
        # Constant defined after use (forward ref handled in pass 2)
        src = 'LMAR DEST\nRET\nDEST = $0080\n'
        b = flat(src)
        self.assertEqual(b[1], 0x00)
        self.assertEqual(b[2], 0x80)

    def test_name_equals_coexists_with_equ(self):
        # Both styles work in the same file
        src = 'A = 10\n.equ B, 20\nADD R1, A\nADD R2, B\n'
        b = flat(src)
        self.assertEqual(b[2], 10)
        self.assertEqual(b[5], 20)  # second ADD immediate byte (offset 3+2)

    # ── Immediate without # ───────────────────────────────────────────────────
    def test_imm_no_hash(self):
        b = flat('ADD R1, 5\n')
        self.assertEqual(b[0], 0x00)
        self.assertEqual(b[2], 5)

    def test_imm_no_hash_hex(self):
        b = flat('ADD R1, $AB\n')
        self.assertEqual(b[2], 0xAB)

    def test_imm_no_hash_expression(self):
        src = 'N = 3\nADD R1, N*2\n'
        b = flat(src)
        self.assertEqual(b[2], 6)

    def test_imm_hash_still_works(self):
        # Old # style must remain valid
        b = flat('ADD R1, #$42\n')
        self.assertEqual(b[2], 0x42)

    def test_imm_no_hash_does_not_confuse_register(self):
        # ADD R1, R2 must still encode as 2-address, not immediate
        b = flat('ADD R1, R2\n')
        self.assertEqual(b[1], (0b01 << 6) | (1 << 2))  # mode=01
        self.assertEqual(b[2], (1 << 4) | 2)

    # ── Macro params without backslash ────────────────────────────────────────
    def test_macro_param_no_backslash(self):
        src = '.macro ZERO reg\n  XOR reg, reg, reg\n.endm\nZERO R5\n'
        b = flat(src)
        self.assertEqual(b[0], 0x08)  # XOR
        self.assertEqual(b[2], (5 << 4) | 5)

    def test_macro_two_params_no_backslash(self):
        src = '.macro COPY dst, src\n  MOV dst, src\n.endm\nCOPY R3, R7\n'
        b = flat(src)
        self.assertEqual(b[0], 0x2D)  # MOV
        self.assertEqual(b[1], (0b01 << 6) | (3 << 2))

    def test_macro_backslash_style_still_works(self):
        # Old \param style must remain valid alongside bare-param style
        src = '.macro ZERO \\reg\n  XOR \\reg, \\reg, \\reg\n.endm\nZERO R3\n'
        b = flat(src)
        self.assertEqual(b[0], 0x08)
        self.assertEqual(b[2], (3 << 4) | 3)

if __name__ == '__main__':
    unittest.main(verbosity=2)
