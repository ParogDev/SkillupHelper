# The journal, the field card, the tracker and the map view

Four new files draw the "what to do and where to go" design. They draw view-models and report clicks. They compute
no plan and write no sentence: text comes from `Where.lua` and `View.lua`.

| File | Module | Holds |
|---|---|---|
| `Widgets.lua` | `ns.Widgets` | palette, text, buttons, pools, chips, band bars, yields, legs, stops, paged lists and areas, pixel snapping, controls |
| `MapCanvas.lua` | `ns.MapCanvas` | the map view at any size |
| `FieldUI.lua` | `ns.FieldUI` (`ns.Field`) | the where-card, `SkillupHelperField`, `SkillupHelperTracker` |
| `JournalUI.lua` | `ns.JournalUI` (`ns.Journal`) | `SkillupHelperJournal`, six pages, the provider, the globals |
| `Bindings.xml` | | the key binding `SKILLUPHELPER_JOURNAL` |

Nothing is created at login. The journal, each page, the field card and the tracker are built on first use.

## Surfaces

**Journal**, 960 x 640, strata HIGH, toplevel, clamped, moved by its 40-px title band, closed by Escape
(`UISpecialFrames`) and, unless `journal.closeInCombat` is false, by `PLAYER_REGEN_DISABLED`. It has no scale of its
own (a fractional scale breaks font hinting) and sits on whole physical pixels: `W.snap` after the saved point is
restored, on every show and after a drag (`W.dragStop`). Title band: name, the profession dropdown, the breadcrumb
(the selected line on Path, the spot on Where, nothing when it would repeat the profession), the client's
`UIPanelCloseButton` (a drawn X when the template is refused). Then the page strip (six tabs; a count only with its
noun in the tab's tooltip and never on Overview; warn pip), the 936 x 512 body, a status line and the key hint (a
click target that opens Settings and data).

**Nothing scrolls.** No scroll bar, no slider that moves content, no mouse-wheel handler, no clipped row that cannot
be reached. Content longer than its box is split into pages at item boundaries with a pager ("Previous / 1 to 8 of 21
lines / Next"): `W.list` for rows, `W.items` and `W.flow` on a `W.pages` area for laid-out pieces. A hand-laid page
calls `:SetContentHeight(total)`; a total over the box increments `W.overflow.count` (in `J.diag().overflow`), which
the tests hold at zero for every fixture and for a worst case.

The brief asked for a left rail. The design spec and its mockup use a top strip and lay every page out on a 936-px
body (the timeline is 3 px per skill point). I kept the strip. Navigation is built in one place (`tab`, `paintTabs`,
`create` in `JournalUI.lua`) if that is to change.

| Page | Draws | Notes |
|---|---|---|
| Overview | `overview` | filter (Mine, All, Crafting, Gathering) and sort (Name, Skill, Cost) are the frame's own, saved in `journal.filter` / `journal.sort`. A grid of cards, 3 columns by 6 rows (306 x 75, 18 professions on one page): icon, name, skill, rank bar with cap ticks, `costText`, `coverText`; gap reasons, unpriced items and the cost breakdown in the tooltip. Click opens Path. |
| Path | `path` | timeline card (128: caps, gates, markers, band segments, hatched gaps, now-line, the shaded stretch, a legend row of the real marker shapes; every edge snapped with `W.px`; a click selects that line), the stretch bar (34: Previous, one button per stretch, Next), then the lines of one stretch (568 wide: a header of 22 + up to two 16-px rank lines, at most `Where.PATH_MAX` = 6 rows of 46 px in a 338-px box) beside the detail (356 wide: Do this, Get the recipe, one paged list of Materials and Other ways, the 330 x 72 map when it fits, buttons). No "N ways" button in a row. |
| Where | `whereList` | left column: the selected spot as a card with its yields, then one paged list: the other spots (62 px, "1 to 3 of 24 spots") or, by a two-segment control, the route `itinerary = { title, rows = { { range, title, sub, key, tone } } }` in its place. The 628 x 430 map (no wheel: its own two-segment control switches the view), the caption strip with the live line and up to three buttons. |
| Shopping | `shopping` | `items` or `blocks` as `V.shoppingItems` rows on a paged area. Side (a flow that pages): total, errand map, Open in Where, stock. |
| Alts and mail | `alts` | `items`, or `groups` through `V.altsItems`, or `characters`, paged. Side: `queue` (`V.mailPanel`), `howto`, `countAlts = { text, on, action }`. |
| Settings and data | `settings` | three columns that page on their own. Planner kinds: `dropdown`, `slider` (`min`, `max`, `step`, `format`), `stepper`, `check`, `list`, `link`, `key`. Data rows with a state pip and each error on its own line. Learned lists with Show (every row, paged in the column) and a Reset that asks once in place. `explain = { lines }` replaces the built-in "How the plan is made" text. |

**Docked panel**, `SkillupHelperPanel` (`UI.lua`, text from `View.describe`), 316 wide beside the profession window:
the at-a-glance surface. It has no tabs and never scrolls. Top to bottom: header (36); the path strip (34: one 8-px
bar of the whole path from 1 to 300, a segment per plan line, the done part dimmed, a hole in the warn colour with
an edge, cap ticks, the now-marker; hover names the line, a click opens it in the journal); the card of what to do
now (`d.now`: action and count, skill range and colour, why, where to go, what it costs, link lines for Shopping
and Alts that open those journal pages, the guide strip); the action bar; "Next" with up to three lines
(`d.next.entries`, from `Where.lines`: "Learn and craft 43 Copper Dagger, 84 to 96", wrapped, never cut); and
"Open the journal: N more steps". Its height follows its content up to the profession window's height: `V.fit`
leaves out whole pieces (the third next line first), never part of one, and reports `overflow` in `selftest.ui.fit`.
Settings live in the journal only. The auction-house list pages five rows.

**Plan lines.** `Where.lines(steps)` is the one place that turns planner steps into what a person reads, for the
panel and the journal: "Train X" or "Buy recipe X" directly before "Craft X" is one line, a rank training hangs on
the line it comes before (`line.rank`) and is shown with the stretch it unlocks, numbers are continuous, and a line
carries the names of its unpriced items. `Where.stretches(rows, caps, skill, max)` cuts the lines at the rank caps
and then into parts that fit the list.

**Minimap button**, `SkillupHelperMinimapButton` (`FieldUI.lua`, menu and tooltip from `Journal.lua`), a child of
`Minimap`, made at login. Drag moves it round the edge (`F.minimapOffset`, round and square minimaps through
`GetMinimapShape`); the angle is saved in `ui.minimap = { angle, hide }`. Left click toggles the journal; right
click opens a menu (open the journal, show or hide the panel, track or stop tracking, settings, hide this button);
the tooltip shows the tracked step. "Show the minimap button" on Settings and data and `/skillup minimap` bring it
back. No library is bundled; when LibDataBroker-1.1 is loaded by another addon a launcher object "SkillupHelper" is
published for bar addons. The addon-compartment entry stays.

**Whole pixels.** A window on a fraction of a screen pixel draws text and 1-px rules differently at every position.
Every window (journal, panel, field card, tracker, guide chip, minimap button) is put on whole physical pixels by
`W.snap` (size, then the top-left corner, by shifting the offsets of its one anchor) after a drag (`W.dragStop`),
on show, after a saved point is restored, and on `UI_SCALE_CHANGED` / `DISPLAY_SIZE_CHANGED`; saved points are the
snapped ones. Frames and regions round their own layout (`SetRoundLayoutToNearestPixel`; `W.roundAll` for trees
made elsewhere), and computed positions (timeline edges, strip segments, bars) go through `W.px`.
`selftest.pixels` counts snaps and names the last refusal.

**Field card**, `SkillupHelperField`, 316 wide: title, skill, fold button, runway, the where-card, up to three
action buttons. It sits under the tracker when the tracker is shown (above it when there is no room), else at its
saved point. `F.newCard(parent)` returns the same 296-px card for the docked panel.

**Tracker**, `SkillupHelperTracker`, 236 x 60: arrow, title, distance, what, gain, the bar (`band`, `ticks`, `steps`;
over 20 ticks a plain bar), mobs. Left click toggles the field card, right click opens the menu, drag moves it unless
locked. With `vm.target` a 26-px drawn Target row hangs under it.

**Map view**, `MapCanvas.new(parent, w, h, opts)`, used at 292 x 132, 330 x 92, 314 x 180 and 628 x 430. Three frames
per view (clip, canvas, top) whatever the point count; with `opts.journal` also the mode and floor buttons.

| k (screen px per layer px) | `mapMode` | Drawn |
|---|---|---|
| up to 2 | `map` | tiles, desaturation .35, ink .28 over them |
| 2 to 4 | `soft` | tiles, desaturation .7, ink .50 |
| over 4 | `plan` | no tiles, field ground, north mark, yard scale |
| no art from the client | `grid` | parch .10 ground, lines every 5 map units (10 when crowded) with numbers, tag "map art missing" |
| a tile the client refuses | `plan`, then `grid` | the map is marked artless for the session; the reason is in `diag` |

Marks: area disc with a 24-segment outline (every other segment for unconfirmed), lead-in dashed (48 dashes per view,
then one solid line at half alpha), loop stops as numbered discs in the journal and diamonds on cards, grey points
dimmed, locked points hollow with a warn edge, chevrons on segments of 40 px or more, next-stop ring, visited ticks,
other-floor stops hollow, stairs marks, errand stops joined by dashes. Colour never stands alone: stops carry
numbers, yields and ranges carry the band letter (O, Y, G), gaps are hatched, unconfirmed marks are hollow or broken.

Deviation: journal loop stops are 16-px discs, not 10. A two-digit number does not fit in 10 px.

### Cost while shown, and nothing while hidden

Each map view has one `OnUpdate`, throttled to 10 Hz. A tick is one `C_Map.GetPlayerMapPosition`, one
`GetPlayerFacing`, two distance sums, one provider call, and about ten setters (arrow, bearing line, distance chip).
The marks are rebuilt only when the signature changes (model, mode, floor, next stop, visited set). The tracker eases
its arrow every frame (one setter) and calls `provider.trackerLive` at 10 Hz. `OnUpdate` does not run on a hidden
frame, so a closed journal, a folded card and a hidden tracker do no work. Hover scans on the map and the timeline
run only while the mouse is over them; a settings slider's drag only while the button is down.

Worst case for a 60-point loop in the journal: 60 lines, 64 discs (each a texture and a mask), 61 font strings.
A second draw of the same loop creates nothing. The test asserts both.

## Provider contract

`ns.JournalUI.provider` is one table of callbacks. All are optional; a missing one is listed in
`JournalUI.diag().missing`, a failing one in `lastWhy`, and the page shows its empty state.

| Callback | Called | Returns |
|---|---|---|
| `journal(ctx)` | every refresh | `{ tabs, professions, profession, status, crumb }` (`Where.journal`) |
| `page(name, ctx)` | every refresh | that page's view-model; `ctx = { page, profession, step, spot }` |
| `context()` | the open-journal button | `{ profession, step, spot }` of the docked panel |
| `live(where, live)` | 10 Hz per shown map | strings `{ dist, line2, line3 or visitedLine, hidden }`; may write `nextIndex`, `floor`, `visited`, `legsDone` into `live` |
| `trackerLive(vm)` | 10 Hz while the tracker shows | `{ title, right, rightTone, angle, ticks }` |
| `selectProfession(key)` | overview row, dropdown | |
| `selectStep(step, action)` | step row, timeline | |
| `selectSpot(key)`, `trackSpot(key)` | spot row, itinerary row | |
| `chooseWay(action, owner)` | "N ways" (`id = "wayMenu"`, owner is the button), a way row (`swap`, `useWay`) | |
| `shortcut(action)` | `allow`, `hide`, `shortcut` | |
| `setting(key, value, action)` | every control | |
| `waypoint(where, pin)` | `pin` | `ok, why`. Absent: `JournalUI.setWaypoint(map, x, y)` |
| `openMap(map, where)` | `openMap` | `ok, why`. Absent: `OpenWorldMap(map)` |
| `resetLearned(id)` | after the in-place confirm | |
| `bindKey(key)` | after the key press | `ok, why`. Absent: `SetBinding` + `SaveBindings` |
| `act(action, owner)` | any other id (`showRecipe`, `fillGap`, `buy`, `mailQueue`, `section`, ...) | Absent: `ns.UI.act` |

The canvas' `live` is `{ ok, why, x, y, facing, onMap, yards, bearing (degrees clockwise from north), compass, mode,
shown }`. After every action the journal calls `refresh()`, which does nothing while it is hidden.

Entry points: `JournalUI.open(page, { profession, step, spot })`, `Toggle(page)`, `close()`, `refresh()`,
`setPage(name, vm)`, `setState(table)`, `newOpenButton(parent)`, `diag()`, `page(name)`, `frame()`.
`FieldUI.show(vm)`, `update(vm)`, `hide()`, `toggle()`, `setTracker(vm or nil)`, `targetAnchor()`, `newCard(parent)`,
`diag()`. Field view-model: `{ title, skill, color, runway (0 to 1), where, actions }`.

State (`setState(SkillupHelperDB.ui)`), plain fields: `journal = { point = { point, x, y }, page, profession,
closeInCombat, filter, sort }`, `where = { mode }`, `field = { open, point }`, `tracker = { point, locked }`; it reads
`collapsed`.

## What the integrator wires

1. TOC, after `View.lua` and `Where.lua`, before `UI.lua`:
   `Widgets.lua`, `MapCanvas.lua`, `FieldUI.lua`, `JournalUI.lua`. `Bindings.xml` is not listed (Blizzard's own
   addons do not list theirs). New files mean a client restart.
2. TOC fields: `## AddonCompartmentFunc: SkillupHelper_OnCompartmentClick`,
   `## AddonCompartmentFuncOnEnter: SkillupHelper_OnCompartmentEnter`,
   `## AddonCompartmentFuncOnLeave: SkillupHelper_OnCompartmentLeave`. `## IconTexture` is already there.
3. `Core.lua`: `ns.JournalUI.setState(db.ui)` after the saved data loads, fill `ns.JournalUI.provider`, and put
   `ns.JournalUI.diag()` in the selftest (`selftest.journal`, `selftest.where = diag().where`).
4. `UI.lua`: `ns.JournalUI.newOpenButton(f)` at `TOPRIGHT -29, -7`, left of the hide button; move `f.skill` to
   `-56`.
5. `GuideUI.lua`: when `ns.FieldUI.targetAnchor()` is not nil, lay `SkillupHelperGuideTarget` over it
   (`SetAllPoints`, out of combat, queued to `PLAYER_REGEN_ENABLED` as today). The row redraws its label on each
   tracker tick and reads "Target after the fight" in combat. No secure frame is created in these files.
6. `.luacheckrc`: nothing for the generated list. The standalone list needs `CreateColor`, `GetBindingKey`,
   `GetCurrentBindingSet`, `GetCursorPosition`, `IsAltKeyDown`, `IsControlKeyDown`, `IsShiftKeyDown`, `OpenWorldMap`,
   `SaveBindings`, `SetBinding`. The four globals are set through `_G`.

## To de-duplicate with UI.lua and GuideUI.lua

`Widgets.lua` repeats what it could not import: `rgb`, `fill`, `setColor`, `text`, `edges`, `showTip`, `hideTip`,
`newButton` / `paintButton` / `setButton`, `newControl` (check, choice, stepper), `drawList` (`W.items`), GuideUI's
`circle`, `here` (`MapCanvas.position`) and `togglePin` (`JournalUI.setWaypoint`). The four new colours (`parch`,
`field`, `horde`, `alliance`) belong in `View.RGB`; `W.rgb` reads `View.RGB` first.

## Checked against the Blizzard source

Paths under `vendor/wow-ui-source/Interface/AddOns` and `vendor/BlizzardInterfaceResources/Resources`, branch `forever`.

| Fact | Where |
|---|---|
| Tiles are row-major, `(row - 1) * cols + col`, set with `SetTexture(id, nil, nil, "TRILINEAR")`, layer `BACKGROUND -8 + layer` | `Blizzard_MapCanvas/Blizzard_MapCanvasDetailLayer.lua:51-67` |
| `UiMapLayerInfo` fields; `GetMapArtLayers` and `GetMapArtLayerTextures` may return nothing | `Blizzard_APIDocumentationGenerated/MapDocumentation.lua:733-745`, `:135-157` |
| `GetMapWorldSize` gives yards wide and high | `MapDocumentation.lua:420-434` |
| C API present: the `C_Map` calls used, `C_SuperTrack.SetSuperTrackedUserWaypoint`, `C_Texture.GetAtlasInfo`, `GetBindingKey`, `SetBinding`, `SaveBindings`, `GetCurrentBindingSet`, `GetCursorPosition`, `GetPlayerFacing` | `GlobalAPI.lua:2843-2882`, `4117`, `4168`, `5319`, `6424`, `6394`, `5367`, `5385`, `5738` |
| Widget methods present: `CreateLine`, `SetStartPoint`, `SetEndPoint`, `SetThickness`, `SetClipsChildren`, `CreateMaskTexture`, `SetGradient`, `SetRotation`, `SetDesaturation`, `SetToplevel`, `SetPropagateKeyboardInput`, `SetFontHeight`, `IsTruncated` | `WidgetAPI.lua:553`, `307`, `305`, `308`, `625`, `554`, `264`, `148`, `263`, `646`, `642`, `184`, `211` |
| `SetGradient` takes two colour objects | `Blizzard_NamePlates/Blizzard_NamePlates.lua:657` |
| `OpenWorldMap(mapID)` is FrameXML Lua, not C API | `Blizzard_WorldMap/Blizzard_WorldMap.lua:1413` |
| The compartment reads `AddonCompartmentFunc`, `...OnEnter`, `...OnLeave`, `IconTexture` and calls `_G[func](addonName, buttonName)` | `Blizzard_Minimap/Mainline/AddonCompartment.lua:102-140`; `Blizzard_Minimap/Camelot/AddonCompartment.xml` exists |
| Escape closes frames named in `UISpecialFrames` | `Blizzard_UIParentPanelManager/Shared/UIParentPanelManager.lua:21`, `:1108` |
| `MenuUtil.CreateContextMenu(owner, generator)` | `Blizzard_Menu/MenuUtil.lua:151` |
| Binding XML shape | `Blizzard_Commentator/Bindings.xml:3` |
| Every atlas used exists | `AtlasInfo.lua:17815` (`MiniMap-QuestArrow`), `17849-17851` (`TaxiNode_*`), `17720-17727`, `17847`, `18102`, `17743`, `25827` |

Long lists are paged by the addon's own `W.list`, never scrolled: ScrollBox is not used anywhere. The close button
is `UIPanelCloseButton` (`Blizzard_SharedXML/Mainline/SharedUIPanelTemplates.xml:148`).

## Tests

`tests/journal_spec.lua`, 39 specs, with its own frame mock (the repo had none) and fixtures written from the design's
shapes: every page builds twice from fixtures without creating frames or regions the second time; nil view-models
show an empty state with a title on all six pages; the map picks `map`, `soft`, `plan`, `grid` at the right
magnifications and after a refused tile; the 60-point loop counts; floors and stairs; the tick with a position, in an
instance and off the map; the auto mode switch; filters and sorts; open, toggle, Escape list, combat close; clicks
reach every provider callback with their arguments; the default waypoint, map and key binding paths; the tracker's
three bars and the Target anchor. A mock proves the code runs and counts regions. It proves nothing about how it
looks.

## To check in game

1. Do `GetMapArtLayers` and `GetMapArtLayerTextures` return art for Forever's vanilla zones and cities, and at what
   layer size? `diag().where` shows `mapMode`, `k`, `tiles` and `artMissing`.
2. Does `Texture:SetTexture(fileID)` from addon code accept those tile IDs? A refusal shows as
   `diag().map.tileFailures` and the plain field. A tile that loads blank without an error would not be caught.
3. Is the base layer whole, or blank where unexplored? Explored overlays (`C_MapExplorationInfo`) are not drawn.
4. Does `SetRotation` turn a solid-colour texture into a diamond, and does a `Line` take a tiling dashed texture
   (one region in place of up to 48 dashes)?
5. `OpenWorldMap(map)` from an addon button in combat: taint or block?
6. `SetBinding` + `SaveBindings` from a key press inside the addon's frame; does `Bindings.xml` load unlisted, and
   does `category="ADDONS"` show the binding under AddOns?
7. Cave and micro-dungeon maps: art layers, and does `GetPlayerMapPosition` answer on them?
8. `SetGradient` on a white texture for the scrim (a flat scrim is the fallback, noted in `diag().map.scrim`).
9. Looks at UI scales 0.64 to 1.0: text fit in the 37-px overview rows, the timeline labels, the caption strip.
10. The compartment entry and its tooltip; Escape with the profession window open; strata against TSM's windows.
