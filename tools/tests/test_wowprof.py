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
<tr><td>Expert</td><td>125</td><td>20</td><td>1g</td></tr>
<tr><td>Artisan</td><td>200</td><td>35</td><td>5g</td></tr></table>
</main></body></html>"""


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
        self.assertEqual(n["ranks"], [
            {"rank": "Expert", "skill": 125, "level": 20, "cost": "1g"},
            {"rank": "Artisan", "skill": 200, "level": 35, "cost": "5g"},
        ])


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

    def test_recipe_spells_and_main_from_saved_pages(self):
        recipes = ("ns.Data.recipes = {\n\tprofessions = {\n\t\t[171] = {\n\t\t\trecipes = {\n"
                   "\t\t\t\t[101] = { name = \"x\" },\n\t\t\t\t[102] = { name = \"y\" },\n\t\t\t},\n\t\t},\n\t},\n}\n")
        self.assertEqual(R.recipe_spells(recipes), {171: {101, 102}})
        with tempfile.TemporaryDirectory() as d:
            Path(d, "alchemy.html").write_text(GUIDE, encoding="utf-8")
            Path(d, "Recipes.lua").write_text(recipes, encoding="utf-8")
            out = Path(d, "Routes.lua")
            rc = R.main(["--only", "alchemy", "--html", d, "--out", str(out), "--recipes", str(Path(d, "Recipes.lua"))])
            # the page names spells the recipe file lacks: written, and exit 2 names them
            self.assertEqual(rc, 2)
            self.assertIn("[171] = {", out.read_text(encoding="utf-8"))
            self.assertEqual(R.main(["--only", "nonsense", "--html", d, "--out", str(out)]), 1)


if __name__ == "__main__":
    unittest.main()
