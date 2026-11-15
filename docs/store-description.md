# Store listing (CurseForge, Wago)

## Short description

Levels every profession to 300 for the least gold: the next craft, the cost to 300, and where to farm. WoW: Forever.

## Description

Skillup Helper plans your professions for WoW: Forever. It needs TradeSkillMaster for prices.

**At the profession window** a panel says what to craft next, how many, what to buy, from whom, and what it costs.
It counts what is in your bags, bank and, through TSM, on your other characters. It buys for a bad-luck run, never
spends materials a later step needs, and keeps a step you already bought for.

**The journal** shows every profession on one page: your skill, what reaching 300 costs from there in materials,
recipes and training, and any skill range the addon cannot plan, with the reason. Pick one for its whole path on a
timeline, step by step.

**Gathering and Lockpicking.** For Mining, Herbalism, Skinning, Fishing and Lockpicking the Where page ranks the
places that still give points at your skill, with the route, mob levels and the nearest flight point. Track a spot
and a small tracker walks you round the loop.

Opens from a button on the panel, the addon menu by the minimap, a key binding, or `/skillup journal`.

### Beta, and what is not confirmed

- This is a beta. The journal, the map and the tracker are new in 0.3.0.
- Gathering and Lockpicking positions come from Classic data and are marked "Classic position" until checked in
  Forever. The colour bands of nodes and locks follow the vanilla rule. Your game counts gathers and skill-ups as
  you play, and you can share that file to correct them.
- Without TSM auction data, costs count vendor items only.

## FAQ

**Does it work without TradeSkillMaster?** No, TSM is a required dependency. Without TSM price data it still plans
paths, gaps and places; auction costs are missing until TSM has data.

**Why does a profession show a gap?** No recipe the addon can plan gives skill there. The row says why: usually a
recipe you must buy or one taught by a special NPC. Turn on "Plan special teachers" or buy the recipe.

**The plan says a trainer recipe at the wrong skill.** Open the trainer once. The addon keeps what the trainer
shows, and that wins over the shipped data.

**Can I change the plan?** Yes. `Data/Custom.lua` (copy `Data/Custom.example.lua`) changes recipes, vendors, NPCs and
places, and survives updates.

**Is it Classic Era?** No. Forever only (interface 16001).

**Does it send keys or click for me?** No. Every craft, buy and mail is your click.

## Credits

- Recipe and world data: the WoW: Forever client tables via wago.tools; facts from Wowhead's Forever section.
- Places and trainer positions: derived from the cmangos classic-db (GPL-3.0, notice in `LICENSES/`).
- Prices: TradeSkillMaster.
- Code: MIT.
