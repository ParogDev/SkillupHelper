# The Where model

`Where.lua` (`ns.Where`) turns the spot data, the character's skill and the planner's result into the tables the
journal, the field card and the tracker draw. `Skills.lua` (`ns.Skills`) reads the rank and cap of any skill line.
Both are pure: client values come in through one context table, and `tests/where_spec.lua` and
`tests/skills_spec.lua` run them whole. The frames never build a sentence. Every string they show is written here.

The shapes follow section 7 of the design spec. This page records what the spec left open and how it was decided.

## Inputs

`W.query(ctx)` normalises the context once. Every builder accepts either the raw `ctx` or its result.

| Field | Meaning |
|---|---|
| `data` | `ns.Data.spots` |
| `line` | skill line id (633, 186, 182, 393, 356) |
| `skill`, `cap`, `level` | numbers, or nil when unknown or secret |
| `faction` | `"A"`, `"H"`, `"Alliance"` or `"Horde"`; anything else is unknown |
| `class` | class token (`"ROGUE"`) |
| `here` | `{ map, x, y }`, normalised 0 to 1 as `C_Map.GetPlayerMapPosition` gives it; nil when hidden |
| `maps` | override of `data.maps`: `{ [uiMapID] = { w, h } }` in yards |
| `confirmed` | `{ [spot id] = true }` for places the character has stood at |
| `continentOf` | `{ [uiMapID] = id }`; defaults to `W.CONTINENT` |
| `selected` | spot id the user picked |

Data positions are map percent (0 to 100). Everything in a view-model is normalised (0 to 1). Distances are yards.

A secret or missing number becomes nil in `W.query`. No builder fails on nil. Each has a worded fallback:

| Missing | What the model does |
|---|---|
| skill | all points stay on the route, rows read "from 110", the list head says the skill is unknown until the first skill-up message |
| level | mob chips are `bone` with no phrase, the score has no danger part |
| faction | no flight point, no start rotation, caption says "Faction unknown" |
| position | `live.ok = false` with the reason; pins and route stay |
| map size | `live.why` says the size is not in the data; a shortened loop is scaled from the data's length |

## Functions

Band maths: `bandsOf`, `stateAt`, `changeAt`, `segs`, `recipeBands`, `skinReq`, `fishAway`, `counts`.
Mobs: `greyLevel`, `danger`, `mobs`.
Choice: `rate`, `rank`, `rankFish`, `itinerary`, `whereList`, `worldPath`.
Route: `route`, `floors`, `nextStop`, `visit`, `fresh`, `visitedLine`, `yards`, `bearing`, `compass`.
Models: `where`, `fishWhere`, `emptyWhere`, `travel`, `yields`, `fishYields`, `live`, `whereLive`, `tracker`,
`errands`, `errand`, `trainerRecords`, `overview`, `path`, `journal`, `dataRows`.
Text: `yd`, `int`, `clock`, and the fixed sentences in `W.TEXT`.

## Colour bands

A target with requirement `req` is orange from `req`, yellow from `req + 25`, green from `req + 50` and grey from
`req + 100`. Below `req` it is `locked`. The offsets come from `data.bands`. They are the vanilla community rule and
`bandsConfirmed = false` travels into `yields.bandsConfirmed`, `where.bandsConfirmed` and each row's tooltip.

Skinning targets carry their `req` in the data. `W.skinReq(level, tiers)` gives the same number from a level.

Fishing has no colours. A zone's row has two tones: grey while fish get away, green from `base + 95`.
`W.fishAway(skill, base)` uses the cmangos rule: a catch needs `skill >= base` and a roll of 1 to 100 at most
`skill - base + 5`. The data does not confirm this rule for Forever. The row's tooltip says so.

## What a route point is worth

`pk[i]` is an index into the spot's `gets`. A key string is accepted too. `0` or a missing entry becomes the type
`other` at the spot's lowest requirement.

- A lock or a beast is its own target.
- A mining or herb site is pooled. Its pin shows the lowest ore that can appear there. The site counts as the best
  state among that ore and every higher one the spot gives. A copper pin stays on the route while the spot's tin
  still gives points. This is an assumption: the data does not say which ores share a site.

## Score

`W.rate(q, spot, skill, level)` returns the score and its parts. Higher is better.

| Part | Value |
|---|---|
| `gain` | +100 x the share of the spot's positions that give points, weighted orange 1, yellow 0.75, green 0.25 |
| `loop` | minus (loop yards per usable position) / 10, at most 20 |
| `danger` | minus 40 deadly, 20 dangerous, 5 even |
| `flight` | minus (yards from the faction's flight point) / 300, at most 10; minus 10 when the faction has none |
| `player` | minus (yards from the player) / 500, at most 10; minus 5 when the player is on another map |
| `place` | minus 25 in an instance, 10 underwater, 5 indoors |

Positions are counted from `gets[].n`, so the share reflects how many of each target the spot has. "Underwater" is
`spot.underwater` or a note that contains the word. A Classic-only position is tagged and never penalised. Ties go
to the lower spot id.

The spec sorts the Where list "nearest first". The list is sorted by this score instead, because distance alone
ranks a grey loop next door above a good one a flight away. The head line reads "best first".

## Danger

`d = mobs.max - level`.

| State | Rule | Tone |
|---|---|---|
| deadly | d >= 5 | warn |
| dangerous | d 3 or 4 | orange |
| even | d -2 to 2 | yellow |
| easy | below that, above the grey level | green |
| trivial | at or under the grey level | grey |

The grey level is the vanilla experience rule (`W.greyLevel`). The data has no elite flag, so `mobs.elite` is false.

## Itinerary

`W.itinerary(q, from, to)` walks the skill's thresholds (every requirement and colour change of every target) and
takes the best spot at each. It returns ordered legs and holes.

- A leg changes only when another spot leads by `W.SWITCH` (10) score points. Otherwise the route would hop between
  near-equal spots.
- The player's position is left out. A plan must not change as the player walks.
- Lockpicking's cap is 5 x level, so skill `s` implies level `s / 5` at least. Danger is judged at that level, or the
  current one when higher. Other skills use the current level.
- `leg.band` is the best colour the spot gives when the leg starts. Green means slow going.
- A hole is a stretch where no spot gives points. Its reason is the first that applies: named targets whose band
  covers it but that sit in no spot ("Small Thorium Vein (42 positions): too few positions in the data to make a
  spot"), then targets new in Forever ("2 targets: new in Forever, position not known yet"), then "nothing in the
  data gives points here".
- Fishing: any zone the skill can fish in, fewest get-aways first. Skill-ups do not depend on the zone.

"Complete 1-300" depends on the unconfirmed bands. With a narrower grey band the same data would show holes.

## Route

`W.route(q, spot)`:

- Grey and locked points leave the tour. The rest keep their order and are renumbered from the faction's start
  (`startA`, `startH`). The first kept point at or after the start index is stop 1.
- `loopYd` is the data's value when nothing was dropped. Otherwise it is summed from map percent and the map's size.
  Without a size it is the data's length scaled by the share of the tour that is left, and `loopWhy` says so.
- Floors: heights are sorted and split where neighbours differ by more than 4 yards (`W.FLOOR_GAP`). The spec says
  6. The data's own note says about 4, and Angor Fortress separates at 4. Two floors are "Lower" and "Upper", three
  add "Middle", more are numbered. Each floor change in the tour is a `stairs` entry at the midpoint of the
  segment. The data has no stair points.
- `poolsOf` is on two lock spots only. Elsewhere `poolsText` reads "how many are up at once: not known".
- A `scattered` spot is `kind = "spot"` with an open route and the caption "N positions spread over the zone, no
  set loop". An instance spot has no route. Its pin is the entrance.

`W.nextStop`: after a visit, the first unvisited stop ahead in tour order. Before any visit, the unvisited stop
nearest the player, or stop 1 with no position. Bearings are degrees clockwise from north. The compass word comes
from `Guide.compass` and is written "northeast", as the guide chip does, not "north-east" as in the spec's example.

Visits live in a plain table `{ [stop] = expiresAt }`. The respawn window is `spot.respawnSec`, else 300 seconds.

## Travel

`W.travel` gives at most three legs: the crossing when the player is on the other continent, the faction's flight
point, and the spot. The spot leg carries the straight-line yards from the flight point and a compass word when
both are on one map. The data has no entrance or building words beyond `note`, which the model passes on as
`where.note`. `where.travel` rows have `map` in addition to the spec's fields, because a flight point can lie on a
neighbouring map.

`enterYd` is the spot's radius in yards plus 40, `leaveYd` the radius plus 120.

## Errands

`W.errands(ctx)` builds one `where` (kind `errand`) per city for a crafting step. The needs and who serves them
come from `Guide.needsOf`, `Guide.pending` and `Guide.serves`. NPCs are grouped by `place`. Cities that serve every
need come first, then the nearest. Inside a city the trainer comes first, then nearest neighbour from the player.
`W.trainerRecords(rows, faction)` turns `Data/Trainers.lua` rows into Guide records. Rows without a position, of
the other faction or with role `recipedrop` are left out.

## Overview

One row per profession in the shipped recipes plus the five world skills. A crafting row takes its numbers from
the injected `costFn(line, prof, from, to)`, which returns `Planner.costToCap`'s result or `nil, why`. Materials
are `spent - back`, recipes the sum of `recipesToBuy`, training `trainingCost`. A world row runs the itinerary.
Its cost is rank training only, when the recipes data has ranks for the line.

A row is `complete`, `gaps` or `nodata`. `overview.holes` lists every gap of every row with profession, bracket
and reason. Nothing is left as a bare "unknown".

## Path

`W.path(ctx)` reads the planner's `steps` as they are today: `craft` (`from`, `to`, `crafts`, `expected`,
`thresholds`, `buy`, `used`, `cash`, `others`, `shortcuts`), `gap`, `buyRecipe`, `train`, `trainRank`. Done steps
are not in a plan, so the fold row reads "Done: 1 to 150" without a step count. A Bind on Pickup shortcut becomes
a `bop` marker. `detail.where` comes from the injected `ctx.errand(step)`.

`W.worldPath(q)` is the Path page of a world skill: the itinerary from 1 as rows with `done`, `now`, `todo` and
`gap` states.

## Not built here

`shopping` and `alts` reuse `V.shoppingItems` and `V.mailPanel`. The planner rows of `settings` are
`V.moreItems`. `W.dataRows` builds the Data section. "Learned in game" needs the saved tables and belongs with the
integration.

## Skills

`Skills.read(line, env)` tries, in order:

1. `skill api`: `C_SkillInfo.GetSkillLineInfoByID`. Forever's character sheet and skills window read it.
2. `tradeskill api`: `C_TradeSkillUI.GetProfessionInfoBySkillLineID` (skipped when it answers 0 / 0), then
   `GetProfessions` and `GetProfessionInfo`.
3. `chat message`: the last skill-up line of this session.
4. `saved`: the same from `SkillupHelperDB.skills[line] = { rank, cap, at, from }`.
5. `estimate`: no rank. Lockpicking still gets its cap, 5 x level.

The result is `{ line, rank, cap, source, capSource, why, available, learned, notNow }`. A rogue below 16 or
another class gets `available = false` and `why = "not available: <reason>"`. A secret value is never used or
saved. It sets `notNow`.

The chat pattern is built from `ERR_SKILL_UP_SI` and `ERR_SKILL_GAINED_S`, positional arguments included. A chat
line names the skill in the client's language. `Skills.names` takes each line's name from the skill api, then
`C_TradeSkillUI.GetTradeSkillDisplayName`, then the data's English name. On a non-English client where neither
api names a line, its chat lines match nothing and `Skills.last.why` says which name failed.

`Skills.register(frame)` registers `CHAT_MSG_SKILL`, `SKILL_LINES_CHANGED` and `PLAYER_LEVEL_UP` and hooks the
frame's `OnEvent`. `Skills.handle(event, ...)` is the same entry for a caller with its own dispatcher.
`Skills.listen(fn)` is called after each change.
