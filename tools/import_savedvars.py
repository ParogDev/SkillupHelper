#!/usr/bin/env python3
"""Merge what players' games learned into the hand-kept data.

    python tools/import_savedvars.py SkillupHelper.lua [more files ...] [--dry-run] [--report FILE]

Python 3 standard library only. Each FILE is the addon's SavedVariables file (WTF/Account/<account>/SavedVariables/
SkillupHelper.lua), as a player attached it to a "Share what my game learned" issue.

Privacy: only the `learned` table of SkillupHelperDB is read (Learned.lua writes it: game facts, no character, realm,
account or guild). Inside it only the fields listed in `clean` below are taken, each checked for its type. Nothing
else of the file is kept, printed or written, and a file is named in the report by its number on the command line,
never by its path (the path holds the account name).

What is merged, and where:
    trainers  what a trainer asks for a recipe            -> overlay.manual.json recipes[spell].learn / .cost
    ranks     what a trainer asks for a profession rank   -> overlay.manual.json ranks[line] (skill, cost)
    colors    the skill a recipe turned yellow / grey at  -> overlay.manual.json recipes[spell].y / .g, only when the
              game pinned the exact skill (orange at 124, yellow at 125)
    vendors   a vendor selling a recipe item              -> overlay.manual.json recipes[spell].vendor (+ src vendor)
              a vendor selling a reagent for money        -> overlay.manual.json vendor (the item id)
    npcs      where a trainer or vendor stands            -> tools/data/npcs_seen.json (tools/gen_npcs.py lays it
              over the Classic positions)
    skillups  tries and skill-ups per recipe              -> the report only (no shipped number to correct)

The merge rule, per fact (one recipe's learn rank, one NPC's position ...). "Shipped" is overlay.manual.json where it
has the field, else Data/Recipes.lua (or Data/Trainers.lua for a position); its build is the one in Data/Recipes.lua.
    1. Files with the same `learned` content count as one file.
    2. An observation made on a client build newer than the shipped build wins, from one file. If files seen on that
       newest build disagree with each other: a conflict, reported, nothing applied.
    3. Otherwise (same or older build, or no build recorded): to override a shipped value at least two independent
       files must agree on the new value and none may disagree. One file is "needs a second file" (reported, kept
       out). Disagreeing files are a conflict.
    4. Where the shipped data has no value at all, one file is enough (it overrides nothing).
    5. A conflict is never applied. Everything applied is listed.
Independent means different files with different content; the tool cannot know who sent a file.

Exit code: 0 nothing to apply, 10 something applied (or would be, with --dry-run), 1 an input broke (named).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gen_recipes as G  # noqa: E402
import luatable  # noqa: E402
import update_data as U  # noqa: E402

EXIT_NONE, EXIT_APPLIED, EXIT_BROKEN = 0, 10, 1
BUILD = re.compile(r"\d+(\.\d+){1,4}")
LOCALE = re.compile(r"[a-z]{2}[A-Z]{2}")
NAME_MAX = 80
POSITION_SLACK = 1.5  # map percent: two sightings of one NPC this close are the same place
CAP_NAMES = {cap: name for name, cap, _, _ in G.DEFAULT_RANKS}
SEEN_ABOUT = ("Where trainers and vendors stand, as players' games saw them (tools/import_savedvars.py). "
              "tools/gen_npcs.py lays these over the Classic positions. npcs[npc id] = { name, map (UiMap id), x, y "
              "(map percent), build, files }.")


# ---------------------------------------------------------------- reading one file: the learned table, checked


def whole(v, low: int = 0, high: int = 10 ** 9):
    if isinstance(v, bool) or not isinstance(v, (int, float)) or v != int(v) or not low <= v <= high:
        return None
    return int(v)


def number(v, low: float = 0, high: float = 10 ** 9):
    if isinstance(v, bool) or not isinstance(v, (int, float)) or not low <= v <= high:
        return None
    return round(float(v), 2)


def text(v):
    if not isinstance(v, str) or not v or len(v) > NAME_MAX or any(ord(c) < 32 for c in v):
        return None
    return v


def build_of(v):
    return v if isinstance(v, str) and BUILD.fullmatch(v) else None


def table(v) -> dict:
    return v if isinstance(v, dict) else {}


def clean(learned) -> dict | None:
    """The `learned` table with only the fields this tool knows, each of the right type. Anything else is dropped."""
    if not isinstance(learned, dict):
        return None
    out = {"version": whole(learned.get("version")), "build": build_of(learned.get("build")),
           "locale": learned.get("locale") if isinstance(learned.get("locale"), str)
           and LOCALE.fullmatch(learned["locale"]) else None,
           "trainers": {}, "ranks": {}, "vendors": {}, "npcs": {}, "colors": {}, "skillups": {}}
    for line, rows in table(learned.get("trainers")).items():
        if whole(line) is None:
            continue
        for key, e in table(rows).items():
            key = whole(key) if not isinstance(key, str) else text(key)
            row = {"skill": whole(table(e).get("skill"), 0, 1000), "cost": whole(table(e).get("cost")),
                   "seenAt": build_of(table(e).get("seenAt"))}
            if key is not None and (row["skill"] is not None or row["cost"] is not None):
                out["trainers"].setdefault(whole(line), {})[key] = row
    for line, rows in table(learned.get("ranks")).items():
        for cap, e in table(rows).items():
            e = table(e)
            if whole(line) is not None and whole(cap, 1, 1000) is not None:
                out["ranks"].setdefault(whole(line), {})[whole(cap)] = {
                    "name": text(e.get("name")), "skill": whole(e.get("skill"), 0, 1000), "cost": whole(e.get("cost")),
                    "seenAt": build_of(e.get("seenAt"))}
    for npc, e in table(learned.get("vendors")).items():
        e = table(e)
        items = {}
        for item, it in table(e.get("items")).items():
            if whole(item, 1) is not None:
                items[whole(item)] = {"price": number(table(it).get("price")), "stock": whole(table(it).get("stock"))}
        if whole(npc, 1) is not None and items:
            out["vendors"][whole(npc)] = {"map": whole(e.get("map"), 1), "x": number(e.get("x"), 0, 100),
                                          "y": number(e.get("y"), 0, 100), "seenAt": build_of(e.get("seenAt")),
                                          "items": items}
    for npc, e in table(learned.get("npcs")).items():
        e = table(e)
        row = {"name": text(e.get("name")), "map": whole(e.get("map"), 1), "x": number(e.get("x"), 0, 100),
               "y": number(e.get("y"), 0, 100)}
        if whole(npc, 1) is not None and None not in (row["map"], row["x"], row["y"]):
            out["npcs"][whole(npc)] = row
    for spell, e in table(learned.get("colors")).items():
        e = table(e)
        row = {k: whole(e.get(k), 0, 1000) for k in ("o", "y", "n", "g")}
        if whole(spell, 1) is not None and any(v is not None for v in row.values()):
            out["colors"][whole(spell)] = {**row, "seenAt": build_of(e.get("seenAt"))}
    for line, rows in table(learned.get("skillups")).items():
        for key, buckets in table(rows).items():
            key = whole(key) if not isinstance(key, str) else text(key)
            for bucket, e in table(buckets).items():
                t, u = whole(table(e).get("t"), 1), whole(table(e).get("u")) or 0
                if whole(line) is not None and key is not None and whole(bucket, 0, 1000) is not None and t:
                    out["skillups"].setdefault(whole(line), {}).setdefault(key, {})[whole(bucket)] = (t, min(u, t))
    return out


def read_file(path: Path) -> dict | None:
    """The cleaned learned table of one SavedVariables file; None when the file has none. Raises GenError (without
    the path) when the file cannot be read as Lua."""
    try:
        raw = path.read_text(encoding="utf-8-sig", errors="replace")
        db = luatable.read_assignment(raw, "SkillupHelperDB")
    except OSError as e:
        raise G.GenError(f"cannot be opened ({type(e).__name__})") from e
    except (luatable.LuaError, RecursionError) as e:
        # the reader's message holds offsets only, never file content
        raise G.GenError(f"is not a SavedVariables file this tool can read ({e})") from e
    return clean(db.get("learned")) if isinstance(db, dict) else None


def digest(learned: dict) -> str:
    return hashlib.sha256(json.dumps(learned, sort_keys=True, default=str).encode("utf-8")).hexdigest()


# ---------------------------------------------------------------- the merge rule


def newer(a: str | None, b: str | None) -> bool:
    return bool(a) and (not b or G.version_key(a) > G.version_key(b))


def decide(shipped, shipped_build: str | None, obs: list[tuple], same=lambda a, b: a == b) -> tuple[str, object, str]:
    """obs = [(value, build or None, file number)], one per file. Returns (status, value, why) with status one of
    apply, confirmed, pending, conflict."""
    files = sorted({f for _, _, f in obs})
    ahead = [o for o in obs if newer(o[1], shipped_build)]
    if ahead:
        top = max((o[1] for o in ahead), key=G.version_key)
        tops = [o for o in ahead if o[1] == top]
        if any(not same(tops[0][0], o[0]) for o in tops):
            return "conflict", None, (f"files {', '.join(str(o[2]) for o in tops)} disagree on build {top}: "
                                      + " / ".join(sorted({show(o[0]) for o in tops})))
        value = tops[0][0]
        if shipped is not None and same(value, shipped):
            return "confirmed", value, f"still true on build {top}"
        return "apply", value, (f"seen on build {top}, newer than the shipped {shipped_build or 'data'} (file "
                                f"{', '.join(str(o[2]) for o in tops)})")
    if any(not same(obs[0][0], o[0]) for o in obs):
        return "conflict", None, (f"files {', '.join(map(str, files))} disagree: "
                                  + " / ".join(sorted({show(o[0]) for o in obs})))
    value = obs[0][0]
    if shipped is not None and same(value, shipped):
        return "confirmed", value, f"{len(files)} file(s)"
    if shipped is None:
        return "apply", value, f"the shipped data has no value (file {', '.join(map(str, files))})"
    if len(files) >= 2:
        return "apply", value, f"{len(files)} files agree (files {', '.join(map(str, files))})"
    return "pending", value, f"one file (file {files[0]}) on a build that is not newer: needs a second file"


def show(v) -> str:
    if isinstance(v, tuple):
        return "map %s at %s, %s" % v
    return str(v)


def near(a, b) -> bool:
    return a[0] == b[0] and abs(a[1] - b[1]) <= POSITION_SLACK and abs(a[2] - b[2]) <= POSITION_SLACK


# ---------------------------------------------------------------- the shipped data, and the facts in the files


class Shipped:
    def __init__(self, root: Path):
        data = root / "tools" / "data"
        self.manual_file, self.seen_file = data / "overlay.manual.json", data / "npcs_seen.json"
        recipes_text = U.read_text(root / "Data" / "Recipes.lua")
        if not recipes_text:
            raise G.GenError("Data/Recipes.lua is missing: nothing to compare the files with")
        self.data = U.read_recipes(recipes_text)
        self.build = self.data["build"]
        self.manual = self._json(self.manual_file, {"recipes": {}, "vendor": []})
        self.manual.setdefault("recipes", {})
        self.manual.setdefault("vendor", [])
        self.seen = self._json(self.seen_file, {"about": SEEN_ABOUT, "npcs": {}})
        self.seen.setdefault("npcs", {})
        self.recipe, self.line_of, self.by_name, self.by_item, self.reagents = {}, {}, {}, {}, set()
        for line, prof in self.data["professions"].items():
            for spell, r in prof["recipes"].items():
                self.recipe[spell], self.line_of[spell] = r, line
                self.by_name.setdefault(line, {}).setdefault((r["name"] or "").lower(), []).append(spell)
                if r["item"]:
                    self.by_item[r["item"]] = spell
                self.reagents.update(r["mats"][0::2])
        self.trainers = {}
        trainers_text = U.read_text(root / "Data" / "Trainers.lua")
        if trainers_text:
            try:
                rows = luatable.read_assignment(trainers_text, "ns.Data.trainers") or {}
            except luatable.LuaError as e:
                raise G.GenError(f"Data/Trainers.lua: not readable ({e})") from e
            self.trainers = {r["id"]: r for r in rows.values() if isinstance(r, dict) and "id" in r}

    @staticmethod
    def _json(path: Path, default: dict) -> dict:
        if not path.is_file():
            return default
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except ValueError as e:
            raise G.GenError(f"tools/data/{path.name}: not JSON ({e})") from e

    def recipe_name(self, spell: int) -> str:
        r = self.recipe.get(spell)
        line = self.data["professions"].get(self.line_of.get(spell), {}).get("name", "?")
        return f"{line}: {r['name']} (spell {spell})" if r else f"spell {spell}"

    def recipe_field(self, spell: int, field: str):
        hand = table(self.manual["recipes"].get(str(spell))).get(field)
        return hand if hand is not None else table(self.recipe.get(spell)).get(field)

    def rank_field(self, line: int, cap: int, field: str):
        for r in table(self.manual.get("ranks")).get(str(line), []):
            if r.get("cap") == cap and r.get(field) is not None:
                return r[field]
        for r in table(self.data["professions"].get(line)).get("ranks") or []:
            if r.get("cap") == cap:
                return r.get(field)
        return None

    def position(self, npc: int):
        row = self.seen["npcs"].get(str(npc)) or self.trainers.get(npc) or {}
        if None in (row.get("map"), row.get("x"), row.get("y")):
            return None
        return (row["map"], row["x"], row["y"])


def collect(files: list[dict], s: Shipped) -> tuple[dict, list[str]]:
    """facts[(kind, ...)] = [(value, build, file number)], and notes for what cannot become a fact."""
    facts: dict[tuple, list[tuple]] = {}
    notes: list[str] = []
    extra: dict[tuple, dict] = {}

    def add(key, value, build, n):
        facts.setdefault(key, []).append((value, build, n))

    for n, learned in enumerate(files, 1):
        for line, rows in learned["trainers"].items():
            for key, e in rows.items():
                spell = key
                if isinstance(key, str):
                    hits = s.by_name.get(line, {}).get(key, []) if learned["locale"] in (None, "enUS") else []
                    if len(hits) != 1:
                        notes.append(f"file {n}: trainer recipe {key!r} of skill line {line} has no spell id and "
                                     "matches no single recipe name: left out")
                        continue
                    spell = hits[0]
                if spell not in s.recipe:
                    notes.append(f"file {n}: a trainer teaches spell {spell} (skill line {line}), which is not a "
                                 "recipe in the shipped data")
                    continue
                if e["skill"] is not None:
                    add(("learn", spell), e["skill"], e["seenAt"], n)
                if e["cost"] is not None:
                    add(("cost", spell), e["cost"], e["seenAt"], n)
        for line, rows in learned["ranks"].items():
            for cap, e in rows.items():
                if cap not in CAP_NAMES or line not in s.data["professions"]:
                    notes.append(f"file {n}: rank with cap {cap} of skill line {line} is not a rank the data knows")
                    continue
                for field in ("skill", "cost"):
                    if e[field] is not None:
                        add(("rank", line, cap, field), e[field], e["seenAt"], n)
        for spell, e in learned["colors"].items():
            if spell not in s.recipe:
                notes.append(f"file {n}: spell {spell} was seen in a profession window and is not in the shipped data")
                continue
            for field, low, high, what in (("y", e["o"], e["y"], "yellow"), ("g", e["n"], e["g"], "grey")):
                have = s.recipe_field(spell, field)
                if low is not None and high is not None and high == low + 1:
                    add((field, spell), high, e["seenAt"], n)
                elif have is not None and ((low is not None and have <= low) or (high is not None and have > high)):
                    span = f"{'' if low is None else low + 1}..{'' if high is None else high}"
                    notes.append(f"file {n}: {s.recipe_name(spell)}: the shipped {what} threshold {have} does not "
                                 f"fit what the game showed (it is in {span}, build {e['seenAt'] or 'unknown'}); "
                                 "not pinned to one skill, so not applied")
        sellers: dict[int, list] = {}  # recipe spell -> [(npc, build)] in this file
        for npc, v in sorted(learned["vendors"].items()):
            name = table(learned["npcs"].get(npc)).get("name")
            for item, it in v["items"].items():
                if item in s.by_item:
                    spell = s.by_item[item]
                    sellers.setdefault(spell, []).append((npc, v["seenAt"]))
                    extra[("vendor", spell, npc)] = {"name": name, "npc": npc, "map": v["map"]}
                elif item in s.reagents and it["price"] is not None and it["stock"] is None:
                    add(("reagent", item), True, v["seenAt"], n)
                    was = s.data["vendor"].get(item)
                    if was is not None and abs(was - it["price"]) > 0.01:
                        notes.append(f"file {n}: {U.item_text(item, s.data['items'])}: the vendor asked {it['price']} "
                                     f"copper, the data says {was} (a reputation discount changes the price shown; "
                                     "the data's price comes from the client tables and is not changed)")
        for spell, who in sellers.items():
            # the data names one vendor per recipe item: the shipped one when this file saw it selling the item
            # (several vendors may sell it), else the lowest NPC id of those seen
            have = table(s.recipe_field(spell, "vendor")).get("npc")
            npc, at = next((w for w in who if w[0] == have), who[0])
            add(("vendor", spell), npc, at, n)
        for npc, e in learned["npcs"].items():
            if s.trainers and npc not in s.trainers:
                continue  # an auctioneer, a bank: not a trainer or recipe vendor of the data
            add(("npc", npc), (e["map"], e["x"], e["y"]), learned["build"], n)
            extra[("npc", npc, n)] = e
    return {"facts": facts, "extra": extra}, notes


def shipped_value(s: Shipped, key: tuple):
    kind = key[0]
    if kind in ("learn", "cost", "y", "g"):
        return s.recipe_field(key[1], kind)
    if kind == "rank":
        return s.rank_field(key[1], key[2], key[3])
    if kind == "vendor":
        return table(s.recipe_field(key[1], "vendor")).get("npc")
    if kind == "reagent":
        return True if key[1] in s.data["vendor"] or key[1] in s.manual["vendor"] else None
    if kind == "npc":
        return s.position(key[1])
    raise KeyError(kind)


def describe(s: Shipped, key: tuple) -> str:
    kind = key[0]
    if kind in ("learn", "cost", "y", "g"):
        what = {"learn": "learn rank", "cost": "training cost", "y": "yellow threshold", "g": "grey threshold"}[kind]
        return f"{s.recipe_name(key[1])}: {what}"
    if kind == "rank":
        prof = s.data["professions"][key[1]]["name"]
        return f"{prof}: {CAP_NAMES[key[2]]} rank: {'skill needed' if key[3] == 'skill' else 'cost'}"
    if kind == "vendor":
        return f"{s.recipe_name(key[1])}: the vendor of its recipe item (NPC id)"
    if kind == "reagent":
        return f"{U.item_text(key[1], s.data['items'])}: sold by a vendor"
    name = table(s.trainers.get(key[1])).get("name") or "NPC"
    return f"{name} (NPC {key[1]}): position"


def apply(s: Shipped, key: tuple, value, why: str, bundle: dict, builds: list) -> None:
    kind = key[0]
    note = "game: " + why
    if kind in ("learn", "cost", "y", "g"):
        row = s.manual["recipes"].setdefault(str(key[1]), {})
        row[kind] = value
        row.setdefault("note", note)
    elif kind == "rank":
        rows = s.manual.setdefault("ranks", {}).setdefault(str(key[1]), [])
        row = next((r for r in rows if r.get("cap") == key[2]), None)
        if row is None:
            row = {"name": CAP_NAMES[key[2]], "cap": key[2]}
            rows.append(row)
            rows.sort(key=lambda r: r["cap"])
        row[key[3]] = value
    elif kind == "vendor":
        row = s.manual["recipes"].setdefault(str(key[1]), {})
        v = bundle["extra"][("vendor", key[1], value)]
        row["vendor"] = {k: x for k, x in v.items() if x is not None}
        if s.recipe_field(key[1], "from") != "vendor":
            row["src"] = "vendor"
        row.setdefault("note", note)
    elif kind == "reagent":
        s.manual["vendor"] = sorted(set(s.manual["vendor"]) | {key[1]})
    elif kind == "npc":
        first = next(n for v, _, n in bundle["facts"][key] if near(v, value))
        e = bundle["extra"][("npc", key[1], first)]
        s.seen["npcs"][str(key[1])] = {
            "name": e["name"] or table(s.trainers.get(key[1])).get("name"), "map": value[0], "x": value[1],
            "y": value[2], "build": max((b for b in builds if b), key=G.version_key, default=None),
            "files": len({n for _, _, n in bundle["facts"][key]})}


def skillup_lines(files: list[dict], s: Shipped) -> list[str]:
    total: dict[tuple, list[int]] = {}
    for learned in files:
        for line, rows in learned["skillups"].items():
            for key, buckets in rows.items():
                for bucket, (t, u) in buckets.items():
                    e = total.setdefault((line, key, bucket), [0, 0])
                    e[0], e[1] = e[0] + t, e[1] + u
    out = []
    for (line, key, bucket), (t, u) in sorted(total.items(), key=lambda kv: (kv[0][0], str(kv[0][1]), kv[0][2])):
        name = s.recipe_name(key) if isinstance(key, int) else f"skill line {line}: {key}"
        out.append(f"{name}, skill {bucket}-{bucket + 4}: {u} skill-ups in {t} tries")
    return out


# ---------------------------------------------------------------- the run


def run(argv: list[str] | None = None, out=None) -> int:
    out = out or sys.stdout
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("files", nargs="+", help="SkillupHelper.lua SavedVariables files")
    ap.add_argument("--dry-run", action="store_true", help="print the report, write nothing")
    ap.add_argument("--report", help="also write the report to this file")
    ap.add_argument("--root", help="the addon folder (default: the one this script is in)")
    a = ap.parse_args(argv)
    lines = ["# What the game learned", ""]
    code = EXIT_BROKEN
    try:
        code = work(a, Path(a.root) if a.root else G.HERE.parent, lines)
    except G.GenError as e:
        lines += [f"**FAILED: {e}**", ""]
        print(f"error: {e}", file=sys.stderr)
    report = "\n".join(lines).rstrip() + "\n"
    out.write(report)
    if a.report:
        Path(a.report).write_text(report, encoding="utf-8", newline="\n")
    return code


def work(a, root: Path, lines: list[str]) -> int:
    s = Shipped(root)
    files, seen_digests = [], set()
    for n, name in enumerate(a.files, 1):
        try:
            learned = read_file(Path(name))
        except G.GenError as e:
            raise G.GenError(f"file {n} {e}") from e
        if learned is None:
            lines.append(f"- file {n}: no `learned` table (written by an addon older than 0.3.0, or the game was "
                         "never logged out with it). Skipped.")
            continue
        d = digest(learned)
        if d in seen_digests:
            lines.append(f"- file {n}: the same content as an earlier file. Counted once.")
            continue
        seen_digests.add(d)
        files.append(learned)
        counts = ", ".join(f"{k} {sum(len(v) if isinstance(v, dict) else 1 for v in learned[k].values())}"
                           for k in ("trainers", "ranks", "colors", "skillups")) \
            + f", vendors {len(learned['vendors'])}, npcs {len(learned['npcs'])}"
        lines.append(f"- file {n} (counted as file {len(files)}): build {learned['build'] or 'unknown'}, locale "
                     f"{learned['locale'] or 'unknown'}; {counts}")
    lines += [f"- shipped data: build {s.build or 'unknown'}", ""]
    if not files:
        raise G.GenError("no file holds a `learned` table")

    bundle, notes = collect(files, s)
    builds = [f["build"] for f in files]
    groups = {"apply": [], "pending": [], "conflict": [], "confirmed": []}
    for key in sorted(bundle["facts"], key=lambda k: tuple(str(x) for x in k)):
        obs = bundle["facts"][key]
        have = shipped_value(s, key)
        status, value, why = decide(have, s.build, obs, near if key[0] == "npc" else (lambda x, y: x == y))
        was = "nothing" if have is None else show(have)
        if status == "apply":
            apply(s, key, value, why, bundle, builds)
            groups[status].append(f"{describe(s, key)}: {was} -> {show(value)} ({why})")
        elif status == "pending":
            groups[status].append(f"{describe(s, key)}: shipped {was}, the game says {show(value)} ({why})")
        elif status == "conflict":
            groups[status].append(f"{describe(s, key)}: shipped {was}; {why}")
        else:
            groups[status].append(key)

    title = "Would apply" if a.dry_run else "Applied"
    lines += U.section(title, groups["apply"], cap=10 ** 6)
    lines += U.section("Needs a second file", groups["pending"], cap=10 ** 6)
    lines += U.section("Conflicts (nothing applied)", groups["conflict"], cap=10 ** 6)
    lines += [f"Confirmed: {len(groups['confirmed'])} facts match the shipped data.", ""]
    lines += U.section("Notes", notes, cap=10 ** 6)
    lines += U.section("Skill-ups seen (not merged: no shipped number to correct)", skillup_lines(files, s),
                       cap=10 ** 6)
    if not groups["apply"]:
        return EXIT_NONE
    manual_text = json.dumps(s.manual, indent=2, ensure_ascii=False) + "\n"
    seen_text = json.dumps(s.seen, indent=2, ensure_ascii=False) + "\n"
    # the generator must be able to read what would be written
    with tempfile.TemporaryDirectory() as tmp:
        check = Path(tmp) / "overlay.manual.json"
        check.write_text(manual_text, encoding="utf-8", newline="\n")
        G.load_overlay(check)
    if not a.dry_run:
        U.write_text(s.manual_file, manual_text)
        if s.seen["npcs"]:
            U.write_text(s.seen_file, seen_text)
        lines += ["Wrote tools/data/overlay.manual.json" + (" and tools/data/npcs_seen.json" if s.seen["npcs"] else "")
                  + ". Run tools/update_data.py (or gen_recipes.py) to carry it into Data/Recipes.lua.", ""]
    return EXIT_APPLIED


if __name__ == "__main__":
    sys.exit(run())
