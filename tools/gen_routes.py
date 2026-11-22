#!/usr/bin/env python3
"""Write Data/Routes.lua: the leveling route of every crafting guide on wow-professions.com's Forever section.

    python tools/gen_routes.py                       # fetch every guide in wowprof.SKILL_LINE, write Data/Routes.lua
    python tools/gen_routes.py --only leatherworking cooking
    python tools/gen_routes.py --html DIR            # read DIR/<profession>.html instead of fetching
    python tools/gen_routes.py --dry-run             # print the summary, write nothing

Facts only: per skill line, the skill ranges and spell ids the guide names, whether an option is one of its
alternatives, and the faction a row is for. No names or sentences from the pages (names come from Data/Recipes.lua).
It also writes ns.Data.routeRanks: per skill line, how each rank after Apprentice is learned (wowprof's "unlocks":
rank word, skill, level, trainer / book / quest, the quest's items) with the NPCs to see. Those carry facts the
recipe data lacks: NPC, quest and item names (an item name only when Data/Recipes.lua has no such item), NPC ids by
name from Data/Trainers.lua and Data/Npcs.lua (nil when neither has the name), and positions from the NPC pages
(tools/data/npcs_site.json first, else the page is fetched; with --html only the JSON is read).
A guide whose page no longer parses (wowprof.ShapeError) is skipped and named; the others are still written. Exit
codes: 0 written (or dry run), 1 no guide parsed, 2 a spell the guide names is not in Data/Recipes.lua (checked when
the file is there; --no-check skips it): nothing is written then, unless --force.
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import luatable  # noqa: E402
import wowprof  # noqa: E402
from gen_recipes import lua_inline, lua_str  # noqa: E402

DEFAULT_OUT = HERE.parent / "Data" / "Routes.lua"
DEFAULT_RECIPES = HERE.parent / "Data" / "Recipes.lua"
DEFAULT_SITE = HERE / "data" / "npcs_site.json"
DEFAULT_NPC_FILES = (HERE.parent / "Data" / "Trainers.lua", HERE.parent / "Data" / "Npcs.lua")


def _norm(s: str) -> str:
    return re.sub(r"[^a-z0-9]+", "", (s or "").lower())


def read_npc_rows(paths) -> list[dict]:
    """The rows of Data/Trainers.lua (ns.Data.trainers) and Data/Npcs.lua (ns.Data.npcs) that exist."""
    rows = []
    for p in paths:
        p = Path(p)
        if not p.is_file():
            continue
        text = p.read_text(encoding="utf-8")
        for name in ("ns.Data.trainers", "ns.Data.npcs"):
            t = luatable.read_assignment(text, name)
            if isinstance(t, dict):
                rows += [r for r in t.values() if isinstance(r, dict)]
    return rows


def npc_id(rows: list[dict], name: str, line: int) -> int | None:
    """The id of the row with this name: the one that trains `line` when several match, None when unsure."""
    hits = {r["id"]: r for r in rows if _norm(r.get("name")) == _norm(name) and r.get("id")}
    if len(hits) == 1:
        return next(iter(hits))

    def skills(r):
        s = r.get("skill")
        return set(s.values()) if isinstance(s, dict) else {s}
    trains = [i for i, r in hits.items() if line in skills(r)]
    return trains[0] if len(trains) == 1 else None


def recipe_items(text: str) -> set[int]:
    """The item ids of Data/Recipes.lua's items table (read by pattern, like recipe_spells)."""
    m = re.search(r"^\titems = \{\n(.*?)^\t\},?$", text, re.M | re.S)
    return {int(i) for i in re.findall(r"^\t\t\[(\d+)\] = \{", m.group(1), re.M)} if m else set()


def rank_records(g: dict, line: int, rows: list[dict], known_items: set[int], site: dict, fetch_npc) -> list[dict]:
    """ns.Data.routeRanks[line]: the guide's unlock records with NPC ids and positions."""
    out = []
    for u in g.get("unlocks") or []:
        names = {int(i): n for i, n in (u.get("names") or {}).items() if int(i) not in known_items}
        npcs = []
        for n in u.get("npcs") or []:
            pos = site.get(n["slug"]) or (fetch_npc(n["slug"]) if fetch_npc else None) or {}
            npcs.append({"id": npc_id(rows, n["name"], line), "name": n["name"], "faction": n.get("faction"),
                         "map": pos.get("map"), "x": pos.get("x"), "y": pos.get("y"), "quest": n.get("quest")})
        out.append({
            "name": u.get("rank"), "skill": u.get("skill"), "level": u.get("level"), "kind": u.get("kind"),
            "quest": u.get("quest"), "questName": u.get("questName"), "item": u.get("item"),
            "items": [v for pair in u.get("items") or [] for v in pair] or None,
            "names": dict(sorted(names.items())) or None, "npcs": npcs or None,
        })
    return out


def entries_of(g: dict) -> list[dict]:
    """The guide's options as route entries, by range then main pick first; one entry per (spell, range, kind)."""
    out, seen = [], set()
    for st in g["steps"]:
        for o in st["options"]:
            e = {"from": o["from"], "to": o["to"], "spell": o["spell"]}
            if o["alt"]:
                e["alt"] = True
            if o["faction"] in ("horde", "alliance"):
                e["faction"] = o["faction"]
            key = (e["from"], e["to"], e["spell"], e.get("alt", False), e.get("faction"))
            if e["to"] > e["from"] and key not in seen:
                seen.add(key)
                out.append(e)
    # an alternative route tab that repeats a main row (same spell, range and side) adds nothing
    main = {(e["from"], e["to"], e["spell"], e.get("faction")) for e in out if not e.get("alt")}
    out = [e for e in out if not e.get("alt") or (e["from"], e["to"], e["spell"], e.get("faction")) not in main]
    out.sort(key=lambda e: (e["from"], e.get("alt", False), e["to"]))
    return out


def recipe_spells(text: str) -> dict[int, set[int]]:
    """Spell ids per skill line of Data/Recipes.lua, read by pattern (the file is too large to parse for this)."""
    out: dict[int, set[int]] = {}
    line = None
    for m in re.finditer(r"^\t\t\[(\d+)\] = \{$|^\t\t\t\t\[(\d+)\] = \{", text, re.M):
        if m.group(1):
            line = int(m.group(1))
            out.setdefault(line, set())
        elif line is not None:
            out[line].add(int(m.group(2)))
    return out


def render(routes: dict[int, list[dict]], source: str, ranks: dict[int, list[dict]] | None = None) -> str:
    out = [
        "-- Generated by tools/gen_routes.py from the leveling guides of wow-professions.com's WoW: Forever section.",
        "-- Do not edit: regenerate. Facts only: per skill line, { from, to, spell, alt, faction } where the guide",
        "-- crafts spell from skill `from` up to (not including) `to`; alt = one of the guide's alternatives, faction =",
        '-- "horde" | "alliance" when a row is for one side. Names come from Data/Recipes.lua. The planner chooses only',
        "-- among these at the skills they cover (README, Planner rules); prices and thresholds stay the planner's.",
        "-- routeRanks: per skill line, each rank after Apprentice as the guide says it is learned: { name (rank word),",
        '-- skill, level, kind = "trainer" | "book" | "quest", quest, questName, item (the book), items = { id, count,',
        "-- ... } (what the quest wants), names = { [item] = name } (only items Data/Recipes.lua lacks), npcs = { { id,",
        '-- name, faction = "H" | "A", map, x, y, quest } } }. npcs[i].quest: that side\'s own quest when the sides',
        "-- differ. NPC ids by name from Data/Trainers.lua / Data/Npcs.lua (nil when unknown); positions from the NPC",
        "-- pages.",
        "-- luacheck: ignore",
        "local _, ns = ...",
        "ns.Data = ns.Data or {}",
        "ns.Data.routes = {",
        f"\tsource = {lua_str(source)},",
    ]
    for line in sorted(routes):
        out.append(f"\t[{line}] = {{")
        out += [f"\t\t{lua_inline(e)}," for e in routes[line]]
        out.append("\t},")
    out += ["}"]
    out.append("ns.Data.routeRanks = {")
    for line in sorted(ranks or {}):
        out.append(f"\t[{line}] = {{")
        out += [f"\t\t{lua_inline(r)}," for r in ranks[line]]
        out.append("\t},")
    out += ["}", ""]
    return "\n".join(out)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--only", nargs="+", help="professions to read (default: every one in wowprof.SKILL_LINE)")
    ap.add_argument("--html", help="folder of saved pages, <profession>.html, instead of fetching")
    ap.add_argument("--out", help="Lua file to write (default: Data/Routes.lua)")
    ap.add_argument("--recipes", help="Data/Recipes.lua to check the spell ids against (default: the addon's)")
    ap.add_argument("--no-check", action="store_true", help="do not check spell ids against Data/Recipes.lua")
    ap.add_argument("--dry-run", action="store_true", help="print the summary, write nothing")
    ap.add_argument("--force", action="store_true",
                    help="write even when a spell is missing from Data/Recipes.lua (exit 2 all the same)")
    ap.add_argument("--site", help="NPC positions from wowprof trainers (default: tools/data/npcs_site.json)")
    ap.add_argument("--npc-files", nargs="+",
                    help="Lua files whose rows give NPC ids by name (default: Data/Trainers.lua Data/Npcs.lua)")
    a = ap.parse_args(argv)
    profs = a.only or sorted(wowprof.SKILL_LINE)
    routes: dict[int, list[dict]] = {}
    ranks: dict[int, list[dict]] = {}
    skipped = []
    site_file = Path(a.site) if a.site else DEFAULT_SITE
    site = json.loads(site_file.read_text(encoding="utf-8")).get("npcs", {}) if site_file.is_file() else {}
    npc_rows = read_npc_rows(a.npc_files or DEFAULT_NPC_FILES)
    rfile = Path(a.recipes) if a.recipes else DEFAULT_RECIPES
    rtext = rfile.read_text(encoding="utf-8") if rfile.is_file() else ""
    known_items = recipe_items(rtext)

    def fetch_npc(slug: str) -> dict | None:
        try:
            n = wowprof.parse_npc(wowprof.fetch(f"/forever/npc/{slug}"))
        except OSError as e:
            print(f"warning: npc/{slug}: no position ({e})", file=sys.stderr)
            return None
        site[slug] = n
        return n
    for prof in profs:
        line = wowprof.SKILL_LINE.get(prof)
        if line is None:
            skipped.append(f"{prof}: not a crafting guide wowprof knows")
            continue
        page = str(Path(a.html) / f"{prof}.html") if a.html else None
        try:
            g = wowprof.guide(prof, page)
        except wowprof.ShapeError as e:
            skipped.append(f"{prof}: the page changed shape ({e})")
            continue
        except OSError as e:
            skipped.append(f"{prof}: could not read the page ({e})")
            continue
        routes[line] = entries_of(g)
        ranks[line] = rank_records(g, line, npc_rows, known_items, site, None if a.html else fetch_npc)
        print(f"{line:>4} {prof:<15} {len(g['steps']):>3} steps, {len(routes[line]):>3} entries, "
              f"{len(ranks[line])} ranks (steps v{g['stepsVersion']})")
    for s in skipped:
        print(f"skipped {s}", file=sys.stderr)
    if not routes:
        print("error: no guide parsed", file=sys.stderr)
        return 1
    rc = 0
    if not a.no_check and rtext:
        known = recipe_spells(rtext)
        for line, entries in sorted(routes.items()):
            missing = sorted({e["spell"] for e in entries} - known.get(line, set()))
            if missing:
                print(f"error: skill line {line}: spells not in {rfile.name}: {missing}", file=sys.stderr)
                rc = 2
    if a.dry_run:
        return rc
    if rc == 2 and not a.force:
        print("nothing written: update Data/Recipes.lua first, or pass --force to write the route anyway",
              file=sys.stderr)
        return rc
    source = f"wow-professions.com, Forever section, {datetime.date.today().isoformat()}"
    out = Path(a.out) if a.out else DEFAULT_OUT
    tmp = out.with_suffix(".lua.tmp")
    tmp.write_text(render(routes, source, ranks), encoding="utf-8", newline="\n")
    os.replace(tmp, out)
    print(f"wrote {out.name}, {out.stat().st_size} bytes")
    return rc


if __name__ == "__main__":
    sys.exit(main())
