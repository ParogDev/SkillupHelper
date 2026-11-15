#!/usr/bin/env python3
"""Write Data/Recipes.lua, the recipe data SkillupHelper ships: every craft recipe of every profession.

    python tools/gen_recipes.py                       # newest wowf build, downloaded into tools/.cache
    python tools/gen_recipes.py --build 1.60.1.70888  # a named build
    python tools/gen_recipes.py --cache DIR           # DIR/<build>/<Table>.enUS.csv, or a folder holding the CSVs
    python tools/gen_recipes.py --offline             # only what is cached
    python tools/gen_recipes.py --check               # write nothing: which skill brackets no recipe covers

Python 3 standard library only. The source is the wago.tools DB2 CSV export of the WoW: Forever client (product
`wowf`): SkillLine, SkillLineAbility, SpellReagents, SpellEffect, SpellName, ItemSparse, ItemEffect, ItemXItemEffect.

What the client data gives, per recipe: the skill where it turns yellow (TrivialSkillLineRankLow) and grey
(TrivialSkillLineRankHigh), skill-ups per craft, reagents, the item made and how many, and how it is learned:
`auto` (AcquireMethod 1, learned with the profession), `item` (a recipe item teaches it; its RequiredSkillRank is the
learn rank) or `trainer` (everything else). The client data does NOT say at which skill a trainer teaches a recipe
(MinSkillLineRank is 1 on nearly every row), nor which "trainer" recipes come from a quest or a special NPC.

What it cannot give comes from tools/data/overlay.json (written by tools/import_wowhead.py from a research export,
with the hand-kept tools/data/overlay.manual.json on top):

    {
      "source": { "name": "...", "retrieved": "YYYY-MM-DD", "compared_with_build": "..." },
      "listed": [ 164, 165 ],
      "ranks": { "<skill line>": [ { "name": "Journeyman", "cap": 150, "skill": 50, "cost": 500, "where": "trainer" } ] },
      "recipes": { "<spell id>": { "learn": 30, "cost": 100, "y": 50, "g": 90, "src": "trainer", "teacher": "who",
                                   "vendor": { "name": "who", "npc": 1, "zone": 2, "a": 1, "h": -1 }, "note": "..." } },
      "vendor": [ 2880, 3466 ]
    }

Per recipe: `learn` the skill needed to learn it, `cost` the training cost in copper, `y` / `g` the yellow and grey
thresholds where they differ from the build (they win: the overlay carries hotfixes a build lacks), `src` one of
auto / trainer / item / special, or where its recipe item comes from: vendor / quest / drop / crafted / other (a
number is a source code with no name yet), `teacher` free text for a special teacher, `vendor` the one vendor known
to sell the recipe item (a / h = its reaction to Alliance / Horde). Every field is optional; `note` is for people and
is not written to the Lua file. `listed` names the skill lines whose recipe list is whole in the overlay: a craft
spell of such a line with no entry is written as src = "unlisted" (not confirmed obtainable; the addon shows it as a
shortcut and never plans it by itself). `ranks` replaces the classic rank rows by name. The top-level `vendor` lists
extra reagents a vendor sells (the built-in list is VENDOR_REAGENTS below).

The file holds no prices from an auction house: the addon reads those from TradeSkillMaster in game. Vendor reagents
carry the vendor's price per item (ItemSparse.BuyPrice / VendorStackCount).

Exit code 2 = a broken link, named on stderr.
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

PRODUCT = "wowf"
BUILDS_URL = "https://wago.tools/api/builds"
CSV_URL = "https://wago.tools/db2/{table}/csv?build={build}&locale=enUS"
USER_AGENT = "Mozilla/5.0 (compatible; skilluphelper-gen/1.0)"
TABLES = ("SkillLine", "SkillLineAbility", "SpellReagents", "SpellEffect", "SpellName", "ItemSparse", "ItemEffect",
          "ItemXItemEffect")
# Names only: where a recipe vendor stands (the overlay gives an AreaTable id, the game a UiMap id). Without them a
# vendor is written without a place. They are downloaded with the rest, and skipped when --offline and not cached.
OPTIONAL_TABLES = ("AreaTable", "UiMap")
EFFECT_CREATE_ITEM = 24
TRIGGER_LEARN = 6  # ItemEffect.TriggerType: the item teaches SpellID
ACQUIRE_AUTO = 1  # SkillLineAbility.AcquireMethod: learned with the profession
BIND_ON_PICKUP = 1  # ItemSparse.Bonding: 0 none, 1 when picked up, 2 when equipped, 3 when used, 4 quest item
DEAD_NAME = re.compile(r"\b(OLD|DEP|DEPRECATED|TEST|UNUSED|NYI)\b|^zz", re.IGNORECASE)
# How the addon plans a recipe: learned with the profession, at a trainer, from a recipe item, from a special teacher
# or quest (a gated shortcut), or not in the overlay's list of a profession it lists whole (gated: not confirmed
# obtainable).
SOURCES = ("auto", "trainer", "item", "special", "unlisted")
# What the overlay may say. vendor / quest / drop / crafted / other tell where a recipe item comes from (written as
# `from` next to src = "item"); with no recipe item in the client data the recipe is a "special" one.
ITEM_SOURCES = ("vendor", "quest", "drop", "crafted", "other")
OVERLAY_SOURCES = ("auto", "trainer", "item", "special") + ITEM_SOURCES
EMPTY_OVERLAY = {"recipes": {}, "vendor": set(), "listed": set(), "ranks": {}, "source": {}}
# The one vendor of a recipe item: zone = an AreaTable id (the research export), map = a UiMap id (seen in game).
VENDOR_FIELDS = {"name", "npc", "zone", "map", "a", "h"}
# The highest profession rank cap (Artisan). The client data holds no rank table.
TOP_RANK_CAP = 300

# Profession ranks: name, cap, the skill needed to train it, the trainer's price in copper. The client data holds none
# of this, so these are the classic values, written into every profession as `confirmed = false`: the addon uses them
# only until the character opens a trainer, whose own numbers then win.
DEFAULT_RANKS = (("Apprentice", 75, 0, 10), ("Journeyman", 150, 50, 500), ("Expert", 225, 125, 5000),
                 ("Artisan", 300, 200, 50000))
# Skill lines with no trainer ranks: Poisons is a class skill, capped by character level.
NO_RANKS = {40, 633}  # Lockpicking too
# A line with fewer craft recipes than this is not levelled by crafting (a gathering skill with a few craftables): it
# is written with `side = true`, and the coverage check and the cost overview skip it.
MIN_CRAFT_RECIPES = 10
# Skills raised in the world, not (or not only) by crafting: Mining, Herbalism, Fishing, Skinning, Lockpicking.
WORLD_LINES = (186, 182, 356, 393, 633)
# Data/Spots.lua's rule (bandsConfirmed = false there): a world target gives skill from its requirement until this
# many points above it.
SPOT_GREY = 100

# Reagents vendors sell (thread, dye, salt, spices, water, milk, vials). More go in overlay.json "vendor".
VENDOR_REAGENTS = {
    2320, 2321, 4291, 8343, 14341,  # threads
    2324, 2604, 2605, 4340, 4341, 4342, 6260, 6261, 2325, 10290,  # bleach and dyes
    4289, 2678, 2692, 3713, 159, 1179, 17194, 30817,  # salt, spices, water, milk, flour
    3371, 3372, 8925, 18256,  # vials
}

LUA_KEYWORDS = frozenset("and break do else elseif end false for function if in local nil not or repeat return then true "
                         "until while".split())

HERE = Path(__file__).resolve().parent
DEFAULT_OVERLAY = HERE / "data" / "overlay.json"
DEFAULT_MANUAL = HERE / "data" / "overlay.manual.json"
DEFAULT_OUT = HERE.parent / "Data" / "Recipes.lua"
DEFAULT_CACHE = HERE / ".cache"


class GenError(Exception):
    """A broken link, named."""


# ---------------------------------------------------------------- download and cache


def http_get(url: str, timeout: int = 300) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=timeout) as r:  # noqa: S310 (fixed https host)
        return r.read()


def version_key(version: str) -> tuple:
    return tuple(int(p) if p.isdigit() else 0 for p in re.split(r"[.\-]", version))


def latest_build(get=http_get) -> str:
    try:
        builds = json.loads(get(BUILDS_URL, 60))
    except (urllib.error.URLError, OSError, ValueError) as e:
        raise GenError(f"build list unavailable: {BUILDS_URL} -> {e}") from e
    rows = builds.get(PRODUCT, []) if isinstance(builds, dict) else [b for b in builds if b.get("product") == PRODUCT]
    rows = [b for b in rows if b.get("version")]
    if not rows:
        raise GenError(f"{BUILDS_URL}: no builds listed for product {PRODUCT!r}")
    return max(rows, key=lambda b: (b.get("created_at") or "", version_key(b["version"])))["version"]


def has_tables(folder: Path) -> bool:
    return all((folder / f"{t}.enUS.csv").is_file() for t in TABLES)


def resolve(cache: Path, build: str | None, download: bool, get=http_get) -> tuple[Path, str]:
    """The folder holding the CSVs and the build they are. `cache` is either a folder of <build>/ folders or one
    build's folder itself (then its name is the build unless --build names it)."""
    if (cache / "SkillLine.enUS.csv").is_file():
        name = build or (cache.name if re.fullmatch(r"[\d.]+", cache.name) else None)
        if not name:
            raise GenError(f"{cache} holds CSVs but its name is not a build: pass --build")
        return cache, name
    if build is None:
        have = [d.name for d in cache.iterdir() if d.is_dir() and re.fullmatch(r"[\d.]+", d.name) and has_tables(d)] \
            if cache.is_dir() else []
        if download:
            build = latest_build(get)
        elif have:
            build = max(have, key=version_key)
        else:
            raise GenError(f"no cached build under {cache} and --offline given")
    return cache / build, build


def fetch_tables(folder: Path, build: str, download: bool = True, get=http_get, tables: tuple = TABLES,
                 optional: tuple = OPTIONAL_TABLES) -> dict[str, list[dict]]:
    """The CSV rows per table. An `optional` table is fetched like the others, and left out when it is not cached and
    --offline is given."""
    out = {}
    for table in tuple(tables) + tuple(t for t in optional if t not in tables):
        f = folder / f"{table}.enUS.csv"
        if not (f.is_file() and f.stat().st_size > 0):
            if not download and table not in tables:
                continue
            if not download:
                raise GenError(f"recipe data missing: {f} is not cached and --offline given")
            url = CSV_URL.format(table=table, build=build)
            try:
                data = get(url)
            except (urllib.error.URLError, OSError) as e:
                raise GenError(f"recipe data unavailable: {url} -> {e}") from e
            if data[:200].lstrip().startswith(b"<") or b"," not in data.split(b"\n", 1)[0]:
                raise GenError(f"recipe data unavailable: {url} did not return a CSV (starts {data[:60]!r})")
            folder.mkdir(parents=True, exist_ok=True)
            tmp = f.with_suffix(".part")
            tmp.write_bytes(data)
            tmp.replace(f)
        with open(f, encoding="utf-8-sig", newline="") as fh:
            out[table] = list(csv.DictReader(fh))
        if not out[table]:
            raise GenError(f"recipe data broken: {f} has no rows")
    return out


# ---------------------------------------------------------------- overlay


def load_overlay(path: Path) -> dict:
    """The overlay, checked: {"recipes": {spell: {learn, cost, y, g, src, teacher, vendor}}, "vendor": {item ids},
    "listed": {skill lines}, "ranks": {line: [rank rows]}, "source": {...}}."""
    if not path.is_file():
        return dict(EMPTY_OVERLAY)
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except ValueError as e:
        raise GenError(f"overlay {path.name}: not JSON ({e})") from e
    if not isinstance(raw, dict):
        raise GenError(f"overlay {path.name}: the top level must be an object")
    recipes = {}
    for key, row in (raw.get("recipes") or {}).items():
        where = f"overlay {path.name}: recipes[{key!r}]"
        if not str(key).isdigit():
            raise GenError(f"{where}: the key must be a spell id")
        if not isinstance(row, dict):
            raise GenError(f"{where}: must be an object")
        out = {}
        for field in ("learn", "cost", "y", "g", "level"):
            v = row.get(field)
            if v is not None:
                if isinstance(v, bool) or not isinstance(v, int) or v < 0:
                    raise GenError(f"{where}.{field}: must be a whole number >= 0, got {v!r}")
                out[field] = v
        src = row.get("src")
        if src is not None:
            # a number is a source code of the research site that has no name yet
            if not (src in OVERLAY_SOURCES or (isinstance(src, int) and not isinstance(src, bool))):
                raise GenError(f"{where}.src: must be one of {', '.join(OVERLAY_SOURCES)} or a number, got {src!r}")
            out["src"] = src
        if row.get("teacher") is not None:
            if not isinstance(row["teacher"], str):
                raise GenError(f"{where}.teacher: must be text")
            out["teacher"] = row["teacher"]
        v = row.get("vendor")
        if v is not None:
            if not isinstance(v, dict) or not isinstance(v.get("npc"), int) or set(v) - VENDOR_FIELDS:
                raise GenError(f"{where}.vendor: must be an object with npc and any of name, zone, map, a, h")
            out["vendor"] = v
        unknown = sorted(set(row) - {"learn", "cost", "y", "g", "level", "src", "teacher", "vendor", "note"})
        if unknown:
            raise GenError(f"{where}: unknown field {unknown[0]!r}")
        recipes[int(key)] = out
    vendor = raw.get("vendor") or []
    if not isinstance(vendor, list) or any(isinstance(i, bool) or not isinstance(i, int) for i in vendor):
        raise GenError(f"overlay {path.name}: vendor must be a list of item ids")
    listed = raw.get("listed") or []
    if not isinstance(listed, list) or any(isinstance(i, bool) or not isinstance(i, int) for i in listed):
        raise GenError(f"overlay {path.name}: listed must be a list of skill line ids")
    ranks = {}
    for key, rows in (raw.get("ranks") or {}).items():
        where = f"overlay {path.name}: ranks[{key!r}]"
        if not str(key).isdigit() or not isinstance(rows, list):
            raise GenError(f"{where}: must be a skill line id with a list of rank rows")
        for r in rows:
            if not isinstance(r, dict) or not isinstance(r.get("name"), str) or not isinstance(r.get("cap"), int):
                raise GenError(f"{where}: a rank row needs name and cap")
            if set(r) - {"name", "cap", "skill", "cost", "where"}:
                raise GenError(f"{where}: unknown field {sorted(set(r) - {'name', 'cap', 'skill', 'cost', 'where'})[0]!r}")
        ranks[int(key)] = rows
    source = raw.get("source") if isinstance(raw.get("source"), dict) else {}
    return {"recipes": recipes, "vendor": set(vendor), "listed": set(listed), "ranks": ranks, "source": source}


def with_manual(overlay: dict, manual: dict) -> dict:
    """The hand-kept overlay (tools/data/overlay.manual.json: corrections, and what tools/import_savedvars.py took
    from the game) laid over the imported one: a recipe's fields one by one, a rank row's fields by rank name, the
    vendor reagents added. import_wowhead.py folds the same file's recipes in when it writes overlay.json; doing it
    here too means a correction reaches Data/Recipes.lua without a new research export."""
    recipes = {spell: dict(row) for spell, row in overlay["recipes"].items()}
    for spell, row in manual["recipes"].items():
        recipes.setdefault(spell, {}).update(row)
    ranks = {line: [dict(r) for r in rows] for line, rows in overlay["ranks"].items()}
    for line, rows in manual["ranks"].items():
        have = {r["name"]: r for r in ranks.setdefault(line, [])}
        for r in rows:
            if r["name"] in have:
                have[r["name"]].update(r)
            else:
                ranks[line].append(dict(r))
        ranks[line].sort(key=lambda r: r["cap"])
    return {**overlay, "recipes": recipes, "ranks": ranks, "vendor": set(overlay["vendor"]) | set(manual["vendor"])}


def place_names(t: dict[str, list[dict]]) -> tuple[dict[int, str], dict[int, str]]:
    """AreaTable id -> name and UiMap id -> name; empty when the optional tables are absent."""
    areas = {int(r["ID"]): (r.get("AreaName_lang") or "").strip() for r in t.get("AreaTable") or []}
    maps = {int(r["ID"]): (r.get("Name_lang") or "").strip() for r in t.get("UiMap") or []}
    return areas, maps


# ---------------------------------------------------------------- recipe data


def num(text, default: float = 0) -> float:
    try:
        return float(text) if text not in (None, "") else default
    except ValueError:
        return default


def count(n: float):
    return int(n) if float(n).is_integer() else round(n, 4)


def build_data(t: dict[str, list[dict]], build: str, overlay: dict | None = None) -> tuple[dict, list[str]]:
    """The whole Recipes.lua table from the CSV rows, and warnings (overlay entries that match no recipe)."""
    overlay = {**EMPTY_OVERLAY, **(overlay or {})}
    stats = {"thresholds": 0, "listed_gone": 0, "vendor_no_place": 0}
    # child lines share the parent's name; the recipes sit on the parent, whose own row names it
    line_names = {int(r["ID"]): (r.get("DisplayName_lang") or "").strip() for r in t["SkillLine"]}
    spell_names = {int(r["ID"]): r["Name_lang"] for r in t["SpellName"]}
    areas, maps = place_names(t)
    items = {}
    for r in t["ItemSparse"]:
        items[int(r["ID"])] = {
            "name": r.get("Display_lang") or f"item {r['ID']}", "sell": int(num(r.get("SellPrice"))),
            "buy": int(num(r.get("BuyPrice"))), "lot": max(1, int(num(r.get("VendorStackCount"), 1))),
            "stack": max(1, int(num(r.get("Stackable"), 1))), "reqSkillRank": int(num(r.get("RequiredSkillRank"))),
            "bonding": int(num(r.get("Bonding"))), "faction": int(num(r.get("MinFactionID"))),
            "rep": int(num(r.get("MinReputation"))),
        }
    reagents: dict[int, dict[int, int]] = {}
    for r in t["SpellReagents"]:
        mats = reagents.setdefault(int(r["SpellID"]), {})
        for i in range(8):
            item, n = int(num(r.get(f"Reagent_{i}"))), int(num(r.get(f"ReagentCount_{i}")))
            if item > 0 and n > 0:
                mats[item] = mats.get(item, 0) + n
    products: dict[int, tuple[int, float]] = {}
    for r in t["SpellEffect"]:
        if int(num(r.get("Effect"))) == EFFECT_CREATE_ITEM and int(num(r.get("EffectItemType"))) > 0:
            products.setdefault(int(r["SpellID"]), (int(r["EffectItemType"]), max(1.0, num(r.get("EffectBasePointsF"), 1))))
    effect_item = {int(r["ItemEffectID"]): int(r["ItemID"]) for r in t["ItemXItemEffect"]}
    teaches: dict[int, int] = {}
    for r in t["ItemEffect"]:
        if int(num(r.get("TriggerType"))) == TRIGGER_LEARN and int(r["ID"]) in effect_item:
            teaches.setdefault(int(r["SpellID"]), effect_item[int(r["ID"])])

    professions: dict[int, dict] = {}
    seen_spells = set()
    for r in sorted(t["SkillLineAbility"], key=lambda r: int(r["ID"])):
        spell, line = int(r["Spell"]), int(r["SkillLine"])
        yellow, grey = int(num(r.get("TrivialSkillLineRankLow"))), int(num(r.get("TrivialSkillLineRankHigh")))
        if not reagents.get(spell) or grey <= 0:
            continue  # not a craft (no reagents) or no skill-up range
        name = spell_names.get(spell, f"spell {spell}")
        if DEAD_NAME.search(name):
            continue
        prof = professions.setdefault(line, {"name": line_names.get(line) or f"skill line {line}", "to": TOP_RANK_CAP,
                                             "recipes": {}})
        if spell in prof["recipes"]:
            continue  # the same spell listed twice on a line (race or class rows)
        seen_spells.add(spell)
        # an enchant has reagents and no created item: it stays, with no `makes`
        product, made = products.get(spell, (None, 1.0))
        item = teaches.get(spell)
        over = overlay["recipes"].get(spell, {})
        src = "item" if item is not None else ("auto" if int(num(r.get("AcquireMethod"))) == ACQUIRE_AUTO else "trainer")
        osrc, came, teacher = over.get("src"), None, over.get("teacher")
        # a trainer recipe the overlay does not call one (no source stated, or a class skill it has no learn rank for)
        unconfirmed = None
        if line in overlay["listed"] and spell not in overlay["recipes"]:
            src = "unlisted"
        elif osrc in ("auto", "trainer", "item", "special"):
            src = osrc
        elif osrc is not None:
            # where the recipe item comes from; with no recipe item in the client data, the source teaches it itself
            came = osrc if isinstance(osrc, str) else f"source {osrc}"
            if item is None:
                src, teacher = "special", teacher or f"a {came}"
        elif src == "trainer" and overlay["listed"] and "level" not in over:
            unconfirmed = True
        if "y" in over or "g" in over:
            stats["thresholds"] += 1
        yellow, grey = over.get("y", yellow), over.get("g", grey)
        scroll = items.get(item, {}) if item is not None else {}
        vendor = over.get("vendor") if src == "item" else None
        if vendor:
            # where the vendor stands, by name: the map the game showed it on, else the research export's area
            place = maps.get(vendor.get("map")) or areas.get(vendor.get("zone"))
            if place:
                vendor = {**vendor, "place": place}
            elif (areas or maps) and (vendor.get("map") or vendor.get("zone")):
                stats["vendor_no_place"] += 1
        learn =over.get("learn", scroll.get("reqSkillRank") or None)
        # an item the recipe needs (a reagent, the product, its recipe item) with no ItemSparse row is not in the
        # game in this build: the recipe stays in the file, flagged, and the planner leaves it out
        needs = list(reagents[spell]) + [i for i in (product, item) if i is not None]
        gone = any(i not in items for i in needs)
        if gone and src != "unlisted" and line in overlay["listed"]:
            # the overlay lists it as a recipe of the game: the build's item table is what is incomplete (items can
            # reach the client outside the exported tables). The recipe is planned; its item has no bundled name.
            stats["listed_gone"] += 1
            gone = False
        prof["recipes"][spell] = {
            "y": yellow, "g": grey, "k": max(1, int(num(r.get("NumSkillUps"), 1))), "name": name,
            "mats": [x for i, n in sorted(reagents[spell].items()) for x in (i, n)],
            "makes": product, "n": count(made) if product else None, "src": src, "item": item, "learn": learn,
            "teacher": teacher, "cost": over.get("cost"),
            # the recipe item's source (vendor, quest, drop, crafted) and the one vendor the overlay names for it:
            # { name, npc, zone, map, place, a, h } (zone = an AreaTable id, map = a UiMap id, place = that zone's name
            # from the client tables; a / h = the NPC's reaction to Alliance / Horde, absent when not known)
            "from": came if src == "item" else None, "vendor": vendor,
            "unc": unconfirmed,
            # learned by character level, not by skill (the rogue's poisons)
            "level": over.get("level"),
            # the recipe item: binds when picked up (never an auction buy), what a vendor would ask for one (the
            # client's BuyPrice; which vendor sells it, if any, is the overlay's to say), and the reputation it needs
            "bop": True if scroll.get("bonding") == BIND_ON_PICKUP else None,
            "buy": count(scroll["buy"] / scroll["lot"]) if scroll.get("buy") else None,
            "faction": scroll.get("faction") or None, "rep": scroll.get("rep") or None,
            "gone": True if gone else None,
        }
    warnings = [f"overlay: spell {s} is not a craft recipe in build {build}"
                for s in sorted(set(overlay["recipes"]) - seen_spells)]
    for line in WORLD_LINES:
        # a skill raised in the world that has no craft recipe at all (Lockpicking) still gets an entry
        if line not in professions and line_names.get(line):
            professions[line] = {"name": line_names[line], "to": TOP_RANK_CAP, "recipes": {}}
    for line, prof in professions.items():
        prof["side"] = True if len(prof["recipes"]) < MIN_CRAFT_RECIPES else None
        # raised mostly or wholly in the world (nodes, herbs, skins, fish, locks): its coverage is recipes plus the
        # world spots of Data/Spots.lua, never recipes alone
        prof["world"] = True if line in WORLD_LINES else None
        # the classic ranks, each replaced by the overlay's row of that name. A rank the overlay gives without a
        # trainer (a quest) keeps the classic skill and has no price; one it lacks altogether (the Expert Cooking
        # book) keeps the classic numbers with where = "unknown". All are confirmed = false.
        given = {r["name"]: r for r in overlay["ranks"].get(line, [])}
        ranks = []
        for name, cap, skill, cost in DEFAULT_RANKS:
            o = given.get(name)
            if o is None:
                ranks.append({"name": name, "cap": cap, "skill": skill or None, "cost": cost,
                              "where": "unknown" if given else "trainer", "confirmed": False})
            elif o.get("where", "trainer") == "trainer":
                ranks.append({"name": name, "cap": o["cap"], "skill": o.get("skill"), "cost": o.get("cost"),
                              "where": "trainer", "confirmed": False})
            else:
                ranks.append({"name": name, "cap": o["cap"], "skill": o.get("skill", skill or None), "cost": None,
                              "where": o["where"], "confirmed": False})
        prof["ranks"] = None if line in NO_RANKS else ranks

    item_ids, made_by = set(), {}
    for _, prof in sorted(professions.items()):
        for spell, row in sorted(prof["recipes"].items()):
            item_ids.update(row["mats"][0::2])
            if row["makes"]:
                item_ids.add(row["makes"])
                made_by.setdefault(row["makes"], spell)
            if row["item"]:
                item_ids.add(row["item"])
    out_items, missing = {}, 0
    for i in sorted(item_ids):
        info = items.get(i)
        if info is None:
            missing += 1
            continue
        out_items[i] = {"name": info["name"], "sell": info["sell"] or None,
                        "stack": info["stack"] if info["stack"] > 1 else None, "madeBy": made_by.get(i)}
    if missing:
        warnings.append(f"{missing} items used by recipes have no ItemSparse row in build {build}: their recipes are "
                        "flagged gone")
    vendor = {}
    for i in sorted(VENDOR_REAGENTS | overlay["vendor"]):
        info = items.get(i)
        if info and info["buy"]:
            # BuyPrice is for one vendor lot of VendorStackCount items
            vendor[i] = count(info["buy"] / info["lot"])
        elif i in overlay["vendor"]:
            warnings.append(f"overlay: vendor item {i} has no vendor price in ItemSparse")
    src = overlay["source"]
    data = {"version": 2, "build": build,
            "source": f"{src['name']}, {src.get('retrieved', 'date unknown')}" if src.get("name") else None,
            "vendor": vendor, "items": out_items, "professions": dict(sorted(professions.items())), "stats": stats}
    return data, warnings


def summary(data: dict) -> list[str]:
    lines = []
    for line, prof in data["professions"].items():
        rows = prof["recipes"].values()
        by = {s: sum(1 for r in rows if r["src"] == s) for s in SOURCES}
        live = [r for r in rows if not r["gone"]]
        no_learn = sum(1 for r in live if r["src"] == "trainer" and r["learn"] is None)
        bop = sum(1 for r in live if r["src"] == "item" and r["bop"])
        trade = sum(1 for r in live if r["src"] == "item" and not r["bop"])
        usable = [r for r in live if r["src"] != "unlisted"]
        learn = sum(1 for r in usable if r["learn"] is not None)
        lines.append(f"{line:>4} {prof['name']:<16} {len(rows):>4} recipes ({len(rows) - len(live)} gone): "
                     f"{by['auto']} auto, {by['trainer']} trainer ({no_learn} in the game without a learn rank), "
                     f"{by['item']} item ({trade} tradeable, {bop} bind on pickup), {by['special']} special, "
                     f"{by['unlisted']} unlisted; learn rank on {learn} of {len(usable)} usable")
    for line, prof in data["professions"].items():
        names = sorted(r["name"] for r in prof["recipes"].values() if r["src"] == "unlisted")
        if names:
            lines.append(f"{line:>4} {prof['name']} unlisted ({len(names)}): {', '.join(names)}")
    stats = data.get("stats") or {}
    lines.append(f"{len(data['items'])} items, {len(data['vendor'])} vendor reagents, {stats.get('thresholds', 0)} "
                 f"threshold overrides from the overlay, {stats.get('listed_gone', 0)} listed recipes kept although "
                 "an item of theirs is not in the build's item table")
    return lines


def brackets(levels: list[int]) -> list[tuple[int, int]]:
    """Sorted skill levels as (first, last) runs."""
    out: list[tuple[int, int]] = []
    for s in levels:
        if out and s == out[-1][1] + 1:
            out[-1] = (out[-1][0], s)
        else:
            out.append((s, s))
    return out


def coverage(prof: dict, top: int = TOP_RANK_CAP, items: bool = True) -> list[tuple[int, int]]:
    """The skill brackets in 1..top-1 where no recipe gives skill (orange, yellow or green), from thresholds and learn
    ranks alone: no prices. A recipe counts from the skill it can be learned at (auto: 1; trainer: its learn rank, or
    yellow when the data has none; a tradeable recipe item: its learn rank) until it turns grey. Left out: recipes
    flagged gone, special teachers, recipe items that bind when picked up, and with items=False every recipe item."""
    spans = []
    for r in prof["recipes"].values():
        if r["gone"] or r["src"] in ("special", "unlisted") or (r["src"] == "item" and (r["bop"] or not items)):
            continue
        if r["src"] == "trainer":
            start = r["learn"] if r["learn"] is not None else r["y"]
        elif r["src"] == "item":
            start = r["learn"] or 1
        else:
            start = 1
        spans.append((max(1, start), r["g"]))
    holes = [s for s in range(1, top) if not any(a <= s < g for a, g in spans)]
    return brackets(holes)


def spot_requirements(text: str) -> dict[int, list[int]]:
    """Data/Spots.lua's world targets per skill line: the `req` of every row under `targets = {`."""
    out: dict[int, list[int]] = {}
    line, in_targets = None, False
    for row in text.splitlines():
        m = re.match(r"^\t\t\[(\d+)\] = \{", row)
        if m:
            line, in_targets = int(m.group(1)), False
        elif line is not None and re.match(r"^\t\t\ttargets = \{", row):
            in_targets = True
        elif in_targets and re.match(r"^\t\t\t\}", row):
            in_targets = False
        elif in_targets:
            m = re.search(r"\breq = (\d+)", row)
            if m:
                out.setdefault(line, []).append(int(m.group(1)))
    return out


def check(data: dict, spots: dict[int, list[int]] | None = None) -> tuple[list[str], bool]:
    """--check: per crafting profession, the uncovered brackets with and without recipe items. True = a hole.
    A skill raised in the world (prof["world"]) is covered by recipes plus world targets: with `spots` (the
    requirements read from Data/Spots.lua) what neither covers is a hole; without, it only says it needs them."""
    lines, bad = [], False
    for line, prof in data["professions"].items():
        full, plain = coverage(prof), coverage(prof, items=False)
        fmt = lambda b: ", ".join(f"{a}-{z + 1}" for a, z in b)  # noqa: E731
        if prof.get("world"):
            if spots is None:
                lines.append(f"{line:>4} {prof['name']:<16} needs world spots"
                             + (f" (recipes cover all but {fmt(full)})" if prof["recipes"] else " (no recipes)"))
                continue
            reqs = spots.get(line, [])
            if not reqs:
                # Fishing: its spots are zones with a skill, not targets with a requirement
                lines.append(f"{line:>4} {prof['name']:<16} needs world spots; the spots file has no targets to check "
                             "it against")
                continue
            left = brackets([s for a, z in full for s in range(a, z + 1)
                             if not any(r <= s < r + SPOT_GREY for r in reqs)])
            if left:
                bad = True
                lines.append(f"{line:>4} {prof['name']:<16} HOLE: neither a recipe nor a world target gives skill at "
                             f"{fmt(left)}")
            else:
                lines.append(f"{line:>4} {prof['name']:<16} covered 1-{TOP_RANK_CAP} by recipes and {len(reqs)} world "
                             "targets")
            continue
        if prof.get("side"):
            continue
        if full:
            bad = True
            lines.append(f"{line:>4} {prof['name']:<16} HOLE: nothing gives skill at {fmt(full)}")
        else:
            lines.append(f"{line:>4} {prof['name']:<16} covered 1-{TOP_RANK_CAP}"
                         + (f"; needs a bought recipe at {fmt(plain)}" if plain else " by trainer recipes alone"))
    return lines, bad


# ---------------------------------------------------------------- Lua


def lua_str(s: str) -> str:
    out = []
    for b in str(s).encode("utf-8"):
        c = chr(b)
        if c in '"\\':
            out.append("\\" + c)
        elif 32 <= b < 127:
            out.append(c)
        else:
            out.append(f"\\{b:03d}")
    return '"' + "".join(out) + '"'


def lua_key(k) -> str:
    if isinstance(k, int):
        return f"[{k}]"
    plain = str(k).isidentifier() and str(k).isascii() and str(k) not in LUA_KEYWORDS
    return k if plain else f"[{lua_str(k)}]"


def lua_inline(v) -> str:
    """A value on one line; None fields of a dict are left out."""
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        return repr(round(v, 4))
    if isinstance(v, str):
        return lua_str(v)
    if isinstance(v, (list, tuple)):
        return "{ " + ", ".join(lua_inline(x) for x in v) + " }" if v else "{}"
    if isinstance(v, dict):
        parts = [f"{lua_key(k)} = {lua_inline(x)}" for k, x in v.items() if x is not None]
        return "{ " + ", ".join(parts) + " }" if parts else "{}"
    raise TypeError(f"cannot write {type(v).__name__} to Lua")


def render(data: dict) -> str:
    """One item, one vendor reagent and one recipe per line, in id order, so a diff reads recipe by recipe."""
    out = [
        "-- Generated by tools/gen_recipes.py from the wago.tools export of the WoW: Forever client, with",
        "-- tools/data/overlay.json on top. Do not edit: change the overlay and regenerate, or put your own changes in",
        "-- Data/Custom.lua (see Data/Custom.example.lua). Every craft recipe of every profession: y / g = the skill where",
        "-- it turns yellow / grey, k = skill-ups a craft, mats = { item, count, ... }, makes / n = the item made and how",
        "-- many, src = auto | trainer | item | special, item = the recipe item, learn = the skill needed to learn it,",
        "-- bop = the recipe item binds when picked up, buy = its vendor price, faction / rep = the reputation it needs,",
        "-- gone = an item the recipe needs is not in this build's item data (left out of plans), from = where the recipe",
        "-- item comes from (vendor, quest, drop, crafted), vendor = the one vendor known to sell it (place = the zone it",
        "-- stands in), unc = a trainer recipe no source confirms. src = unlisted: not in the overlay's list for its",
        "-- profession (a gated shortcut).",
        "-- No auction prices: those come from TradeSkillMaster in game.",
        "-- luacheck: ignore",
        "local _, ns = ...",
        "ns.Data = ns.Data or {}",
        "ns.Data.recipes = {",
        f"\tversion = {data['version']},",
        f"\tbuild = {lua_str(data['build'])},",
    ]
    if data.get("source"):
        out.append(f"\tsource = {lua_str(data['source'])},")
    # recipes per profession, so the addon can say what loaded without walking the tables
    out.append("\tcounts = " + lua_inline({line: len(p["recipes"]) for line, p in data["professions"].items()}) + ",")
    out.append("\tvendor = {")
    out += [f"\t\t[{i}] = {lua_inline(p)}," for i, p in data["vendor"].items()]
    out += ["\t},", "\titems = {"]
    out += [f"\t\t[{i}] = {lua_inline(row)}," for i, row in data["items"].items()]
    out += ["\t},", "\tprofessions = {"]
    for line, prof in data["professions"].items():
        out += [f"\t\t[{line}] = {{", f"\t\t\tname = {lua_str(prof['name'])},", f"\t\t\tto = {prof['to']},"]
        if prof.get("side"):
            out.append("\t\t\tside = true,")
        if prof.get("world"):
            out.append("\t\t\tworld = true,")
        if prof.get("ranks"):
            out.append("\t\t\tranks = {")
            out += [f"\t\t\t\t{lua_inline(r)}," for r in prof["ranks"]]
            out.append("\t\t\t},")
        out.append("\t\t\trecipes = {")
        out += [f"\t\t\t\t[{spell}] = {lua_inline(row)}," for spell, row in sorted(prof["recipes"].items())]
        out += ["\t\t\t},", "\t\t},"]
    out += ["\t},", "}", ""]
    return "\n".join(out)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--build", help="client build, e.g. 1.60.1.70888 (default: the newest wowf build on wago.tools)")
    ap.add_argument("--cache", help="folder of <build>/<Table>.enUS.csv, or one build's folder (default: tools/.cache)")
    ap.add_argument("--out", help="Lua file to write (default: Data/Recipes.lua)")
    ap.add_argument("--overlay", help="overlay file (default: tools/data/overlay.json)")
    ap.add_argument("--manual", help="hand-kept overlay laid on top (default: tools/data/overlay.manual.json)")
    ap.add_argument("--offline", action="store_true", help="never download: use the cache only")
    ap.add_argument("--check", action="store_true",
                    help="write nothing: print per profession the skill brackets in 1..300 no recipe covers (exit 1 on a hole)")
    ap.add_argument("--spots", help="with --check: Data/Spots.lua, so a skill raised in the world (Mining) is checked "
                                    "against its world targets too")
    a = ap.parse_args(argv)
    try:
        cache = Path(a.cache) if a.cache else DEFAULT_CACHE
        folder, build = resolve(cache, a.build, not a.offline)
        overlay = with_manual(load_overlay(Path(a.overlay) if a.overlay else DEFAULT_OVERLAY),
                              load_overlay(Path(a.manual) if a.manual else DEFAULT_MANUAL))
        data, warnings = build_data(fetch_tables(folder, build, not a.offline), build, overlay)
        if not data["professions"]:
            raise GenError(f"build {build}: no craft recipe found on any skill line")
        if a.check:
            spots = None
            if a.spots:
                f = Path(a.spots)
                if not f.is_file():
                    raise GenError(f"--spots {f.name}: no such file")
                spots = spot_requirements(f.read_text(encoding="utf-8"))
            lines, bad = check(data, spots)
            print(f"build {build}")
            for line in lines:
                print(line)
            return 1 if bad else 0
        out = Path(a.out) if a.out else DEFAULT_OUT
        if not out.parent.is_dir():
            raise GenError(f"folder {out.parent} is missing")
        tmp = out.with_suffix(".lua.tmp")
        tmp.write_text(render(data), encoding="utf-8", newline="\n")
        os.replace(tmp, out)
        for w in warnings:
            print(f"warning: {w}", file=sys.stderr)
        print(f"build {build}")
        for line in summary(data):
            print(line)
        print(f"wrote {out.name}, {out.stat().st_size} bytes")
        return 0
    except GenError as e:
        print(f"error: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
