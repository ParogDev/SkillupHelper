#!/usr/bin/env python3
"""A small, tolerant reader of Lua table literals: the data files this addon ships and a SavedVariables file.

    read_assignment(text, "SkillupHelperDB")   -> the table assigned to that name, or None
    read_assignment(text, "ns.Data.recipes")   -> works on a dotted name too
    parse_value(text)                          -> one literal

Python 3 standard library only. A table becomes a dict: `[1] = x`, `["a"] = x` and `a = x` keep their key, values
without a key get 1, 2, 3 ... as Lua numbers them. Strings, numbers, true / false / nil, nested tables and comments
are read; anything else (a function call, a variable) is a LuaError that names the offset. Nothing is executed.
"""
from __future__ import annotations

import re

TOKEN = re.compile(r"""
    (?P<ws>\s+)
  | (?P<comment>--\[(?P<ceq>=*)\[.*?\](?P=ceq)\] | --[^\n]*)
  | (?P<number>-?(?:0[xX][0-9a-fA-F]+ | (?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?))
  | (?P<name>[A-Za-z_][A-Za-z0-9_]*)
  | (?P<long>\[(?P<leq>=*)\[(?P<longbody>.*?)\](?P=leq)\])
  | (?P<punct>[{}\[\]=,;])
  | (?P<quote>["'])
""", re.VERBOSE | re.DOTALL)
ESCAPES = {"n": 10, "t": 9, "r": 13, "a": 7, "b": 8, "f": 12, "v": 11, "\\": 92, '"': 34, "'": 39, "\n": 10}
MAX_DEPTH = 64


class LuaError(ValueError):
    """Not a literal this reader knows; the message names the offset."""


class _Reader:
    def __init__(self, text: str, pos: int = 0):
        self.text, self.pos = text, pos

    def _next(self, peek: bool = False):
        """The next token as (kind, value), skipping blanks and comments."""
        pos = self.pos
        while True:
            m = TOKEN.match(self.text, pos)
            if not m:
                if pos >= len(self.text):
                    return ("end", None)
                raise LuaError(f"unexpected {self.text[pos]!r} at offset {pos}")
            kind = m.lastgroup
            if kind in ("ws", "comment"):
                pos = m.end()
                continue
            break
        if kind == "quote":
            value, end = self._string(m.end(), m.group("quote"))
            kind = "string"
        elif kind == "long":
            value, end, kind = m.group("longbody"), m.end(), "string"
        else:
            value, end = m.group(kind), m.end()
        if not peek:
            self.pos = end
        return (kind, value)

    def _string(self, pos: int, quote: str):
        out = bytearray()
        text = self.text
        while True:
            if pos >= len(text):
                raise LuaError("a string never ends")
            c = text[pos]
            if c == quote:
                return out.decode("utf-8", "replace"), pos + 1
            if c == "\\":
                pos += 1
                d = re.compile(r"\d{1,3}").match(text, pos)
                if d:
                    out.append(int(d.group()) & 255)
                    pos = d.end()
                    continue
                if pos < len(text) and text[pos] in ESCAPES:
                    out.append(ESCAPES[text[pos]])
                    pos += 1
                    continue
                raise LuaError(f"unknown string escape at offset {pos}")
            out += c.encode("utf-8")
            pos += 1

    def value(self, depth: int = 0):
        kind, v = self._next()
        if kind == "string":
            return v
        if kind == "number":
            if v.lower().startswith(("0x", "-0x")):
                return int(v, 16)
            n = float(v)
            return int(n) if n.is_integer() and "e" not in v.lower() and "." not in v else n
        if kind == "name":
            if v in ("true", "false"):
                return v == "true"
            if v == "nil":
                return None
            raise LuaError(f"{v!r} is not a literal (offset {self.pos})")
        if kind == "punct" and v == "{":
            if depth >= MAX_DEPTH:
                raise LuaError("tables nested too deep")
            return self._table(depth + 1)
        raise LuaError(f"expected a value, got {v!r} at offset {self.pos}")

    def _table(self, depth: int) -> dict:
        out, index = {}, 1
        while True:
            kind, v = self._next(peek=True)
            if kind == "punct" and v == "}":
                self._next()
                return out
            if kind == "end":
                raise LuaError("a table never closes")
            if kind == "punct" and v == "[":
                self._next()
                key = self.value(depth)
                self._expect("]")
                self._expect("=")
                if isinstance(key, float) and key.is_integer():
                    key = int(key)
                out[key] = self.value(depth)
            elif kind == "name" and self._is_field():
                self._next()
                self._expect("=")
                out[v] = self.value(depth)
            else:
                out[index] = self.value(depth)
                index += 1
            kind, v = self._next(peek=True)
            if kind == "punct" and v in ",;":
                self._next()

    def _is_field(self) -> bool:
        """The name ahead is `name =`, not a bare value such as true."""
        save = self.pos
        self._next()
        kind, v = self._next(peek=True)
        self.pos = save
        return kind == "punct" and v == "="

    def _expect(self, what: str):
        kind, v = self._next()
        if v != what:
            raise LuaError(f"expected {what!r}, got {v!r} at offset {self.pos}")


def parse_value(text: str, pos: int = 0):
    """The literal that starts at `pos`."""
    return _Reader(text, pos).value()


def read_assignment(text: str, name: str):
    """The literal assigned to `name` at the start of a line (`name = { ... }`), or None when the file has no such
    assignment. A `name = something that is not a literal` is skipped; the first literal wins."""
    for m in re.finditer(r"(?m)^[ \t]*" + re.escape(name) + r"[ \t]*=[ \t]*", text):
        try:
            return parse_value(text, m.end())
        except LuaError:
            if text[m.end():m.end() + 1] == "{":
                raise
    return None
