#!/usr/bin/env python3
"""Turn a research export of Wowhead's Forever section into tools/data/overlay.json, the overlay gen_recipes.py reads.

    python tools/import_wowhead.py --research DIR [--retrieved 2026-11-14] [--build X] [--cache DIR] [--offline]

DIR holds the research files (not committed; they are a crawl of someone else's site):
    recipes.json       { ranks: { <skill line>: [ { rank, learn, cost, source } ] },
                         recipes: { <spell>: { skill, learn, colors [orange, yellow, green, grey], cost, source } } }
    recipe_items.json  { <item>: { source, sourcemore } }
    npcs.json          { <npc>: { react [alliance, horde] } }   (optional)

Only facts are taken, never text from the pages: per spell the skill needed to learn it, the training cost, the yellow
and grey thresholds where they differ from the client build (the site already carries hotfixes a build lacks), how the
recipe is obtained, and the one vendor the site names for a recipe item. The link from a recipe item to its spell
comes from the client data (ItemEffect), not from names.

Source codes of the site, as observed: 6 trainer, 5 vendor, 4 quest, 2 drop, 1 crafted. A row with none of these
keeps its first unknown code as a number. A trainer source wins over the others.

Entries kept by hand live in tools/data/overlay.manual.json (same shape as the overlay's "recipes" and "vendor") and
are laid over the imported ones. Exit code 2 = a broken link, named on stderr.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gen_recipes as G  # noqa: E402

SOURCE_NAME = "Wowhead, Forever section"
SOURCE_CODES = {6: "trainer", 5: "vendor", 4: "quest", 2: "drop", 1: "crafted"}
SOURCE_ORDER = (6, 5, 4, 2, 1)
NO_SKILL = 9999  # the site's "no skill requirement" marker
RANK_CAPS = {name: cap for name, cap, _, _ in G.DEFAULT_RANKS}
MANUAL = G.HERE / "data" / "overlay.manual.json"


def source_of(codes) -> str | int | None:
    codes = [c for c in (codes or []) if isinstance(c, int)]
    for c in SOURCE_ORDER:
        if c in codes:
            return SOURCE_CODES[c]
    return codes[0] if codes else None


def vendor_of(item_row: dict, npcs: dict) -> dict | None:
    """The single vendor the site names for a recipe item: { name, npc, zone, a, h } (a / h = how the NPC reacts to
    Alliance / Horde: 1 friendly, 0 neutral, -1 hostile; absent when not known)."""
    more = item_row.get("sourcemore")
    if 5 not in (item_row.get("source") or []) or not isinstance(more, list) or not more:
        return None
    m = more[0]
    if m.get("t") != 1 or not m.get("ti"):
        return None
    out = {"name": m.get("n"), "npc": m["ti"], "zone": m.get("z")}
    react = (npcs.get(str(m["ti"])) or {}).get("react") or [None, None]
    for key, v in zip(("a", "h"), react):
        if v is not None:
            out[key] = v
    return {k: v for k, v in out.items() if v is not None}


def convert(research: dict, items: dict, npcs: dict, db2: dict, retrieved: str, build: str, manual: dict) -> tuple[dict, dict]:
    """The overlay, and counts for the summary. db2 = gen_recipes.build_data's table made with no overlay."""
    spells = {}  # spell -> (line, the generator's row)
    for line, prof in db2["professions"].items():
        for spell, row in prof["recipes"].items():
            spells[spell] = (line, row)
    recipes, stats = {}, {"thresholds": 0, "not_in_build": 0, "learn": 0}
    listed = set()
    for key, w in sorted(research["recipes"].items(), key=lambda kv: int(kv[0])):
        spell = int(key)
        listed.add(int(w["skill"]))
        if spell not in spells:
            stats["not_in_build"] += 1
            continue
        _, row = spells[spell]
        out = {}
        item_row = items.get(str(row["item"])) if row["item"] is not None else None
        src = source_of(w.get("source"))
        if src != "trainer" and item_row is not None:
            src = source_of(item_row.get("source")) or src
        if src is not None:
            out["src"] = src
        learn = w.get("learn")
        if isinstance(learn, int) and learn != NO_SKILL and learn != row["learn"]:
            out["learn"] = learn
        if isinstance(learn, int) and learn != NO_SKILL:
            stats["learn"] += 1
        if w.get("cost"):
            out["cost"] = int(w["cost"])
        # a recipe with no learn skill and a character level (the rogue's poisons) is learned by level
        if not isinstance(learn, int) and isinstance(w.get("level"), int) and w["level"] > 0:
            out["level"] = w["level"]
        colors = w.get("colors")
        if isinstance(colors, list) and len(colors) == 4:
            if colors[1] != row["y"]:
                out["y"] = colors[1]
            if colors[3] != row["g"]:
                out["g"] = colors[3]
            if "y" in out or "g" in out:
                stats["thresholds"] += 1
        vendor = vendor_of(item_row, npcs) if item_row else None
        if vendor:
            out["vendor"] = vendor
        recipes[spell] = out
    for key, row in (manual.get("recipes") or {}).items():
        recipes.setdefault(int(key), {}).update(row)
    ranks = {}
    for line, rows in sorted(research.get("ranks", {}).items(), key=lambda kv: int(kv[0])):
        out = []
        for r in rows:
            if 6 in (r.get("source") or []) and r.get("rank") in RANK_CAPS and r.get("cost") is not None:
                learn = r.get("learn")
                out.append({"name": r["rank"], "cap": RANK_CAPS[r["rank"]],
                            "skill": None if learn in (None, NO_SKILL) else learn, "cost": int(r["cost"])})
        # a rank no trainer row covers (Artisan Cooking comes from a quest): its source alone, no skill or price
        have = {r["name"] for r in out}
        for r in rows:
            src = source_of(r.get("source"))
            if r.get("rank") in RANK_CAPS and r["rank"] not in have and isinstance(src, str):
                have.add(r["rank"])
                out.append({"name": r["rank"], "cap": RANK_CAPS[r["rank"]], "where": src})
        if out:
            ranks[int(line)] = sorted(out, key=lambda r: r["cap"])
    overlay = {
        "source": {"name": SOURCE_NAME, "retrieved": retrieved, "compared_with_build": build},
        "listed": sorted(listed),
        "ranks": ranks,
        "recipes": dict(sorted(recipes.items())),
        "vendor": sorted(manual.get("vendor") or []),
    }
    return overlay, stats


def render(overlay: dict) -> str:
    """Compact and stable: one rank list and one recipe per line, in id order."""
    j = lambda v: json.dumps(v, ensure_ascii=False, separators=(", ", ": "))  # noqa: E731
    out = ["{", f'  "source": {j(overlay["source"])},', f'  "listed": {j(overlay["listed"])},', '  "ranks": {']
    ranks = [f'    "{line}": {j([{k: v for k, v in r.items() if v is not None} for r in rows])}'
             for line, rows in overlay["ranks"].items()]
    out += [",\n".join(ranks), "  },", '  "recipes": {']
    out += [",\n".join(f'    "{spell}": {j(row)}' for spell, row in overlay["recipes"].items())]
    out += ["  },", f'  "vendor": {j(overlay["vendor"])}', "}", ""]
    return "\n".join(out)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--research", required=True, help="folder with recipes.json, recipe_items.json, npcs.json")
    ap.add_argument("--retrieved", required=True, help="the day the research was read from the site, YYYY-MM-DD")
    ap.add_argument("--build")
    ap.add_argument("--cache")
    ap.add_argument("--offline", action="store_true")
    ap.add_argument("--out", help="default: tools/data/overlay.json")
    a = ap.parse_args(argv)
    try:
        folder = Path(a.research)

        def read(name: str, needed: bool = True):
            f = folder / name
            if not f.is_file():
                if needed:
                    raise G.GenError(f"research file missing: {name} in the --research folder")
                return {}
            try:
                return json.loads(f.read_text(encoding="utf-8"))
            except ValueError as e:
                raise G.GenError(f"research file {name}: not JSON ({e})") from e

        research, items, npcs = read("recipes.json"), read("recipe_items.json"), read("npcs.json", False)
        manual = json.loads(MANUAL.read_text(encoding="utf-8")) if MANUAL.is_file() else {}
        cache = Path(a.cache) if a.cache else G.DEFAULT_CACHE
        csv_folder, build = G.resolve(cache, a.build, not a.offline)
        db2, _ = G.build_data(G.fetch_tables(csv_folder, build, not a.offline), build)
        overlay, stats = convert(research, items, npcs, db2, a.retrieved, build, manual)
        out = Path(a.out) if a.out else G.DEFAULT_OVERLAY
        out.write_text(render(overlay), encoding="utf-8", newline="\n")
        G.load_overlay(out)  # the generator must read what was written
        print(f"compared with build {build}")
        print(f"{len(overlay['recipes'])} recipes, {stats['learn']} with a learn rank, {stats['thresholds']} with a "
              f"yellow or grey threshold that differs from the build, {stats['not_in_build']} listed but not in the build")
        print(f"ranks for {len(overlay['ranks'])} professions; wrote {out.name}")
        return 0
    except G.GenError as e:
        print(f"error: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
