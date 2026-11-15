# Changelog

## 0.3.3

- The TOC no longer lists `Data\Custom.lua`, a file nobody ships, so its load warning is gone from every start.
  Your own changes now go in a small addon folder of your own, `SkillupHelper_Custom`: copy it from `extras/` next
  to `SkillupHelper`, edit its `Custom.lua`, restart the game once. An update of Skillup Helper never overwrites it.
  The shape is unchanged (`Custom.example.lua` in the same folder). A `Data/Custom.lua` left in the SkillupHelper
  folder is no longer read: move its table into the new folder's `Custom.lua` as `SkillupHelper_Custom = { ... }`.

## 0.3.2

- The guide knows which trainer rank teaches a recipe. A trainer teaches the recipes learned below the next rank's
  training skill: a Journeyman trainer up to 124, an Expert up to 199, an Artisan the rest. Hillman's Shoulders
  (learned at 130) now points at Arthur Moore, the Expert next to Dan Golthas in Undercity, not at Dan Golthas.
  When every trainer the guide knows is below that rank, it says "needs an Expert Leatherworking trainer or
  better". A trainer's own list, read in full, still wins over its rank.
- The guide card names the trainer's rank ("Expert Leatherworking trainer").
- Opening a trainer no longer re-reads its list on every frame while the window is open: reading stops once the
  whole list is in, or after six tries. A failed read always puts the trainer window's filters back.

## 0.3.1

- A step that crafts a reagent first (Cured Medium Hide from your own Medium Hide and Salt) gets a working button:
  "Craft 8 Cured Medium Hide first" makes the reagent, and Show recipe opens its recipe. Once the bags hold enough,
  the button crafts the step itself. Before, the button only named the reagent and could not be clicked.

## 0.3.0

- Recipes are ranked by what you pay: materials plus effort. Selling what you craft no longer makes a dearer recipe
  look cheap (at Blacksmithing 55 the plan picked Coarse Grinding Stone over Rough because it counted selling all
  37). Turn on "Count selling what I craft" (Settings and data, or `/skillup resale on`) to count it
  again; with it off a step says what selling would bring, without counting it.
- Mining: where no smelting recipe gives points (about 140 to 155 and 185 to 300), the plan shows "Mine nodes"
  stretches from the node route, at no gold cost, instead of a red gap; on the panel strip, in the Next lines, in
  the journal and in `/skillup cost mining`.
- The mailbox panel on an alt turns pages instead of growing past the screen.
- The price diagnostics count an item with no price as missing, not as a live TSM price.
- Nothing scrolls. The panel at the profession window shows what to do now, the next three steps and a strip of
  the whole path; its tabs are gone, and shopping, alts and settings are journal pages. The journal's Path page
  shows one stretch of the path at a time (pick it on the timeline or with Previous and Next), Overview is a grid
  of cards, and long lists turn pages.
- "Learn X" followed by "Craft X" is one step ("Learn and craft 43 Copper Dagger"). Rank training is shown with the
  stretch it unlocks, with its skill and cost. Steps are numbered without breaks.
- A minimap button: left-click opens the journal, right-click a menu, drag moves it. `/skillup minimap` or
  Settings and data hides it. Bar addons that use LibDataBroker get a "SkillupHelper" launcher.
- Windows stay sharp wherever you drag them: every window sits on whole screen pixels.
- A trainer window read at a low skill no longer hides the trainer's later recipes; that left a false "nothing
  from 185 to 215" for Blacksmithing. An item without a price never makes a gap: the step is planned and says
  "price unknown for N items".
- The guide knows every shipped trainer and recipe vendor for your faction, nearest first, and no longer says
  "No known trainer yet" when one is in the data.
- A journal window with six pages. Overview lists every profession with your skill, the cost to 300 in materials,
  recipes and training, and each skill range the addon cannot plan, with the reason. Path lays one profession out
  from 1 to 300 on a timeline with its steps. Where ranks the places to level Mining, Herbalism, Skinning, Fishing
  and Lockpicking at your skill, with the route, mob levels, flight point and map. Shopping, Alts and mail, and
  Settings and data hold the rest.
- Open it with the new button on the panel (it pulses once after an install or update), the addon menu by the
  minimap, a key binding (Key Bindings > AddOns), or `/skillup journal`. `/skillup` with no profession window open
  opens it too; with one open it still shows or hides the panel.
- "Track this spot" on the Where page puts a small tracker on screen: next stop, distance, an arrow, the stops
  done. A click opens a card with the map. The spot is kept per character. While it shows, the guide chip steps
  aside, so only one of them is ever up.
- The Mining window gets a card under the panel with the best node spot for your skill.
- Every slash-command setting is a control on the Settings page and writes the same setting.
- Without TradeSkillMaster auction data the journal says what to do; costs then count vendor items only.
- Where to level world skills (`Data/Spots.lua`) and every trainer and recipe vendor (`Data/Trainers.lua`) ship with
  the addon. Positions come from Classic data and are marked so until checked in Forever.
- Gathering and picking locks near a mapped spot is counted (tries and skill-ups, in `learned.skillups`), so shared
  files can correct the unconfirmed colour bands.
- `Data/Custom.lua` can add, correct or leave out spots and trainers (`spots`, `trainers`).
- `AGENTS.md` explains the folder, the data and how to change a plan, for AI assistants;
  `docs/first-launch-checklist.md` lists what the game still has to confirm.
- The addon now ships the recipes of every profession (`Data/Recipes.lua`): thresholds, reagents, the skill needed
  to learn each recipe and what the trainer charges. It plans any profession out of the box; no file from a PC tool
  is needed. Prices still come from TradeSkillMaster in game.
- A trainer recipe is planned from the skill where you can learn it, through its orange range, with a Train step
  that shows the price. Open your trainer once and the addon keeps the skill each recipe asks for.
- Until a trainer is read, the plan assumes the usual ranks (75, 150, 225, 300) and runs past your current cap.
- Recipe items: one you can buy is planned from TSM's price, or from its vendor when the data names one and that is
  cheaper. One with no auction price today, one that binds when picked up, and a recipe not confirmed obtainable
  are shown as shortcuts that say why, with Use it and Hide.
- `/skillup cost` prints what levelling each profession to 300 costs at today's prices, the skill ranges nothing
  covers, and how many prices TSM lacks. `/skillup cost tailoring` prints one.
- `Data/Custom.lua` holds your own changes: a recipe's learn skill, source or reagents, a recipe to leave out,
  vendor reagents, guide NPCs. `Data/Custom.example.lua` shows the shape. A bad entry is named in chat and left
  out; the rest applies.
- The "TSM data age unknown" line is gone: the age is only shown when it is known.
- For maintainers: `tools/gen_recipes.py` rebuilds the data from the wago.tools export of the client
  (`--check` lists uncovered skill ranges), with `tools/data/overlay.json` on top.
- A recipe sold by a vendor now says where: "sold by Kelsey Yance in Stranglethorn Vale".
- What your game teaches the addon (what trainers ask, what vendors sell and for how much, where the trainers and
  vendors you opened stand, the skill at which a recipe changed colour, how often a craft gave a point) is kept in
  one table of the saved file, `learned`. It holds no character, realm, account or guild name. You can share it
  with a "Share what my game learned" issue so the shipped data gets it; `docs/data-sources.md` lists everything
  the addon saves and what stays private. Your saved trainer ranks and learned NPCs move into it on first load.
- For maintainers: `tools/update_data.py` looks for a newer game build every day (the `data-update` workflow),
  regenerates the data and opens a pull request with a report of what changed. `tools/import_savedvars.py` merges
  shared files under a written rule (a newer build wins, otherwise two files must agree, conflicts are reported).

## 0.2.17

- A step whose reagent you can craft from something in your bags crafts it instead of buying it: with Medium Hide
  in your bags, Hillman's Shoulders says "Craft 2 Cured Medium Hide first" and puts Salt on the vendor list rather
  than buying Cured Medium Hide on the AH. Before, the planner only took that route when crafting the reagent from
  bought materials was 20% cheaper than buying it.

## 0.2.16

- The More tab has controls for the planner's options: "Buy for bad luck" (50% to 99%), "Effort per craft" with - and
  +, "Suggest recipes to buy", "Count reagents on my other characters" (new) and the recipe sources (dungeon and AH
  patterns, special teachers). They write the same settings as `/skillup luck`, `effort`, `recipes` and `exclude`.
- More also lists the shortcuts in use (Stop using) and the hidden recipes (Offer again).
- The card's "Use this" rows and shortcut rows become one "Way: X" button. Its menu lists the other ways cheapest
  first, the stock option and each shortcut with Use it / Hide; a switched step shows "your pick" and "Back to X".
- Right-click a step, then "Ways...", to switch that step's recipe without previewing it.
- A Shopping block whose items are all in your bags folds itself and says "covered".

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
