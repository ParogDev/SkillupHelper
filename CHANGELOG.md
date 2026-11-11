# Changelog

## 0.2.1

- The panel leads with the next craft: a card with the recipe's icon, its name in its skill colour, how many to craft,
  the expected points and cost a point, each material with have/need or where to buy it, and the use-your-stock
  alternative. Later steps follow as numbered rows; what to keep, spare stock and stock verdicts sit quietly below.
- A bar under the skill fills toward the recipe's next colour change ("6 to yellow"). The card pulses in the step's
  colour, materials strike through as you use them, and the next step slides in when the skill passes one.

## 0.2.0

- A skill-up planner replaces the "cheapest next step" line. It prices every recipe per skill point with a small effort
  charge per craft (20c, `/skillup effort <copper>`), counts what you own at what it is really worth (the buy price when
  the plan buys more of it, otherwise what it sells for), and lists ordered steps: craft from stock, buy and craft, buy
  a recipe, train, or a gap. Buy steps show the use-your-stock alternative with its extra cost.
- Stock goes where it saves most: a recipe about to turn grey uses its materials first, materials a later step needs
  are kept for it, and surplus is listed as a leftover with what it sells for.
- Prices come from TSM live (AuctionDB synced by the TSM app); `Data/Plan.lua` version 2 supplies the fallback. The
  panel says when the TSM data is over 24 hours old or when prices came from the fallback.
- The plan is recomputed after bag changes, skill changes and craft results.
- `selftest.scans` keeps the last scan of each profession, with the planner's timing, price sources and the client's
  grey threshold next to the exported one.

## 0.1.0

- First version: a panel beside the profession window with the recipes you can craft for skill from bags and bank,
  the cheapest next step of a price plan (`Data/Plan.lua`), and the recipe items worth buying. `/skillup` toggles it.
- Requires TradeSkillMaster; docks to TSM's crafting window or to Blizzard's after TSM's "WoW UI" switch.
