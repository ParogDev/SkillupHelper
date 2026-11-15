#!/usr/bin/env python3
"""Write Data/Spots.lua: where to level the skills you level out in the world.

    python tools/gen_spots.py --wago DIR --cmangos FILE --out Data/Spots.lua
    python tools/gen_spots.py --wago DIR --cmangos FILE --out Data/Spots.lua --download --build 1.60.1.70888

Python 3 standard library only. Lockpicking (633), Mining (186), Herbalism (182), Skinning (393), Fishing (356).

Two sources, joined here (docs/spots-data.md has the long version):

  --wago DIR      wago.tools DB2 CSV exports of the WoW: Forever client (product wowf), one <Table>.csv per table:
                  the tables in WAGO_TABLES below. They give what a lock needs (Lock), the lockbox items (ItemSparse),
                  the zone maps (UiMap, UiMapAssignment, WorldMapOverlay), flight points (TaxiNodes), instance names and
                  entrances (Map), who is hostile (FactionTemplate) and area names (AreaTable).
  --cmangos FILE  the cmangos classic-db full dump (Classic 1.12, GPL-3.0), unpacked .sql: which object carries which
                  lock, and every spawn position. Positions are Classic's: unconfirmed for Forever.

--download fetches whatever is missing into those two paths; without it a missing input is an error that names it.
tools/data/spots_curated.json holds what no data source has: area names, route notes, quest starters, manual spots.

Exit code 2 = a broken link, named on stderr.
"""
from __future__ import annotations

import argparse
import collections
import csv
import gzip
import json
import math
import re
import sys
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
CURATED = HERE / "data" / "spots_curated.json"
WAGO_URL = "https://wago.tools/db2/{table}/csv?build={build}"
CMANGOS_URL = "https://raw.githubusercontent.com/cmangos/classic-db/master/Full_DB/ClassicDB_1_12_1_z2815.sql.gz"
USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"
WAGO_TABLES = (
    "Lock", "ItemSparse", "AreaTable", "UiMap", "UiMapAssignment", "UiMapXMapArt", "UiMapArt", "UiMapArtStyleLayer",
    "WorldMapOverlay", "AreaPOI", "TaxiNodes", "Map", "FactionTemplate", "SkillLine",
)
SQL_TABLES = (
    "gameobject", "gameobject_template", "creature", "creature_template", "skill_fishing_base_level",
    "pool_gameobject", "pool_pool", "pool_template",
)
CLASSIC_SOURCE = "cmangos classic-db z2815 (GPL-3.0), Classic 1.12 positions: unconfirmed for Forever"

# ---------------------------------------------------------------- assumptions, each one named
# Skill-up colour bands above the requirement. NOT found in any source: the vanilla community rule. The addon labels
# it (bandsConfirmed = false) and replaces it with what it observes.
BANDS = {"yellow": 25, "green": 50, "grey": 100}
BANDS_CONFIRMED = False
# Lockpicking: skill cap per character level and the level it is learned at (Forever guide; the skill line is 633).
LOCKPICK_CAP_PER_LEVEL = 5
LOCKPICK_LEARN_LEVEL = 16
# Skinning skill needed by mob level (Forever guide, unconfirmed): need = level * mul + add, first tier that fits.
SKIN_TIERS = ({"to": 10, "mul": 0, "add": 1}, {"to": 19, "mul": 10, "add": -100}, {"to": 999, "mul": 5, "add": 0})
SKIN_FORMULA = "mob level 1-10: 1; 11-19: (level - 10) x 10; 20 and up: level x 5"

LOCK_PICK, LOCK_HERB, LOCK_MINE = 1, 2, 3  # LockType ids (Lock._Index_n when Type_n = 2)
# gameobject_template.type -> which dataN holds the lock id (cmangos GameObjectTemplate union).
LOCK_FIELD = {0: 1, 1: 1, 2: 0, 3: 0, 6: 0, 10: 0}
GO_TYPE_NAME = {0: "door", 1: "button", 3: "chest"}
CHEST_QUEST_FIELD = 8  # type 3: data8 = quest id the chest belongs to

CONTINENTS = (0, 1)  # Eastern Kingdoms, Kalimdor: the only maps with outdoor spots
CLASSIC_UIMAP_MAX = 1464  # zone maps above this id are new in Forever: never the home of a Classic position
MOB_RADIUS = 45.0  # yards around any point of a spot
MOB_LIST = 4
# creature_template.CreatureType left out of the mob list: critter, totem, non-combat pet, gas cloud.
NOT_A_MOB_TYPES = {8, 11, 12, 13}
UNIT_FLAG_NON_ATTACKABLE, UNIT_FLAG_NOT_SELECTABLE = 0x2, 0x2000000
SKINNABLE_TYPES = {1: "beast", 2: "dragonkin"}

# Clustering (world yards). eps = how far apart two spawns may be and still be one farming area.
LOCK_EPS, LOCK_TIGHT, LOCK_REACH = 150.0, 60.0, 3.0  # see link_cluster
LOCK_LOOSE, LOCK_LOOSE_MERGE = 2, 3  # 3 or more groups of at most 2 boxes, same zone and kind: one scattered spot
NODE_EPS, NODE_CORE, NODE_MIN, NODE_TOP = 130.0, 3, 10, 4
SKIN_EPS, SKIN_CORE, SKIN_MIN, SKIN_TOP = 120.0, 3, 8, 4
LOOP_CAP = 40  # points in a gathering or skinning loop; lock spots keep every position
SPLIT_SPAN = 1000.0  # a gathering area wider than this is split with a smaller eps
MIN_EPS = 45.0
INSTANCE_MIN = 5  # gathering nodes in one instance worth a line
GETS_CAP = 8

SKILLS = (633, 186, 182, 393, 356)


class GenError(Exception):
    pass


# ---------------------------------------------------------------- inputs
def http_get(url: str, timeout: int = 180) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=timeout) as r:  # noqa: S310 (fixed https hosts)
        return r.read()


def read_build(wago: Path, build: str | None) -> str:
    if build:
        return build
    note = wago / "build.txt"
    if note.is_file():
        return note.read_text(encoding="utf-8").strip()
    raise GenError(f"client build unknown: pass --build <wowf build of the CSVs>, or put it in {wago / 'build.txt'}")


def load_wago(wago: Path, build: str, download: bool) -> dict[str, list[dict]]:
    out = {}
    for table in WAGO_TABLES:
        f = wago / f"{table}.csv"
        if not f.is_file() or f.stat().st_size == 0:
            if not download:
                raise GenError(f"client table missing: {f} (rerun with --download, or fetch {WAGO_URL.format(table=table, build=build)})")
            wago.mkdir(parents=True, exist_ok=True)
            data = http_get(WAGO_URL.format(table=table, build=build))
            if not data.strip():
                raise GenError(f"wago.tools returned an empty {table} for build {build}")
            f.write_bytes(data)
            (wago / "build.txt").write_text(build + "\n", encoding="utf-8")
        with open(f, encoding="utf-8", newline="") as fh:
            out[table] = list(csv.DictReader(fh))
        if not out[table]:
            raise GenError(f"client table empty: {f}")
    return out


def sql_tuples(line: str) -> list[list[str]]:
    """The rows of one MySQL extended INSERT: "(a,'b'),(c,d);"."""
    out, i, n = [], 0, len(line)
    while i < n:
        if line[i] != "(":
            i += 1
            continue
        i += 1
        row, cur, quoted = [], [], False
        while True:
            c = line[i]
            if quoted:
                if c == "\\":
                    cur.append(line[i + 1])
                    i += 2
                    continue
                if c == "'":
                    quoted = False
                else:
                    cur.append(c)
            elif c == "'":
                quoted = True
            elif c == ",":
                row.append("".join(cur))
                cur = []
            elif c == ")":
                row.append("".join(cur))
                i += 1
                break
            else:
                cur.append(c)
            i += 1
        out.append(row)
    return out


def load_sql(path: Path, download: bool, tables: tuple = None) -> dict[str, list[dict]]:
    """The wanted tables as lists of {column: text}; column names come from the dump's own CREATE TABLE."""
    tables = tables or SQL_TABLES
    if not path.is_file():
        if not download:
            raise GenError(f"cmangos dump missing: {path} (rerun with --download, or unpack {CMANGOS_URL})")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(gzip.decompress(http_get(CMANGOS_URL, 600)))
    cols: dict[str, list[str]] = {}
    rows: dict[str, list[dict]] = {t: [] for t in tables}
    creating = None
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if creating:
                m = re.match(r"\s*`(\w+)` ", line)
                if m:
                    cols[creating].append(m.group(1))
                elif line.startswith(")"):
                    creating = None
                continue
            m = re.match(r"CREATE TABLE `(\w+)`", line)
            if m and m.group(1) in rows:
                creating = m.group(1)
                cols[creating] = []
                continue
            m = re.match(r"INSERT INTO `(\w+)` VALUES ", line)
            if m and m.group(1) in rows:
                names = cols.get(m.group(1))
                if not names:
                    raise GenError(f"{path}: INSERT into {m.group(1)} before its CREATE TABLE")
                rows[m.group(1)].extend(dict(zip(names, t)) for t in sql_tuples(line[m.end():]))
    for t in tables:
        if not rows[t] and not t.startswith("pool_"):
            raise GenError(f"{path}: no rows for table {t} (is this the cmangos classic-db full dump?)")
    return rows


def load_curated(path: Path) -> dict:
    if not path.is_file():
        raise GenError(f"curated file missing: {path}")
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except ValueError as e:
        raise GenError(f"{path}: not JSON ({e})") from e


# ---------------------------------------------------------------- zone maps
class Zones:
    """World position -> zone map and map percent.

    UiMapAssignment gives each zone map one world rectangle (Region_0/3 = world X min/max, Region_1/4 = world Y
    min/max); map percent is x = (maxY - Y) / (maxY - minY), y = (maxX - X) / (maxX - minX). The rectangles of
    neighbours overlap, so a point near a border sits in two or three. The tie is broken with WorldMapOverlay: the
    explored-area pieces of each zone's map art, which cover the land that really belongs to the zone. A zone with
    a piece around the point beats one without; among those, the zone where the point sits deeper inside a piece
    (in halves of the way from the middle to the edge); still tied, the zone owning the nearest AreaPOI label.
    When no piece holds the point the zone with the nearest piece wins; with no overlay data at all the smallest
    rectangle wins. City maps and the maps new in Forever are a last resort.
    Measured on the 170 AreaPOI labels inside a zone rectangle (each left out of its own test): 163 right, against
    120 for "smallest rectangle" and 148 for "most central rectangle".
    """

    def __init__(self, w: dict[str, list[dict]]):
        uimap = {int(r["ID"]): r for r in w["UiMap"]}
        layer = {int(r["UiMapArtStyleID"]): (float(r["LayerWidth"]), float(r["LayerHeight"]))
                 for r in w["UiMapArtStyleLayer"] if r["LayerIndex"] == "0"}
        art_style = {int(r["ID"]): int(r["UiMapArtStyleID"]) for r in w["UiMapArt"]}
        art_of = collections.defaultdict(list)
        for r in w["UiMapXMapArt"]:
            art_of[int(r["UiMapID"])].append(int(r["UiMapArtID"]))
        pieces = collections.defaultdict(list)
        for r in w["WorldMapOverlay"]:
            dim = layer.get(art_style.get(int(r["UiMapArtID"]), -1))
            tw, th = float(r["TextureWidth"]), float(r["TextureHeight"])
            if not dim or tw <= 0 or th <= 0:
                continue
            x0, y0 = float(r["OffsetX"]) / dim[0] * 100, float(r["OffsetY"]) / dim[1] * 100
            pieces[int(r["UiMapArtID"])].append((x0, y0, x0 + tw / dim[0] * 100, y0 + th / dim[1] * 100))
        self.zones = []
        self.by_id = {}
        for r in w["UiMapAssignment"]:
            u = uimap.get(int(r["UiMapID"]))
            if not u or u["Type"] != "3":  # 3 = zone; continents, dungeons, micro maps are not outdoor zone maps
                continue
            if (float(r["UiMin_0"]), float(r["UiMin_1"]), float(r["UiMax_0"]), float(r["UiMax_1"])) != (0, 0, 1, 1):
                continue  # a partial assignment (a corner of another map), never the zone's own rectangle
            z = {
                "id": int(r["UiMapID"]), "name": u["Name_lang"], "cont": int(r["MapID"]), "area": int(r["AreaID"]),
                "x0": float(r["Region_0"]), "x1": float(r["Region_3"]),
                "y0": float(r["Region_1"]), "y1": float(r["Region_4"]),
                "city": int(u["Flags"]) & 2 == 0, "new": int(r["UiMapID"]) > CLASSIC_UIMAP_MAX,
                "pieces": [p for a in art_of.get(int(r["UiMapID"]), []) for p in pieces.get(a, [])],
            }
            z["w"], z["h"] = z["y1"] - z["y0"], z["x1"] - z["x0"]  # yards across (map x) and down (map y)
            self.zones.append(z)
            self.by_id.setdefault(z["id"], z)
        if not self.zones:
            raise GenError("UiMapAssignment/UiMap: no zone-type map with a world rectangle")
        # anchors: AreaPOI rows (town and landmark labels) carry a position and an area, so each is a point whose
        # zone is known. They settle the ties the pieces leave.
        self.area = {int(r["ID"]): r for r in w["AreaTable"]}
        self.by_area = {z["area"]: z for z in self.zones if z["area"]}
        self.anchors = collections.defaultdict(list)
        for r in w["AreaPOI"]:
            z = self.zone_of_area(int(r["AreaID"]))
            if z and z["cont"] == int(r["ContinentID"]):
                self.anchors[(z["cont"], z["id"])].append((float(r["Pos_0"]), float(r["Pos_1"])))

    def zone_of_area(self, area_id: int) -> dict | None:
        """The zone map of an AreaTable id: its own, or its parent area's."""
        for _ in range(6):
            if area_id in self.by_area:
                return self.by_area[area_id]
            a = self.area.get(area_id)
            if not a or not int(a["ParentAreaID"]):
                return None
            area_id = int(a["ParentAreaID"])
        return None

    @staticmethod
    def percent(z: dict, x: float, y: float) -> tuple[float, float]:
        return (z["y1"] - y) / z["w"] * 100, (z["x1"] - x) / z["h"] * 100

    def _anchor(self, z: dict, cont: int, x: float, y: float) -> float:
        best = 1e9
        for ax, ay in self.anchors.get((cont, z["id"]), ()):
            d = (ax - x) ** 2 + (ay - y) ** 2
            if d < best:
                best = d
        return best

    def _score(self, z: dict, cont: int, x: float, y: float):
        mx, my = self.percent(z, x, y)
        if not z["pieces"]:
            return (2, z["w"] * z["h"], 0)
        depth = None  # 0 = at the middle of a piece, 1 = on its edge
        for p in z["pieces"]:
            if p[0] <= mx <= p[2] and p[1] <= my <= p[3]:
                d = max(abs(mx - (p[0] + p[2]) / 2) / ((p[2] - p[0]) / 2), abs(my - (p[1] + p[3]) / 2) / ((p[3] - p[1]) / 2))
                depth = d if depth is None else min(depth, d)
        if depth is not None:
            return (0, round(depth * 2) / 2, self._anchor(z, cont, x, y))
        best = min(math.hypot(max(p[0] - mx, 0, mx - p[2]) / 100 * z["w"], max(p[1] - my, 0, my - p[3]) / 100 * z["h"])
                   for p in z["pieces"])
        return (1, best, 0)

    def candidates(self, cont: int, x: float, y: float) -> list[dict]:
        return [z for z in self.zones if z["cont"] == cont and z["x0"] <= x <= z["x1"] and z["y0"] <= y <= z["y1"]]

    def find(self, cont: int, x: float, y: float) -> dict | None:
        hit = self.candidates(cont, x, y)
        for group in ([z for z in hit if not z["city"] and not z["new"]], [z for z in hit if z["city"]], hit):
            if len(group) == 1:
                return group[0]
            if group:
                return min(group, key=lambda z: (self._score(z, cont, x, y), z["w"] * z["h"], z["id"]))
        return None


# ---------------------------------------------------------------- geometry
def cluster(points: list[tuple], eps: float, core: int) -> list[list[int]]:
    """DBSCAN over (x, y, ...) tuples; returns lists of point indexes, noise dropped (core = 1: single linkage)."""
    grid = collections.defaultdict(list)
    for i, p in enumerate(points):
        grid[(int(p[0] // eps), int(p[1] // eps))].append(i)

    def near(i):
        p = points[i]
        cx, cy = int(p[0] // eps), int(p[1] // eps)
        return [j for dx in (-1, 0, 1) for dy in (-1, 0, 1) for j in grid.get((cx + dx, cy + dy), ())
                if (points[j][0] - p[0]) ** 2 + (points[j][1] - p[1]) ** 2 <= eps * eps]

    label = [None] * len(points)
    out = []
    for i in range(len(points)):
        if label[i] is not None:
            continue
        nb = near(i)
        if len(nb) < core:
            continue
        cid = len(out)
        members = []
        queue = [i]
        label[i] = cid
        while queue:
            j = queue.pop()
            members.append(j)
            nbj = near(j)
            if len(nbj) < core:
                continue
            for k in nbj:
                if label[k] is None:
                    label[k] = cid
                    queue.append(k)
        out.append(sorted(members))
    return out


def link_cluster(points: list[tuple], eps: float, tight: float, factor: float) -> list[list[int]]:
    """Single linkage where a tight group does not reach out: two points join when they are within eps and within
    max(tight, factor x the smaller of their nearest-neighbour distances). Boxes packed in one building (a few
    yards apart) stay their own spot next to a loose field of boxes 130 yards off; loose fields still join up."""
    n = len(points)
    nn = [min((math.dist(points[i][:2], points[j][:2]) for j in range(n) if j != i), default=eps) for i in range(n)]
    parent = list(range(n))

    def root(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    for i in range(n):
        for j in range(i + 1, n):
            d = math.dist(points[i][:2], points[j][:2])
            if d <= eps and d <= max(tight, factor * min(nn[i], nn[j])):
                parent[root(j)] = root(i)
    groups = collections.defaultdict(list)
    for i in range(n):
        groups[root(i)].append(i)
    return [groups[k] for k in sorted(groups)]


def span(points: list[tuple]) -> float:
    xs, ys = [p[0] for p in points], [p[1] for p in points]
    return math.hypot(max(xs) - min(xs), max(ys) - min(ys))


def split_areas(points: list[tuple], eps: float, core: int) -> list[list[tuple]]:
    """Farming areas: clusters, with one too wide or too long for a loop split again at a smaller eps."""
    out = []
    for members in cluster(points, eps, core):
        pts = [points[i] for i in members]
        if (len(pts) > LOOP_CAP or span(pts) > SPLIT_SPAN) and eps * 0.8 >= MIN_EPS:
            out.extend(split_areas(pts, eps * 0.8, core))
        else:
            out.append(pts)
    return out


def thin(points: list[tuple], cap: int) -> list[tuple]:
    """At most `cap` points, spread out: farthest-point sampling from the point nearest the centre."""
    if len(points) <= cap:
        return list(points)
    cx = sum(p[0] for p in points) / len(points)
    cy = sum(p[1] for p in points) / len(points)
    first = min(range(len(points)), key=lambda i: ((points[i][0] - cx) ** 2 + (points[i][1] - cy) ** 2, i))
    chosen = [first]
    dist = [(p[0] - points[first][0]) ** 2 + (p[1] - points[first][1]) ** 2 for p in points]
    while len(chosen) < cap:
        nxt = max(range(len(points)), key=lambda i: (dist[i], -i))
        chosen.append(nxt)
        for i, p in enumerate(points):
            d = (p[0] - points[nxt][0]) ** 2 + (p[1] - points[nxt][1]) ** 2
            if d < dist[i]:
                dist[i] = d
    return [points[i] for i in sorted(chosen)]


def tour_length(points: list[tuple], order: list[int]) -> float:
    n = len(order)
    if n < 2:
        return 0.0
    return sum(math.dist(points[order[i]][:2], points[order[(i + 1) % n]][:2]) for i in range(n))


def nearest_neighbour(points: list[tuple]) -> list[int]:
    left = set(range(1, len(points)))
    order = [0]
    while left:
        last = points[order[-1]]
        nxt = min(left, key=lambda j: ((points[j][0] - last[0]) ** 2 + (points[j][1] - last[1]) ** 2, j))
        left.remove(nxt)
        order.append(nxt)
    return order


def improve(points: list[tuple], order: list[int]) -> list[int]:
    """2-opt, then or-opt (move a run of 1-3 points elsewhere, either way round), until neither shortens the loop."""
    n = len(order)
    if n < 4:
        return order

    def d(a, b):
        return math.dist(points[a][:2], points[b][:2])

    order = list(order)
    improved = True
    while improved:
        improved = False
        for i in range(n - 1):
            for j in range(i + 2, n):
                if i == 0 and j == n - 1:
                    continue
                a, b, c, e = order[i], order[i + 1], order[j], order[(j + 1) % n]
                if d(a, b) + d(c, e) - d(a, c) - d(b, e) > 1e-7:
                    order[i + 1:j + 1] = reversed(order[i + 1:j + 1])
                    improved = True
        for seg in (1, 2, 3):
            if n < seg + 3:
                continue
            i = 0
            while i < n:
                run = [order[(i + k) % n] for k in range(seg)]
                rest = [order[(i + seg + k) % n] for k in range(n - seg)]  # starts after the run, ends before it
                gain_cut = d(rest[-1], run[0]) + d(run[-1], rest[0]) - d(rest[-1], rest[0])
                best = None
                for k in range(len(rest) - 1):
                    p, q = rest[k], rest[k + 1]
                    base = d(p, q)
                    for rev in (False, True):
                        s, t = (run[-1], run[0]) if rev else (run[0], run[-1])
                        gain = gain_cut - (d(p, s) + d(t, q) - base)
                        if gain > 1e-7 and (best is None or gain > best[0]):
                            best = (gain, k, rev)
                if best:
                    _, k, rev = best
                    order = rest[:k + 1] + (run[::-1] if rev else run) + rest[k + 1:]
                    improved = True
                i += 1
    return order


def make_tour(points: list[tuple]) -> tuple[list[int], float, float]:
    """A short closed tour: (order, length in yards, the nearest-neighbour seed's length)."""
    seed = nearest_neighbour(points)
    best = improve(points, seed)
    return best, tour_length(points, best), tour_length(points, seed)


# ---------------------------------------------------------------- helpers
def slug(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", text.lower().replace("'", "")).strip("-")


def skin_need(level: int) -> int:
    for t in SKIN_TIERS:
        if level <= t["to"]:
            return max(1, level * t["mul"] + t["add"])
    return level * 5


def lua_str(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def num(v: float, digits: int = 1) -> str:
    s = f"{v:.{digits}f}"
    if "." in s:
        s = s.rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


def lua(v) -> str:
    """A compact Lua literal: dict -> record (keys in insertion order), list -> array, None dropped from records."""
    if v is None:
        return "nil"
    if v is True or v is False:
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        return num(v, 2)
    if isinstance(v, str):
        return lua_str(v)
    if isinstance(v, (list, tuple)):
        return "{ " + ", ".join(lua(x) for x in v) + " }" if v else "{}"
    if isinstance(v, dict):
        parts = []
        for k, x in v.items():
            if x is None:
                continue
            key = k if isinstance(k, str) and re.fullmatch(r"[A-Za-z_]\w*", k) else "[" + lua(k) + "]"
            parts.append(f"{key} = {lua(x)}")
        return "{ " + ", ".join(parts) + " }" if parts else "{}"
    raise TypeError(type(v))


# ---------------------------------------------------------------- the build
class Builder:
    def __init__(self, w: dict, sql: dict, curated: dict, build: str):
        self.w, self.sql, self.curated, self.build = w, sql, curated, build
        self.zones = Zones(w)
        self.stats = collections.OrderedDict()
        self.warnings: list[str] = []
        self.used_maps: set[int] = set()
        self.used_curated: set[str] = set()
        self.ids: set[str] = set()

        self.locks = collections.defaultdict(list)  # lock id -> [(lock type, skill)]
        for r in w["Lock"]:
            for i in range(8):
                if r[f"Type_{i}"] == "2":
                    self.locks[int(r["ID"])].append((int(r[f"_Index_{i}"]), int(r[f"Skill_{i}"])))

        self.templates = {int(t["entry"]): t for t in sql["gameobject_template"]}
        self.creatures = {int(t["Entry"]): t for t in sql["creature_template"]}
        self.instances = {int(r["ID"]): r for r in w["Map"]}
        self.factions = {int(r["ID"]): (int(r["FriendGroup"]), int(r["EnemyGroup"])) for r in w["FactionTemplate"]}

        self.go_spawns = collections.defaultdict(list)  # entry -> [(guid, map, x, y, z)]
        for g in sql["gameobject"]:
            self.go_spawns[int(g["id"])].append(
                (int(g["guid"]), int(g["map"]), float(g["position_x"]), float(g["position_y"]), float(g["position_z"])))

        # pools: a spawn row's pool, its mother pools, and how many of each pool may be up at once
        self.pool_of = {int(r["guid"]): int(r["pool_entry"]) for r in sql["pool_gameobject"]}
        self.mother = {int(r["pool_id"]): int(r["mother_pool"]) for r in sql["pool_pool"]}
        self.pool_limit = {int(r["entry"]): int(r["max_limit"]) for r in sql["pool_template"]}

        self.mob_grid = collections.defaultdict(list)  # (map, cell) -> [(x, y, entry)]
        self.cre_spawns = collections.defaultdict(list)
        for c in sql["creature"]:
            e, mp, x, y = int(c["id"]), int(c["map"]), float(c["position_x"]), float(c["position_y"])
            self.cre_spawns[e].append((mp, x, y, float(c["position_z"])))
            if self.is_mob(e):
                self.mob_grid[(mp, int(x // MOB_RADIUS), int(y // MOB_RADIUS))].append((x, y, e))

        self.taxi = []
        for r in w["TaxiNodes"]:
            flags, name = int(r["Flags"]), r["Name_lang"]
            # Flags bit 1 = shown on the Alliance flight map, bit 2 = on the Horde one. Nodes with neither bit are
            # transports, quest paths and world targets (and a few Forever nodes this rule cannot place): left out.
            sides = ("A" if flags & 1 else "") + ("H" if flags & 2 else "")
            if not sides or name.startswith(("zzOLD", "Quest Path", "Transport", "Generic")) or r["ConditionID"] != "0":
                continue
            self.taxi.append((int(r["ContinentID"]), float(r["Pos_0"]), float(r["Pos_1"]), name, sides, int(r["ID"])))

    # ---- creatures
    def is_mob(self, entry: int) -> bool:
        """Something that can fight any player: see docs/spots-data.md, "Mob levels"."""
        t = self.creatures.get(entry)
        if not t:
            return False
        if int(t["CreatureType"]) in NOT_A_MOB_TYPES or int(t["NpcFlags"]) != 0:
            return False
        if int(t["UnitFlags"]) & (UNIT_FLAG_NON_ATTACKABLE | UNIT_FLAG_NOT_SELECTABLE):
            return False
        friend, _enemy = self.factions.get(int(t["Faction"]), (0, 0))
        return friend & 7 == 0  # friendly to players (1), Alliance (2) or Horde (4): a guard or townsman, not a mob

    def mobs_near(self, mp: int, points: list[tuple]) -> dict | None:
        seen = collections.Counter()
        done = set()
        r2 = MOB_RADIUS * MOB_RADIUS
        for p in points:
            cx, cy = int(p[0] // MOB_RADIUS), int(p[1] // MOB_RADIUS)
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    for x, y, e in self.mob_grid.get((mp, cx + dx, cy + dy), ()):
                        if (x, y, e) not in done and (x - p[0]) ** 2 + (y - p[1]) ** 2 <= r2:
                            done.add((x, y, e))
                            seen[e] += 1
        if not seen:
            return None
        lv = [int(self.creatures[e][k]) for e in seen for k in ("MinLevel", "MaxLevel")]
        top = sorted(seen.items(), key=lambda kv: (-kv[1], kv[0]))[:MOB_LIST]
        return {"min": min(lv), "max": max(lv),
                "list": [[e, self.creatures[e]["Name"], int(self.creatures[e]["MinLevel"]), int(self.creatures[e]["MaxLevel"])]
                         for e, _ in top]}

    # ---- places
    def place(self, cont: int, x: float, y: float) -> tuple[dict, float, float] | None:
        z = self.zones.find(cont, x, y)
        if not z:
            return None
        mx, my = self.zones.percent(z, x, y)
        return z, mx, my

    def flight_points(self, cont: int, x: float, y: float) -> dict | None:
        out = {}
        for side in ("A", "H"):
            best = None
            for c, tx, ty, name, sides, tid in self.taxi:
                if c != cont or side not in sides:
                    continue  # never across continents
                d = math.hypot(tx - x, ty - y)
                if best is None or (d, tid) < best[:2]:
                    best = (d, tid, tx, ty, name)
            if not best:
                continue
            placed = self.place(cont, best[2], best[3])
            if not placed:
                continue
            z, mx, my = placed
            self.used_maps.add(z["id"])
            out[side] = {"name": best[4].split(",")[0], "node": best[1], "map": z["id"], "x": round(mx, 1), "y": round(my, 1),
                         "yd": int(round(best[0])), "_xy": (best[2], best[3])}
        return out or None

    def new_id(self, kind: str, zone: str, mx: float, my: float) -> str:
        base = f"{kind}:{slug(zone)}:{int(mx):02d}-{int(my):02d}"
        sid, n = base, 1
        while sid in self.ids:
            n += 1
            sid = base + chr(ord("a") + n - 1)
        self.ids.add(sid)
        return sid

    def apply_curated(self, spot: dict) -> None:
        over = self.curated.get("spots", {}).get(spot["id"])
        if not over:
            return
        self.used_curated.add(spot["id"])
        for k in ("area", "note", "indoor"):
            if k in over:
                spot[k] = over[k]

    def pools_up(self, sites: list[dict], all_roots: collections.Counter) -> int | None:
        """About how many of these positions hold an object at one time, from the dump's pool tables."""
        mine = collections.Counter(s["root"] for s in sites)
        if set(mine) == {None}:
            return None  # nothing here is pooled in the dump: nothing to say
        up = 0.0
        for root, m in mine.items():
            if root is None:
                up += m
            else:
                up += min(m, self.pool_limit.get(root, 1) * m / all_roots[root])
        return max(1, int(round(up)))

    def root_pool(self, guid: int) -> int | None:
        p = self.pool_of.get(guid)
        seen = set()
        while p is not None and p in self.mother and p not in seen:
            seen.add(p)
            p = self.mother[p]
        return p

    # ---- sites: one per position, whatever can spawn there
    def sites_for(self, entry_target: dict[int, str]) -> tuple[list[dict], collections.Counter]:
        sites = {}
        for entry, key in entry_target.items():
            for guid, mp, x, y, z in self.go_spawns.get(entry, ()):
                s = sites.setdefault((mp, round(x), round(y), round(z)), {"map": mp, "x": x, "y": y, "z": z, "t": collections.Counter(), "root": None})
                s["t"][key] += 1
                if s["root"] is None:
                    s["root"] = self.root_pool(guid)
        out = [sites[k] for k in sorted(sites)]
        return out, collections.Counter(s["root"] for s in out)

    def build_spot(self, kind: str, cont: int, sites: list[dict], targets: dict, all_roots, keep_all: bool,
                   with_z: bool) -> dict | None:
        """One outdoor spot from its sites (dicts with x, y, z, t = Counter of target keys)."""
        cx = sum(s["x"] for s in sites) / len(sites)
        cy = sum(s["y"] for s in sites) / len(sites)
        votes = collections.Counter()
        for s in sites:
            z = self.zones.find(cont, s["x"], s["y"])
            if z:
                votes[z["id"]] += 1
        if not votes:
            return None
        zid = sorted(votes.items(), key=lambda kv: (-kv[1], kv[0]))[0][0]
        # a hand-kept correction for a border the map data gets wrong: target key -> uiMap
        for s in sites:
            for k in s["t"]:
                fix = self.curated.get("zoneOf", {}).get(k)
                if fix:
                    if fix not in self.zones.by_id:
                        raise GenError(f"spots_curated.json zoneOf[{k!r}]: {fix} is not a zone map")
                    zid = fix
        zone = self.zones.by_id[zid]
        mx, my = self.zones.percent(zone, cx, cy)
        if not (0 <= mx <= 100 and 0 <= my <= 100):
            return None
        self.used_maps.add(zid)

        count = collections.Counter()
        for s in sites:
            for k in s["t"]:
                count[k] += 1
        gets_keys = sorted(count, key=lambda k: (-count[k], targets[k]["req"], k))[:GETS_CAP]
        index = {k: i + 1 for i, k in enumerate(gets_keys)}
        reqs = [targets[k]["req"] for k in count]

        def site_key(s):  # the target a pin stands for: the lowest requirement that can spawn there
            return min(s["t"], key=lambda k: (targets[k]["req"], k))

        loop = sites if keep_all else thin([(s["x"], s["y"], s) for s in sites], LOOP_CAP)
        loop = [p[2] if isinstance(p, tuple) else p for p in loop]
        pts = [(s["x"], s["y"]) for s in loop]
        fp = self.flight_points(cont, cx, cy)
        order, loop_yd, nn_yd = make_tour(pts)
        starts = {}
        if fp:
            for side, f in fp.items():
                fx, fy = f.pop("_xy")
                starts[side] = min(range(len(order)), key=lambda i: ((pts[order[i]][0] - fx) ** 2 + (pts[order[i]][1] - fy) ** 2, i))
            first = starts.get("A", starts.get("H", 0))
            order = order[first:] + order[:first]
            starts = {side: (i - first) % len(order) + 1 for side, i in starts.items()}
        flat = []
        for i in order:
            px, py = self.zones.percent(zone, pts[i][0], pts[i][1])
            flat += [round(min(100, max(0, px)), 2), round(min(100, max(0, py)), 2)]
        radius = max(math.hypot(s["x"] - cx, s["y"] - cy) for s in sites)

        spot = collections.OrderedDict()
        spot["id"] = self.new_id(kind, zone["name"], mx, my)
        spot["map"] = zid
        spot["zone"] = zone["name"]
        spot["area"] = None
        spot["x"], spot["y"] = round(mx, 1), round(my, 1)
        spot["r"] = round(max(0.2, radius / zone["w"] * 100), 1)
        spot["sites"] = len(sites)
        spot["pts"] = flat
        spot["pk"] = [index.get(site_key(loop[i]), 0) for i in order]
        spot["z"] = [int(round(loop[i]["z"])) for i in order] if with_z else None
        spot["loopYd"] = int(round(loop_yd))
        spot["nnYd"] = int(round(nn_yd))
        spot["startA"], spot["startH"] = starts.get("A"), starts.get("H")
        spot["sampled"] = True if len(loop) < len(sites) else None
        spot["poolsOf"] = self.pools_up(sites, all_roots)
        spot["gets"] = [{"t": k, "n": count[k]} for k in gets_keys]
        spot["req"], spot["top"] = min(reqs), max(reqs)
        spot["mobs"] = self.mobs_near(cont, [(s["x"], s["y"]) for s in sites])
        spot["fp"] = fp
        spot["scattered"] = None
        spot["indoor"] = None
        spot["instance"] = None
        spot["note"] = None
        spot["classic"] = True
        self.apply_curated(spot)
        return spot

    def instance_spots(self, kind: str, sites: list[dict], targets: dict, minimum: int) -> list[dict]:
        out = []
        by_map = collections.defaultdict(list)
        for s in sites:
            if s["map"] not in CONTINENTS:
                by_map[s["map"]].append(s)
        skipped = 0
        for mp in sorted(by_map):
            row = self.instances.get(mp)
            group = by_map[mp]
            if not row or row["InstanceType"] not in ("1", "2") or len(group) < minimum:
                skipped += len(group)
                continue
            count = collections.Counter()
            for s in group:
                for k in s["t"]:
                    count[k] += 1
            keys = sorted(count, key=lambda k: (-count[k], targets[k]["req"], k))[:GETS_CAP]
            spot = collections.OrderedDict()
            spot["id"] = f"{kind}:instance:{slug(row['MapName_lang'])}"
            self.ids.add(spot["id"])
            # the entrance: Map.Corpse (where a ghost enters) on Map.CorpseMapID
            placed = None
            if int(row["CorpseMapID"]) in CONTINENTS and (float(row["Corpse_0"]) or float(row["Corpse_1"])):
                placed = self.place(int(row["CorpseMapID"]), float(row["Corpse_0"]), float(row["Corpse_1"]))
            if placed:
                z, mx, my = placed
                self.used_maps.add(z["id"])
                spot["map"], spot["zone"], spot["x"], spot["y"] = z["id"], z["name"], round(mx, 1), round(my, 1)
                spot["fp"] = self.flight_points(int(row["CorpseMapID"]), float(row["Corpse_0"]), float(row["Corpse_1"]))
                for f in (spot["fp"] or {}).values():
                    f.pop("_xy")
            else:
                self.warnings.append(f"{spot['id']}: Map {mp} has no entrance (Corpse) on a continent: no map point")
            spot["sites"] = len(group)
            spot["gets"] = [{"t": k, "n": count[k]} for k in keys]
            reqs = [targets[k]["req"] for k in count]
            spot["req"], spot["top"] = min(reqs), max(reqs)
            spot["instance"] = row["MapName_lang"]
            spot["note"] = None
            spot["classic"] = True
            self.apply_curated(spot)
            out.append(spot)
        if skipped:
            self.stats[f"{kind}: spawns in instances left out (under {minimum} or not a dungeon/raid)"] = skipped
        return out

    # ---- object skills: lockpicking, mining, herbalism
    def object_targets(self, lock_type: int, with_req_in_key: bool) -> tuple[dict, dict[int, str]]:
        groups = collections.defaultdict(list)  # (name, req) -> [template]
        for entry, t in self.templates.items():
            typ = int(t["type"])
            if typ not in LOCK_FIELD:
                continue
            for idx, skill in self.locks.get(int(t[f"data{LOCK_FIELD[typ]}"]), ()):
                if idx == lock_type:
                    groups[(t["name"], skill)].append(t)
        names = collections.Counter(n for n, _ in groups)
        targets, entry_target = collections.OrderedDict(), {}
        for (name, req), tpls in sorted(groups.items(), key=lambda kv: (kv[0][1], kv[0][0])):
            entries = sorted(int(t["entry"]) for t in tpls)
            spawned = [e for e in entries if self.go_spawns.get(e)]
            if lock_type == LOCK_PICK and not spawned:
                continue  # a template nobody placed: nothing to pick
            if lock_type != LOCK_PICK and req < 1:
                continue  # quest plants with a herbalism lock of skill 0: no skill-up, not a node
            key = slug(name) + (f"-{req}" if with_req_in_key or names[name] > 1 else "")
            typ = int(tpls[0]["type"])
            quests = sorted({int(t[f"data{CHEST_QUEST_FIELD}"]) for t in tpls if int(t["type"]) == 3} - {0})
            targets[key] = collections.OrderedDict(
                name=name, req=req, objects=spawned or entries,
                n=sum(len(self.go_spawns.get(e, ())) for e in entries),
                type=GO_TYPE_NAME.get(typ, "other") if lock_type == LOCK_PICK else None,
                quest=quests[0] if quests and len(quests) == 1 and lock_type == LOCK_PICK else None,
            )
            for e in spawned:
                entry_target[e] = key
        return targets, entry_target

    def new_targets(self, lock_type: int, targets: dict) -> None:
        """Lock rows of the Forever client that no cmangos gathering node uses: nodes new in Forever."""
        used = {int(t["data0"]) for t in self.templates.values() if int(t["type"]) == 3}
        for lock_id in sorted(self.locks):
            for idx, skill in self.locks[lock_id]:
                if idx == lock_type and skill >= 1 and lock_id not in used:
                    targets[f"new-{skill}-lock{lock_id}"] = collections.OrderedDict(
                        req=skill, lock=lock_id, n=0, new=True, note="new in Forever, position unknown")

    def lockbox_items(self, targets: dict) -> None:
        for r in sorted(self.w["ItemSparse"], key=lambda r: int(r["ID"])):
            lock_id = int(r["LockID"] or 0)
            name = r["Display_lang"]
            for idx, skill in self.locks.get(lock_id, ()):
                if idx == LOCK_PICK and name and skill <= 1000 and not re.search(r"\[DNT\]|Deprecated|Test", name):
                    targets[f"item-{slug(name)}-{skill}"] = collections.OrderedDict(name=name, req=skill, item=int(r["ID"]))

    def lockpicking(self) -> dict:
        targets, entry_target = self.object_targets(LOCK_PICK, True)
        sites, roots = self.sites_for(entry_target)
        spots = []
        for cont in CONTINENTS:
            here = [s for s in sites if s["map"] == cont]
            pts = [(s["x"], s["y"], s) for s in here]
            groups, loose = [], collections.defaultdict(list)
            for members in link_cluster(pts, LOCK_EPS, LOCK_TIGHT, LOCK_REACH):
                group = [pts[i][2] for i in members]
                if len(group) <= LOCK_LOOSE:
                    kinds = frozenset(k for s in group for k in s["t"])
                    loose[(self.vote(cont, [(s["x"], s["y"]) for s in group]), kinds)].append(group)
                else:
                    groups.append((group, None))
            # boxes strewn one or two at a time along a coast (Azshara) are one swim, not twenty spots
            for (_zid, _kinds), parts in sorted(loose.items(), key=lambda kv: (kv[0][0] or 0, sorted(kv[0][1]))):
                if len(parts) >= LOCK_LOOSE_MERGE:
                    groups.append(([s for g in parts for s in g], True))
                else:
                    groups.extend((g, None) for g in parts)
            for group, scattered in groups:
                spot = self.build_spot("lock", cont, group, targets, roots, True, True)
                if spot:
                    spot["scattered"] = scattered
                    spots.append(spot)
                else:
                    self.warnings.append(f"lock: {len(group)} spawn(s) on continent {cont} outside every zone map: dropped")
        spots.sort(key=lambda s: (s["req"], s["zone"], s["id"]))
        spots += self.instance_spots("lock", sites, targets, 1)
        self.lockbox_items(targets)
        quests = {}
        for side, q in self.curated.get("quests", {}).get("633", {}).items():
            quests[side] = self.quest_starter(q)
        return collections.OrderedDict(
            name="Lockpicking", kind="lock", capPerLevel=LOCKPICK_CAP_PER_LEVEL, learnLevel=LOCKPICK_LEARN_LEVEL,
            quests=quests or None, targets=targets, spots=spots + self.manual("633"))

    def quest_starter(self, q: dict) -> dict:
        out = collections.OrderedDict(quest=q["quest"], npc=None, name=q["npc"], note=q.get("note"))
        match = [e for e, t in self.creatures.items() if t["Name"] == q["npc"] and self.cre_spawns.get(e)]
        if not match:
            raise GenError(f"spots_curated.json quests: no spawned creature named {q['npc']!r} in the cmangos dump")
        e = min(match)
        mp, x, y, _ = self.cre_spawns[e][0]
        z = self.zones.find(mp, x, y)
        city = [c for c in self.zones.zones if c["city"] and c["cont"] == mp and c["x0"] <= x <= c["x1"] and c["y0"] <= y <= c["y1"]]
        z = city[0] if city else z  # a quest giver in a capital is shown on the city map
        if not z:
            raise GenError(f"spots_curated.json quests: {q['npc']!r} stands outside every zone map")
        mx, my = self.zones.percent(z, x, y)
        self.used_maps.add(z["id"])
        out.update(npc=e, map=z["id"], zone=z["name"], x=round(mx, 1), y=round(my, 1), classic=True)
        return out

    def manual(self, skill: str) -> list[dict]:
        out = []
        for m in self.curated.get("manual", {}).get(skill, []):
            for k in ("id", "map", "zone", "x", "y"):
                if k not in m:
                    raise GenError(f"spots_curated.json manual[{skill}]: a spot without {k!r}")
            if m["id"] in self.ids:
                raise GenError(f"spots_curated.json manual[{skill}]: id {m['id']!r} is already a generated spot")
            self.ids.add(m["id"])
            out.append(collections.OrderedDict(m, manual=True))
        return out

    def nodes(self, lock_type: int, kind: str, name: str, skill: str) -> dict:
        targets, entry_target = self.object_targets(lock_type, False)
        sites, roots = self.sites_for(entry_target)
        per_zone = collections.defaultdict(list)
        dropped = 0
        for cont in CONTINENTS:
            pts = [(s["x"], s["y"], s) for s in sites if s["map"] == cont]
            for area in split_areas(pts, NODE_EPS, NODE_CORE):
                if len(area) < NODE_MIN:
                    dropped += 1
                    continue
                zid = self.vote(cont, area)
                if zid:
                    per_zone[zid].append((cont, [p[2] for p in area]))
        spots = []
        for zid in sorted(per_zone):
            best = sorted(per_zone[zid], key=lambda a: (-len(a[1]), a[1][0]["x"], a[1][0]["y"]))[:NODE_TOP]
            for cont, area in best:
                spot = self.build_spot(kind, cont, area, targets, roots, False, False)
                if spot:
                    spots.append(spot)
        spots.sort(key=lambda s: (s["zone"], -s["sites"], s["id"]))
        spots += self.instance_spots(kind, sites, targets, INSTANCE_MIN)
        self.new_targets(lock_type, targets)
        self.stats[f"{kind}: areas under {NODE_MIN} nodes left out"] = dropped
        return collections.OrderedDict(name=name, kind="node", targets=targets, spots=spots + self.manual(skill))

    def vote(self, cont: int, area: list[tuple]) -> int | None:
        votes = collections.Counter()
        for p in area:
            z = self.zones.find(cont, p[0], p[1])
            if z:
                votes[z["id"]] += 1
        return sorted(votes.items(), key=lambda kv: (-kv[1], kv[0]))[0][0] if votes else None

    # ---- skinning
    def skinning(self) -> dict:
        targets = collections.OrderedDict()
        sites = {}  # one per 3-yard cell: two spawns on the same spot are one pin
        for e in sorted(self.creatures):
            t = self.creatures[e]
            typ = int(t["CreatureType"])
            # normal-rank beasts and dragonkin with a skinning loot table; elites and rares are not a camp to farm
            if int(t["SkinningLootId"]) <= 0 or typ not in SKINNABLE_TYPES or int(t["Rank"]) != 0 or not self.is_mob(e):
                continue
            key = f"n{e}"
            lo, hi = int(t["MinLevel"]), int(t["MaxLevel"])
            targets[key] = collections.OrderedDict(name=t["Name"], req=skin_need(hi), npc=e, min=lo, max=hi,
                                                   type=SKINNABLE_TYPES[typ])
            for mp, x, y, z in self.cre_spawns.get(e, ()):
                if mp in CONTINENTS:
                    s = sites.setdefault((mp, int(x // 3), int(y // 3)),
                                         {"map": mp, "x": x, "y": y, "z": z, "t": collections.Counter(), "root": None})
                    s["t"][key] += 1
        sites = [sites[k] for k in sorted(sites)]
        per_zone = collections.defaultdict(list)
        for cont in CONTINENTS:
            pts = [(s["x"], s["y"], s) for s in sites if s["map"] == cont]
            for area in split_areas(pts, SKIN_EPS, SKIN_CORE):
                if len(area) >= SKIN_MIN:
                    zid = self.vote(cont, area)
                    if zid:
                        per_zone[zid].append((cont, [p[2] for p in area]))
        spots = []
        roots = collections.Counter()
        for zid in sorted(per_zone):
            best = sorted(per_zone[zid], key=lambda a: (-len(a[1]), a[1][0]["x"], a[1][0]["y"]))[:SKIN_TOP]
            for cont, area in best:
                spot = self.build_spot("skin", cont, area, targets, roots, False, False)
                if spot:
                    spots.append(spot)
        spots.sort(key=lambda s: (s["zone"], s["req"], s["id"]))
        used = {g["t"] for s in spots for g in s["gets"]}
        targets = collections.OrderedDict((k, v) for k, v in targets.items() if k in used)
        return collections.OrderedDict(
            name="Skinning", kind="skin", formula=SKIN_FORMULA, tiers=list(SKIN_TIERS), formulaConfirmed=False,
            targets=targets, spots=spots + self.manual("393"))

    # ---- fishing
    def fishing(self) -> dict:
        area = {int(r["ID"]): r for r in self.w["AreaTable"]}
        map_of_area = {z["area"]: z for z in self.zones.zones if z["area"]}
        rows = []
        for r in self.sql["skill_fishing_base_level"]:
            aid, base = int(r["entry"]), int(r["skill"])
            a = area.get(aid)
            if not a:
                self.warnings.append(f"fish: area {aid} of skill_fishing_base_level is not in the Forever AreaTable: dropped")
                continue
            parent = area.get(int(a["ParentAreaID"]))
            z = map_of_area.get(aid) or (map_of_area.get(int(a["ParentAreaID"])) if parent else None)
            if z:
                self.used_maps.add(z["id"])
            rows.append(collections.OrderedDict(
                map=z["id"] if z else None, zone=z["name"] if z else a["AreaName_lang"],
                area=a["AreaName_lang"] if z and z["area"] != aid else None, areaID=aid, base=base,
                instance=True if not z else None, classic=True))
        rows.sort(key=lambda r: (r["base"], r["zone"], r["area"] or ""))
        return collections.OrderedDict(
            name="Fishing", kind="fish", baseConfirmed=False,
            baseNote="zone base skill from Classic data; the no-getaway rule was not found, so this is the base value only",
            zones=rows)

    # ---- the file
    def render(self) -> str:
        skills = collections.OrderedDict()
        skills[633] = self.lockpicking()
        skills[186] = self.nodes(LOCK_MINE, "mine", "Mining", "186")
        skills[182] = self.nodes(LOCK_HERB, "herb", "Herbalism", "182")
        skills[393] = self.skinning()
        skills[356] = self.fishing()
        unknown = sorted(set(self.curated.get("spots", {})) - self.used_curated)
        if unknown:
            raise GenError("spots_curated.json: no generated spot has the id " + ", ".join(repr(u) for u in unknown)
                           + " (the data moved: rerun and rekey the entry from the ids in Data/Spots.lua)")
        L = [
            "-- GENERATED by tools/gen_spots.py: do not edit. Hand-kept notes live in tools/data/spots_curated.json.",
            "-- Where to level Lockpicking, Mining, Herbalism, Skinning and Fishing. Lock requirements: WoW: Forever client",
            "-- data (wago.tools). Object and creature positions, fishing base skills: derived from the cmangos classic-db",
            "-- (GPL-3.0, see LICENSES/cmangos-classic-db.txt): Classic 1.12 data, unconfirmed for Forever.",
            "-- Schema and assumptions: docs/spots-data.md.",
            "local _, ns = ...",
            "ns.Data = ns.Data or {}",
            "",
            "ns.Data.spots = {",
            f"\tversion = 1, build = {lua_str(self.build)}, classicSource = {lua_str(CLASSIC_SOURCE)},",
            f"\tbands = {lua(BANDS)}, bandsConfirmed = {lua(BANDS_CONFIRMED)},",
            "\tmaps = {",
        ]
        for zid in sorted(self.used_maps):
            z = self.zones.by_id[zid]
            L.append(f"\t\t[{zid}] = {{ name = {lua_str(z['name'])}, w = {num(z['w'], 1)}, h = {num(z['h'], 1)} }},")
        L += ["\t},", "\tskills = {"]
        for sid, sk in skills.items():
            head = collections.OrderedDict((k, v) for k, v in sk.items() if k not in ("targets", "spots", "zones", "quests"))
            L.append(f"\t\t[{sid}] = {{")
            L.append("\t\t\t" + lua(head)[2:-2] + ",")
            if sk.get("quests"):
                L.append("\t\t\tquests = {")
                for side, q in sk["quests"].items():
                    L.append(f"\t\t\t\t{side} = {lua(q)},")
                L.append("\t\t\t},")
            for block in ("targets", "spots", "zones"):
                if block not in sk:
                    continue
                L.append(f"\t\t\t{block} = {{")
                if block == "targets":
                    for k, v in sk[block].items():
                        L.append(f"\t\t\t\t[{lua_str(k)}] = {lua(v)},")
                else:
                    for v in sk[block]:
                        L.append(f"\t\t\t\t{lua(v)},")
                L.append("\t\t\t},")
            L.append("\t\t},")
            self.stats[f"{sk['name']}: targets"] = len(sk.get("targets", ()))
            self.stats[f"{sk['name']}: spots"] = len(sk.get("spots", sk.get("zones", ())))
        L += ["\t},", "}", ""]
        return "\n".join(L)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--wago", required=True, help="folder of <Table>.csv exports of the wowf client")
    ap.add_argument("--cmangos", required=True, help="the unpacked cmangos classic-db full dump (.sql)")
    ap.add_argument("--out", required=True, help="the Lua file to write (Data/Spots.lua)")
    ap.add_argument("--build", help="wowf build of the CSVs (default: build.txt in --wago)")
    ap.add_argument("--curated", default=str(CURATED), help="hand-kept notes (default: tools/data/spots_curated.json)")
    ap.add_argument("--download", action="store_true", help="fetch missing inputs into --wago and --cmangos")
    a = ap.parse_args(argv)
    try:
        wago = Path(a.wago)
        build = read_build(wago, a.build)
        b = Builder(load_wago(wago, build, a.download), load_sql(Path(a.cmangos), a.download),
                    load_curated(Path(a.curated)), build)
        text = b.render()
        out = Path(a.out)
        out.parent.mkdir(parents=True, exist_ok=True)
        with open(out, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(text)
    except GenError as e:
        print(f"gen_spots: {e}", file=sys.stderr)
        return 2
    for w in b.warnings:
        print("warning:", w, file=sys.stderr)
    for k, v in b.stats.items():
        print(f"{k}: {v}")
    print(f"{out}: {len(text.encode('utf-8')) / 1024:.1f} KB, build {build}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
