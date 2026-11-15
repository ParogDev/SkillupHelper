#!/usr/bin/env python3
"""Keep the shipped data in step with the game: look for a newer WoW: Forever build, regenerate, say what changed.

    python tools/update_data.py --report report.md             # regenerate what changed, write the report
    python tools/update_data.py --dry-run --report report.md   # write nothing but the report
    python tools/update_data.py --cmangos classicdb.sql        # also regenerate Data/Spots.lua (positions need the dump)
    python tools/update_data.py --cmangos classicdb.sql --npcs npcs.json --items recipe_items.json   # and Trainers.lua

Python 3 standard library only. It asks https://wago.tools/api/builds for the newest `wowf` build, compares it with
the build written in Data/Recipes.lua, and regenerates from the client tables of that build:

  Data/Recipes.lua                  always, whole (tools/gen_recipes.py with tools/data/overlay.json and
                                    overlay.manual.json on top).
  tools/data/client_snapshot.json   always: what the client tables say that Data/Spots.lua is built on (what every
                                    lock, herb and ore needs, the flight points, the zone maps). Its diff is how a new
                                    lock or node requirement is noticed without the Classic position dump.
  Data/Spots.lua                    only with --cmangos: its positions come from the cmangos classic-db dump, which is
                                    not in the repository. Without the dump the file is left exactly as it is (no
                                    position is dropped) and the report says so and lists what waits.
  Data/Trainers.lua                 only with --cmangos, --npcs and --items (the NPC list is a manual research export).

Never refreshed here: tools/data/overlay.json (a person reads it from Wowhead; docs/data-sources.md).

The report (--report FILE, markdown) lists recipes added, removed and renamed, threshold, reagent and bonding changes,
recipe items that appeared or went, lock and node requirements that changed, new craft spells the overlay does not
know ("needs a source"), and the 1-300 coverage of every profession before and after.

Exit code: 0 nothing changed, 10 data changed (written, unless --dry-run), 1 a coverage hole appeared or an input
broke (named on stderr and in the report; nothing but the report is written). The download cache (tools/.cache) is
written in every mode.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gen_recipes as G  # noqa: E402
import luatable  # noqa: E402

EXIT_SAME, EXIT_CHANGED, EXIT_BROKEN = 0, 10, 1
SNAPSHOT_TABLES = ("Lock", "TaxiNodes", "UiMap")
# LockType ids (Lock._Index_n where Type_n = 2, a skill lock), as tools/gen_spots.py reads them
LOCK_SKILLS = {1: "Lockpicking", 2: "Herbalism", 3: "Mining"}
UIMAP_ZONE = "3"
ROW_KEYS = ("y", "g", "k", "name", "mats", "makes", "n", "src", "item", "learn", "teacher", "cost", "from", "vendor",
            "unc", "level", "bop", "buy", "faction", "rep", "gone")
OTHER_FIELDS = ("k", "makes", "n", "src", "learn", "cost", "from", "level", "buy", "faction", "rep", "gone", "unc",
                "teacher", "vendor")
SECTION_CAP = 150  # lines of one report section; the rest is counted


# ---------------------------------------------------------------- the shipped files


def shipped_build(text: str) -> str | None:
    m = re.search(r'\bbuild = "([\d.]+)"', text)
    return m.group(1) if m else None


def from_lua(parsed: dict | None) -> dict:
    """A parsed Data/Recipes.lua in the shape gen_recipes.build_data makes (every row field present, None when the
    file leaves it out), so the shipped file and a fresh render compare like for like."""
    parsed = parsed or {}
    professions = {}
    for line, p in sorted((parsed.get("professions") or {}).items()):
        recipes = {}
        for spell, r in (p.get("recipes") or {}).items():
            row = {k: r.get(k) for k in ROW_KEYS}
            row["mats"] = [v for _, v in sorted((r.get("mats") or {}).items())]
            recipes[spell] = row
        professions[line] = {"name": p.get("name") or f"skill line {line}", "to": p.get("to"), "side": p.get("side"),
                             "world": p.get("world"), "recipes": recipes,
                             "ranks": [v for _, v in sorted((p.get("ranks") or {}).items())]}
    return {"build": parsed.get("build"), "source": parsed.get("source"), "professions": professions,
            "items": parsed.get("items") or {}, "vendor": parsed.get("vendor") or {}}


def read_recipes(text: str) -> dict:
    try:
        return from_lua(luatable.read_assignment(text, "ns.Data.recipes"))
    except luatable.LuaError as e:
        raise G.GenError(f"Data/Recipes.lua: not readable ({e})") from e


# ---------------------------------------------------------------- what changed


def mats_text(mats: list, items: dict) -> str:
    pairs = zip(mats[0::2], mats[1::2])
    return ", ".join(f"{n}x {(items.get(i) or {}).get('name') or f'item {i}'}" for i, n in pairs) or "nothing"


def item_text(item, items: dict) -> str:
    if item is None:
        return "none"
    return f"{(items.get(item) or {}).get('name') or 'unnamed'} (item {item})"


def diff_recipes(old: dict, new: dict) -> dict[str, list[str]]:
    """Every section of the report that compares two recipe tables, as lines of text."""
    out = {k: [] for k in ("added", "removed", "renamed", "thresholds", "reagents", "bonding", "recipe_items", "other",
                           "ranks", "professions", "vendor")}
    items = {**old["items"], **new["items"]}
    for line in sorted(set(old["professions"]) | set(new["professions"])):
        po, pn = old["professions"].get(line), new["professions"].get(line)
        name = (pn or po)["name"]
        if po is None or pn is None:
            out["professions"].append(f"{name} ({line}): {'new skill line' if po is None else 'skill line removed'}, "
                                      f"{len((pn or po)['recipes'])} recipes")
        ro, rn = (po or {"recipes": {}})["recipes"], (pn or {"recipes": {}})["recipes"]
        for spell in sorted(set(rn) - set(ro)):
            r = rn[spell]
            out["added"].append(f"{name}: {r['name']} (spell {spell}), yellow {r['y']}, grey {r['g']}, {r['src']}"
                                + (f", learn {r['learn']}" if r["learn"] is not None else "")
                                + f"; needs {mats_text(r['mats'], items)}")
        for spell in sorted(set(ro) - set(rn)):
            out["removed"].append(f"{name}: {ro[spell]['name']} (spell {spell})")
        for spell in sorted(set(ro) & set(rn)):
            a, b = ro[spell], rn[spell]
            who = f"{name}: {b['name']} (spell {spell})"
            if a["name"] != b["name"]:
                out["renamed"].append(f"{name}: {a['name']} -> {b['name']} (spell {spell})")
            if (a["y"], a["g"]) != (b["y"], b["g"]):
                out["thresholds"].append(f"{who}: yellow {a['y']} -> {b['y']}, grey {a['g']} -> {b['g']}")
            if a["mats"] != b["mats"]:
                out["reagents"].append(f"{who}: {mats_text(a['mats'], items)} -> {mats_text(b['mats'], items)}")
            if bool(a["bop"]) != bool(b["bop"]):
                out["bonding"].append(f"{who}: its recipe item {'now binds' if b['bop'] else 'no longer binds'} when "
                                      "picked up")
            if a["item"] != b["item"]:
                out["recipe_items"].append(f"{who}: recipe item {item_text(a['item'], items)} -> "
                                           f"{item_text(b['item'], items)}")
            changed = []
            for f in OTHER_FIELDS:
                if a[f] == b[f]:
                    continue
                if isinstance(a[f], dict) and isinstance(b[f], dict):
                    # the vendor: only the parts that changed
                    changed += [f"{f} {k} {show(a[f].get(k))} -> {show(b[f].get(k))}"
                                for k in sorted(set(a[f]) | set(b[f])) if a[f].get(k) != b[f].get(k)]
                else:
                    changed.append(f"{f} {show(a[f])} -> {show(b[f])}")
            if changed:
                out["other"].append(f"{who}: " + ", ".join(changed))
        if po is not None and pn is not None and po["ranks"] != pn["ranks"]:
            for a, b in zip(po["ranks"], pn["ranks"]):
                if a != b:
                    out["ranks"].append(f"{name}: {b.get('name')}: " + ", ".join(
                        f"{f} {show(a.get(f))} -> {show(b.get(f))}" for f in ("cap", "skill", "cost", "where")
                        if a.get(f) != b.get(f)))
            if len(po["ranks"]) != len(pn["ranks"]):
                out["ranks"].append(f"{name}: {len(po['ranks'])} rank rows -> {len(pn['ranks'])}")
    for item in sorted(set(old["vendor"]) | set(new["vendor"])):
        a, b = old["vendor"].get(item), new["vendor"].get(item)
        if a != b:
            out["vendor"].append(f"{item_text(item, items)}: vendor price {show(a)} -> {show(b)}")
    return out


def show(v) -> str:
    if v is None:
        return "none"
    if isinstance(v, dict):
        return "{" + ", ".join(f"{k} {show(x)}" for k, x in v.items()) + "}"
    return str(v)


def unknown_to_overlay(data: dict, overlay: dict) -> dict[int, tuple[str, str]]:
    """Craft spells of the data with no overlay entry: spell -> (profession, recipe name)."""
    return {spell: (prof["name"], r["name"]) for prof in data["professions"].values()
            for spell, r in prof["recipes"].items() if spell not in overlay["recipes"] and r["src"] != "auto"}


def coverage_rows(data: dict, spots: dict | None) -> tuple[dict[int, str], set[str]]:
    """Per profession the --check line (without its id and name), and the holes as text."""
    rows, holes = {}, set()
    for line, prof in data["professions"].items():
        lines, bad = G.check({"professions": {line: prof}}, spots)
        if not lines:
            continue
        text = re.sub(r"^\s*\d+\s+" + re.escape(prof["name"]) + r"\s*", "", lines[0]).strip()
        rows[line] = text
        if bad:
            holes.add(f"{prof['name']} ({line}): {text}")
    return rows, holes


# ---------------------------------------------------------------- the client snapshot (locks, nodes, flight points)


def client_snapshot(t: dict[str, list[dict]], build: str) -> dict:
    """What the client tables say that Data/Spots.lua is built on. Keys are text so the JSON round-trips."""
    locks = {}
    for r in t["Lock"]:
        reqs = sorted([int(r[f"_Index_{i}"]), int(float(r.get(f"Skill_{i}") or 0))] for i in range(8)
                      if r.get(f"Type_{i}") == "2" and int(r.get(f"_Index_{i}") or 0) in LOCK_SKILLS)
        if reqs:
            locks[str(int(r["ID"]))] = reqs
    taxi = {}
    for r in t["TaxiNodes"]:
        name = r.get("Name_lang") or ""
        # the rows tools/gen_spots.py keeps: on the Alliance or the Horde flight map, no condition
        if int(r.get("Flags") or 0) & 3 and r.get("ConditionID", "0") == "0" and not name.startswith(
                ("zzOLD", "Quest Path", "Transport", "Generic")):
            taxi[str(int(r["ID"]))] = name
    zones = {str(int(r["ID"])): r.get("Name_lang") or "" for r in t["UiMap"] if r.get("Type") == UIMAP_ZONE}
    return {"build": build, "locks": locks, "taxi": taxi, "zones": zones}


def render_snapshot(snap: dict) -> str:
    j = lambda v: json.dumps(v, ensure_ascii=False, separators=(", ", ": "))  # noqa: E731
    out = ["{", '  "about": "Written by tools/update_data.py from the WoW: Forever client tables. Do not edit. locks: '
           "lock id -> [[lock type, skill needed]] (1 Lockpicking, 2 Herbalism, 3 Mining); taxi: flight points; "
           'zones: zone maps.",', f'  "build": {j(snap["build"])},']
    for i, key in enumerate(("locks", "taxi", "zones")):
        rows = sorted(snap[key].items(), key=lambda kv: int(kv[0]))
        out.append(f'  "{key}": {{')
        out.append(",\n".join(f'    "{k}": {j(v)}' for k, v in rows))
        out.append("  }" + ("," if i < 2 else ""))
    out += ["}", ""]
    return "\n".join(out)


def lock_text(reqs) -> str:
    return ", ".join(f"{LOCK_SKILLS.get(t, f'lock type {t}')} {s}" for t, s in reqs)


def diff_snapshot(old: dict | None, new: dict) -> dict[str, list[str]]:
    out = {"locks": [], "taxi": [], "zones": []}
    if old is None:
        return out
    lo, ln = old.get("locks") or {}, new["locks"]
    for k in sorted(set(lo) | set(ln), key=int):
        a, b = lo.get(k), ln.get(k)
        if a is None:
            out["locks"].append(f"new lock {k}: needs {lock_text(b)}")
        elif b is None:
            out["locks"].append(f"lock {k} removed (needed {lock_text(a)})")
        elif [list(x) for x in a] != [list(x) for x in b]:
            out["locks"].append(f"lock {k}: {lock_text(a)} -> {lock_text(b)}")
    for key, what in (("taxi", "flight point"), ("zones", "zone map")):
        a, b = old.get(key) or {}, new[key]
        for k in sorted(set(a) | set(b), key=int):
            if k not in a:
                out[key].append(f"new {what} {k}: {b[k]}")
            elif k not in b:
                out[key].append(f"{what} {k} removed: {a[k]}")
            elif a[k] != b[k]:
                out[key].append(f"{what} {k}: {a[k]} -> {b[k]}")
    return out


# ---------------------------------------------------------------- the report


def section(title: str, lines: list[str], empty: str = "None.", cap: int = SECTION_CAP) -> list[str]:
    out = [f"### {title} ({len(lines)})", ""]
    if not lines:
        return out + [empty, ""]
    out += [f"- {x}" for x in lines[:cap]]
    if len(lines) > cap:
        out.append(f"- ... and {len(lines) - cap} more")
    return out + [""]


def render_report(r: dict) -> str:
    """r: the facts collected by run(). Sections that had no input (a broken run) are left out."""
    out = ["# SkillupHelper data update", ""]
    out.append(f"**Result: {r['result']}**")
    out.append("")
    out.append(f"- Build in the shipped data: {r.get('old_build') or 'none'}")
    out.append(f"- Newest `wowf` build on wago.tools: {r.get('new_build') or 'not known'}")
    if r.get("overlay"):
        out.append(f"- Overlay: {r['overlay']}")
    if r.get("dry"):
        out.append("- Dry run: nothing was written but this report.")
    out.append("")
    if r.get("broken"):
        out += ["## Broken", ""] + [f"- {x}" for x in r["broken"]] + [""]
    if r.get("new_holes"):
        out += ["## Coverage holes that appeared", ""] + [f"- {x}" for x in sorted(r["new_holes"])] + [""]
    if r.get("refreshed") or r.get("not_refreshed"):
        out += ["## What was refreshed", ""] + [f"- {x}" for x in r.get("refreshed", [])] + [""]
        out += ["## What was not refreshed", ""] + [f"- {x}" for x in r.get("not_refreshed", [])] + [""]
    d = r.get("recipes")
    if d is not None:
        out += ["## Recipes", ""]
        if d["professions"]:
            out += section("Skill lines", d["professions"])
        out += section("Added", d["added"])
        out += section("Removed", d["removed"])
        out += section("Renamed", d["renamed"])
        out += section("Threshold changes", d["thresholds"])
        out += section("Reagent changes", d["reagents"])
        out += section("Bonding changes", d["bonding"])
        out += section("Recipe items that appeared, went or changed", d["recipe_items"])
        out += section("Other recipe fields", d["other"])
        out += section("Profession ranks", d["ranks"])
        out += section("Vendor reagents", d["vendor"])
    if r.get("needs_source") is not None:
        out += ["## Needs a source", "",
                "Craft spells the overlay does not know: no learn rank, cost or source for them until a person reads "
                "them from Wowhead (docs/data-sources.md) or a player shares what their game learned.", ""]
        out += section("New in this update", r["needs_source"])
        out += [f"Craft spells without an overlay entry in all: {r.get('needs_source_total', 0)}.", ""]
    s = r.get("snapshot")
    if s is not None:
        out += ["## Locks, nodes and flight points (client tables)", ""]
        if r.get("snapshot_first"):
            out += [f"First snapshot: {r['snapshot_first']}. Nothing to compare with yet.", ""]
        else:
            out += section("Lock and node skill requirements", s["locks"])
            out += section("Flight points", s["taxi"])
            out += section("Zone maps", s["zones"])
    if r.get("coverage"):
        out += ["## Coverage 1-300", "", "| Profession | Before | After |", "| --- | --- | --- |"]
        out += [f"| {name} ({line}) | {before} | {after} |" for line, name, before, after in r["coverage"]]
        out.append("")
    if r.get("warnings"):
        out += section("Warnings", r["warnings"])
    return "\n".join(out).rstrip() + "\n"


# ---------------------------------------------------------------- the run


def read_text(path: Path) -> str | None:
    return path.read_text(encoding="utf-8") if path.is_file() else None


def write_text(path: Path, text: str) -> None:
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text, encoding="utf-8", newline="\n")
    os.replace(tmp, path)


def regenerate_spots(a, root: Path, folder: Path, build: str) -> tuple[dict[str, str], list[str], list[str]]:
    """With the cmangos dump: Data/Spots.lua, and with the NPC research files Data/Trainers.lua too. Returns
    ({relative path: new text}, what was refreshed, what was not)."""
    files, done, skipped = {}, [], []
    spots, trainers = root / "Data" / "Spots.lua", root / "Data" / "Trainers.lua"
    b_spots, b_tr = (shipped_build(read_text(f) or "") for f in (spots, trainers))
    if not a.cmangos:
        skipped.append(
            f"Data/Spots.lua (build {b_spots or 'none'}): left exactly as it is. Its positions come from the cmangos "
            "classic-db dump, which is not in the repository; rerun with `--cmangos FILE` to regenerate it. Lock and "
            "node requirements that changed in the client are listed below and wait for that run; no position was "
            "dropped.")
        skipped.append(
            f"Data/Trainers.lua (build {b_tr or 'none'}): left exactly as it is. It needs the cmangos dump and the "
            "NPC research export (`--cmangos FILE --npcs FILE --items FILE`).")
        return files, done, skipped
    try:
        import gen_spots as gs
    except ImportError as e:
        raise G.GenError(f"tools/gen_spots.py is missing: {e}") from e
    wago = folder / "spots"
    try:
        w = gs.load_wago(wago, build, not a.offline)
        builder = gs.Builder(w, gs.load_sql(Path(a.cmangos), False), gs.load_curated(gs.CURATED), build)
        files["Data/Spots.lua"] = builder.render()
        done.append(f"Data/Spots.lua: regenerated from build {build} and the cmangos dump (Classic positions).")
        if a.npcs and a.items:
            import gen_npcs as gn
            text, _ = gn.build(w, gs.load_sql(Path(a.cmangos), False, gn.SQL_TABLES),
                               gn.read_json(Path(a.npcs), "NPC list"), gn.read_json(Path(a.items), "recipe item list"),
                               gn.read_places(root / "Data" / "Npcs.lua"), build,
                               gn.read_seen(root / "tools" / "data" / "npcs_seen.json"))
            files["Data/Trainers.lua"] = text
            done.append(f"Data/Trainers.lua: regenerated from build {build}, the NPC research export and the dump.")
        else:
            skipped.append(f"Data/Trainers.lua (build {b_tr or 'none'}): left as it is; it also needs `--npcs FILE "
                           "--items FILE` (the NPC research export).")
    except gs.GenError as e:
        raise G.GenError(f"spots: {e}") from e
    return files, done, skipped


def run(argv: list[str] | None = None, get=G.http_get) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--report", help="write the change report here (markdown)")
    ap.add_argument("--dry-run", action="store_true", help="write nothing but the report")
    ap.add_argument("--build", help="a named wowf build instead of the newest")
    ap.add_argument("--cache", help="folder of <build>/<Table>.enUS.csv (default: tools/.cache)")
    ap.add_argument("--offline", action="store_true", help="never download: the cache only")
    ap.add_argument("--cmangos", help="the unpacked cmangos classic-db dump: also regenerate Data/Spots.lua")
    ap.add_argument("--npcs", help="with --cmangos: the NPC research export, to regenerate Data/Trainers.lua")
    ap.add_argument("--items", help="with --npcs: the recipe item research export")
    ap.add_argument("--root", help="the addon folder (default: the one this script is in)")
    a = ap.parse_args(argv)
    root = Path(a.root) if a.root else G.HERE.parent
    r: dict = {"dry": a.dry_run, "result": "", "broken": []}
    code = EXIT_BROKEN
    try:
        code = work(a, root, r, get)
    except G.GenError as e:
        r["broken"].append(str(e))
        r["result"] = "FAILED: an input broke"
        print(f"error: {e}", file=sys.stderr)
    text = render_report(r)
    if a.report:
        Path(a.report).write_text(text, encoding="utf-8", newline="\n")
    print(r["result"])
    for key in ("refreshed", "not_refreshed"):
        for line in r.get(key, []):
            print(f"  {key.replace('_', ' ')}: {line}")
    return code


def work(a, root: Path, r: dict, get) -> int:
    recipes_file = root / "Data" / "Recipes.lua"
    snap_file = root / "tools" / "data" / "client_snapshot.json"
    old_text = read_text(recipes_file)
    old = read_recipes(old_text) if old_text else from_lua(None)
    r["old_build"] = old["build"]
    cache = Path(a.cache) if a.cache else G.DEFAULT_CACHE
    folder, build = G.resolve(cache, a.build, not a.offline, get)
    r["new_build"] = build
    overlay = G.with_manual(G.load_overlay(root / "tools" / "data" / "overlay.json"),
                            G.load_overlay(root / "tools" / "data" / "overlay.manual.json"))
    src = overlay["source"]
    if src.get("name"):
        r["overlay"] = (f"{src['name']}, read {src.get('retrieved', 'date unknown')}, compared with build "
                        f"{src.get('compared_with_build', 'unknown')}")
    t = G.fetch_tables(folder, build, not a.offline, get, G.TABLES + SNAPSHOT_TABLES)
    data, warnings = G.build_data(t, build, overlay)
    if not data["professions"]:
        raise G.GenError(f"build {build}: no craft recipe found on any skill line")
    new_text = G.render(data)
    new = read_recipes(new_text)
    r["warnings"] = warnings
    files: dict[str, str] = {}
    refreshed, not_refreshed = [], []
    same = new_text == old_text
    refreshed.append(f"Data/Recipes.lua: regenerated from build {build}: "
                     + ("identical to the shipped file." if same else "changed."))
    if not same:
        files["Data/Recipes.lua"] = new_text
    r["recipes"] = diff_recipes(old, new)

    was = unknown_to_overlay(old, overlay)
    now = unknown_to_overlay(new, overlay)
    r["needs_source"] = [f"{prof}: {name} (spell {spell})" for spell, (prof, name) in sorted(now.items())
                         if spell not in was and old_text]
    r["needs_source_total"] = len(now)

    try:
        snap = client_snapshot(t, build)
    except (KeyError, ValueError) as e:
        raise G.GenError(f"client tables Lock / TaxiNodes / UiMap of build {build}: unexpected shape ({e!r})") from e
    snap_text = render_snapshot(snap)
    old_snap_text = read_text(snap_file)
    try:
        old_snap = json.loads(old_snap_text) if old_snap_text else None
    except ValueError as e:
        raise G.GenError(f"tools/data/client_snapshot.json: not JSON ({e})") from e
    r["snapshot"] = diff_snapshot(old_snap, snap)
    if old_snap is None:
        r["snapshot_first"] = (f"{len(snap['locks'])} locks with a skill requirement, {len(snap['taxi'])} flight "
                               f"points, {len(snap['zones'])} zone maps")
    if snap_text != old_snap_text:
        files["tools/data/client_snapshot.json"] = snap_text
    refreshed.append("tools/data/client_snapshot.json: lock and node requirements, flight points and zone maps of "
                     f"build {build}: " + ("changed." if snap_text != old_snap_text else "identical."))

    more, done, skipped = regenerate_spots(a, root, folder, build)
    for rel, text in more.items():
        if text != read_text(root / rel):
            files[rel] = text
    refreshed += done
    not_refreshed += skipped
    not_refreshed.append("tools/data/overlay.json: read by a person from Wowhead's Forever section "
                         "(docs/data-sources.md); never fetched by a script.")
    r["refreshed"], r["not_refreshed"] = refreshed, not_refreshed

    spots_before = read_text(root / "Data" / "Spots.lua")
    spots_after = files.get("Data/Spots.lua", spots_before)
    req = lambda text: G.spot_requirements(text) if text else None  # noqa: E731
    before, holes_before = coverage_rows(old, req(spots_before))
    after, holes_after = coverage_rows(data, req(spots_after))
    r["coverage"] = [(line, (data["professions"].get(line) or old["professions"][line])["name"],
                      before.get(line, "not in the data"), after.get(line, "not in the data"))
                     for line in sorted(set(before) | set(after))]
    new_holes = holes_after - holes_before
    if new_holes:
        r["new_holes"] = new_holes
        r["result"] = "FAILED: a coverage hole appeared; nothing was written"
        for h in sorted(new_holes):
            print(f"error: coverage hole: {h}", file=sys.stderr)
        return EXIT_BROKEN
    if not files:
        r["result"] = "No change"
        return EXIT_SAME
    names = ", ".join(sorted(files))
    if a.dry_run:
        r["result"] = f"Data changed (dry run, would write {names})"
    else:
        for rel, text in files.items():
            target = root / rel
            if not target.parent.is_dir():
                raise G.GenError(f"folder {target.parent.name} is missing in the addon folder")
            write_text(target, text)
        r["result"] = f"Data changed (wrote {names})"
    return EXIT_CHANGED


if __name__ == "__main__":
    sys.exit(run())
