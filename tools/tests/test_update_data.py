"""update_data.py on tiny tables, with the network replaced by a function. Also luatable.py and the two things
gen_recipes.py gained with it: the vendor's place name and the hand-kept overlay laid on top.
Run: python -m unittest discover -s tools/tests -v"""
import copy
import csv
import io
import json
import re
import sys
import tempfile
import unittest
import urllib.error
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import gen_recipes as G  # noqa: E402
import luatable  # noqa: E402
import test_gen_recipes as T  # noqa: E402
import update_data as U  # noqa: E402

OLD, NEW = "1.60.1.100", "1.60.1.200"
FULL = 900  # a skill line with enough recipes to be checked for coverage


def lock(i, kind, skill):
    row = {"ID": str(i)}
    for k in range(8):
        row[f"Type_{k}"], row[f"_Index_{k}"], row[f"Skill_{k}"] = ("2", str(kind), str(skill)) if k == 0 else ("0", "0", "0")
    return row


def tables(grey=300):
    """test_gen_recipes' tables, plus skill line 900 with ten auto recipes that give skill until `grey`, and the
    tables the snapshot and the place names read."""
    t = T.tables()
    t["SkillLine"].append({"ID": str(FULL), "DisplayName_lang": "Tinkering"})
    for i in range(10):
        spell = 9000 + i
        t["SpellName"].append({"ID": str(spell), "Name_lang": f"Gadget {i}"})
        t["SpellReagents"].append(T.reagents(spell, (T.BAR, 1)))
        t["SkillLineAbility"].append(T.ability(100 + i, FULL, spell, 10, grey, acquire=1))
    t["Lock"] = [lock(1, 1, 25), lock(2, 3, 65), {**lock(3, 1, 0), "Type_0": "1"}]
    t["TaxiNodes"] = [{"ID": "5", "Name_lang": "Harbor", "Flags": "1", "ConditionID": "0"},
                      {"ID": "6", "Name_lang": "Quest Path 6", "Flags": "1", "ConditionID": "0"}]
    t["UiMap"] = [{"ID": "1429", "Name_lang": "Elwynn Forest", "Type": "3"},
                  {"ID": "946", "Name_lang": "Cosmic", "Type": "0"}]
    t["AreaTable"] = [{"ID": "12", "AreaName_lang": "Elwynn Forest", "ParentAreaID": "0"}]
    return t


class Wago:
    """Stands in for gen_recipes.http_get: the build list and one CSV per table."""

    def __init__(self, build, t, fail=None):
        self.build, self.t, self.fail, self.calls = build, t, fail, []

    def __call__(self, url, timeout=0):
        self.calls.append(url)
        if self.fail and self.fail in url:
            raise urllib.error.URLError("no route")
        if url == G.BUILDS_URL:
            return json.dumps({"wowf": [{"product": "wowf", "version": self.build, "created_at": "2026-01-01"}],
                               "wow": [{"product": "wow", "version": "12.9.9.99999", "created_at": "2027-01-01"}]}).encode()
        table = re.search(r"/db2/(\w+)/csv\?build=" + re.escape(self.build), url).group(1)
        rows = self.t[table]
        out = io.StringIO()
        w = csv.DictWriter(out, fieldnames=list(rows[0]), lineterminator="\n")
        w.writeheader()
        w.writerows(rows)
        return out.getvalue().encode("utf-8")


class Root:
    """A scratch addon folder: Data/, tools/data/, a cache and a report."""

    def __init__(self, tmp):
        self.root = Path(tmp)
        (self.root / "Data").mkdir()
        (self.root / "tools" / "data").mkdir(parents=True)
        self.report = self.root / "report.md"

    def run(self, get, *extra):
        argv = ["--root", str(self.root), "--cache", str(self.root / "cache"), "--report", str(self.report), *extra]
        return U.run(argv, get)

    def text(self, rel):
        f = self.root / rel
        return f.read_text(encoding="utf-8") if f.is_file() else None

    def write(self, rel, text):
        (self.root / rel).write_text(text, encoding="utf-8", newline="\n")


class UpdateData(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.r = Root(self.tmp.name)
        self.r.write("tools/data/overlay.json", json.dumps({"recipes": {"101": {"learn": 20, "src": "trainer"}}}))

    def baseline(self):
        self.assertEqual(U.EXIT_CHANGED, self.r.run(Wago(OLD, tables())))
        return self.r.text("Data/Recipes.lua"), self.r.text("tools/data/client_snapshot.json")

    def test_first_run_writes_then_nothing_changes(self):
        recipes, snap = self.baseline()
        self.assertIn(f'build = "{OLD}"', recipes)
        self.assertEqual({"1": [[1, 25]], "2": [[3, 65]]}, json.loads(snap)["locks"])
        self.assertEqual({"5": "Harbor"}, json.loads(snap)["taxi"])
        self.assertIn("First snapshot: 2 locks", self.r.text("report.md"))
        get = Wago(OLD, tables())
        self.assertEqual(U.EXIT_SAME, self.r.run(get))
        self.assertIn("**Result: No change**", self.r.text("report.md"))
        self.assertEqual(G.BUILDS_URL, get.calls[0])
        self.assertEqual(recipes, self.r.text("Data/Recipes.lua"))

    def changed_tables(self):
        t = tables()
        names = {r["ID"]: r for r in t["SpellName"]}
        names["101"]["Name_lang"] = "Copper Girdle"  # renamed
        t["SkillLineAbility"] = [r for r in t["SkillLineAbility"] if r["Spell"] != "200"]  # Smelt Copper removed
        for r in t["SkillLineAbility"]:
            if r["Spell"] == "102":
                r["TrivialSkillLineRankLow"], r["TrivialSkillLineRankHigh"] = "70", "95"  # thresholds
        t["SpellReagents"] = [T.reagents(103, (T.BAR, 6)) if r["SpellID"] == "103" else r for r in t["SpellReagents"]]
        for r in t["ItemSparse"]:
            if r["ID"] == str(T.PLANS):
                r["Bonding"] = "1"  # the plans of 102 now bind
        t["ItemXItemEffect"].append({"ItemEffectID": "3", "ItemID": str(T.STONE)})
        t["ItemEffect"].append({"ID": "3", "TriggerType": "6", "SpellID": "101"})  # 101 gets a recipe item
        t["SpellName"].append({"ID": "150", "Name_lang": "Copper Crown"})
        t["SpellReagents"].append(T.reagents(150, (T.BAR, 9)))
        t["SkillLineAbility"].append(T.ability(50, 164, 150, 30, 60))  # added, unknown to the overlay
        t["Lock"] = [lock(1, 1, 40), lock(4, 2, 115), {**lock(3, 1, 0), "Type_0": "1"}]
        return t

    def test_dry_run_reports_every_kind_of_change_and_writes_nothing(self):
        recipes, snap = self.baseline()
        self.assertEqual(U.EXIT_CHANGED, self.r.run(Wago(NEW, self.changed_tables()), "--dry-run"))
        self.assertEqual(recipes, self.r.text("Data/Recipes.lua"))
        self.assertEqual(snap, self.r.text("tools/data/client_snapshot.json"))
        rep = self.r.text("report.md")
        for want in (
            f"Build in the shipped data: {OLD}", f"Newest `wowf` build on wago.tools: {NEW}",
            "Dry run: nothing was written but this report.",
            "### Added (1)", "Blacksmithing: Copper Crown (spell 150), yellow 30, grey 60, trainer; needs 9x Bar",
            "### Removed (1)", "Mining: Smelt Copper (spell 200)",
            "### Renamed (1)", "Blacksmithing: Copper Belt -> Copper Girdle (spell 101)",
            "Blacksmithing: Copper Axe (spell 102): yellow 60 -> 70, grey 80 -> 95",
            "Blacksmithing: Fine Axe (spell 103): 4x Bar -> 6x Bar",
            "Blacksmithing: Copper Axe (spell 102): its recipe item now binds when picked up",
            "Blacksmithing: Copper Girdle (spell 101): recipe item none -> Stone (item 2)",
            "### New in this update (1)", "- Blacksmithing: Copper Crown (spell 150)",
            "lock 1: Lockpicking 25 -> Lockpicking 40", "lock 2 removed (needed Mining 65)",
            "new lock 4: needs Herbalism 115",
            "| Tinkering (900) | covered 1-300 by trainer recipes alone | covered 1-300 by trainer recipes alone |",
        ):
            self.assertIn(want, rep)

    def test_a_real_run_writes_what_the_dry_run_listed(self):
        self.baseline()
        self.assertEqual(U.EXIT_CHANGED, self.r.run(Wago(NEW, self.changed_tables())))
        self.assertIn(f'build = "{NEW}"', self.r.text("Data/Recipes.lua"))
        self.assertIn("Copper Crown", self.r.text("Data/Recipes.lua"))
        self.assertEqual(NEW, json.loads(self.r.text("tools/data/client_snapshot.json"))["build"])
        self.assertEqual(U.EXIT_SAME, self.r.run(Wago(NEW, self.changed_tables())))

    def test_a_coverage_hole_that_appears_fails_and_writes_nothing(self):
        recipes, snap = self.baseline()
        self.assertEqual(U.EXIT_BROKEN, self.r.run(Wago(NEW, tables(grey=200))))
        self.assertEqual(recipes, self.r.text("Data/Recipes.lua"))
        self.assertEqual(snap, self.r.text("tools/data/client_snapshot.json"))
        rep = self.r.text("report.md")
        self.assertIn("FAILED: a coverage hole appeared", rep)
        self.assertIn("Tinkering (900): HOLE: nothing gives skill at 200-300", rep)

    def test_a_hole_that_was_already_there_does_not_fail(self):
        data, _ = G.build_data(tables(grey=200), OLD, G.load_overlay(self.r.root / "tools" / "data" / "overlay.json"))
        self.r.write("Data/Recipes.lua", G.render(data))
        self.assertEqual(U.EXIT_CHANGED, self.r.run(Wago(OLD, tables(grey=200))))  # the snapshot is new
        self.assertEqual(U.EXIT_SAME, self.r.run(Wago(OLD, tables(grey=200))))
        self.assertIn("| Tinkering (900) | HOLE: nothing gives skill at 200-300 | HOLE", self.r.text("report.md"))

    def test_a_broken_input_is_named_and_exits_1(self):
        recipes, _ = self.baseline()
        for fail, said in ((G.BUILDS_URL, "build list unavailable"), ("/db2/Lock/", "recipe data unavailable")):
            self.assertEqual(U.EXIT_BROKEN, self.r.run(Wago(NEW, tables(), fail=fail)))
            rep = self.r.text("report.md")
            self.assertIn("## Broken", rep)
            self.assertIn(said, rep)
            self.assertEqual(recipes, self.r.text("Data/Recipes.lua"))
        self.r.write("tools/data/overlay.json", "{ not json")
        self.assertEqual(U.EXIT_BROKEN, self.r.run(Wago(OLD, tables())))
        self.assertIn("overlay overlay.json: not JSON", self.r.text("report.md"))

    def test_without_the_dump_the_spots_file_is_left_alone_and_said_so(self):
        spots = '-- positions\nns.Data.spots = {\n\tversion = 1, build = "1.60.1.50",\n}\n'
        self.r.write("Data/Spots.lua", spots)
        self.baseline()
        self.assertEqual(spots, self.r.text("Data/Spots.lua"))
        rep = self.r.text("report.md")
        self.assertIn("Data/Spots.lua (build 1.60.1.50): left exactly as it is.", rep)
        self.assertIn("no position was dropped", rep)
        self.assertIn("Data/Trainers.lua (build none): left exactly as it is.", rep)
        self.assertIn("tools/data/overlay.json: read by a person", rep)

    def test_only_the_wowf_product_counts_and_no_personal_data_is_sent(self):
        get = Wago(OLD, tables())
        self.r.run(get)
        self.assertTrue(all(u.startswith("https://wago.tools/") for u in get.calls))
        self.assertNotIn("12.9.9", " ".join(get.calls))
        self.assertRegex(G.USER_AGENT, r"^Mozilla/5\.0 \(compatible; [a-z\-]+/[\d.]+\)$")


class Diff(unittest.TestCase):
    def data(self, t=None, **over):
        data, _ = G.build_data(t or tables(), OLD, T.overlay(**over) if over else None)
        return U.read_recipes(G.render(data))

    def test_identical_tables_have_no_difference(self):
        d = U.diff_recipes(self.data(), self.data())
        self.assertTrue(all(not v for v in d.values()), d)

    def test_other_fields_and_ranks(self):
        old = self.data(recipes={101: {"learn": 20, "cost": 100}})
        new = self.data(recipes={101: {"learn": 25, "cost": 100}},
                        ranks={FULL: [{"name": "Journeyman", "cap": 150, "skill": 60, "cost": 700}]})
        d = U.diff_recipes(old, new)
        self.assertEqual(["Blacksmithing: Copper Belt (spell 101): learn 20 -> 25"], d["other"])
        self.assertIn("Tinkering: Journeyman: skill 50 -> 60, cost 500 -> 700", d["ranks"])

    def test_snapshot_difference(self):
        a = U.client_snapshot(tables(), OLD)
        b = copy.deepcopy(a)
        b["taxi"]["9"], b["zones"]["1429"] = "New Dock", "Elwynn"
        d = U.diff_snapshot(a, b)
        self.assertEqual(["new flight point 9: New Dock"], d["taxi"])
        self.assertEqual(["zone map 1429: Elwynn Forest -> Elwynn"], d["zones"])
        self.assertEqual({"locks": [], "taxi": [], "zones": []}, U.diff_snapshot(None, b))
        back = json.loads(U.render_snapshot(a))
        self.assertEqual(a, {k: back[k] for k in a})

    def test_a_long_section_is_cut_and_counted(self):
        lines = U.section("Added", [f"row {i}" for i in range(200)], cap=3)
        self.assertEqual(["### Added (200)", "", "- row 0", "- row 1", "- row 2", "- ... and 197 more", ""], lines)


class Generator(unittest.TestCase):
    def test_a_vendor_gets_the_name_of_its_zone(self):
        over = T.overlay(recipes={102: {"src": "vendor", "vendor": {"name": "Sal", "npc": 7, "zone": 12}},
                                  103: {"src": "vendor", "vendor": {"name": "Ann", "npc": 8, "map": 1429}}})
        data, _ = G.build_data(tables(), OLD, over)
        r = data["professions"][164]["recipes"]
        self.assertEqual("Elwynn Forest", r[102]["vendor"]["place"])
        self.assertEqual("Elwynn Forest", r[103]["vendor"]["place"])
        self.assertIn('vendor = { name = "Sal", npc = 7, zone = 12, place = "Elwynn Forest" }', G.render(data))
        # without the name tables the vendor is written as before
        t = tables()
        del t["AreaTable"], t["UiMap"]
        data, _ = G.build_data(t, OLD, over)
        self.assertNotIn("place", data["professions"][164]["recipes"][102]["vendor"])

    def test_offline_the_name_tables_are_optional(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            t = tables()
            for name in G.TABLES:
                with open(folder / f"{name}.enUS.csv", "w", encoding="utf-8", newline="") as fh:
                    w = csv.DictWriter(fh, fieldnames=list(t[name][0]))
                    w.writeheader()
                    w.writerows(t[name])
            got = G.fetch_tables(folder, OLD, download=False)
            self.assertEqual(set(G.TABLES), set(got))

    def test_the_hand_kept_overlay_lies_on_top(self):
        with tempfile.TemporaryDirectory() as tmp:
            base, manual = Path(tmp) / "overlay.json", Path(tmp) / "overlay.manual.json"
            base.write_text(json.dumps({
                "recipes": {"101": {"learn": 20, "cost": 100}}, "vendor": [5],
                "ranks": {"164": [{"name": "Journeyman", "cap": 150, "skill": 50, "cost": 500}]}}), encoding="utf-8")
            manual.write_text(json.dumps({
                "recipes": {"101": {"learn": 30, "note": "game"}, "102": {"y": 61}}, "vendor": [6],
                "ranks": {"164": [{"name": "Journeyman", "cap": 150, "cost": 450},
                                  {"name": "Expert", "cap": 225, "skill": 125, "cost": 4000}]}}), encoding="utf-8")
            o = G.with_manual(G.load_overlay(base), G.load_overlay(manual))
            self.assertEqual({"learn": 30, "cost": 100}, o["recipes"][101])
            self.assertEqual({"y": 61}, o["recipes"][102])
            self.assertEqual({5, 6}, o["vendor"])
            self.assertEqual([{"name": "Journeyman", "cap": 150, "skill": 50, "cost": 450},
                              {"name": "Expert", "cap": 225, "skill": 125, "cost": 4000}], o["ranks"][164])
            # a missing hand-kept file changes nothing
            self.assertEqual(G.load_overlay(base)["recipes"],
                             G.with_manual(G.load_overlay(base), G.load_overlay(Path(tmp) / "none.json"))["recipes"])


class LuaTable(unittest.TestCase):
    def test_literals(self):
        v = luatable.parse_value(r'''{ 1, "a\"b\065\n", 'q', x = -1.5, ["k y"] = { true, nil, false }, -- note
            [3] = 0x10; [-2] = 1e2, long = [[two
lines]], --[[ block ]] last = 7 }''')
        # [3] = 0x10 is written after the positional 'q' took index 3: the later one wins, as in Lua
        self.assertEqual({1: 1, 2: 'a"bA\n', 3: 16, "x": -1.5, "k y": {1: True, 2: None, 3: False}, -2: 100.0,
                          "long": "two\nlines", "last": 7}, v)
        self.assertEqual("q", luatable.parse_value("{ 'a', 'q' }")[2])
        self.assertEqual("café", luatable.parse_value(r'"caf\195\169"'))

    def test_assignments(self):
        text = 'local _, ns = ...\nns.Data = ns.Data or {}\nns.Data.x = {\n\tbuild = "1.2",\n}\nOther = nil\nDB = {\n["a"] = 1,\n}\n'
        self.assertEqual({"build": "1.2"}, luatable.read_assignment(text, "ns.Data.x"))
        self.assertEqual({"a": 1}, luatable.read_assignment(text, "DB"))
        self.assertIsNone(luatable.read_assignment(text, "Missing"))
        self.assertIsNone(luatable.read_assignment(text, "ns.Data"))

    def test_what_is_not_a_literal_is_an_error(self):
        for bad in ("{ a = f() }", "{ 1, 2", '{ "never ends }', "{ [1 = 2 }"):
            with self.assertRaises(luatable.LuaError):
                luatable.parse_value(bad)

    def test_the_shipped_recipe_file_round_trips(self):
        data, _ = G.build_data(tables(), OLD)
        back = U.read_recipes(G.render(data))
        self.assertEqual(OLD, back["build"])
        row = back["professions"][164]["recipes"][101]
        self.assertEqual(data["professions"][164]["recipes"][101]["mats"], row["mats"])
        self.assertEqual(sorted(data["professions"]), sorted(back["professions"]))


if __name__ == "__main__":
    unittest.main()
