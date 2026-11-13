# Skillup Helper

A panel on the right of the profession window that answers "what do I craft next to level this?":

- **Plan**: ordered steps from your skill to the cap. Craft N from stock, buy materials (vendor or auction house, with
  the cost) and craft, buy a recipe, train, or a gap where nothing gives skill. Each step says how many points to
  expect. A buy step also shows the use-your-stock alternative and what it costs extra over the whole path.
- Materials you own count at what they are worth: the buy price when the plan buys more of them anyway, otherwise what
  they sell for. A recipe about to turn grey uses its materials first, materials a later step needs are kept for it,
  and surplus is listed with what it sells for.
- **Craftable from bags + bank**: every learned recipe you can make from stock, with a verdict: now, keep for later, or
  wasteful (and how much more per point than the plan).

Prices come from TradeSkillMaster live (the TSM app keeps AuctionDB synced). The recipe data, and fallback prices when
TSM has none, come from `Data/Plan.lua`, a file written on your PC (the maintainer's tool, not shipped); without it the
panel shows the from-stock list only. The panel warns when the TSM data is more than 24 hours old.

`/skillup` shows or hides the panel. `/skillup effort <copper>` sets the effort charge per craft (default 20c): the
planner adds it to every craft so a cheap recipe with a low skill-up chance does not win on price alone.
`/skillup recipes off` plans only with recipes you know or can train; `/skillup recipes on` lets it suggest recipe
items to buy again.

**Guide**: a small chip, there with the profession window closed too, points to the nearest vendor, trainer or
auction house the next step needs, with the distance and a "Target" button. It learns every vendor you open.

Requires TradeSkillMaster. The panel docks to TSM's crafting window, and to Blizzard's window after you press TSM's
"WoW UI" button; it follows you when you switch. It finds TSM's window through `TSM_API` only and never changes TSM's
frames. TSM's API cannot add to its crafting queue, so there is no "queue these" button.

Only WoW: Forever (interface 16001) is supported.

## Planner rules

These rules hold for every plan, every replan and every alternative the panel offers:

1. **Buy for bad luck.** A step that buys reagents buys enough for a bad-luck run: the 90th percentile of the crafts
   it takes to reach the step's target, not the average. The card says "usually N crafts, up to M". A lucky run ends
   early and the spares count as stock for later steps. `/skillup luck 95` changes the percentile (50, 75, 80, 90, 95
   or 99).
2. **Earmarked materials stay put.** A material a later step needs is never offered for something else: not as "Or use
   stock", not in the from-stock list as "ok", and not by a replan. Only true spares are offered.
3. **A bought step holds.** Once a step is on your AH list, its recipe and target hold until you reach the target or
   the recipe turns grey. A replan after a skill-up or a price change never switches or shrinks it.
4. **One recipe, one step.** A recipe's crafts stay one step even when part comes from stock and part is bought.
5. **No one-craft detours.** A single point of another recipe between two runs of the same recipe is folded in,
   unless it saves at least 10% of the remaining cost.
6. **Caps are planned.** The live cap comes from the client; ranks above it come from what the addon read at a
   profession trainer (Forever's client carries no rank table), "unknown" until then. A rank-up goes between its
   unlock skill and the cap, next to a trainer visit already planned when there is one, and never splits a craft
   run. A rank your character level can't train yet is a hard stop.
7. **Shopping by place.** Blocks are grouped by city: the city whose nearest stop is closest comes first, and inside a
   city the order is trainer, vendor, auction house. A city is the town of the nearest known NPC serving the row
   (a seed's place, or for an NPC you opened, the seed town nearby or the map's name); rows with no known town come
   last. Never vendor, AH, vendor in one city.
8. **Only recipes you can surely get.** The plan uses recipes you know, recipes a trainer you opened teaches,
   auto-learned ones and patterns with a price. A recipe from a special NPC (a dungeon teacher), a quest, or a
   trainer recipe no trainer you opened lists is a **shortcut**: never planned, but shown on the step it would make
   cheaper ("Shortcut: X saves 1g 10s (needs: …)") or the gap it would fill, with **Use it** (plan with it from now
   on; `/skillup allow <spellID>` toggles it) and **Hide** (never offer it). Until you open a trainer of the
   profession, trainer recipes are planned and the footer says how many are unconfirmed.

## Limits

- Bank counts are what the client remembers from your last bank visit.
- A rank's cap is known only when the trainer's text names it. A trainer line that gives the rank without its skill
  cap leaves that cap "unknown" in the plan until another trainer's text says it.
- Special teachers (a dungeon NPC, a faction vendor that teaches) come from the `SPECIAL_TEACHERS` list of the
  plan generator that writes `Data/Plan.lua`. It is curated by hand: when a recipe turns
  up that a special NPC teaches, add it there, or the planner treats it as a trainer recipe.
- Points per craft use the vanilla formula (chance falls from 1 at yellow to 0 at grey); the client's own colour wins
  where it gives one.
