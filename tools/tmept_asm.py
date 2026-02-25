#!/usr/bin/env python3
r"""
tmept_asm.py  –  Assembler for the TMEPT 8-bit CPU
====================================================

Usage:
    python3 tmept_asm.py input.asm [-o output.bin] [-l listing.lst]
                                   [-D NAME[=VALUE] ...] [--no-reset-vec]

Output:
    Flat binary file (.bin)     raw ROM image, zero-padded between regions
    Listing file   (.lst)       optional annotated source with hex bytes and addresses

Features:
    Labels          foo:     define; foo  reference (resolved in two passes)
    Constants       NAME = expr  or  .equ NAME, expr
    Expressions     +  -  *  /  %  |  &  ^  ~  <<  >>  ( )
                    lo(expr)  hi(expr)  – low/high byte extractors
                    $XXXX  – hex literals (alias for 0xXXXX)
    Macros          .macro NAME [p1, p2, ...] / .endm  with \p1 substitution
    Built-in macros LOADADDR, JMP_L, CALL_L  (handle register-indirect branches)
    Directives      .org  .byte  .word  .include  .resetvec
    Comments        ; to end of line
    Includes        .include "file.asm"  (relative to including file)
    Command-line    -D NAME  or  -D NAME=VALUE  pre-define constants

Instruction syntax recap:
    3-address:   ADD  Rd, Rs1, Rs2
    2-address:   ADD  Rd, Rs             (dst = dst op src)
    immediate:   ADD  Rd, expr    (or  ADD  Rd, #expr)
    memory:      MOV  Rd, [MAR]
    branch:      JMP  Rn
    MAR:         LMAR expr16  |  SMAR Rn  |  LOAD Rd  |  STOR Rs
                 IMAR  |  DMAR
    stack:       PUSH Rs  |  POP Rd  |  CALL Rn  |  RET
    compound:    DJN  Rs, Rjmp
                 ALE  Rs1, Rs2, Rd, Rjmp
                 SLE  Rs1, Rs2, Rd, Rjmp
                 SJN  Rs1, Rs2, Rd, Rjmp
"""

import re
import sys
import os
import argparse
from copy import deepcopy

# ── Opcode table ──────────────────────────────────────────────────────────────
# Each entry: (opcode_byte, encoding_class)
# encoding_class:
#   '3std'   3-byte standard  (supports mode 00/01/10/11 via operand inspection)
#   '2reg'   2-byte, single register in w1_dst field
#   '2noreg' 2-byte, no register (IMAR, DMAR, RET)
#   'lmar'   3-byte LMAR (16-bit address in W1+W2)
#   'cmp4'   4-byte compound (src1, src2, dst, Rjmp)
#   'djn4'   4-byte DJN     (src1, Rjmp  – src2/dst implicit)

OPCODES = {
    # Arithmetic / logic
    'ADD':  (0x00, '3std'),
    'ADC':  (0x01, '3std'),
    'SUB':  (0x02, '3std'),
    'SBC':  (0x03, '3std'),
    'AND':  (0x04, '3std'),
    'OR':   (0x05, '3std'),
    'NOR':  (0x06, '3std'),
    'NAD':  (0x07, '3std'),
    'XOR':  (0x08, '3std'),
    'CMP':  (0x09, '3std'),
    # Shift / rotate
    'ROL':  (0x0A, '3std'),
    'SOL':  (0x0B, '3std'),
    'SZL':  (0x0C, '3std'),
    'RIL':  (0x0D, '3std'),
    'ROR':  (0x0E, '3std'),
    'SOR':  (0x0F, '3std'),
    'SZR':  (0x10, '3std'),
    'RIR':  (0x11, '3std'),
    # Bit manipulation (all single-operand: dst = f(dst))
    'INV':  (0x12, '3std'),
    'INH':  (0x13, '3std'),
    'INL':  (0x14, '3std'),
    'INE':  (0x15, '3std'),
    'INO':  (0x16, '3std'),
    'IEH':  (0x17, '3std'),
    'IOH':  (0x18, '3std'),
    'IEL':  (0x19, '3std'),
    'IOL':  (0x1A, '3std'),
    'IFB':  (0x1B, '3std'),
    'ILB':  (0x1C, '3std'),
    'REV':  (0x1D, '3std'),
    'RVL':  (0x1E, '3std'),
    'RVH':  (0x1F, '3std'),
    'RVE':  (0x20, '3std'),
    'RVO':  (0x21, '3std'),
    'RLE':  (0x22, '3std'),
    'RHE':  (0x23, '3std'),
    'RLO':  (0x24, '3std'),
    'RHO':  (0x25, '3std'),
    # Branches (register-indirect)
    'JMP':  (0x26, '2reg'),
    'JMZ':  (0x27, '2reg'),
    'JMN':  (0x28, '2reg'),
    'JMG':  (0x29, '2reg'),
    'JMO':  (0x2A, '2reg'),
    'JIE':  (0x2B, '2reg'),
    'JIO':  (0x2C, '2reg'),
    'JNE':  (0x38, '2reg'),
    'JGE':  (0x39, '2reg'),
    'JLE':  (0x3A, '2reg'),
    # Data movement
    'MOV':  (0x2D, '3std'),  # also handles MOV Rd,[MAR]
    'LMAR': (0x2E, 'lmar'),
    'SMAR': (0x2F, '2reg'),
    'LOAD': (0x30, '2reg'),
    'STOR': (0x31, '2reg'),
    'IMAR': (0x32, '2noreg'),
    'DMAR': (0x33, '2noreg'),
    # Compound
    'ALE':  (0x34, 'cmp4'),
    'DJN':  (0x35, 'djn4'),
    'SLE':  (0x36, 'cmp4'),
    'SJN':  (0x37, 'cmp4'),
    # Stack
    'PUSH': (0x3B, '2reg'),
    'POP':  (0x3C, '2reg'),
    'CALL': (0x3D, '2reg'),
    'RET':  (0x3E, '2noreg'),
}

# Single-operand bit-manip (only dst, no src in standard 3-byte form)
SINGLE_OPERAND = {
    'INV','INH','INL','INE','INO','IEH','IOH','IEL','IOL','IFB','ILB',
    'REV','RVL','RVH','RVE','RVO','RLE','RHE','RLO','RHO',
}

# ── Built-in macros ───────────────────────────────────────────────────────────
# These expand before the main encode step.
# LOADADDR Rn, expr  →  XOR Rn,Rn,Rn  +  ADD Rn,#lo(expr)
#                       [if expr > 0xFF also: ADD Rn,#hi(expr) then shift somehow]
# Note: since the ISA only supports 8-bit immediate writes to the low byte,
# addresses > 0xFF cannot be fully loaded with two instructions.
# We emit a warning and load only the low byte for those cases.
# A proper 16-bit load requires additional instructions (documented in the ref).
BUILTIN_MACROS = {
    'LOADADDR': ['\\1', '\\2'],   # handled specially in expand_macros
    'JMP_L':    ['\\1', '\\2'],
    'CALL_L':   ['\\1', '\\2'],
}

# ── Error / warning helpers ───────────────────────────────────────────────────

class AsmError(Exception):
    def __init__(self, msg, filename=None, lineno=None):
        self.msg      = msg
        self.filename = filename
        self.lineno   = lineno
    def __str__(self):
        loc = ''
        if self.filename:
            loc = f'{self.filename}'
        if self.lineno is not None:
            loc += f':{self.lineno}'
        return f'Error ({loc}): {self.msg}' if loc else f'Error: {self.msg}'

warnings_issued = []

def warn(msg, filename=None, lineno=None):
    loc = ''
    if filename:
        loc = f'{filename}'
    if lineno is not None:
        loc += f':{lineno}'
    w = f'Warning ({loc}): {msg}' if loc else f'Warning: {msg}'
    warnings_issued.append(w)
    print(w, file=sys.stderr)

# ── Expression evaluator ──────────────────────────────────────────────────────

def eval_expr(expr_str, symbols, filename=None, lineno=None):
    """
    Evaluate an integer expression with:
      - decimal, 0x hex, 0b binary, 0o octal literals
      - operators: + - * / % | & ^ ~ << >> ( )
      - functions: lo(x) hi(x)
      - symbol references (resolved from 'symbols' dict)
    Returns an integer.
    """
    s = expr_str.strip()

    # Translate $XXXX hex literals to 0xXXXX so Python eval understands them
    s = re.sub(r'\$([0-9A-Fa-f]+)', lambda m: hex(int(m.group(1), 16)), s)

    # Replace lo() and hi() with Python-evaluable forms
    # Use unique markers to avoid re-substitution
    s = re.sub(r'\blo\s*\(', '__lo__(', s)
    s = re.sub(r'\bhi\s*\(', '__hi__(', s)

    # Build a local namespace with all symbols
    ns = {k: v for k, v in symbols.items()}
    ns['__lo__'] = lambda x: int(x) & 0xFF
    ns['__hi__'] = lambda x: (int(x) >> 8) & 0xFF

    # Replace symbol names that look like identifiers (but not Python keywords)
    # We do this by building the namespace and letting eval handle it.
    # Strip any 'R' prefix from register names that sneaked in as expressions.

    try:
        result = eval(s, {"__builtins__": {}}, ns)
        return int(result)
    except Exception as e:
        raise AsmError(f"Cannot evaluate expression '{expr_str}': {e}",
                       filename, lineno)

# ── Tokeniser / line parser ───────────────────────────────────────────────────

def strip_comment(line):
    """Remove ; comments, respecting strings (for .include "path")."""
    in_str = False
    for i, ch in enumerate(line):
        if ch == '"':
            in_str = not in_str
        if ch == ';' and not in_str:
            return line[:i]
    return line

def parse_register(tok, filename=None, lineno=None):
    """Parse 'R0'..'R15' (case-insensitive). Returns 0..15."""
    m = re.fullmatch(r'[Rr](\d+)', tok.strip())
    if not m:
        raise AsmError(f"Expected register (R0–R15), got '{tok}'", filename, lineno)
    n = int(m.group(1))
    if n > 15:
        raise AsmError(f"Register R{n} out of range (max R15)", filename, lineno)
    return n

def split_operands(operand_str):
    """Split comma-separated operands, respecting parentheses."""
    parts = []
    depth = 0
    cur   = ''
    for ch in operand_str:
        if ch == '(':
            depth += 1
            cur += ch
        elif ch == ')':
            depth -= 1
            cur += ch
        elif ch == ',' and depth == 0:
            parts.append(cur.strip())
            cur = ''
        else:
            cur += ch
    if cur.strip():
        parts.append(cur.strip())
    return parts

# ── Source line representation ────────────────────────────────────────────────

class SourceLine:
    __slots__ = ('filename', 'lineno', 'label', 'mnemonic', 'operands', 'raw')
    def __init__(self, filename, lineno, label, mnemonic, operands, raw):
        self.filename  = filename
        self.lineno    = lineno
        self.label     = label    # str or None
        self.mnemonic  = mnemonic # str (upper) or None
        self.operands  = operands # list of str
        self.raw       = raw      # original text

# ── Pre-processor: include + macro expansion ──────────────────────────────────

class Preprocessor:
    def __init__(self, defines=None):
        self.macros   = {}          # name -> (params, body_lines)
        self.defines  = dict(defines or {})
        self._include_stack = []    # to detect circular includes

    def process_file(self, path):
        """Return list of SourceLine after include/macro expansion."""
        abs_path = os.path.abspath(path)
        if abs_path in self._include_stack:
            raise AsmError(f"Circular include: {path}")
        self._include_stack.append(abs_path)
        try:
            with open(abs_path, 'r') as fh:
                raw_lines = fh.readlines()
        except OSError as e:
            raise AsmError(f"Cannot open '{path}': {e}")
        result = self._process_lines(raw_lines, abs_path)
        self._include_stack.pop()
        return result

    def process_string(self, text, filename='<string>'):
        return self._process_lines(text.splitlines(keepends=True), filename)

    def _process_lines(self, raw_lines, filename):
        out      = []
        lineno   = 0
        in_macro = None   # (name, params, body) while collecting .macro body
        macro_body = []

        for raw in raw_lines:
            lineno += 1
            line = strip_comment(raw).strip()
            if not line:
                continue

            # ── .macro / .endm collection ────────────────────────────────
            if in_macro is not None:
                if line.upper() == '.ENDM':
                    name, params, _ = in_macro
                    self.macros[name.upper()] = (params, macro_body)
                    in_macro   = None
                    macro_body = []
                else:
                    macro_body.append(line)
                continue

            upper = line.upper()

            if upper.startswith('.MACRO'):
                rest = line[6:].strip()
                parts = re.split(r'[\s,]+', rest, maxsplit=1)
                mname = parts[0].upper() if parts else ''
                if not mname:
                    raise AsmError(".macro requires a name", filename, lineno)
                param_str = parts[1] if len(parts) > 1 else ''
                # Strip leading backslash(es) from param names so
                # '.macro M \\name' and '.macro M name' both work.
                params = [p.strip().lstrip('\\') for p in param_str.split(',') if p.strip()]
                in_macro   = (mname, params, [])
                macro_body = []
                continue

            # ── .include ─────────────────────────────────────────────────
            if upper.startswith('.INCLUDE'):
                m = re.match(r'\.include\s+"([^"]+)"', line, re.IGNORECASE)
                if not m:
                    raise AsmError("Malformed .include", filename, lineno)
                inc_path = m.group(1)
                if not os.path.isabs(inc_path):
                    inc_path = os.path.join(os.path.dirname(filename), inc_path)
                out.extend(self.process_file(inc_path))
                continue

            # ── NAME = expr  (6502-style constant assignment) ───────────
            m_assign = re.match(r'^([A-Za-z_]\w*)\s*=\s*(.+)$', line)
            if m_assign:
                name = m_assign.group(1)
                # Rewrite as .equ so pass 1/2 handle it uniformly
                line = f'.equ {name}, {m_assign.group(2).strip()}'
                upper = line.upper()

            # ── .equ (pre-processor phase — also handled in pass 1) ──────
            m = re.match(r'(?:[A-Za-z_]\w*\s*:\s*)?\.equ\s+(\w+)\s*,\s*(.+)',
                         line, re.IGNORECASE)
            if m:
                name = m.group(1)
                try:
                    val = eval_expr(m.group(2), self.defines, filename, lineno)
                    self.defines[name] = val
                except AsmError:
                    pass  # will be re-evaluated in pass 1 with full symbol table

            # ── Macro invocation check ────────────────────────────────────
            # Parse the line first to get mnemonic
            sl = self._parse_one(line, filename, lineno)
            if sl and sl.mnemonic and sl.mnemonic.upper() in self.macros:
                expanded = self._expand_macro(sl, filename, lineno)
                out.extend(expanded)
                continue

            # ── Built-in macros ───────────────────────────────────────────
            if sl and sl.mnemonic:
                mn = sl.mnemonic.upper()
                if mn in ('LOADADDR', 'JMP_L', 'CALL_L'):
                    expanded = self._expand_builtin(sl, filename, lineno)
                    out.extend(expanded)
                    continue

            if sl:
                out.append(sl)

        if in_macro is not None:
            raise AsmError(f"Unterminated .macro '{in_macro[0]}'", filename)
        return out

    def _parse_one(self, line, filename, lineno):
        """Parse a single (already comment-stripped) line into a SourceLine."""
        line = line.strip()
        if not line:
            return None

        label    = None
        mnemonic = None
        operands = []

        # Label (optional): identifier followed by ':'
        m = re.match(r'^([A-Za-z_]\w*)\s*:', line)
        if m:
            label = m.group(1)
            line  = line[m.end():].strip()

        if not line:
            return SourceLine(filename, lineno, label, None, [], line)

        # Directive or mnemonic
        m = re.match(r'^([A-Za-z_.]\w*)', line)
        if not m:
            return SourceLine(filename, lineno, label, None, [], line)

        mnemonic  = m.group(1)
        rest      = line[m.end():].strip()
        operands  = split_operands(rest) if rest else []

        return SourceLine(filename, lineno, label, mnemonic.upper(), operands, line)

    def _expand_macro(self, sl, filename, lineno):
        """Expand a user-defined macro invocation."""
        name   = sl.mnemonic.upper()
        params, body = self.macros[name]
        args   = sl.operands

        if len(args) != len(params):
            raise AsmError(
                f"Macro '{name}' expects {len(params)} args, got {len(args)}",
                filename, lineno)

        result = []
        for body_line in body:
            expanded = body_line
            for param, arg in zip(params, args):
                # Support both \param and bare param as substitution markers
                expanded = expanded.replace(f'\\{param}', arg)
                expanded = re.sub(rf'\b{re.escape(param)}\b', arg, expanded)
            # Re-parse the expanded line
            sub = self._parse_one(expanded, filename, lineno)
            if sub:
                # carry through the label from the invocation site (first line only)
                if result == [] and sl.label:
                    sub.label = sl.label
                result.append(sub)
        return result

    def _expand_builtin(self, sl, filename, lineno):
        """Expand LOADADDR, JMP_L, CALL_L."""
        mn   = sl.mnemonic.upper()
        ops  = sl.operands
        out  = []

        def make(label, mnemonic, operands):
            s = SourceLine(filename, lineno, label, mnemonic, operands, '')
            return s

        if mn == 'LOADADDR':
            if len(ops) != 2:
                raise AsmError("LOADADDR requires 2 operands: LOADADDR Rn, expr",
                                filename, lineno)
            rn, expr = ops[0], ops[1]
            out.append(make(sl.label, 'XOR',  [rn, rn, rn]))
            out.append(make(None,     'ADD',  [rn, f'#lo({expr})']))
            # High byte: emit as comment placeholder; assembler will warn if >0xFF
            # We store the full expression for the high-byte check in pass 2
            out.append(make(None, '__LOADADDR_HI__', [rn, expr]))

        elif mn == 'JMP_L':
            if len(ops) != 2:
                raise AsmError("JMP_L requires 2 operands: JMP_L Rn, label",
                                filename, lineno)
            rn, target = ops[0], ops[1]
            out.extend(self._expand_builtin(
                make(sl.label, 'LOADADDR', [rn, target]), filename, lineno))
            out.append(make(None, 'JMP', [rn]))

        elif mn == 'CALL_L':
            if len(ops) != 2:
                raise AsmError("CALL_L requires 2 operands: CALL_L Rn, label",
                                filename, lineno)
            rn, target = ops[0], ops[1]
            out.extend(self._expand_builtin(
                make(sl.label, 'LOADADDR', [rn, target]), filename, lineno))
            out.append(make(None, 'CALL', [rn]))

        return out


# ── Pass 1: assign addresses, collect labels ──────────────────────────────────

def instruction_size(sl, symbols_so_far):
    """
    Return the byte size of a SourceLine without fully encoding it.
    Used in pass 1 to advance the location counter.
    """
    if sl.mnemonic is None:
        return 0
    mn = sl.mnemonic.upper()

    # Directives
    if mn == '.ORG':
        return 0
    if mn == '.EQU':
        return 0
    if mn == '.BYTE':
        return len(sl.operands)   # each operand = 1 byte (approximate)
    if mn == '.WORD':
        return len(sl.operands) * 2
    if mn == '.RESETVEC':
        return 0   # no bytes at current LC; writes to fixed 0xFFFC
    if mn == '__LOADADDR_HI__':
        return 0   # sentinel – no bytes emitted unless hi != 0

    if mn not in OPCODES:
        return 0

    _, enc = OPCODES[mn]
    if enc == '3std':
        return 3
    if enc in ('2reg', '2noreg'):
        return 2
    if enc == 'lmar':
        return 3
    if enc in ('cmp4', 'djn4'):
        return 4
    return 0

def pass1(source_lines, predefined=None):
    """
    First pass: build symbol table (labels + .equ).
    predefined: dict of symbols that take priority over .equ (e.g. -D defines).
    Returns (symbols dict, [(sl, address), ...])
    """
    symbols  = dict(predefined or {})  # seed with -D defines
    _frozen  = set(symbols.keys())     # these cannot be overwritten by .equ
    located  = []   # (SourceLine, address)
    lc       = 0    # location counter

    for sl in source_lines:
        if sl.label:
            if sl.label in symbols:
                raise AsmError(f"Duplicate label '{sl.label}'",
                               sl.filename, sl.lineno)
            symbols[sl.label] = lc

        if sl.mnemonic:
            mn = sl.mnemonic.upper()
            if mn == '.ORG':
                if not sl.operands:
                    raise AsmError(".org requires an address", sl.filename, sl.lineno)
                try:
                    lc = eval_expr(sl.operands[0], symbols, sl.filename, sl.lineno)
                except AsmError:
                    lc = lc   # unresolvable in pass 1 – will error in pass 2
            elif mn == '.EQU':
                if len(sl.operands) < 2:
                    raise AsmError(".equ requires NAME, value", sl.filename, sl.lineno)
                name = sl.operands[0]
                if name in _frozen:
                    pass  # -D define wins; skip .equ
                else:
                    try:
                        val = eval_expr(sl.operands[1], symbols, sl.filename, sl.lineno)
                        symbols[name] = val
                    except AsmError:
                        pass  # forward reference – retry in pass 2
            else:
                size = instruction_size(sl, symbols)
                located.append((sl, lc))
                lc += size

        else:
            located.append((sl, lc))

    return symbols, located


# ── Pass 2: encode ────────────────────────────────────────────────────────────

def encode_3std(opc, sl, symbols):
    """Encode a 3-byte standard instruction."""
    fn = sl.filename
    ln = sl.lineno
    mn = sl.mnemonic.upper()
    ops = sl.operands

    # Detect encoding form from operands
    # MOV Rd, [MAR]  → mode=11
    if mn == 'MOV' and len(ops) == 2 and ops[1].strip().upper() == '[MAR]':
        rd = parse_register(ops[0], fn, ln)
        return bytes([opc, (0b11 << 6) | (rd << 2), 0x00])

    # Single-operand bit-manip:  INV Rd  →  encode as mode=01 dst=Rd src=Rd
    # (dst = f(dst), src fields don't matter but we pack them cleanly)
    if mn in SINGLE_OPERAND:
        if len(ops) != 1:
            raise AsmError(f"{mn} takes 1 operand", fn, ln)
        rd = parse_register(ops[0], fn, ln)
        # mode=01 (2-addr), dst=rd; src fields 0
        return bytes([opc, (0b01 << 6) | (rd << 2), (rd << 4) | 0x0, 0x00])

    if len(ops) == 3:
        # 3-address: Rd, Rs1, Rs2
        rd  = parse_register(ops[0], fn, ln)
        rs1 = parse_register(ops[1], fn, ln)
        rs2 = parse_register(ops[2], fn, ln)
        return bytes([opc, (0b00 << 6) | (rd << 2), (rs1 << 4) | rs2, 0x00])

    if len(ops) == 2:
        rd = parse_register(ops[0], fn, ln)
        op2 = ops[1].strip()

        # Strip optional # prefix (6502-style immediate marker)
        imm_str = op2[1:] if op2.startswith('#') else op2
        # Determine if this operand is a register or an immediate
        if re.fullmatch(r'[Rr]\d+', imm_str.strip()):
            # 2-address: Rd, Rs  → mode=01
            rs = parse_register(imm_str, fn, ln)
            return bytes([opc, (0b01 << 6) | (rd << 2), (rd << 4) | rs, 0x00])
        else:
            # immediate — evaluate as expression
            imm = eval_expr(imm_str, symbols, fn, ln) & 0xFF
            return bytes([opc, (0b10 << 6) | (rd << 2), imm, 0x00])

    if len(ops) == 1:
        # CMP Rd  (single register compare with self? unlikely but legal)
        rd = parse_register(ops[0], fn, ln)
        return bytes([opc, (0b01 << 6) | (rd << 2), (rd << 4) | rd, 0x00])

    raise AsmError(f"{mn}: unexpected operand count ({len(ops)})", fn, ln)


def encode_2reg(opc, sl, symbols):
    """Encode a 2-byte instruction with a single register in w1_dst."""
    fn = sl.filename
    ln = sl.lineno
    mn = sl.mnemonic.upper()
    ops = sl.operands
    if len(ops) != 1:
        raise AsmError(f"{mn} takes exactly 1 register operand", fn, ln)
    rn = parse_register(ops[0], fn, ln)
    return bytes([opc, (rn << 2)])


def encode_2noreg(opc, sl, symbols):
    """Encode a 2-byte instruction with no register (IMAR, DMAR, RET)."""
    fn = sl.filename
    ln = sl.lineno
    mn = sl.mnemonic.upper()
    if sl.operands:
        raise AsmError(f"{mn} takes no operands", fn, ln)
    return bytes([opc, 0x00])


def encode_lmar(opc, sl, symbols):
    """Encode LMAR: 3 bytes, 16-bit address in W1+W2."""
    fn = sl.filename
    ln = sl.lineno
    ops = sl.operands
    if len(ops) != 1:
        raise AsmError("LMAR takes one address operand", fn, ln)
    addr = eval_expr(ops[0], symbols, fn, ln)
    if addr < 0 or addr > 0xFFFF:
        raise AsmError(f"LMAR address 0x{addr:X} out of 16-bit range", fn, ln)
    return bytes([opc, (addr >> 8) & 0xFF, addr & 0xFF])


def encode_cmp4(opc, sl, symbols):
    """Encode ALE/SLE/SJN: 4 bytes – src1, src2, dst, Rjmp."""
    fn = sl.filename
    ln = sl.lineno
    mn = sl.mnemonic.upper()
    ops = sl.operands
    if len(ops) != 4:
        raise AsmError(f"{mn} requires 4 operands: Rs1, Rs2, Rd, Rjmp", fn, ln)
    rs1  = parse_register(ops[0], fn, ln)
    rs2  = parse_register(ops[1], fn, ln)
    rd   = parse_register(ops[2], fn, ln)
    rjmp = parse_register(ops[3], fn, ln)
    return bytes([opc,
                  (rs1 << 4) | rs2,
                  (rd  << 4),
                  (rjmp << 4)])


def encode_djn4(opc, sl, symbols):
    """Encode DJN: 4 bytes – src1 (also dst), Rjmp."""
    fn = sl.filename
    ln = sl.lineno
    ops = sl.operands
    if len(ops) != 2:
        raise AsmError("DJN requires 2 operands: Rs, Rjmp", fn, ln)
    rs   = parse_register(ops[0], fn, ln)
    rjmp = parse_register(ops[1], fn, ln)
    # Compound: src1=rs src2=0 dst=rs jmp=rjmp
    return bytes([opc,
                  (rs << 4) | 0,
                  (rs << 4),
                  (rjmp << 4)])


def encode_directive(sl, symbols, memory):
    """
    Handle assembler directives. Returns (bytes_to_emit, new_lc or None).
    memory: dict address->byte (for .resetvec which writes to a fixed address).
    """
    fn = sl.filename
    ln = sl.lineno
    mn = sl.mnemonic.upper()
    ops = sl.operands

    if mn == '.ORG':
        addr = eval_expr(ops[0], symbols, fn, ln)
        return b'', addr   # signal lc change

    if mn == '.EQU':
        # Already handled in pass 1; resolve again in case of forward refs
        name = ops[0]
        val  = eval_expr(ops[1], symbols, fn, ln)
        symbols[name] = val
        return b'', None

    if mn == '.BYTE':
        data = bytearray()
        for op in ops:
            v = eval_expr(op, symbols, fn, ln)
            if v < -128 or v > 255:
                raise AsmError(f".byte value {v} out of range", fn, ln)
            data.append(v & 0xFF)
        return bytes(data), None

    if mn == '.WORD':
        data = bytearray()
        for op in ops:
            v = eval_expr(op, symbols, fn, ln) & 0xFFFF
            data.append(v & 0xFF)        # little-endian
            data.append((v >> 8) & 0xFF)
        return bytes(data), None

    if mn == '.RESETVEC':
        # Emit the reset vector at 0xFFFC/0xFFFD
        if len(ops) != 1:
            raise AsmError(".resetvec requires one address", fn, ln)
        addr = eval_expr(ops[0], symbols, fn, ln) & 0xFFFF
        memory[0xFFFC] = addr & 0xFF
        memory[0xFFFD] = (addr >> 8) & 0xFF
        return b'', None   # no bytes at current LC

    if mn == '__LOADADDR_HI__':
        # Sentinel from LOADADDR expansion.
        # Check if the address is > 0xFF. If so, warn (can't fully load with ISA).
        rn   = ops[0]
        expr = ops[1]
        try:
            val = eval_expr(expr, symbols, fn, ln)
        except AsmError:
            val = 0
        if val > 0xFF:
            warn(f"LOADADDR: address 0x{val:04X} > 0xFF; "
                 f"only low byte loaded into {rn}. "
                 "High byte requires additional instructions.",
                 fn, ln)
        return b'', None  # never emits bytes

    return None, None   # not a directive


def pass2(located, symbols):
    """
    Second pass: encode everything.
    Returns (memory dict addr->byte, listing list).
    """
    memory  = {}   # addr -> byte
    listing = []   # (address, bytes, SourceLine)
    lc      = 0

    # Resolve any .equ that had forward refs in pass 1.
    # Don't overwrite symbols that were pre-defined (e.g. via -D flag).
    equ_names = set()
    for sl, addr in located:
        if sl.mnemonic and sl.mnemonic.upper() == '.EQU' and len(sl.operands) >= 2:
            equ_names.add(sl.operands[0])
    # pre-defined symbols (from -D or preprocessor) take priority over .equ
    predefined = {k: v for k, v in symbols.items() if k not in equ_names}
    for sl, addr in located:
        if sl.mnemonic and sl.mnemonic.upper() == '.EQU' and len(sl.operands) >= 2:
            name = sl.operands[0]
            if name in predefined:
                continue   # -D define wins
            try:
                val = eval_expr(sl.operands[1], symbols, sl.filename, sl.lineno)
                symbols[name] = val
            except AsmError:
                pass

    for sl, addr in located:
        lc = addr

        if sl.mnemonic is None:
            listing.append((lc, b'', sl))
            continue

        mn = sl.mnemonic.upper()

        # Directives
        dir_result = encode_directive(sl, symbols, memory)
        if dir_result[0] is not None:
            data, new_lc = dir_result
            for i, b in enumerate(data):
                memory[lc + i] = b
            listing.append((lc, data, sl))
            if new_lc is not None:
                lc = new_lc
            continue

        # Instructions
        if mn not in OPCODES:
            raise AsmError(f"Unknown mnemonic '{mn}'", sl.filename, sl.lineno)

        opc, enc = OPCODES[mn]

        try:
            if enc == '3std':
                data = encode_3std(opc, sl, symbols)
            elif enc == '2reg':
                data = encode_2reg(opc, sl, symbols)
            elif enc == '2noreg':
                data = encode_2noreg(opc, sl, symbols)
            elif enc == 'lmar':
                data = encode_lmar(opc, sl, symbols)
            elif enc == 'cmp4':
                data = encode_cmp4(opc, sl, symbols)
            elif enc == 'djn4':
                data = encode_djn4(opc, sl, symbols)
            else:
                raise AsmError(f"Internal: unknown encoding '{enc}'")
        except AsmError:
            raise
        except Exception as e:
            raise AsmError(str(e), sl.filename, sl.lineno)

        for i, b in enumerate(data):
            memory[lc + i] = b
        listing.append((lc, data, sl))

    return memory, listing


# ── Binary writer ─────────────────────────────────────────────────────────────

def write_binary(memory, out_path):
    """
    Write memory dict to a flat binary file.

    The file spans from address 0 to max(address), with unwritten locations
    filled with 0x00.  Gaps between regions (e.g. between main code and the
    reset vector at 0xFFFC) are zero-padded, which is correct for ROM images.
    """
    if not memory:
        open(out_path, 'wb').close()
        return

    size = max(memory.keys()) + 1
    image = bytearray(size)           # initialised to 0x00
    for addr, byte in memory.items():
        image[addr] = byte

    with open(out_path, 'wb') as fh:
        fh.write(image)


# ── Listing writer ────────────────────────────────────────────────────────────

def write_listing(listing, symbols, out_path, src_path):
    """Write annotated listing file."""
    lines = []
    lines.append(f'; TMEPT Assembler listing')
    lines.append(f'; Source: {src_path}')
    lines.append('')

    # Symbol table at top
    if symbols:
        lines.append('; Symbols:')
        for name, val in sorted(symbols.items()):
            lines.append(f';   {name:<24} = 0x{val:04X}  ({val})')
        lines.append('')

    lines.append(f'{"Addr":>6}  {"Bytes":<12}  Source')
    lines.append('-' * 72)

    for addr, data, sl in listing:
        hex_str = ' '.join(f'{b:02X}' for b in data)
        src_txt = sl.raw if sl.raw else ''
        lines.append(f'  {addr:04X}  {hex_str:<12}  {src_txt}')

    with open(out_path, 'w') as fh:
        fh.write('\n'.join(lines) + '\n')


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description='TMEPT 8-bit CPU Assembler',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__)
    parser.add_argument('input',               help='Assembly source file')
    parser.add_argument('-o', '--output',      help='Output binary file (default: <input>.bin)')
    parser.add_argument('-l', '--listing',     help='Listing file (default: none)')
    parser.add_argument('-D', '--define',      action='append', default=[],
                        metavar='NAME[=VALUE]',
                        help='Pre-define a constant (may be repeated)')
    parser.add_argument('--no-reset-vec',      action='store_true',
                        help='Do not warn if no reset vector is defined')
    args = parser.parse_args()

    # Parse -D defines
    predefines = {}
    for d in args.define:
        if '=' in d:
            k, v = d.split('=', 1)
            try:
                predefines[k.strip()] = int(v, 0)
            except ValueError:
                predefines[k.strip()] = v.strip()
        else:
            predefines[d.strip()] = 1

    out_path = args.output or (os.path.splitext(args.input)[0] + '.bin')

    try:
        # Pre-process (includes, macros)
        pp = Preprocessor(defines=predefines)
        source_lines = pp.process_file(args.input)

        # Merge pre-processor defines into symbol table seed
        seed_symbols = dict(pp.defines)

        # Pass 1: labels + .equ
        symbols, located = pass1(source_lines, predefined=predefines)
        symbols.update({k: v for k, v in seed_symbols.items() if k not in symbols})

        # Pass 2: encode
        memory, listing = pass2(located, symbols)

        # Reset vector check
        if not args.no_reset_vec:
            if 0xFFFC not in memory or 0xFFFD not in memory:
                warn("No reset vector defined at 0xFFFC/0xFFFD. "
                     "Use .resetvec <addr> or write to 0xFFFC/0xFFFD explicitly.")

        # Outputs
        write_binary(memory, out_path)
        print(f'Wrote {len(memory)} bytes to {out_path}')

        if args.listing:
            write_listing(listing, symbols, args.listing, args.input)
            print(f'Wrote listing to {args.listing}')

        if warnings_issued:
            print(f'{len(warnings_issued)} warning(s).', file=sys.stderr)

    except AsmError as e:
        print(str(e), file=sys.stderr)
        sys.exit(1)
    except FileNotFoundError as e:
        print(f'Error: {e}', file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
