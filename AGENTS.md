# AGENTS.md: working on SkillupHelper as an AI assistant

For an assistant that has this addon folder and nothing else. Read this before you change anything. Paths are
relative to the addon folder. The game is WoW: Forever: a Mainline 12.1 client with interface `16001`.

## Rules you must not break

| Rule | Why |
|---|---|
| Never send input to the game (keys, clicks, macros from outside) | anti-cheat; the player clicks, the addon never does |
| Never edit `WTF\...\SavedVariables\SkillupHelper.lua` while the game runs | the game overwrites it on logout and `/reload` |
| A new file (a new `.lua`, a new `Data/Custom.lua`) needs a game restart | the client reads the TOC and file list at start |
| An edit to an existing listed file needs `/reload` | |
| Never edit `Data/Recipes.lua`, `Data/Spots.lua`, `Data/Trainers.lua` by hand | generated; a regeneration drops your edit. Use `Data/Custom.lua` |
| No globals beyond the seven in `tests/wiring_spec.lua` (`ALLOWED_GLOBALS`) | the load-order test fails on any other |
| Check `issecretvalue(v)` before using any client value in an instance or encounter | Forever hands out secret values there; use them and the addon errors |
| Nothing that taints in combat: no frame show/hide of secure frames, no binding change | `InCombatLockdown()` guards are in place; keep them |

## Map of the folder

| Path | What it is |
|---|---|
| `SkillupHelper.toc` | load order. Data first, then logic, then frames, `Core.lua`, `Journal.lua` last |
| `Data/Recipes.lua` | generated: every recipe of every profession (`ns.Data.recipes`) |
| `Data/Spots.lua` | generated: where to level world skills (`ns.Data.spots`) |
| `Data/Trainers.lua` | generated: trainers and recipe vendors (`ns.Data.trainers`) |
| `Data/Npcs.lua` | hand-kept seed NPCs for the guide chip (`ns.Data.npcs`) |
| `Data/Plan.lua` | optional, local: fallback prices from a price tool (shape in `Data/Plan.example.lua`) |
| `Data/Custom.lua` | optional, local: the player's own changes (shape in `Data/Custom.example.lua` and below) |

The TOC lists both optional files, so a client without them logs one load warning per missing file (BugGrabber
shows it as a warning, not an error). That is deliberate: see `docs/data-sources.md`, "Optional local files and
the load warning", before you move them out of the TOC.
| `Logic.lua` | data layers (`effectivePlan`), settings (`applySetting`), money text, data status |
| `Learned.lua` | `SkillupHelperDB.learned`: what the game showed (shareable, anonymous) |
| `Planner.lua` | the planner (`Planner.costToCap`, the rules in README "How the plan is made") |
| `Scan.lua` | reads the profession window and the trainer; `Scan.costOf` costs one profession |
| `TSM.lua` | TradeSkillMaster prices and its crafting window |
| `Guide.lua`, `GuideUI.lua` | the guide chip (nearest vendor, trainer, auction house) |
| `View.lua`, `UI.lua` | the docked panel's text and frames |
| `Skills.lua` | rank and cap of any skill line, Lockpicking included |
| `Where.lua` | spot ranking, routes, itinerary, and every sentence the journal shows |
| `Widgets.lua`, `MapCanvas.lua`, `FieldUI.lua`, `JournalUI.lua` | journal, map, field card, tracker frames; they only draw view-models |
| `Journal.lua` | the provider: wires the journal to the planner, Skills, Where and the settings; custom spots; world tries |
| `Core.lua` | events, SavedVariables, selftest, `/skillup` |
| `tests/*_spec.lua` | busted specs; `tests/wiring_spec.lua` loads the whole addon in TOC order |
| `tools/*.py` | data generators and the update tools (Python 3, standard library only) |
| `docs/` | `data-sources.md`, `spots-data.md`, `where-model.md`, `ui.md`, `first-launch-checklist.md` |

## Data schemas

### `ns.Data.recipes` (`Data/Recipes.lua`)

```
{ version = 2, build = "1.60.1.70938", source = "...", counts = { [line] = n },
  vendor = { [item] = copper },                         -- reagents a vendor sells
  items = { [item] = { name, sell, stack, madeBy } },
  professions = { [line] = { name, to, ranks = { { name, skill, cap, cost, level } }, recipes = {
      [spell] = { name, y, g, k, mats = { item, count, ... }, makes, n, src, learn, cost, item, bop, buy,
                  faction, rep, gone, from, vendor, place, unc } } } } }
```

`y` / `g` are the skills where a recipe turns yellow / grey. `src` is `auto`, `trainer`, `item`, `special` or
`unlisted`. Skill lines: 164 Blacksmithing, 165 Leatherworking, 171 Alchemy, 185 Cooking, 186 Mining, 197 Tailoring,
202 Engineering, 333 Enchanting, 129 First Aid, 40 Poisons; world skills 633 Lockpicking, 182 Herbalism, 393
Skinning, 356 Fishing.

### `ns.Data.spots` (`Data/Spots.lua`)

Full schema in `docs/spots-data.md`, "Schema of `ns.Data.spots`". In short:

```
{ version = 1, build, bands = { yellow = 25, green = 50, grey = 100 }, bandsConfirmed = false,
  maps = { [uiMap] = { name, w, h } },                  -- yards
  skills = { [line] = { name, kind = "lock"|"node"|"skin"|"fish", targets = { [key] = { name, req, ... } },
                        spots = { { id, map, zone, x, y, r, pts = { x, y, ... }, pk, gets = { { t, n } },
                                    req, top, mobs, fp, classic, ... } }, zones (fishing) } } }
```

Positions are map percent (0 to 100). `pts` is a flat list of x, y pairs in route order. `pk[i]` is an index into
`gets`; `gets[j].t` is a target key.

### `ns.Data.trainers` (`Data/Trainers.lua`) and `ns.Data.npcs` (`Data/Npcs.lua`)

Arrays of `{ id, name, map, x, y, place, role, trains, skill, rank, faction = "A"|"H"|"B", sells, recipes,
classic, nopos }`. Field meanings: `docs/spots-data.md`, "`ns.Data.trainers`". `Data/Npcs.lua` rows use roles
`trade`, `cook`, `lwtrainer`, `cooktrainer`, `auction`, `trainer`.

### `ns.Data.plan` (`Data/Plan.lua`, optional)

See `Data/Plan.example.lua`: `{ version = 2, pricesAt, effort, sellShare, vendor, items = { [item] = { name, sell,
mv, stack } }, professions = { [line] = { name, from, to, rows } } }`. `items[].mv` is the fallback auction price
when TSM has none. Without this file auction items have no price until TSM has data.

## Change a plan without touching shipped files: `Data/Custom.lua`

1. Copy `Data/Custom.example.lua` to `Data/Custom.lua`.
2. Keep only the entries you need. Restart the game the first time; `/reload` after later edits.
3. Check the result: a bad entry is left out and named in one chat line at login, in the journal's Settings and data
   page ("Your Custom file"), and in `SkillupHelperDB.selftest.data.custom.errors` and
   `selftest.journalWiring.customPlaces.errors`.

What wins, weakest first: `Data/Recipes.lua`, `Data/Plan.lua`, `Data/Custom.lua`, then what a trainer showed in
game (`learned.trainers`) for learn ranks.

| Goal | Key | Example |
|---|---|---|
| Change a recipe's learn skill | `recipes[line][spell].learn` | `recipes = { [164] = { [2660] = { learn = 1 } } }` |
| Change how a recipe is learned | `.src` (`trainer`, `item`, `auto`, `special`), `.teacher` | `[9813] = { src = "special", teacher = "a quest in the Barrens" }` |
| Change thresholds | `.y`, `.g` | `[3320] = { y = 45, g = 65 }` |
| Change the training cost | `.cost` (copper) | `[3320] = { learn = 25, cost = 100 }` |
| Leave a recipe out of every plan | `[spell] = false` | `[2663] = false` |
| Add a recipe the data lacks | needs `y`, `g`, `mats` | see `[999001]` in `Data/Custom.example.lua` |
| Add or remove a vendor reagent | `vendor[item] = copper` or `false` | `vendor = { [2880] = 100, [4289] = false }` |
| Name an item your recipe makes | `items[item] = { name, sell, stack }` | `items = { [999002] = { name = "Example Buckle", sell = 150, stack = 20 } }` |
| Add or replace a guide NPC | `npcs = { row }` (same id replaces) | `{ id = 3355, name = "Saru Steelfury", map = 1454, x = 76.6, y = 34.6, role = "trainer", trains = "Blacksmithing", place = "Orgrimmar" }` |
| Add a spot for a world skill | `spots[line][id] = { map, x, y, gets, pts? , zone?, note? }` | below |
| Correct a shipped spot | the shipped `id` with a full spot | `spots = { [633] = { ["lock:badlands:41-28"] = { ... } } }` |
| Leave a shipped spot out | `spots[line][id] = false` | `spots = { [186] = { ["mine:durotar:52-40"] = false } }` |
| Add or replace a trainer row | `trainers = { row }` (same id replaces) | `{ id = 999001, name = "My Trainer", map = 1454, x = 40, y = 60, role = "trainer", trains = "Mining" }` |

A custom spot (checked by `Journal.lua`, `P.applyCustom`; tested in `tests/wiring_spec.lua`):

```lua
spots = {
	[633] = { -- Lockpicking; also 186 Mining, 182 Herbalism, 393 Skinning. Fishing has zones: not customisable.
		["lock:custom:my-loop"] = {
			map = 1418,                      -- uiMap id of the zone (a number)
			zone = "Badlands",
			x = 41.5, y = 28.7,              -- centre, map percent
			gets = { { t = "<target key from Data/Spots.lua skills[633].targets>", n = 4 } },
			pts = { 41.0, 28.0, 42.0, 29.5 },-- optional route points, x, y pairs in map percent
			note = "Up the west ramp",
		},
	},
},
```

Errors it names: `map must be a uiMap id`, `x and y must be map percent, 0 to 100`, `gets[1]: no target "x" in this
skill's targets`, `pts must be x, y pairs`, `no shipped spot with this id to leave out`, `not a world skill line`,
and for trainers `needs id (a number) and name`, `role must be "trainer" or "recipes"`, `a trainer needs trains`.

Today the guide chip reads `Data/Npcs.lua` plus your `npcs`; `Data/Trainers.lua` and your `trainers` feed the data
counts and the Where page's errands when those are wired.

## Regenerate the data

Python 3, standard library only. Inputs are downloaded on request (`--download`).

| Command | Writes | Needs |
|---|---|---|
| `python tools/gen_recipes.py ... --out Data/Recipes.lua` (`--check` lists uncovered ranges) | `Data/Recipes.lua` | the wago.tools CSV export of the Forever build; `tools/data/overlay.json` |
| `python tools/import_wowhead.py ...` | `tools/data/overlay.json` | a research export of Wowhead's Forever section |
| `python tools/gen_spots.py --wago DIR --cmangos FILE.sql --build B --out Data/Spots.lua` | `Data/Spots.lua` | client tables, cmangos dump, `tools/data/spots_curated.json` |
| `python tools/gen_npcs.py --npcs npcs.json --items recipe_items.json --wago DIR --cmangos FILE.sql --out Data/Trainers.lua` | `Data/Trainers.lua` | the same, plus the Forever NPC lists |
| `python tools/update_data.py --report report.md` (`--dry-run`) | all of the above that changed | network (wago.tools) |
| `python tools/import_savedvars.py FILE ... --dry-run` | `tools/data/overlay.manual.json`, `tools/data/npcs_seen.json` | players' shared SavedVariables files |

Exit codes of the two update tools: `0` nothing changed, `10` changed, `1` broke. Details: `docs/data-sources.md`.

## Run the tests and lint

The same three tools CI runs (`.github/workflows/ci.yml`), from the addon folder:

```
luacheck . --no-color
busted --verbose
stylua --check .
python3 -m unittest discover -s tools/tests -v
```

Versions: Lua 5.1, luacheck, busted and stylua as current releases. `.busted` sets the test root; `.luacheckrc`
falls back to its own globals list when the maintainer's generated list is absent. Format only the files you
changed (`stylua Journal.lua`), never the whole tree in one go, so a diff stays readable.

## SavedVariables (`SkillupHelperDB`, account-wide)

| Field | Safe to read | Holds |
|---|---|---|
| `selftest` | yes | diagnostics, rewritten on login and logout (below) |
| `learned` | yes, and to share | trainers, ranks, vendors, npcs, colors, skillups (`Learned.lua` header) |
| `luck`, `effort`, `noRecipeBuys`, `noAlts`, `resale` | yes | planner settings (`/skillup` and the Settings page); `resale` true = "Count selling what I craft" (off by default) |
| `exclude` | yes | `dungeon`, `ahPatterns`, `special`, `notNow[spell]`, `allow[spell]`, `swap[spell]` |
| `skills` | yes | last rank seen per skill line (`Skills.lua`) |
| `ui` | yes | journal, field card, tracker positions and state; `track[GUID] = { line, spot }` |
| `trips`, `ahSkip`, `trainerSeen`, `guide`, `shown` | yes | AH list, guide state, panel shown |
| alts' names (inside mail and alt caches) | private | do not paste these anywhere public |

## The selftest and "the plan looks wrong"

After `/reload` (or logout) read `SkillupHelperDB.selftest` from the SavedVariables file with the game closed, or ask
the player to.

| Field | Says |
|---|---|
| `version` | the code that loaded (`ns.CODE_VERSION`) |
| `data` | data layers: shipped build and counts, `custom.errors`, `status` (data age), `gameIsNewer` |
| `lastError`, panel errors | the docked panel's last failure |
| `journal` | `JournalUI.diag()`: pages drawn, `missing` provider callbacks, `lastWhy`, map mode and art |
| `journalWiring` | `firstError` of the wiring, planner `costRuns` / `costMaxMs`, `customPlaces`, `worldTries` |
| `skills` | rank, cap and source per world skill; `last` skill-up message parsed |
| `where` | spot and trainer counts, map diagnostics |
| `firstLaunch` | compartment registered, binding name and key, skill api answered, map art missing, prices |

Step by step:

1. `selftest.version` is the version you expect? If not, the game loaded another copy: restart.
2. `selftest.data.custom.errors` or `journalWiring.customPlaces.errors` empty? Fix each named entry.
3. `selftest.data.gameIsNewer` true? The shipped data predates the game build: a changed recipe may be off.
4. Prices: `firstLaunch.prices` false means TSM has no auction data. Costs then count vendor items only.
5. Wrong learn skill or cost for one recipe: open the trainer once (the game's word wins), or set
   `recipes[line][spell].learn` / `.cost` in `Data/Custom.lua`.
6. A recipe the player cannot get is planned: `[spell] = false` in `Data/Custom.lua`, or Hide on its shortcut.
7. A gap ("Nothing gives skill from X to Y"): the Overview row's tooltip names the reason. Usually a recipe item to
   buy (`/skillup recipes on`) or a special teacher (Settings: "Plan special teachers").
8. Wrong place for a world skill: add or correct the spot in `Data/Custom.lua` (`spots`).
9. "Why did it pick the dearer recipe?" With "Count selling what I craft" on (`resale = true`), what a product
   sells for lowers its recipe's cost; off (the default) the plan ranks by what the player pays and the card only
   notes "about Xs back if you sell N (not counted)". Leftover reagents are valued at salvage either way.
10. Mining shows "Mine nodes ... from mining nodes" between smelting recipes: a world step from the Where route
    (`Where.worldStretches`, `input.world`), no gold, not a gap. A red hole there means no spot covers that skill.
11. Still wrong: reproduce it in a busted spec against `Planner.costToCap` (see `tests/planner_spec.lua`,
   `tests/coverage_spec.lua`) before changing code.

## Invariants

- The planner rules in README "How the plan is made" hold for every plan; `tests/planner_spec.lua` pins them.
- Every client value that can be secret is checked with `issecretvalue` and degrades to a "not now" text.
- The frames (`Widgets`, `MapCanvas`, `FieldUI`, `JournalUI`) build no sentence and compute no plan; text comes
  from `Where.lua` and `View.lua`.
- Every journal callback runs under `pcall`; a failure is recorded in the selftest, never raised into the panel.
- Frames are built on first use, never at login. A hidden frame runs no `OnUpdate`.
- Nothing scrolls: no scroll bar, slider or mouse-wheel handler anywhere. Long content turns pages (`W.list`,
  `W.pages`; the mailbox panel through `View.mailPages`). `docs/ui.md` has the layouts.
- A plan step is `craft`, `train`, `trainRank`, `buyRecipe`, `gap` or `world`. Code that switches on `kind` handles
  `world` (a node stretch, no gold) wherever it handles `gap`.
- `learned` holds no character, realm, account, guild or faction name.
