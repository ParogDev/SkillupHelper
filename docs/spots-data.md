# Spots and trainers data

`Data/Spots.lua` says where to level the skills you level out in the world: Lockpicking (633), Mining (186),
Herbalism (182), Skinning (393) and Fishing (356). `Data/Trainers.lua` lists profession trainers and recipe vendors.
Both files are generated. Edit the generators or `tools/data/spots_curated.json`, never the Lua.

## Sources and licences

| Source | Gives | Licence |
|---|---|---|
| wago.tools DB2 CSV export of the WoW: Forever client (product `wowf`, build 1.60.1.70888) | lock requirements, lockbox items, zone maps, flight points, instance names and entrances, factions, area names | Blizzard game data |
| cmangos classic-db full dump `ClassicDB_1_12_1_z2815` | which object carries which lock, every object and creature position, creature levels, pools, fishing base skill, vendor stock | GPL-3.0, notice in `LICENSES/cmangos-classic-db.txt` |
| `npcs.json`, `recipe_items.json` (a Wowhead Forever list scrape, 2026-11-14) | which NPCs train or sell recipes in Forever, their faction and zone | Wowhead listing data |
| `tools/data/spots_curated.json` | area names, route notes, quest starters, border fixes | this repo |

Everything cmangos gives is Classic 1.12 data, unconfirmed for Forever. The files say so in `classicSource` and with
`classic = true` on each row.

The addon is MIT and the two data files derive from a GPL-3.0 database. The licence notice states that for the two
files. The owner should settle whether that mix can ship before a release.

## Regenerate

```
python tools/gen_spots.py --wago DIR --cmangos FILE.sql --build 1.60.1.70888 --out Data/Spots.lua
python tools/gen_npcs.py --npcs npcs.json --items recipe_items.json --wago DIR --cmangos FILE.sql --build 1.60.1.70888 --out Data/Trainers.lua
```

`DIR` holds one `<Table>.csv` per client table. `--download` fetches missing tables from
`https://wago.tools/db2/<Table>/csv?build=<build>` into `DIR` and the dump from
`https://raw.githubusercontent.com/cmangos/classic-db/master/Full_DB/ClassicDB_1_12_1_z2815.sql.gz` into `FILE.sql`.
Without it a missing input stops the run with exit code 2 and its name. `--build` may be left out when `DIR/build.txt`
holds it. Python 3 standard library only. Two runs on the same inputs write the same bytes.

Tables read: Lock, ItemSparse, AreaTable, UiMap, UiMapAssignment, UiMapXMapArt, UiMapArt, UiMapArtStyleLayer,
WorldMapOverlay, AreaPOI, TaxiNodes, Map, FactionTemplate, SkillLine. From the dump: gameobject, gameobject_template,
creature, creature_template, skill_fishing_base_level, pool_gameobject, pool_pool, pool_template, npc_vendor,
npc_vendor_template.

Current output: `Data/Spots.lua` 460 KB, `Data/Trainers.lua` 93 KB.

## How a world position becomes a map point

`UiMapAssignment` gives each zone map one world rectangle. `Region_0` and `Region_3` are the smallest and largest
world X, `Region_1` and `Region_4` the smallest and largest world Y. World X runs north, world Y runs west, so

```
map x % = (maxY - Y) / (maxY - minY) * 100
map y % = (maxX - X) / (maxX - minX) * 100
```

Only zone maps count (`UiMap.Type = 3`) on the point's own continent (`MapID`). Continent, dungeon and micro maps are
never the answer for an outdoor point.

The rectangles of neighbouring zones overlap, so a point near a border lies in two or three. "Smallest rectangle"
picks wrong often. It puts the Scarlet Monastery doors in Western Plaguelands. The generator breaks the tie in this
order:

1. Zones that existed in Classic before city maps, city maps before zones new in Forever (uiMap id above 1464).
   A Classic position is never placed on Mount Hyjal, Riverglades, Shen'dralas or Zephras Isle while a Classic zone
   holds it.
2. `WorldMapOverlay` holds the explored-area pieces of each zone's map art. Those cover the land that belongs to the
   zone. A zone with a piece around the point beats a zone without one.
3. Among those, the zone where the point lies deeper inside a piece, measured in halves of the way from the middle
   of the piece to its edge.
4. Still tied, the zone that owns the nearest `AreaPOI` label. Those labels carry a position and an area id.
5. No piece around the point anywhere: the zone with the nearest piece. No overlay data: the smallest rectangle.

I measured this on the 170 `AreaPOI` labels that lie inside a zone rectangle, leaving each label out of its own test.
163 land in the right zone, against 120 for "smallest rectangle" and 148 for "most central rectangle". The seven
misses sit on borders: Uldaman, Shady Rest Inn, Timbermaw Hold, Talrendis Point, Bloodvenom Post, the Talondeep Path,
the Weeping Cave. A spot can therefore still show on the neighbour's map. `zoneOf` in the curated file corrects one
by hand. The Venture Co. Strongbox has such a fix (The Barrens, not Durotar).

A farming area takes the zone most of its points vote for, so one loop never spans two maps.

Three positions checked against the game, also in the spec: the Alther's Mill lockboxes land in Redridge Mountains at
46.9, 45.2; Angor Fortress in Badlands at 41.5, 28.7; the ship off Ratchet in The Barrens at 65.0, 45.4.

## Schema of `ns.Data.spots`

```
version = 1, build, classicSource,
bands = { yellow = 25, green = 50, grey = 100 }, bandsConfirmed = false,
maps = { [uiMapID] = { name, w, h } },      -- size of the zone map in yards, across and down
skills = { [633] = {...}, [186] = {...}, [182] = {...}, [393] = {...}, [356] = {...} }
```

A skill has `name`, `kind` (`lock`, `node`, `skin`, `fish`), `targets` and `spots`. Fishing has `zones` instead.

**Targets** are keyed by a string. `req` is the skill needed.

- Lock and node objects: `name, req, objects = { gameobject ids }, n = spawn rows`. Lock targets add
  `type = "door" | "chest" | "button" | "other"` and `quest = id` when the chest belongs to one quest.
- Lockbox items: `name, req, item = id`. No position.
- New Forever nodes: `req, lock = Lock id, new = true, note`. No name and no position.
- Skinning: `name, req, npc = id, min, max, type = "beast" | "dragonkin"`. `req` is the skill for the top level.

**Spots**, one per line:

| Field | Meaning |
|---|---|
| `id` | `<lock/mine/herb/skin>:<zone slug>:<XX>-<YY>` from the centre's map percent, or `<kind>:instance:<name>` |
| `map, zone, x, y` | zone map, its name, centre in map percent |
| `area, note, indoor` | from the curated file only, else nil |
| `r` | radius in percent of the map's width |
| `sites` | positions in the spot |
| `pts` | flat list of x, y pairs in map percent (2 decimals), in route order, a closed loop |
| `pk` | per point, the index into `gets` of what the pin stands for (0 = not in `gets`) |
| `z` | lock spots only, per point, world height in whole yards |
| `loopYd, nnYd` | length of the loop in yards, and of the nearest-neighbour tour it was improved from |
| `startA, startH` | index of the point nearest that faction's flight point |
| `sampled` | true when a gathering loop shows 40 of more positions |
| `poolsOf` | about how many of the positions hold an object at one time |
| `scattered` | lock spots: single boxes strewn over a zone, joined into one route |
| `gets` | `{ { t = target key, n = positions } }`, most common first, at most 8 |
| `req, top` | lowest and highest requirement here |
| `mobs` | `{ min, max, list = { { id, name, minLevel, maxLevel } } }`, the 4 most numerous |
| `fp` | `{ A = { name, node, map, x, y, yd }, H = {...} }` |
| `instance` | instance name. Then `map, x, y` are the entrance and there are no points |
| `classic` | true: positions from cmangos |

Lockpicking also has `capPerLevel = 5`, `learnLevel = 16` and
`quests = { A = { quest, npc, name, map, zone, x, y }, H = {...} }`. Skinning has `formula`, `tiers` and
`formulaConfirmed = false`. Fishing zones are `{ map, zone, area, areaID, base, instance, classic }`.

## How spots are built

**Sites.** Spawn rows of the same skill at the same yard are one site. A mining site often has three rows, one per
ore that can appear there.

**Lock spots** keep every position. Two boxes join one spot when they are within 150 yards and within
max(60 yards, 3 x the smaller of their nearest-neighbour distances). That keeps the six boxes inside Alther's Mill
apart from the Lake Everstill field 130 yards away, while loose fields still join up. Three or more leftover groups
of one or two boxes with the same contents in one zone become one `scattered` spot. Azshara's 21 Mossy Footlockers
are one.

**Mining and Herbalism.** DBSCAN with eps 130 yards and 3 neighbours. An area with more than 40 sites or wider than
1000 yards is clustered again at 0.8 x eps, down to 45 yards. Areas under 10 sites are dropped. Each zone keeps its
4 largest. A loop shows at most 40 points. Above that the generator picks 40 spread-out ones.

**Skinning.** Creatures with `SkinningLootId > 0`, type beast or dragonkin, normal rank, that pass the mob filter.
Spawns within the same 3-yard cell count once. Eps 120 yards, camps of at least 8, 4 largest per zone. No instance
camps, because skinnable creatures there are elites.

**Instances.** Objects on a dungeon or raid map (`Map.InstanceType` 1 or 2) make one spot per instance. Its map
point is the entrance, read from `Map.Corpse` on `Map.CorpseMapID`. Gathering needs 5 nodes in the instance.
Naxxramas has no entrance in the table, so it has no map point.

**Routes.** Computed in world yards. Nearest-neighbour seed, then 2-opt and or-opt (moving runs of 1 to 3 points,
either way round) until neither shortens the loop. The loop then rotates to start at the point nearest the Alliance
flight point. `startH` is the index of the point nearest the Horde one. The UI can draw the same loop from either.

**Floors.** A map point has no height. `z` gives it for lock spots. Points of one spot whose `z` differ by more than
about 4 yards are on different floors. In Angor Fortress the two tiers separate that way, and `pk` says which tier a
pin is.

**Pools.** cmangos puts gathering nodes in pools: `pool_gameobject` ties a spawn row to a pool, `pool_pool` ties
pools to a mother pool, `pool_template.max_limit` says how many may be up. `poolsOf` is the mother pool's limit times
the share of its sites that lie in the spot, summed over pools, plus unpooled sites. The footlockers are not pooled
in this dump. Only two lock spots have `poolsOf`, both Large Mithril Bound Chests in Western Plaguelands. For the
others the data cannot say how many are up at once.

**Mob levels.** Creatures within 45 yards of any site of the spot. Left out: critters, totems, non-combat pets and
gas clouds (`CreatureType` 8, 11, 12, 13), anything with an `NpcFlags` bit (vendors, quest givers, flight masters),
anything not attackable or not selectable (`UnitFlags` 0x2, 0x2000000), and any creature whose `FactionTemplate`
`FriendGroup` includes players, Alliance or Horde. That last rule drops town guards, which matter only to one side.

**Flight points.** `TaxiNodes.Flags` bit 1 is the Alliance flight map, bit 2 the Horde one. The nearest node of each
side on the same continent, straight-line yards from the spot's centre. Left out: nodes with neither bit, nodes
with a `ConditionID`, and names starting with zzOLD, Quest Path, Transport or Generic. That drops Powderfuse Port and
Tidegear Coast, which look like real Forever flight points with no faction bit.

## Assumptions, each a named constant in `gen_spots.py`

- `BANDS`: skill-up colours change 25, 50 and 100 points above the requirement. This is the vanilla community rule.
  No source has it for locks or nodes. `bandsConfirmed = false`.
- `LOCKPICK_CAP_PER_LEVEL = 5`, `LOCKPICK_LEARN_LEVEL = 16`.
- `SKIN_TIERS`: mob level 1 to 10 needs 1, 11 to 19 needs (level - 10) x 10, 20 and up needs level x 5. From a
  Forever guide.
- Fishing `base` is the cmangos zone value as it stands, negative values included. The no-getaway rule was not found.
- `CLASSIC_UIMAP_MAX = 1464` marks the zone maps new in Forever.
- `LOCK_FIELD`: which `dataN` of a gameobject type holds the lock id (door and button `data1`; chest, goober, quest
  giver, trap `data0`). Chest `data8` is the quest.

## Unconfirmed for Forever

- Every position, pool size, mob level and fishing base value (Classic data).
- Which object carries which lock id. The requirement itself is Forever's `Lock` row.
- Whether quest chests (Lucius's Lockbox, Gallywix's Lockbox, Benedict's Chest, Duskwood Chest, Cozzle's Footlocker,
  The Jewel of the Southsea) open or give a skill-up without the quest.
- The colour bands, the skinning formula, the lockpicking cap.
- Area names and notes in the curated file come from research notes, not from the game.

Known holes:

- Small Thorium Vein has 42 spawn rows in the dump and its usual object 176643 has none. Un'Goro, Silithus, the
  Plaguelands and Burning Steppes have no thorium here. Rich Thorium Vein has 81 rows, in Winterspring, Azshara and
  Dire Maul only.
- Forever `Lock` rows that no cmangos node uses are listed as `new` targets: Mining 25, 50, 75, 100, 125, 300, 310
  and Herbalism 25, 75, 125, 130, 140, 215.
- Herb objects with requirement 0 are quest plants and are left out.

## `ns.Data.trainers`

A plain array in the shape of `Data/Npcs.lua`, plus `ns.Data.trainersMeta = { version, build, classicSource }`.

| Field | Meaning |
|---|---|
| `id, name` | NPC id and name from the Forever list |
| `map, x, y` | zone or city map and map percent: seen in game, else the wow-professions.com NPC page, else the Classic spawn |
| `place` | the town of a `Data/Npcs.lua` row on the same map within 6 map percent, else the zone name |
| `role` | `trainer`, `recipes` or `recipedrop` |
| `trains` | trainers: the profession name, the field `Guide.seedRecords` reads for role `trainer` |
| `skill` | skill line id, or a list (rogue trainers: `{ 40, 633 }`) |
| `rank` | the highest rank the trainer teaches in Forever, from its wow-professions.com page (or the guide section that sends the player to it) when the site has one; else `apprentice` to `grand master` when the tag starts with it |
| `ranks` | site trainers with a rank table: `{ { rank, skill, level, cost } }`, rank lowercase, `skill` / `level` required to learn it, `cost` in copper |
| `tag` | the NPC's title as listed |
| `faction` | `A`, `H` or `B` from `react`. When `react` is missing, from the Classic faction template |
| `recipes`, `sells` | recipe item ids: the Forever list joined with Classic `npc_vendor` and `npc_vendor_template` |
| `limited` | `{ [item] = n }`, Classic limited stock |
| `classic` | true: position from cmangos |
| `seen` | true: position seen in the Forever game (`tools/data/npcs_seen.json`) |
| `site` | true: position from the NPC's wow-professions.com page (`tools/data/npcs_site.json`, matched by name and skill line) |
| `nopos` | true: no position. `place` is the zone and `map` its map when known |
| `unsure` | true: listed as a recipe's source, absent from Classic. It may be a vendor or a drop |
| `mismatch` | the cmangos name when it differs from the Forever name. The row is then `nopos` |

When an NPC has several Classic spawns the generator takes one inside the zone the Forever list names.

Roles. `Guide.lua` knows `lwtrainer`, `cooktrainer`, `auction` and `trainer` with a `trains` name, and treats any
other row with `sells` as a vendor. So `trainer` rows work as they are, and `recipes` rows read as vendors. Proposed
new role names, none of which need a Guide change today: `recipes` for a recipe vendor and `recipedrop` for a
creature the recipe drops from. The Forever list names 28 of those as a recipe's single source and Classic shows
they sell nothing. They carry `recipes` and no `sells`. If Guide later wants one role per profession the list is
`<skill slug>trainer` (`alchemytrainer`, `miningtrainer` and so on) derived from `skill`.

Counts for this build: 437 rows, 349 with a position and 88 without. No name mismatches. 339 trainers, 70 recipe
vendors (11 `unsure`), 28 drop sources. 40 vendors have limited stock. 53 Leatherworking and Cooking trainers carry
the site layer (2026-11-22; `python tools/gen_npcs.py --relayer` re-applies it to the shipped file without the
cmangos dump).

## Curated file

`tools/data/spots_curated.json`:

- `quests[skill][A|H] = { quest, npc }`. The generator finds the NPC by name in the dump and places it.
- `zoneOf[target key] = uiMap` forces the zone of the spot that holds the target.
- `spots[spot id] = { area, note, indoor }`. An id the generator no longer writes stops the run and names the id.
- `manual[skill] = [ spot ]` copies hand-written spots as they are (`id, map, zone, x, y` required), with
  `manual = true`.

## Tests

`tests/spots_spec.lua` checks the shape of both files, that each route visits every point once, that `loopYd` equals
the summed legs, that no loop is longer than its nearest-neighbour seed, and the known positions.
