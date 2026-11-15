# Where the data comes from, and how it stays current

SkillupHelper ships three generated data files. Each fact in them has one of four sources. This page lists the
sources with their licences, which one wins when two disagree, how each is refreshed, and how a change in the game
reaches players.

| File | What it holds | Generator |
| --- | --- | --- |
| `Data/Recipes.lua` | every craft recipe: thresholds, reagents, learn rank, cost, recipe item, vendor | `tools/gen_recipes.py` |
| `Data/Spots.lua` | where to level Lockpicking, Mining, Herbalism, Skinning, Fishing | `tools/gen_spots.py` |
| `Data/Trainers.lua` | profession trainers and recipe vendors, with a position where one is known | `tools/gen_npcs.py` |

`docs/spots-data.md` has the schema and the assumptions of the last two.

## The sources

### 1. The client tables (wago.tools)

The DB2 tables of the WoW: Forever client (product `wowf`), exported as CSV by <https://wago.tools>. Game data,
© Blizzard Entertainment; wago.tools publishes the export. The addon ships numbers and names derived from it, as
every database addon does, and no file of the export itself.

Feeds:

- `Data/Recipes.lua`: which spells are recipes of which skill line, the yellow and grey thresholds, skill-ups per
  craft, reagents, the item made, the recipe item that teaches it with its bonding, vendor price and reputation
  (`SkillLine`, `SkillLineAbility`, `SpellReagents`, `SpellEffect`, `SpellName`, `ItemSparse`, `ItemEffect`,
  `ItemXItemEffect`), and the name of the zone a recipe vendor stands in (`AreaTable`, `UiMap`).
- `Data/Spots.lua`: the skill a lock, an ore vein or a herb needs (`Lock`), lockbox items, zone maps, flight
  points, instance names.
- `tools/data/client_snapshot.json`: the lock and node requirements, flight points and zone maps of the last build
  looked at. It exists so a change in them is noticed without the Classic position dump.

Refreshed by `tools/update_data.py`, daily (see "Staying current").

What the client tables do not hold: the skill at which a trainer teaches a recipe, what the trainer charges, which
"trainer" recipes really come from a quest or a special NPC, the profession rank table, any position of an NPC or a
node, and thresholds changed by a server hotfix after the build.

### 2. The Wowhead overlay (the Forever section)

`tools/data/overlay.json`, written by `tools/import_wowhead.py` from a manual extraction of the list pages of
Wowhead's Forever section. Wowhead's pages are © their publisher. Only facts are taken (ids and numbers); no text
from a page is copied, and the extraction itself is never committed.

Feeds `Data/Recipes.lua`: the skill needed to learn a recipe, the training cost, yellow and grey thresholds where
they differ from the build (the site carries hotfixes a build lacks), how a recipe is obtained (trainer, vendor,
quest, drop, crafted), the one vendor the site names for a recipe item, and the profession ranks. It also says
which professions it lists whole: a craft spell of such a profession that the site does not list is written as
`unlisted` and never planned by itself.

Refreshed by a person. The procedure is below.

### 3. The cmangos classic-db

The cmangos Classic database dump (`ClassicDB_1_12_1_z2815`), GPL-3.0. The notice is in
`LICENSES/cmangos-classic-db.txt`. Only data derived from it is shipped: positions and a few numbers.

Feeds `Data/Spots.lua` (which object carries which lock, every spawn position, fishing skill per zone, mob levels)
and `Data/Trainers.lua` (where an NPC stands, limited vendor stock).

It is Classic 1.12 data, **unconfirmed for Forever**. Both files say so in their header, and every position from
it is marked `classic = true`. A position the Forever game itself showed (source 4) replaces it.

Refreshed by a person: the dump is 73 MB and not in the repository. `tools/update_data.py --cmangos FILE`
regenerates `Data/Spots.lua` with it.

### 4. The game

What the addon sees while its user plays, kept in `SkillupHelperDB.learned` and shared by players who choose to
(see "The game as a shared source"). Contributed under the repository's licence.

Feeds, in game and at once: the addon's own plan (a trainer's numbers win over the shipped ones the moment the
trainer is opened). Feeds, for everyone, after a merge: `tools/data/overlay.manual.json` (learn ranks, costs,
thresholds, ranks, vendors, vendor reagents) and `tools/data/npcs_seen.json` (positions).

## Which source wins

For one fact, from weakest to strongest:

1. The client tables.
2. `tools/data/overlay.json` (Wowhead) over the client tables, field by field: a threshold or a learn rank in the
   overlay replaces the build's.
3. `tools/data/overlay.manual.json` over the overlay, field by field. It holds corrections made by hand and what
   `tools/import_savedvars.py` merged from players' games. `gen_recipes.py` lays it on top every time, so a
   correction survives a new Wowhead import.
4. `tools/data/npcs_seen.json` over a cmangos position, in `gen_npcs.py`.
5. In the running game: what this player's own game showed (`SkillupHelperDB.learned`) over everything shipped,
   and the player's `Data/Custom.lua` over that.

Never overridden by a script: a hand-kept value in `overlay.manual.json` counts as shipped data, so the merge rule
below applies to it like to any other value.

## Staying current

### The daily check (`tools/update_data.py`)

```
python tools/update_data.py --report report.md             # regenerate what changed, write the report
python tools/update_data.py --dry-run --report report.md   # write nothing but the report
```

It asks `https://wago.tools/api/builds` for the newest `wowf` build, downloads that build's tables into
`tools/.cache`, regenerates, and compares with what is shipped. The request carries a generic User-Agent and
nothing else.

| | Refreshed | When |
| --- | --- | --- |
| `Data/Recipes.lua` | whole | always |
| `tools/data/client_snapshot.json` | whole | always |
| `Data/Spots.lua` | whole | only with `--cmangos FILE` |
| `Data/Trainers.lua` | whole | only with `--cmangos FILE --npcs FILE --items FILE` |
| `tools/data/overlay.json` | never | a person, see below |

Without the dump `Data/Spots.lua` and `Data/Trainers.lua` are left byte for byte as they are. No position is
dropped and no half-regenerated file is written. The report says so, and lists the lock and node requirements that
changed in the client tables, which wait for a run with the dump.

The report lists: recipes added, removed and renamed; threshold, reagent and bonding changes; recipe items that
appeared, went or changed; other changed fields; profession ranks; vendor reagents; craft spells the overlay does
not know ("needs a source", by name); lock and node requirements, flight points and zone maps; and the 1-300
coverage of every profession before and after.

Exit codes: `0` nothing changed, `10` data changed (written unless `--dry-run`), `1` a coverage hole appeared or
an input broke. On `1` nothing but the report is written, and the report and stderr name what broke.

### The workflow (`.github/workflows/data-update.yml`)

Runs the check every day and on demand. On exit `10` it runs luacheck, busted, stylua and the Python tool tests on
the regenerated files, commits them to the branch `auto/data-update` (replaced each time, so there is never a
second pull request) and opens or updates one pull request with the report as its body. It never merges. On exit
`1` the job fails with the report in its summary.

Two things to know:

- A pull request opened with the workflow's `GITHUB_TOKEN` does not start other workflows, so `ci.yml` does not run
  on it. That is why the same checks run inside `data-update.yml` before the pull request is opened. To get the
  `ci` check on the pull request as well, close and reopen it.
- The repository setting "Allow GitHub Actions to create and approve pull requests" (Settings > Actions > General)
  must be on, and the runner needs `gh`.

A "needs a source" entry in the report is a job for a person: read the Wowhead list again, or wait for a player's
shared file.

### Refreshing the Wowhead overlay by hand

Wowhead's list pages sit behind a human-verification check. **Nobody scripts around it.** A person opens the pages
in a normal browser session, passes the check as a person, and saves what the page already loaded. If the check
cannot be passed by hand, the overlay is not refreshed that day.

1. In a browser, open the list page of each profession:
   - primary professions: `https://www.wowhead.com/forever/spells/professions/<slug>` (`alchemy`, `blacksmithing`,
     `enchanting`, `engineering`, `leatherworking`, `tailoring`, `mining`, `herbalism`, `skinning`)
   - secondary skills: `https://www.wowhead.com/forever/spells/secondary-skills/<slug>` (`cooking`, `first-aid`,
     `fishing`)
   - a skill with no page of its own (Poisons): `https://www.wowhead.com/forever/skill=<id>` (`skill=40`)
2. Each page builds its table from a data block named `listviewspells` in the page source. Save that block as it
   is, one file per page. The recipe items and the NPCs come from the item and NPC lists those pages link to, saved
   the same way. The names of the blocks and of their fields are Wowhead's and can change; what the import needs is
   the three files of step 3, whatever the page calls things that day.
3. Turn the saved blocks into the three files `import_wowhead.py` reads, in one folder that is **not** committed
   (it is a copy of someone else's site):

   ```
   recipes.json       { "ranks":   { "<skill line>": [ { "rank": "Journeyman", "learn": 50, "cost": 500, "source": [6] } ] },
                        "recipes": { "<spell id>": { "skill": 164, "learn": 30, "colors": [o, y, g, grey],
                                                     "cost": 100, "source": [6], "level": 20 } } }
   recipe_items.json  { "<item id>": { "source": [5], "sourcemore": [ { "t": 1, "ti": <npc id>, "n": "name", "z": <area id> } ] } }
   npcs.json          { "<npc id>": { "react": [alliance, horde] } }        (optional)
   ```

   Per recipe: `skill` the skill line, `learn` the skill needed to learn it (9999 on the site means none),
   `colors` the four colour thresholds, `cost` the training cost in copper, `source` the site's source codes
   (6 trainer, 5 vendor, 4 quest, 2 drop, 1 crafted), `level` a character level for a recipe learned by level.
   `ranks` holds the rank spells (Apprentice to Artisan) of a profession with the same fields.
4. Run the import, naming the day the pages were read:

   ```
   python tools/import_wowhead.py --research DIR --retrieved YYYY-MM-DD
   ```

   It compares with the newest client build, writes `tools/data/overlay.json` and prints how many thresholds
   differ from the build.
5. Run `python tools/update_data.py --report report.md`, read the report, commit the overlay and the regenerated
   data together.

The date is written into `Data/Recipes.lua` (`source`), and the addon shows the data's age from it.

## The game as a shared source

### What the addon keeps

Everything the addon observes goes into one table, `SkillupHelperDB.learned` (`Learned.lua`), version 1:

```lua
learned = {
  version = 1,
  build = "1.60.1.70938",   -- the newest client build that wrote here
  locale = "enUS",
  trainers = { [skillLine] = { [spell or lowercased recipe name] = { skill, cost, seenAt = build } } },
  ranks    = { [skillLine] = { [cap] = { name, cap, skill, level, cost, where, seen, seenAt = build } } },
  vendors  = { [npcId] = { map, x, y, seenAt = build, items = { [item] = { price, stock } } } },
  npcs     = { [npcId] = { id, name, map, x, y, place, sells, teaches, trains, auction, seen } },
  colors   = { [spell] = { o, y, n, g, seenAt = build } },
  skillups = { [skillLine] = { [spell or target key] = { [skill bucket] = { t = tries, u = skill-ups } } } },
}
```

- `trainers`: what a trainer asks for each recipe it lists. Keyed by the recipe's name when the client gave no
  spell id.
- `ranks`: the profession ranks a trainer offers. `seen` is a timestamp.
- `vendors`: what a vendor sells. `price` is copper for one item as this character was shown it (a reputation
  discount is in it), absent when the item costs something other than money. `stock` is absent when unlimited.
- `npcs`: the trainers, vendors and auctioneers whose window was opened, with their map position.
- `colors`: per learned recipe, `o` the highest skill it was seen orange at, `y` the lowest seen yellow or green,
  `n` the highest seen not grey, `g` the lowest seen grey. The yellow threshold is in `o+1 .. y`, the grey one in
  `n+1 .. g`.
- `skillups`: tries and skill-ups in buckets of five skill points. A craft is counted when a scan at least 1.5 s
  later shows the skill; crafts of two different recipes between two scans are not counted.

Versions before 0.3.0 kept `trainerReq`, `ranks`, `colorSeen` and `guide.npcs` at the top of `SkillupHelperDB`.
The first load moves them into `learned` and removes the old fields.

### What stays out (privacy audit)

`learned` holds game facts only. These fields of `SkillupHelperDB` are outside it, and the import tool never reads
them:

| Field | Why it is not shared |
| --- | --- |
| `mailQueue` | keyed `"<faction> - <realm>"`, then by character name; each row names the alt it mails to |
| `trips` | your shopping lists with your auction prices and the time they were saved |
| `ahSkip` | auction buys you skipped |
| `skills` | your characters' skill ranks, with timestamps |
| `selftest` | diagnostics of the last session: your settings, a copy of `trips`, counts of alts and queued mail, error texts |
| `guide` | the step you are on, a map pin, the chip's place on screen |
| `ui` | the open tab, folded sections, the journal's state |
| `exclude`, `luck`, `effort`, `sellShare`, `noRecipeBuys`, `noAlts`, `shown` | your planner settings |
| `trainerSeen` | which recipes the trainers you opened list: no name in it, but it is a plan input of this account, not a fact with a build |

Character names of alts are read from TradeSkillMaster at run time and are saved only inside `mailQueue`.

Inside `learned`, the only texts are NPC names, recipe names, rank names, a locale code and client builds. The
addon records nothing there from a secret value (`issecretvalue`), and nothing about the player's position except
where an NPC window was opened.

### Sharing it

A player opens a "Share what my game learned" issue (`.github/ISSUE_TEMPLATE/share-game-data.yml`) and attaches
`WTF\Account\<account>\SavedVariables\SkillupHelper.lua`. The attachment is public and the whole file is in it, so
the template says what else the file holds and how to cut it down to the `learned` block first.

### Merging it (`tools/import_savedvars.py`)

```
python tools/import_savedvars.py FILE [FILE ...] --dry-run    # print the report, write nothing
python tools/import_savedvars.py FILE [FILE ...]              # merge
```

The tool has its own small Lua reader (`tools/luatable.py`), executes nothing, reads only the `learned` table and
inside it only the fields above, each checked for its type. A file is named by its number on the command line,
never by its path, because the path holds the account name.

Where things go:

| From | To |
| --- | --- |
| `trainers` | `overlay.manual.json` `recipes[spell].learn` / `.cost` |
| `ranks` | `overlay.manual.json` `ranks[line]` (`skill`, `cost`) |
| `colors` | `overlay.manual.json` `recipes[spell].y` / `.g`, only when the game pinned the exact skill (orange at 124, yellow at 125). A range that contradicts the shipped threshold without pinning it is a note in the report. |
| `vendors` | a recipe item sold: `recipes[spell].vendor`. A reagent sold for money, unlimited: the `vendor` list. A price that differs is a note only, because a reputation discount changes the price shown. |
| `npcs` | `tools/data/npcs_seen.json`, which `gen_npcs.py` lays over the Classic positions (`seen = true` in `Data/Trainers.lua`) |
| `skillups` | the report only: there is no shipped number to correct |

The merge rule, per fact (one recipe's learn rank, one NPC's position). "Shipped" is `overlay.manual.json` where it
has the field, else `Data/Recipes.lua` (`Data/Trainers.lua` for a position); its build is the one in
`Data/Recipes.lua`.

1. Files with the same `learned` content count as one file.
2. An observation made on a client build **newer** than the shipped build wins, from one file. If files seen on
   that newest build disagree with each other, it is a conflict.
3. Otherwise (same or older build, or no build recorded) overriding a shipped value needs **two independent
   files** that agree, and none that disagrees. One file is listed under "Needs a second file" and kept out.
   Disagreeing files are a conflict.
4. Where the shipped data has no value at all, one file is enough: it overrides nothing.
5. A conflict is reported and never applied. Everything applied is listed.

Two positions of one NPC are the same when they are on the same map within 1.5 map percent. "Independent" means
different files with different content; the tool cannot know who sent a file, so the maintainer judges that.

Exit codes: `0` nothing to apply, `10` something applied (or would be, with `--dry-run`), `1` an input broke.

After a merge, `python tools/update_data.py --report report.md` carries `overlay.manual.json` into
`Data/Recipes.lua` and shows the result as a diff of recipes.

## How a hotfix reaches players

A server hotfix changes a number (a threshold, a training cost) without a new client build, so the client tables
do not show it.

1. **The game learns it.** A player with the addon opens the trainer or the profession window. The addon records
   what it is shown in `learned`, with the build, and that player's plan is right from then on.
2. **A shared file.** The player attaches the SavedVariables file to an issue.
3. **`overlay.manual.json`.** The maintainer runs `tools/import_savedvars.py`. The build is the same as the
   shipped one, so the change needs two files that agree; with one, it waits under "Needs a second file". A
   maintainer who has checked the number in game can write it into `overlay.manual.json` by hand.
4. **A release.** `tools/update_data.py` regenerates `Data/Recipes.lua`, the change is reviewed in a pull request,
   and the next release ships it.

A new client build takes the short way: the daily workflow opens the pull request by itself, and a shared file
seen on that newer build is applied from one file.
