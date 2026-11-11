# Skillup Helper

A panel on the right of the profession window that answers "what do I craft next to level this?":

- **Craft now from bags + bank**: every learned recipe that still gives skill and that you can make from what you carry
  and what sits in your bank, orange first, with how many crafts you have the materials for and roughly how many points
  that is. Vendor reagents (thread, spices, dyes, vials) count as always available; the line says how many to buy.
- **Cheapest next step**: the recipe a price plan picks for your current skill, how many crafts are left in that stretch
  and which materials you are still short of.
- **Recipes worth buying**: recipe and pattern items the plan buys, with the price and whether you can learn them yet.

The live list needs nothing else. The plan comes from `Data/Plan.lua`, a file written on your PC from your auction house
prices (the maintainer's tool, not shipped); without it the panel says so and shows the live list only.

`/skillup` shows or hides the panel.

Only WoW: Forever (interface 16001) is supported.

## Limits

- Bank counts are what the client remembers from your last bank visit.
- Points per craft use the vanilla formula (chance falls from 1 at yellow to 0 at grey); the client's own colour wins
  where it gives one.
