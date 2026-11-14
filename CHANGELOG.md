# Changelog

## 0.2.15

- The Plan tab's buttons (Queue mail, Buy, Craft, Show recipe) sit in a bar at the bottom of the panel and no longer
  scroll away.
- The card's notes fold into one Why line. "+3" opens the rest in place; a new step folds it again.
- A card with more than five reagents shows five and "3 more reagents >".
- Shopping and Alts sections fold with a click on their title, and stay folded. Stock starts folded.
- Click a later step to preview it on the card, with "< Step 3 of 9 >" and Back to now. A preview never crafts or
  buys: its bar reads "Step 1 comes first". Any skill-up returns to step 1.
- Right-click a step for a menu: preview it, Show recipe, Back to now.

## 0.2.14

- The mail queue sends exactly what the plan wants, not whole stacks. When a stack holds more, the mailbox panel's
  button first reads "Split 3 Itemname from 20": that click puts 3 in an empty bag slot. The button then turns into
  Fill, which attaches those 3. Each step is your click, and you still press Send yourself. Splitting needs one free
  slot in a plain bag.

## 0.2.13

- The panel has four tabs under the skill bar: Plan, Shopping, Alts and More. The tab you pick stays picked.
- Plan holds the Next card and every later step; the "and N more steps" cut is gone, the list scrolls.
- Shopping holds the stops by place and city with their total, the Add to AH list button, and a Stock section with
  the Keep, Spare and from-stock lines.
- Alts lists the reagents the plan takes from your other characters, one section per character, with Queue on each
  row and Queue all.
- More holds what the plan is unsure of: price-file coverage, shortcuts and trainer recipes not confirmed yet. A red
  dot on the tab means a trainer visit is due.
- The Next card links to Shopping and Alts ("Shopping: 3 stops, 12s >") instead of repeating them.

## 0.2.12

- Reagents on your other characters count. TSM's inventory tracking says what each alt on your faction and realm
  holds in bags, bank and mail, and the plan uses those units before it buys. A material row says "3 on Altname".
- "Queue mail" on the Next card keeps a list of what each alt should send you. On that alt, at a mailbox, a panel
  beside the mail window lists it. Its Fill button opens Send Mail, writes your name and attaches whole stacks from
  the bags; you press Send. The addon never sends mail by itself. Stacks in the bank or the mailbox are named, not
  attached.
- New files (Alts.lua, MailUI.lua): restart the game client once, a /reload does not load them.

## 0.2.11

- Show recipe is instant when the profession window is open: it selects the recipe in the list instead of asking the
  server to reopen the window. It still asks the server when the recipe is filtered out or TSM's window is up.
- Each "Other way" on the Next card has a Use this button: the plan crafts that recipe wherever it would have crafted
  this one. The step then says it is your choice and offers Back to, which lets the plan pick again.
- In an instance, where the game hides recipe colours, the scan no longer reads them; the selftest now lists the
  learned recipes it could not plan, by reason.

## 0.2.10

- Every recipe you know joins the plan, read from the game: a pattern learned after the price file was made, or a
  whole profession it never covered (First Aid, Tailoring and the rest). The plan changes the moment you learn one.
- For those recipes the game gives the grey level but not where they turn yellow: the plan starts from a usual gap
  and tightens it with every colour the game shows as you level.
- The price file is now optional: without one, the plan runs on the game's recipes and TSM's live prices.
- At your cap the Next card says why nothing is planned. Poisons, now in the price file, rises 5 per character level.

## 0.2.9

- The plan uses only recipes you can surely get: known, taught by a trainer you opened, auto-learned, or a pattern
  with a price. A trainer recipe no trainer you opened lists (often a quest reward) is no longer planned at a 10%
  penalty; like a special NPC's recipe, it becomes a shortcut.
- Shortcuts show on the Next card where they save money or fill a gap, with what they need, and two buttons: Use it
  (plan with it; `/skillup allow <spellID>` toggles) and Hide. Later rows say "· shortcut", the footer counts them.
- Before you open a trainer of the profession, the footer says how many trainer recipes are unconfirmed; the first
  trainer visit replans.

## 0.2.8

- The Next card has a guide strip: the guide chip's arrow, the place and the distance on one line under the card's
  notes, and "Then: auction house" (or the trainer) when the step needs a second stop. Click it to pin the place on
  your map; the chip pings so you can find its Target button. With the merchant open and a Buy button on the card
  it says only "You are here".
- The shopping list is grouped by city. The vendor block splits per town, and the city whose nearest stop is
  closest comes first, with trainer, vendor and auction house in that order inside it. Block titles name the city
  ("Vendor, Crossroads: 10c").
- Vendors, trainers and auctioneers you open are remembered with their town.

## 0.2.7

- The planner knows your profession's ranks. At a profession trainer the addon reads each rank (Journeyman, Expert,
  Artisan...) with its skill, level and cost and keeps it; until then those show "unknown". A plan that runs into
  your cap gets a "Train Expert" step at a convenient point before it, never in the middle of a craft run. A rank
  your character level can't train yet stops the plan with a message. `/skillup ranks` lists what was read.
- No more one-craft detours: a single point of another recipe between two runs of the same recipe is folded in.
- Purchases are grouped by place: one trainer block, one vendor block and one auction house block, in travel order.
- At the auction house the AH list becomes buy rows: one click to buy (commodities ask for a confirm click with the
  live total), patterns at the cheapest buyout. Sold out or overpriced rows say so.
- "Other ways" on a step lists alternatives with their extra cost. `/skillup exclude dungeon|ahpatterns|special|<spellID>`
  keeps routes you don't want out of the plan.
- Recipes taught by special NPCs (a dungeon teacher, for example) are no longer planned as trainer visits, and are left
  out unless you enable them (`/skillup exclude special`). A trainer recipe not yet seen at a trainer is marked "not
  checked" and loses near ties.
- Show recipe works on every learned craft row, not only the Next card.
- One AH trip for the stretch ahead: when a step needs the auction house, the card lists every AH buy up to the next
  trainer visit, patterns included, with one total. "Add to AH list" keeps the list.
- Buys cover a bad-luck run. A step buys for the 90th percentile of the crafts it takes, so a run of failed
  skill-ups no longer sends you back to the AH. `/skillup luck <50|75|80|90|95|99>` changes it.
- Materials a later step needs are never offered for something else ("Or use stock", the from-stock list, a replan).
- A step on your AH list keeps its recipe and target until you reach it or it turns grey.

## 0.2.6

- A guide chip says where to go for the step to do now: the nearest vendor that sells its materials, the
  profession's trainer, or an auction house. An arrow turns with you and the distance counts down; it stays up with
  the profession window closed. Click it to pin the place on your map (click again to remove the pin), right-click
  for "Stop guiding this step", "Lock position" and "Reset position", drag it to move it.
- "Target <name>" under the chip targets the NPC once they are in sight and, when you play solo, puts a star on
  them. It is your click on a secure button; it keeps working in combat.
- Horde trade supply, cooking and Leatherworking NPCs and auctioneers ship as approximate starting points. Every
  vendor, trainer and auctioneer you open is remembered with where it stands and what it sells, and replaces the
  starting point.

## 0.2.5

- The Next card buys its vendor reagents. When a step needs something a vendor sells ("buy 7 Hot Spices"), a Buy
  button above Craft shows the count and the price. It works while a vendor that sells the item is open, in WoW's
  merchant window and in TSM's vendoring window. It buys exactly what the step is short of, in whole vendor lots.
  It stays off and says why when no open vendor sells the item, your gold is short or your bags are full.

## 0.2.4

- `/skillup recipes off` plans only with recipes you know or can train, no recipe items to buy. `/skillup recipes on`
  brings them back.
- A bag change that moves none of the plan's materials no longer reruns the plan.

## 0.2.3

- The Next card no longer vanishes when two skill-ups come close together.
- A step never claims stock you no longer have: once an earlier step has used it up, the step says to buy instead.
- The Craft button counts every material of a recipe, also those past the eighth row the card shows.
- A product that sells for less on the auction house than at a vendor is always planned as vendored.
- A changed `sellShare` setting takes effect at once instead of after the five-minute price refresh.
- Switching between the TSM and WoW profession windows redraws the card for the window now in front.

## 0.2.2

- The Next card can act on a recipe you know. "Craft 3" casts the step's crafts, as many as your bags allow now; when
  nothing can be crafted yet the button says what to do first ("Buy 7 Gray Dye first"). Beside the WoW profession
  window, "Show recipe" selects the recipe there.
- Hiding the panel leaves a small tab in the same spot; click it to bring the panel back. `/skillup` still toggles it.
- Beside the WoW profession window the panel now stands clear of the profession tabs on the window's right edge.
- The panel is as tall as what it shows. The scroll bar appears only when the plan is longer than the window.

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
