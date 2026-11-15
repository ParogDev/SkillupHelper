# First launch: what the game must confirm

Nothing in 0.3.0's journal, field card, tracker or world-skill code has run in the game yet. The tests run it
against a mock, which proves the code runs and nothing about how it looks or what the client answers. Go through
this list in order on the first launch. Each item names its automatic evidence in `SkillupHelperDB.selftest`
(written on `/reload` and logout) where there is one.

Start: restart the game (new files), log in, `/reload` once, log out or `/reload` again so the selftest is written.

| # | Check | How | Evidence in the selftest |
|---|---|---|---|
| 1 | The addon loads with no Lua error | BugGrabber shows nothing from SkillupHelper | `journalWiring.firstError` is nil; `journal.lastWhy` is nil |
| 2 | One chat line on first login, the panel's journal button pulses | log in, open a profession | `journalWiring.openButton` true |
| 3 | The compartment entry and its tooltip | the addon menu by the minimap | `firstLaunch.compartment` true |
| 4 | The key binding is listed under AddOns and can be set | Key Bindings, or Settings and data > Key | `firstLaunch.bindingName` true; `firstLaunch.bindingKey` |
| 5 | `Bindings.xml` loads without being in the TOC | item 4 shows the entry | as item 4 |
| 6 | The skill api answers for Lockpicking and the gathering lines | journal Overview shows ranks, not "unknown" | `firstLaunch.skillApi` true; `skills["633"].source` is "skill api" |
| 7 | The journal opens from all four entry points and closes with Escape | button, compartment, key, `/skillup journal` | `journal.opened` counts |
| 8 | Escape with the profession window open closes the journal first | | |
| 9 | Strata against TSM's windows: the journal is on top | open both | |
| 10 | Map art: `GetMapArtLayers` / `GetMapArtLayerTextures` return art for vanilla zones and cities | Where page of any world skill | `firstLaunch.mapArtMissing` false; `where.mapDiag.artMissing` lists maps without art |
| 11 | Addon code may `SetTexture(fileID)` the tiles | the map shows terrain, not the plain grid | `firstLaunch.tileFailures` 0 |
| 12 | The base layer is whole where the zone is unexplored | look at an unexplored zone | |
| 13 | `SetRotation` turns a square into a diamond; a `Line` takes a dashed texture | loop stops on cards are diamonds | |
| 14 | `OpenWorldMap(map)` from the journal button, in and out of combat | "Open zone map" | `journal.lastWhy` names a refusal |
| 15 | Pin on the map sets a waypoint and super-tracks it | "Pin on the map" | `journal.lastWhy` |
| 16 | Cave and micro-dungeon maps: art and `GetPlayerMapPosition` | a spot inside a cave | `where.mapDiag` |
| 17 | `SetGradient` on a white texture for the scrim | the map's caption strip fades | `where.mapDiag.scrim` |
| 18 | Text fits at UI scales 0.64 to 1.0 | Overview rows, timeline labels, caption strip | |
| 19 | Track this spot: tracker appears, arrow turns with you, distance falls | Where page, a gathering skill | `journalWiring.tracked` true; `journal.field.ticks` rising |
| 20 | The guide chip steps aside while the tracker is shown and returns after "Stop" | track a spot during a crafting step | `journalWiring.chipYields` |
| 21 | The tracker survives `/reload` and a zone change, per character | | |
| 22 | Mining window: the where-card shows under the panel | open Mining (smelting) | `journalWiring.panelCard` is 186 |
| 23 | World tries are recorded: Pick Lock, Mining, Herb Gathering and Skinning spell ids are right for Forever | gather a few nodes near a mapped spot | `journalWiring.worldTries.recorded` rises; `.event` is "registered"; `.last` names a target or why not |
| 24 | Prices: with TSM data the status line reads "Prices: TradeSkillMaster, live." | journal | `firstLaunch.prices` true |
| 25 | Without TSM data the status line says what to do | a character on a fresh TSM install | `firstLaunch.prices` false |
| 26 | Overview costing does not stall the game | open the Overview with the cache empty | `journalWiring.costMaxMs` (test machine: about 130 ms per profession, one per frame) |
| 27 | Vendor price capture (`C_MerchantFrame.GetItemInfo`) | open a vendor | `learned.vendors` has the NPC; GuideUI status `lastVendor` |
| 28 | Craft skill-up counting (`UNIT_SPELLCAST_SUCCEEDED`) | craft a few at the window | `learned.skillups[line]` grows |
| 29 | Recipe colour recording | open a profession window | `learned.colors` grows |
| 30 | Settings page: every control changes the plan as its slash command does | flip each, watch the panel | |

Items 27 to 29 come from the data-freshness work (`Learned.lua`); they have not run in game either.

Report what fails with the selftest block and the BugGrabber text. Each failure names its broken link: an api that
answered nothing, a secret value, a texture refused.
