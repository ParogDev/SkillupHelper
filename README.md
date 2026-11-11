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

Requires TradeSkillMaster. The panel docks to TSM's crafting window, and to Blizzard's window after you press TSM's
"WoW UI" button; it follows you when you switch. It finds TSM's window through `TSM_API` only and never changes TSM's
frames. TSM's API cannot add to its crafting queue, so there is no "queue these" button.

Only WoW: Forever (interface 16001) is supported.

## Planner rules

Three rules hold for every plan, every replan and every alternative the panel offers:

1. **Buy for bad luck.** A step that buys reagents buys enough for a bad-luck run: the 90th percentile of the crafts
   it takes to reach the step's target, not the average. The card says "usually N crafts, up to M". A lucky run ends
   early and the spares count as stock for later steps. `/skillup luck 95` changes the percentile (50, 75, 80, 90, 95
   or 99).
2. **Earmarked materials stay put.** A material a later step needs is never offered for something else: not as "Or use
   stock", not in the from-stock list as "ok", and not by a replan. Only true spares are offered.
3. **A bought step holds.** Once a step is on your AH list, its recipe and target hold until you reach the target or
   the recipe turns grey. A replan after a skill-up or a price change never switches or shrinks it.

## Limits

- Bank counts are what the client remembers from your last bank visit.
- Points per craft use the vanilla formula (chance falls from 1 at yellow to 0 at grey); the client's own colour wins
  where it gives one.
