"""wowprof.py and gen_routes.py on small pages written here in the site's shape (no copy of a real page).

Run: python -m unittest discover -s tools/tests -v
"""
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import gen_routes as R  # noqa: E402
import wowprof as W  # noqa: E402


def spell(i, name, count="10"):
    return f'{count}x <a href="https://www.wowhead.com/forever/spell={i}"><img src="x.png"> {name}</a>'


GUIDE = f"""<html><body><main>
<h1>Test Leveling Guide 1-300</h1>
<div data-steps-version="4"></div>
<h2>Introduction</h2><p>Text that is not a route.</p>
<h2>Apprentice Testing (1-50)</h2>
<table><tr><td>{spell(101, "Plain Thing", "55")}</td></tr>
<tr><td>{spell(102, "Other Thing", "55")}</td></tr></table>
<h2>Journeyman Testing (50-150)</h2>
<div class="route-step"><div class="route-range">50-80</div>
<p>{spell(201, "Main Pick", "20")}</p>
<h4>Alternative recipes</h4>
<p>{spell(202, "Alt Pick", "24")}</p>
<p>{spell(203, "Horde Pick", "5")} (Horde only)</p>
</div>
<div class="route-step"><div class="route-range">80-150</div>
<p>{spell(301, "Long Pick", "65-75")}</p>
<h4>Some Pattern</h4>
<table><tr><td>80-100</td><td>{spell(302, "Split A", "20")}</td></tr>
<tr><td>100-150</td><td>{spell(303, "Split B", "40")} (Alliance)</td></tr></table>
<p>Make <a href="https://www.wowhead.com/forever/spell=304">Bare Spell</a> if you have the pattern.</p>
</div>
</main></body></html>"""

NPC = """<html><body><main>
<h1>Test Trainer - Artisan Testing Trainer</h1>
<button data-clipboard-text="/way #1444 74.4 42.9 Test Trainer">copy</button>
<table><tr><th>Rank</th><th>Required skill</th><th>Required level</th><th>Cost</th></tr>
<tr><td><b>Expert Testing</b></td><td>125</td><td>20</td><td><span class="silvermoney">50</span></td></tr>
<tr><td>Artisan Testing</td><td>200</td><td>35</td><td><span class="goldmoney">5</span>
<span class="silvermoney">2</span><span class="coppermoney">3</span></td></tr></table>
</main></body></html>"""

NPC_NO_RANK_TITLE = """<main><h1>Plain Trainer - Testing Trainer in Town</h1>
<button data-clipboard-text="/way #1454 63.2 44.6 Plain Trainer">copy</button>
<table><tr><th>Rank</th><th>Required skill</th><th>Required level</th><th>Cost</th></tr>
<tr><td>Journeyman Testing</td><td>50</td><td>-</td><td>5s</td></tr>
<tr><td>Expert Testing</td><td>125</td><td>20</td><td>1g 50s</td></tr></table></main>"""


def npc(slug, name, side=None):
    icon = f'<img src="/images/icons/{side}.png" width="15">' if side else ""
    return f'<a href="/forever/npc/{slug}">{icon}{name}</a>'


def item(i, name):
    return f'<a href="https://www.wowhead.com/forever/item={i}"><img src="x.png">{name}</a>'


UNLOCKS = f"""<main><h1>Test Guide</h1>
<h2>Apprentice Testing (1-50)</h2>
<p>{spell(101, "Plain Thing", "55")}</p>
<h2>Journeyman Testing (50-125)</h2>
<p>Visit a trainer. It needs <b>Testing 50</b> and <b>level 10</b>:</p>
<div class="column-2"><div><p><b>Horde trainers:</b></p><ul><li>City: {npc("horde-one", "Horde One")}</li></ul></div>
<div><p><b>Alliance trainers:</b></p><ul><li>City: {npc("ally-one", "Ally One")}</li></ul></div></div>
<div class="route-step"><div class="route-range">50-125</div><p>{spell(201, "Main Pick", "20")}</p></div>
<h2>Expert Testing (125-200)</h2>
<p>Reach Testing 125, then buy the {item(16072, "Expert Book")} from {npc("vendor-h", "Vendor H", "horde")} (Horde)
or from {npc("vendor-a", "Vendor A")} (Alliance).</p>
<div class="route-step"><div class="route-range">125-200</div><p>{spell(301, "Long Pick", "30")}</p></div>
<h2>Artisan Testing (200-300)</h2>
<p>The rank is the reward of the <a href="https://www.wowhead.com/forever/quest=6610">Test Quest</a> from
{npc("quest-giver", "Quest Giver")}. It requires <b>level 35</b> and <b>Testing 200</b>.</p>
<ol class="step-list"><li>Buy 12x {item(12207, "Giant Egg")} and 10x {item(7974, "Clam Meat")}.</li>
<li>Buy 20x {item(8932, "Swiss")} from {npc("cheese-vendor", "Cheese Vendor", "alliance")}.</li></ol>
<div class="route-step"><div class="route-range">200-300</div><p>{spell(401, "Top Pick", "60")}</p></div>
</main>"""

TABBED = f"""<main><h1>Tabs</h1>
<h2>Apprentice Testing (1-70)</h2>
<div class="route-step"><div class="route-range">1-20</div>
<p>Make one of these:</p><ul><li>{spell(11, "First Of List", "20")}</li><li>{spell(12, "Second Of List", "20")}</li></ul>
</div>
<div class="route-step"><div class="route-range">20-70</div>
<p>Make both of these:</p><ol><li>{spell(13, "Both A", "25")}</li><li>{spell(14, "Both B", "25")}</li></ol></div>
<h2>Journeyman Testing (70-150)</h2>
<p>Learn it from {npc("t-h", "Trainer H")} (Horde). You need <b>Testing 50</b>.</p>
<div class="tab-container"><div class="tabs">
<button class="tab-button active" data-tab="tab2-70-150">Dust</button>
<button class="tab-button" data-tab="tab1-70-150">Essence</button></div>
<div class="tab-content" id="tab1-70-150">
<div class="route-step"><div class="route-range">70-150</div><p>{spell(21, "Essence Route", "80")}</p>
<p><a href="https://www.wowhead.com/forever/spell=29">Not An Option</a> after it.</p></div>
</div>
<div class="tab-content active" id="tab2-70-150">
<div class="route-step"><div class="route-range">70-150</div><p>{spell(22, "Dust Route", "80")}</p></div>
</div></div>
</main>"""

TRIAGE = f"""<h2>Artisan Testing (225-300)</h2>
<p>Train past 225 with a quest. It requires <b>Testing 225</b> and <b>level 35</b>.</p>
<div class="tab-container tabs-thin"><div class="tabs"><button class="tab-button is-horde active" data-tab="horde-tab">
Horde</button><button class="tab-button is-alliance" data-tab="alliance-tab">Alliance</button></div>
<div class="tab-content is-horde active" id="horde-tab" role="tabpanel">
<p>The <a href="https://www.wowhead.com/forever/quest=6622">Triage</a> quest is given by {npc("doc-h", "Doc H")}.</p>
</div>
<div class="tab-content is-alliance" id="alliance-tab" role="tabpanel">
<p>The <a href="https://www.wowhead.com/forever/quest=6624">Triage</a> quest is given by {npc("doc-a", "Doc A")}.</p>
</div></div>"""


class ParseGuide(unittest.TestCase):
    def setUp(self):
        self.g = W.parse_guide(GUIDE)

    def test_title_version_and_sections(self):
        self.assertEqual(self.g["title"], "Test Leveling Guide 1-300")
        self.assertEqual(self.g["stepsVersion"], 4)
        self.assertEqual({s["section"] for s in self.g["steps"]},
                         {"Apprentice Testing (1-50)", "Journeyman Testing (50-150)"})

    def test_section_without_steps_is_one_step(self):
        first = self.g["steps"][0]
        self.assertEqual((first["from"], first["to"]), (1, 50))
        self.assertEqual([o["spell"] for o in first["options"]], [101, 102])
        self.assertFalse(any(o["alt"] for o in first["options"]))

    def test_alternatives_and_faction(self):
        step = self.g["steps"][1]
        self.assertEqual((step["from"], step["to"]), (50, 80))
        by = {o["spell"]: o for o in step["options"]}
        self.assertFalse(by[201]["alt"])
        self.assertTrue(by[202]["alt"])
        self.assertEqual(by[202]["variant"], "Alternative recipes")
        self.assertEqual(by[203]["faction"], "horde")
        self.assertIsNone(by[201]["faction"])

    def test_count_range_sub_ranges_and_bare_spell(self):
        step = self.g["steps"][2]
        by = {o["spell"]: o for o in step["options"]}
        self.assertEqual(by[301]["count"], 75)
        self.assertEqual((by[302]["from"], by[302]["to"]), (80, 100))
        self.assertEqual((by[303]["from"], by[303]["to"], by[303]["faction"]), (100, 150, "alliance"))
        self.assertIsNone(by[304]["count"])
        self.assertEqual((by[304]["from"], by[304]["to"]), (80, 150))

    def test_shape_errors(self):
        with self.assertRaises(W.ShapeError):
            W.parse_guide("<main><h1>x</h1><h2>No range here</h2></main>")
        with self.assertRaises(W.ShapeError):
            W.parse_guide('<main><h2>A (1-50)</h2><div class="route-step"><div class="route-range">1-50</div>'
                          "<p>nothing</p></div></main>")
        alt_only = (f'<main><h2>A (1-50)</h2><div class="route-step"><div class="route-range">1-50</div>'
                    f"<h4>Alternative</h4><p>{spell(1, 'X')}</p></div></main>")
        with self.assertRaises(W.ShapeError):
            W.parse_guide(alt_only)


class ParseNpc(unittest.TestCase):
    def test_role_position_ranks(self):
        n = W.parse_npc(NPC)
        self.assertEqual((n["name"], n["role"]), ("Test Trainer", "Artisan Testing Trainer"))
        self.assertEqual((n["map"], n["x"], n["y"]), (1444, 74.4, 42.9))
        self.assertEqual(n["rank"], "artisan")
        self.assertEqual(n["ranks"], [
            {"rank": "expert", "skill": 125, "level": 20, "cost": 5000},
            {"rank": "artisan", "skill": 200, "level": 35, "cost": 50203},
        ])

    def test_rank_from_highest_row_and_text_costs(self):
        n = W.parse_npc(NPC_NO_RANK_TITLE)
        self.assertEqual(n["rank"], "expert")  # the title names no rank: the highest row does
        self.assertEqual([(r["rank"], r["level"], r["cost"]) for r in n["ranks"]],
                         [("journeyman", None, 500), ("expert", 20, 15000)])

    def test_no_rank_at_all(self):
        n = W.parse_npc('<main><h1>Vendor - Cooking Supplies</h1></main>')
        self.assertEqual((n["rank"], n["ranks"]), (None, []))

    def test_trainer_slugs(self):
        page = f"<main><h2>Expert (150-225)</h2>{npc('una', 'Una')} {npc('una', 'Una')} {npc('tarn', 'Tarn')}</main>"
        self.assertEqual(W.trainer_slugs(page), ["una", "tarn"])
        with self.assertRaises(W.ShapeError):
            W.trainer_slugs("<main>nothing</main>")


class Unlocks(unittest.TestCase):
    def setUp(self):
        self.u = {u["rank"]: u for u in W.parse_guide(UNLOCKS)["unlocks"]}

    def test_first_section_skipped(self):
        self.assertEqual(list(self.u), ["Journeyman", "Expert", "Artisan"])

    def test_trainer_rank_with_column_factions(self):
        j = self.u["Journeyman"]
        self.assertEqual((j["kind"], j["skill"], j["level"], j["from"], j["to"]), ("trainer", 50, 10, 50, 125))
        self.assertEqual(j["npcs"], [{"slug": "horde-one", "name": "Horde One", "faction": "H"},
                                     {"slug": "ally-one", "name": "Ally One", "faction": "A"}])

    def test_book_from_vendors(self):
        e = self.u["Expert"]
        self.assertEqual((e["kind"], e["item"], e["skill"], e["level"]), ("book", 16072, 125, None))
        self.assertEqual(e["names"], {16072: "Expert Book"})
        self.assertEqual([(n["slug"], n["faction"]) for n in e["npcs"]], [("vendor-h", "H"), ("vendor-a", "A")])

    def test_quest_with_items(self):
        a = self.u["Artisan"]
        self.assertEqual((a["kind"], a["quest"], a["questName"], a["skill"], a["level"]),
                         ("quest", 6610, "Test Quest", 200, 35))
        self.assertEqual(a["items"], [[12207, 12], [7974, 10], [8932, 20]])
        self.assertEqual(a["names"][8932], "Swiss")
        # the quest giver only: the cheese vendor's line has no quest link
        self.assertEqual(a["npcs"], [{"slug": "quest-giver", "name": "Quest Giver", "faction": None}])

    def test_faction_tabs_give_each_side_its_quest(self):
        u = W.parse_unlock("Artisan Testing (225-300)", TRIAGE)
        self.assertEqual((u["kind"], u["quest"], u["skill"], u["level"]), ("quest", 6622, 225, 35))
        self.assertEqual([(n["slug"], n["faction"], n["quest"]) for n in u["npcs"]],
                         [("doc-h", "H", 6622), ("doc-a", "A", 6624)])


class ListsAndTabs(unittest.TestCase):
    def setUp(self):
        self.steps = W.parse_guide(TABBED)["steps"]

    def test_ul_is_one_of_ol_is_both(self):
        one, both = self.steps[0]["options"], self.steps[1]["options"]
        self.assertEqual([(o["spell"], o["alt"]) for o in one], [(11, False), (12, True)])
        self.assertEqual([(o["spell"], o["alt"]) for o in both], [(13, False), (14, False)])

    def test_inactive_route_tab_is_an_alternative(self):
        tabbed = [s for s in self.steps if s["from"] == 70]
        self.assertEqual(len(tabbed), 2)
        by = {o["spell"]: o for s in tabbed for o in s["options"]}
        self.assertEqual(set(by), {21, 22})  # the bare link in a tab is not an option
        self.assertEqual((by[21]["alt"], by[21]["variant"]), (True, "Essence"))
        self.assertFalse(by[22]["alt"])

    def test_route_entries_drop_a_tab_row_that_repeats_the_main_one(self):
        page = TABBED.replace(spell(21, "Essence Route", "80"), spell(22, "Dust Route", "80"))
        entries = R.entries_of(W.parse_guide(page))
        self.assertEqual([e for e in entries if e["from"] == 70], [{"from": 70, "to": 150, "spell": 22}])


class GenRoutes(unittest.TestCase):
    def test_entries_facts_only_main_first(self):
        entries = R.entries_of(W.parse_guide(GUIDE))
        for e in entries:
            self.assertLessEqual(set(e), {"from", "to", "spell", "alt", "faction"})
        at50 = [e for e in entries if e["from"] == 50]
        self.assertEqual(at50[0], {"from": 50, "to": 80, "spell": 201})
        self.assertIn({"from": 50, "to": 80, "spell": 203, "alt": True, "faction": "horde"}, at50)

    def test_render_is_lua_with_a_source(self):
        text = R.render({165: [{"from": 1, "to": 50, "spell": 101, "alt": True}]}, "the source, 2026-01-01")
        self.assertIn("ns.Data.routes = {", text)
        self.assertIn('source = "the source, 2026-01-01",', text)
        self.assertIn("\t[165] = {\n\t\t{ from = 1, to = 50, spell = 101, alt = true },\n\t},", text)
        self.assertNotIn("Plain Thing", text)

    def test_rank_records_resolve_ids_positions_and_names(self):
        rows = [{"id": 12033, "name": "Vendor H"}, {"id": 1, "name": "Horde One", "skill": 171},
                {"id": 2, "name": "Horde One", "skill": 165}, {"id": 3, "name": "Ally One", "skill": {1: 40, 2: 165}}]
        site = {"vendor-h": {"map": 1443, "x": 26.1, "y": 69.7}}
        fetched = []

        def fetch(slug):
            fetched.append(slug)
            return {"map": 1, "x": 2.5, "y": 3.5} if slug == "quest-giver" else None
        ranks = R.rank_records(W.parse_guide(UNLOCKS), 165, rows, {12207, 7974}, site, fetch)
        j, e, a = ranks
        self.assertEqual(j["name"], "Journeyman")
        self.assertEqual([(n["id"], n["faction"]) for n in j["npcs"]], [(2, "H"), (3, "A")])  # skill picks the row
        self.assertEqual(e["npcs"][0], {"id": 12033, "name": "Vendor H", "faction": "H", "map": 1443, "x": 26.1,
                                        "y": 69.7, "quest": None})
        self.assertIsNone(e["npcs"][1]["id"])  # unknown name: nil, not a guess
        self.assertEqual((e["kind"], e["item"], e["names"]), ("book", 16072, {16072: "Expert Book"}))
        self.assertEqual(a["items"], [12207, 12, 7974, 10, 8932, 20])
        self.assertEqual(a["names"], {8932: "Swiss"})  # items the recipe data has keep its names
        self.assertEqual((a["npcs"][0]["map"], a["npcs"][0]["x"]), (1, 2.5))
        self.assertNotIn("vendor-h", fetched)  # the site file is read first
        text = R.render({165: []}, "src", {165: ranks})
        self.assertIn("ns.Data.routeRanks = {\n\t[165] = {\n\t\t{ name = \"Journeyman\", skill = 50, level = 10, "
                      "kind = \"trainer\", npcs = { { id = 2, name = \"Horde One\", faction = \"H\" }", text)
        self.assertIn('questName = "Test Quest", items = { 12207, 12, 7974, 10, 8932, 20 }, '
                      'names = { [8932] = "Swiss" }', text)

    def test_recipe_items(self):
        text = ("ns.Data.recipes = {\n\titems = {\n\t\t[118] = { name = \"a\" },\n\t\t[159] = { name = \"b\" },\n"
                "\t},\n\tprofessions = {\n\t\t[171] = {\n\t\t},\n\t},\n}\n")
        self.assertEqual(R.recipe_items(text), {118, 159})
        self.assertEqual(R.recipe_items("nothing"), set())

    def test_recipe_spells_and_main_from_saved_pages(self):
        recipes = ("ns.Data.recipes = {\n\tprofessions = {\n\t\t[171] = {\n\t\t\trecipes = {\n"
                   "\t\t\t\t[101] = { name = \"x\" },\n\t\t\t\t[102] = { name = \"y\" },\n\t\t\t},\n\t\t},\n\t},\n}\n")
        self.assertEqual(R.recipe_spells(recipes), {171: {101, 102}})
        with tempfile.TemporaryDirectory() as d:
            Path(d, "alchemy.html").write_text(GUIDE, encoding="utf-8")
            Path(d, "Recipes.lua").write_text(recipes, encoding="utf-8")
            out = Path(d, "Routes.lua")
            args = ["--only", "alchemy", "--html", d, "--out", str(out), "--recipes", str(Path(d, "Recipes.lua"))]
            # the page names spells the recipe file lacks: exit 2 names them and nothing is written
            self.assertEqual(R.main(args), 2)
            self.assertFalse(out.exists())
            # --force writes all the same, still exit 2
            self.assertEqual(R.main(args + ["--force"]), 2)
            self.assertIn("[171] = {", out.read_text(encoding="utf-8"))
            # with no recipe check it writes and exits 0
            self.assertEqual(R.main(args + ["--no-check"]), 0)
            self.assertEqual(R.main(["--only", "nonsense", "--html", d, "--out", str(out)]), 1)


if __name__ == "__main__":
    unittest.main()
