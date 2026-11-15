#!/usr/bin/env python3
"""Write Data/Trainers.lua: profession trainers and recipe vendors, with a map position where one is known.

    python tools/gen_npcs.py --npcs npcs.json --items recipe_items.json --wago DIR --cmangos FILE --out Data/Trainers.lua

Python 3 standard library only; shares the zone mapping and the dump reader with gen_spots.py (same --wago,
--cmangos, --build and --download).

  --npcs FILE    { "<npc id>": { name, tag, react [alliance, horde], zones [area ids], trains [skill lines],
                 sells [recipe item ids] } }: the WoW: Forever trainers and recipe vendors (a Wowhead Forever list
                 scrape; it has who and which zone, not where).
  --items FILE   { "<item id>": { skill, name, ... } }: the recipe items, to tell a vendor's recipes from its other wares.
  --cmangos      the Classic 1.12 dump: creature spawns give the position, creature_template checks the name,
                 npc_vendor / npc_vendor_template give the recipes sold and their limited stock. Classic data.
  --places FILE  the addon's Data/Npcs.lua (default): a row of it on the same map and close by lends its town name.

An NPC the dump lacks, or has under another name, is kept without a position (nopos = true): the addon learns it
when the player opens the NPC. Exit code 2 = a broken link, named on stderr.
"""
from __future__ import annotations

import argparse
import collections
import json
import math
import re
import sys
from pathlib import Path

import gen_spots as gs

HERE = Path(__file__).resolve().parent
SQL_TABLES = ("creature", "creature_template", "npc_vendor", "npc_vendor_template")
RANKS = ("Grand Master", "Apprentice", "Journeyman", "Expert", "Artisan", "Master")
PLACE_REACH = 6.0  # map percent: how near a Data/Npcs.lua row must be to lend its town name
ROLE_TRAINER, ROLE_VENDOR, ROLE_DROP = "trainer", "recipes", "recipedrop"


def read_json(path: Path, what: str) -> dict:
    if not path.is_file():
        raise gs.GenError(f"{what} missing: {path}")
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except ValueError as e:
        raise gs.GenError(f"{path}: not JSON ({e})") from e


def read_places(path: Path) -> list[tuple]:
    if not path.is_file():
        return []
    out = []
    for line in path.read_text(encoding="utf-8").splitlines():
        m = re.search(r'map = (\d+), x = ([\d.]+), y = ([\d.]+).*?place = "([^"]+)"', line)
        if m:
            out.append((int(m.group(1)), float(m.group(2)), float(m.group(3)), m.group(4)))
    return out


def same_name(a: str, b: str) -> bool:
    def norm(s):
        return re.sub(r"[^a-z0-9]+", "", s.lower())
    return norm(a) == norm(b)


def side(react) -> str | None:
    """react = [alliance, horde], 1 friendly, 0 neutral, -1 hostile, None unknown: who can use this NPC."""
    if not react:
        return None
    a, h = (-1 if v is None else v for v in react)
    if a == h:
        return "B" if a >= 0 else None
    return "A" if a > h else "H"


def build(w: dict, sql: dict, npcs: dict, items: dict, places: list, wowf_build: str) -> tuple[str, dict]:
    zones = gs.Zones(w)
    templates = {int(t["Entry"]): t for t in sql["creature_template"]}
    spawns = collections.defaultdict(list)
    for c in sql["creature"]:
        spawns[int(c["id"])].append((int(c["guid"]), int(c["map"]), float(c["position_x"]), float(c["position_y"])))
    factions = {int(r["ID"]): int(r["FriendGroup"]) for r in w["FactionTemplate"]}
    skill_name = {int(r["ID"]): r["DisplayName_lang"] for r in w["SkillLine"]}
    recipe_items = {int(k) for k in items}
    vendor = collections.defaultdict(dict)  # creature entry or template id -> {item: maxcount}
    vendor_tpl = collections.defaultdict(dict)
    for r in sql["npc_vendor"]:
        vendor[int(r["entry"])][int(r["item"])] = int(r["maxcount"])
    for r in sql["npc_vendor_template"]:
        vendor_tpl[int(r["entry"])][int(r["item"])] = int(r["maxcount"])

    rows, stats = [], collections.Counter()
    mismatches, differs = [], []
    for key in sorted(npcs, key=int):
        n, npc_id = npcs[key], int(key)
        trains = [int(s) for s in n.get("trains") or []]
        hint = [zones.zone_of_area(int(a)) for a in n.get("zones") or [] if int(a) > 0]
        hint = [z for z in hint if z]
        area = next((zones.area.get(int(a)) for a in n.get("zones") or [] if int(a) in zones.area), None)
        row = collections.OrderedDict(id=npc_id, name=n["name"])
        tpl = templates.get(npc_id)
        positioned = False
        if tpl and not same_name(tpl["Name"], n["name"]):
            mismatches.append(f"{npc_id}: Forever {n['name']!r}, cmangos {tpl['Name']!r}")
            row["mismatch"] = tpl["Name"]
            tpl = None
        if tpl and spawns.get(npc_id):
            here = sorted(spawns[npc_id])
            pick = None
            for _guid, mp, x, y in here:  # a spawn inside the zone the Forever list names, when there is one
                for z in hint:
                    if z["cont"] == mp and z["x0"] <= x <= z["x1"] and z["y0"] <= y <= z["y1"]:
                        pick = pick or (z, mp, x, y)
            if not pick:
                _guid, mp, x, y = here[0]
                z = zones.find(mp, x, y) if mp in gs.CONTINENTS else None
                if z:
                    pick = (z, mp, x, y)
                    if hint:
                        differs.append(f"{npc_id} {n['name']}: Forever list says {hint[0]['name']}, the Classic spawn is in {z['name']}")
            if pick:
                z, mp, x, y = pick
                mx, my = zones.percent(z, x, y)
                near = [(math.hypot(px - mx, py - my), place) for pm, px, py, place in places if pm == z["id"]]
                near = [p for p in near if p[0] <= PLACE_REACH or z["city"]]
                row.update(map=z["id"], x=round(mx, 1), y=round(my, 1))
                row["place"] = min(near)[1] if near else z["name"]
                positioned = True
        if not positioned:
            z = hint[0] if hint else None
            row["map"] = z["id"] if z else None
            row["place"] = z["name"] if z else (area["AreaName_lang"] if area else None)
        row["role"] = ROLE_TRAINER if trains else ROLE_VENDOR
        if trains:
            row["trains"] = skill_name.get(trains[0])  # the one name Guide.seedRecords reads for role "trainer"
            row["skill"] = trains[0] if len(trains) == 1 else trains
            tag = n.get("tag") or ""
            row["rank"] = next((r.lower() for r in RANKS if tag.startswith(r + " ")), None)
        row["tag"] = n.get("tag") or None
        faction = side(n.get("react"))
        if faction is None and tpl:
            friend = factions.get(int(tpl["Faction"]), 0)
            faction = "B" if friend & 1 or friend & 6 == 6 else "A" if friend & 2 else "H" if friend & 4 else None
        row["faction"] = faction
        sold = {int(i) for i in n.get("sells") or []}
        limited, stocked = {}, set()
        if tpl:
            stock = dict(vendor_tpl.get(int(tpl["VendorTemplateId"]), {}))
            stock.update(vendor.get(npc_id, {}))
            for item, maxcount in stock.items():
                if item in recipe_items:
                    stocked.add(item)
                    if maxcount > 0:
                        limited[item] = maxcount
        if not trains and tpl and not stocked and not n.get("tag") and not n.get("react"):
            # the Forever list names this NPC as a recipe's one source, and in Classic it sells nothing: the recipe
            # drops from it (a mob or a boss), it is not a vendor
            row["role"] = ROLE_DROP
        if sold or stocked:
            row["recipes"] = sorted(sold | stocked)
            if row["role"] != ROLE_DROP:
                row["sells"] = sorted(sold | stocked)
            row["limited"] = collections.OrderedDict(sorted(limited.items())) or None
        if row["role"] == ROLE_VENDOR and not tpl:
            row["unsure"] = True  # not in the Classic data: vendor or drop source, the list does not say
        row["classic"] = True if positioned else None
        row["nopos"] = None if positioned else True
        rows.append(row)
        for s in trains or ["vendor"]:
            label = skill_name.get(s, str(s)) if s != "vendor" else (
                "Recipe drop sources" if row["role"] == ROLE_DROP else "Recipe vendors")
            stats[(label, faction or "?", "pos" if positioned else "nopos")] += 1

    rows.sort(key=lambda r: (r["role"], str(r.get("trains") or ""), r["id"]))
    L = [
        "-- GENERATED by tools/gen_npcs.py: do not edit.",
        "-- Profession trainers and recipe vendors of WoW: Forever. Who they are: a Wowhead Forever list scrape. Where they",
        "-- stand, and limited stock: derived from the cmangos classic-db (GPL-3.0, LICENSES/cmangos-classic-db.txt):",
        "-- Classic 1.12 data, unconfirmed for Forever. nopos = true: position not known yet. Schema: docs/spots-data.md.",
        "local _, ns = ...",
        "ns.Data = ns.Data or {}",
        "",
        f"ns.Data.trainersMeta = {{ version = 1, build = {gs.lua_str(wowf_build)}, classicSource = {gs.lua_str(gs.CLASSIC_SOURCE)} }}",
        "ns.Data.trainers = {",
    ]
    L += ["\t" + gs.lua(r) + "," for r in rows]
    L += ["}", ""]
    return "\n".join(L), {"stats": stats, "mismatches": mismatches, "differs": differs, "rows": len(rows)}


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--npcs", required=True)
    ap.add_argument("--items", required=True)
    ap.add_argument("--wago", required=True)
    ap.add_argument("--cmangos", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--build")
    ap.add_argument("--places", default=str(HERE.parent / "Data" / "Npcs.lua"))
    ap.add_argument("--download", action="store_true")
    a = ap.parse_args(argv)
    try:
        wago = Path(a.wago)
        wowf_build = gs.read_build(wago, a.build)
        text, info = build(
            gs.load_wago(wago, wowf_build, a.download), gs.load_sql(Path(a.cmangos), a.download, SQL_TABLES),
            read_json(Path(a.npcs), "NPC list"), read_json(Path(a.items), "recipe item list"),
            read_places(Path(a.places)), wowf_build)
        out = Path(a.out)
        out.parent.mkdir(parents=True, exist_ok=True)
        with open(out, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(text)
    except gs.GenError as e:
        print(f"gen_npcs: {e}", file=sys.stderr)
        return 2
    table = collections.defaultdict(collections.Counter)
    for (label, faction, state), n in info["stats"].items():
        table[label][f"{faction} {state}"] += n
        table[label][state] += n
    for label in sorted(table):
        c = table[label]
        detail = ", ".join(f"{k} {c[k]}" for k in sorted(c) if " " in k)
        print(f"{label}: positioned {c['pos']}, nopos {c['nopos']} ({detail})")
    print(f"name mismatches: {len(info['mismatches'])}")
    for m in info["mismatches"]:
        print("  " + m)
    print(f"zone differs from the Forever list: {len(info['differs'])}")
    for m in info["differs"]:
        print("  " + m)
    print(f"{out}: {info['rows']} rows, {len(text.encode('utf-8')) / 1024:.1f} KB, build {wowf_build}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
