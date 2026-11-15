"""import_savedvars.py: the reader takes the learned table and nothing else, and the merge rule.
Run: python -m unittest discover -s tools/tests -v"""
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import gen_recipes as G  # noqa: E402
import import_savedvars as I  # noqa: E402
import test_gen_recipes as T  # noqa: E402

SHIPPED, NEWER = "1.60.1.100", "1.60.1.200"
# what a private part of a SavedVariables file would hold: none of it may reach the output
PRIVATE = ("Privatechar", "Altnameone", "Secretrealm", "Guildofsecrets", "MYACCOUNT", "Smugglerbank")


def saved(learned: str, n: int = 1) -> str:
    """A SavedVariables file as the game writes it: private fields around the learned table."""
    return f"""
SkillupHelperDB = {{
	["shown"] = true,
	["mailQueue"] = {{
		["Alliance - Secretrealm"] = {{
			["Privatechar"] = {{ {{ ["to"] = "Altnameone", ["item"] = 2589, ["count"] = {n} }}, }},
		}},
	}},
	["trips"] = {{ ["Tailoring"] = {{ ["rows"] = {{ {{ ["item"] = 2589, ["name"] = "Smugglerbank" }}, }}, }}, }},
	["selftest"] = {{ ["guild"] = "Guildofsecrets", ["alts"] = "Altnameone" }},
	["guide"] = {{ ["pin"] = {{ ["map"] = 1429, ["x"] = 1, ["y"] = 2 }}, }},
	["skills"] = {{ [164] = {{ ["rank"] = 120 }}, }},
	["learned"] = {{
		["version"] = 1,
		["locale"] = "enUS",
		["owner"] = "Privatechar", -- not a field the addon writes: dropped
{learned}
	}},
}}
"""


def trainer(spell=101, skill=30, cost=120, at=NEWER, build=NEWER):
    return f"""
		["build"] = "{build}",
		["trainers"] = {{ [164] = {{ [{spell}] = {{ ["skill"] = {skill}, ["cost"] = {cost}, ["seenAt"] = "{at}" }}, }}, }},
"""


class Case(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / "addon"
        (self.root / "Data").mkdir(parents=True)
        (self.root / "tools" / "data").mkdir(parents=True)
        over = T.overlay(recipes={101: {"learn": 20}, 102: {"src": "vendor", "vendor": {"name": "Sal", "npc": 7}}},
                         vendor={T.THREAD})
        data, _ = G.build_data(T.tables(), SHIPPED, over)
        (self.root / "Data" / "Recipes.lua").write_text(G.render(data), encoding="utf-8", newline="\n")
        self.manual = self.root / "tools" / "data" / "overlay.manual.json"
        self.count = 0

    def file(self, learned: str) -> str:
        self.count += 1
        folder = Path(self.tmp.name) / "WTF" / "Account" / "MYACCOUNT#1" / f"copy{self.count}" / "SavedVariables"
        folder.mkdir(parents=True)
        f = folder / "SkillupHelper.lua"
        f.write_text(saved(learned, self.count), encoding="utf-8", newline="\n")
        return str(f)

    def run_tool(self, *argv):
        out = io.StringIO()
        code = I.run(["--root", str(self.root), *argv], out)
        return code, out.getvalue()

    def manual_json(self):
        return json.loads(self.manual.read_text(encoding="utf-8")) if self.manual.is_file() else None


class Privacy(Case):
    def test_only_the_learned_table_is_read(self):
        learned = I.read_file(Path(self.file(trainer())))
        self.assertEqual({"version", "build", "locale", "trainers", "ranks", "vendors", "npcs", "colors", "skillups"},
                         set(learned))
        self.assertEqual({164: {101: {"skill": 30, "cost": 120, "seenAt": NEWER}}}, learned["trainers"])
        self.assertNotIn("Privatechar", json.dumps(learned))

    def test_nothing_private_reaches_the_report_or_the_written_files(self):
        f = self.file(trainer() + """
		["npcs"] = { [7] = { ["id"] = 7, ["name"] = "Sal", ["map"] = 1429, ["x"] = 40.1, ["y"] = 60.2, ["seen"] = 1 }, },
""")
        report = self.root / "report.md"
        code, out = self.run_tool(f, "--report", str(report))
        self.assertEqual(I.EXIT_APPLIED, code)
        written = out + report.read_text(encoding="utf-8") + self.manual.read_text(encoding="utf-8") \
            + (self.root / "tools" / "data" / "npcs_seen.json").read_text(encoding="utf-8")
        for word in PRIVATE:
            self.assertNotIn(word, written)
        self.assertNotIn("WTF", written)
        self.assertIn("file 1", out)

    def test_a_file_without_the_table_and_a_file_that_is_not_lua(self):
        old = Path(self.tmp.name) / "old.lua"
        old.write_text('SkillupHelperDB = {\n\t["shown"] = true,\n\t["mailQueue"] = { ["Horde - Secretrealm"] = {} },\n}\n',
                       encoding="utf-8")
        code, out = self.run_tool(str(old))
        self.assertEqual(I.EXIT_BROKEN, code)
        self.assertIn("file 1: no `learned` table", out)
        self.assertIn("no file holds a `learned` table", out)
        self.assertNotIn("Secretrealm", out)
        bad = Path(self.tmp.name) / "Privatechar.lua"
        bad.write_text('SkillupHelperDB = { ["mailQueue"] = { "Secretrealm", ', encoding="utf-8")
        code, out = self.run_tool(str(bad))
        self.assertEqual(I.EXIT_BROKEN, code)
        self.assertIn("file 1 is not a SavedVariables file", out)
        for word in PRIVATE:
            self.assertNotIn(word, out)

    def test_fields_of_the_wrong_type_are_dropped(self):
        learned = I.clean({"build": "not a build", "locale": "Privatechar", "trainers": {164: {"x" * 200: {"skill": 1}}},
                           "ranks": {164: {75: {"name": 5, "skill": "Altnameone", "cost": -1}}},
                           "npcs": {7: {"name": "Sal\nPrivatechar", "map": 1, "x": 500, "y": 1}},
                           "vendors": {"Altnameone": {"items": {1: {}}}}, "colors": {5: {"o": True}}})
        self.assertEqual((None, None, {}, {}, {}, {}), (learned["build"], learned["locale"], learned["trainers"],
                                                        learned["npcs"], learned["vendors"], learned["colors"]))
        self.assertEqual({164: {75: {"name": None, "skill": None, "cost": None, "seenAt": None}}}, learned["ranks"])


class MergeRule(Case):
    def test_decide(self):
        d = I.decide
        self.assertEqual("apply", d(20, SHIPPED, [(30, NEWER, 1)])[0])  # a newer build wins from one file
        self.assertEqual("confirmed", d(20, SHIPPED, [(20, NEWER, 1)])[0])
        self.assertEqual("pending", d(20, SHIPPED, [(30, SHIPPED, 1)])[0])  # same build, one file
        self.assertEqual("pending", d(20, SHIPPED, [(30, None, 1)])[0])  # no build recorded
        self.assertEqual("apply", d(20, SHIPPED, [(30, SHIPPED, 1), (30, "1.60.1.90", 2)])[0])  # two files agree
        self.assertEqual("conflict", d(20, SHIPPED, [(30, SHIPPED, 1), (35, SHIPPED, 2)])[0])
        self.assertEqual("conflict", d(20, SHIPPED, [(30, SHIPPED, 1), (20, SHIPPED, 2)])[0])  # one says shipped
        self.assertEqual("conflict", d(20, SHIPPED, [(30, NEWER, 1), (35, NEWER, 2)])[0])
        self.assertEqual("apply", d(None, SHIPPED, [(30, SHIPPED, 1)])[0])  # a gap: nothing is overridden
        self.assertEqual("conflict", d(None, SHIPPED, [(30, SHIPPED, 1), (31, SHIPPED, 2)])[0])
        # the newest build decides over an older file that disagrees
        status, value, _ = d(20, SHIPPED, [(30, "1.60.1.150", 1), (40, NEWER, 2)])
        self.assertEqual(("apply", 40), (status, value))
        self.assertEqual("confirmed", d((1, 40.0, 60.0), SHIPPED, [((1, 40.9, 59.2), SHIPPED, 1)], I.near)[0])

    def test_a_newer_build_overrides_and_a_gap_is_filled(self):
        code, out = self.run_tool(self.file(trainer()))
        self.assertEqual(I.EXIT_APPLIED, code)
        self.assertEqual({"learn": 30, "cost": 120}, {k: v for k, v in self.manual_json()["recipes"]["101"].items()
                                                      if k != "note"})
        self.assertIn("Blacksmithing: Copper Belt (spell 101): learn rank: 20 -> 30 (seen on build 1.60.1.200", out)
        self.assertIn("training cost: nothing -> 120", out)
        # the generator reads the result, and it reaches the data
        o = G.with_manual(dict(G.EMPTY_OVERLAY), G.load_overlay(self.manual))
        data, _ = G.build_data(T.tables(), NEWER, o)
        self.assertEqual((30, 120), (data["professions"][164]["recipes"][101]["learn"],
                                     data["professions"][164]["recipes"][101]["cost"]))

    def test_the_same_build_needs_two_files(self):
        one = self.file(trainer(skill=30, cost=120, at=SHIPPED, build=SHIPPED))
        code, out = self.run_tool(one)
        self.assertEqual(I.EXIT_APPLIED, code)  # the cost fills a gap
        self.assertNotIn("learn", self.manual_json()["recipes"]["101"])
        self.assertIn("learn rank: shipped 20, the game says 30 (one file (file 1)", out)
        two = self.file(trainer(skill=30, cost=120, at=SHIPPED, build=SHIPPED) + '\t\t["colors"] = {},\n'
                        '\t\t["ranks"] = { [164] = { [150] = { ["name"] = "Journeyman", ["cap"] = 150, ["skill"] = 50, '
                        '["cost"] = 475, ["seenAt"] = "' + SHIPPED + '" }, }, },\n')
        code, out = self.run_tool(one, two)
        self.assertEqual(30, self.manual_json()["recipes"]["101"]["learn"])
        self.assertIn("learn rank: 20 -> 30 (2 files agree (files 1, 2))", out)

    def test_a_copy_of_a_file_counts_once(self):
        one = self.file(trainer(at=SHIPPED, build=SHIPPED))
        copy = Path(self.tmp.name) / "copy.lua"
        copy.write_text(Path(one).read_text(encoding="utf-8").replace('["count"] = 1', '["count"] = 9'), encoding="utf-8")
        code, out = self.run_tool(one, str(copy), "--dry-run")
        self.assertIn("file 2: the same content as an earlier file. Counted once.", out)
        self.assertIn("needs a second file", out)

    def test_files_that_disagree_are_a_conflict_and_nothing_is_applied(self):
        a = self.file(trainer(skill=30, cost=100, at=SHIPPED, build=SHIPPED))
        b = self.file(trainer(skill=35, cost=100, at=SHIPPED, build=SHIPPED))
        code, out = self.run_tool(a, b)
        self.assertIn("### Conflicts (nothing applied) (1)", out)
        self.assertIn("learn rank: shipped 20; files 1, 2 disagree: 30 / 35", out)
        self.assertNotIn("learn", self.manual_json()["recipes"]["101"])
        self.assertEqual(100, self.manual_json()["recipes"]["101"]["cost"])

    def test_dry_run_writes_nothing(self):
        code, out = self.run_tool(self.file(trainer()), "--dry-run")
        self.assertEqual(I.EXIT_APPLIED, code)
        self.assertIn("### Would apply (2)", out)
        self.assertIsNone(self.manual_json())
        self.assertFalse((self.root / "tools" / "data" / "npcs_seen.json").exists())

    def test_nothing_new_exits_0(self):
        code, out = self.run_tool(self.file(f"""
		["build"] = "{NEWER}",
		["trainers"] = {{ [164] = {{ [101] = {{ ["skill"] = 20, ["seenAt"] = "{NEWER}" }}, }}, }},
"""))
        self.assertEqual(I.EXIT_NONE, code)
        self.assertIn("Confirmed: 1 facts match the shipped data.", out)
        self.assertIsNone(self.manual_json())

    def test_hand_kept_values_count_as_shipped(self):
        self.manual.write_text(json.dumps({"recipes": {"101": {"learn": 30, "note": "by hand"}}, "vendor": []}),
                               encoding="utf-8")
        code, out = self.run_tool(self.file(trainer(skill=30, cost=120)))
        self.assertEqual("by hand", self.manual_json()["recipes"]["101"]["note"])
        self.assertIn("Confirmed: 1 facts", out)


class Facts(Case):
    def test_colours_ranks_vendors_positions_and_skillups(self):
        f = self.file(f"""
		["build"] = "{NEWER}",
		["trainers"] = {{ [164] = {{ ["copper belt"] = {{ ["skill"] = 33, ["seenAt"] = "{NEWER}" }}, ["no such thing"] = {{ ["skill"] = 1 }}, }}, }},
		["ranks"] = {{ [164] = {{ [150] = {{ ["name"] = "Journeyman", ["cap"] = 150, ["skill"] = 55, ["cost"] = 450,
			["seen"] = 1700000000, ["seenAt"] = "{NEWER}" }}, }}, }},
		["colors"] = {{
			[102] = {{ ["o"] = 64, ["y"] = 65, ["n"] = 70, ["g"] = 90, ["seenAt"] = "{NEWER}" }},
			[101] = {{ ["o"] = 50, ["seenAt"] = "{NEWER}" }},
			[4242] = {{ ["o"] = 1 }},
		}},
		["vendors"] = {{
			[9] = {{ ["map"] = 1429, ["x"] = 41.5, ["y"] = 65.5, ["seenAt"] = "{NEWER}", ["items"] = {{
				[{T.PLANS}] = {{ ["price"] = 90, ["stock"] = 1 }},
				[{T.BAR}] = {{ ["price"] = 12 }},
				[{T.THREAD}] = {{ ["price"] = 9 }},
				[{T.STONE}] = {{ ["price"] = 1 }},
			}}, }},
		}},
		["npcs"] = {{ [9] = {{ ["id"] = 9, ["name"] = "Dana", ["map"] = 1429, ["x"] = 41.5, ["y"] = 65.5 }},
			["name:Nobody"] = {{ ["name"] = "Nobody", ["map"] = 1, ["x"] = 1, ["y"] = 1 }}, }},
		["skillups"] = {{ [164] = {{ [101] = {{ [45] = {{ ["t"] = 10, ["u"] = 6 }}, [50] = {{ ["t"] = 4 }}, }}, }}, }},
""")
        code, out = self.run_tool(f)
        self.assertEqual(I.EXIT_APPLIED, code)
        m = self.manual_json()
        # 102: yellow pinned at 65 (orange at 64, yellow at 65); its grey is only known to be in 71..90: left alone
        self.assertEqual(65, m["recipes"]["102"]["y"])
        self.assertNotIn("g", m["recipes"]["102"])
        # the plans were seen at another vendor than the shipped one
        self.assertEqual({"name": "Dana", "npc": 9, "map": 1429}, m["recipes"]["102"]["vendor"])
        self.assertEqual(33, m["recipes"]["101"]["learn"])  # the name-keyed trainer row found its spell
        self.assertEqual([{"name": "Journeyman", "cap": 150, "skill": 55, "cost": 450}], m["ranks"]["164"])
        self.assertEqual([T.BAR], m["vendor"])  # a reagent a vendor sells; thread was known, the stone is no reagent
        seen = json.loads((self.root / "tools" / "data" / "npcs_seen.json").read_text(encoding="utf-8"))
        self.assertEqual({"name": "Dana", "map": 1429, "x": 41.5, "y": 65.5, "build": NEWER, "files": 1},
                         seen["npcs"]["9"])
        for want in (
            "the shipped yellow threshold 45 does not fit what the game showed (it is in 51.., build 1.60.1.200)",
            "trainer recipe 'no such thing' of skill line 164 has no spell id",
            "spell 4242 was seen in a profession window and is not in the shipped data",
            "Coarse Thread (item 2320): the vendor asked 9.0 copper, the data says 10",
            "Blacksmithing: Copper Belt (spell 101), skill 45-49: 6 skill-ups in 10 tries",
            "skill 50-54: 0 skill-ups in 4 tries",
        ):
            self.assertIn(want, out)
        self.assertNotIn("Nobody", out)
        G.load_overlay(self.manual)

    def test_a_position_near_the_shipped_one_is_confirmed(self):
        (self.root / "Data" / "Trainers.lua").write_text(
            'ns.Data.trainers = {\n\t{ id = 9, name = "Dana", map = 1429, x = 41, y = 65, role = "recipes" },\n'
            '\t{ id = 10, name = "Eli", role = "trainer", nopos = true },\n}\n', encoding="utf-8")
        f = self.file(f"""
		["build"] = "{SHIPPED}",
		["npcs"] = {{ [9] = {{ ["name"] = "Dana", ["map"] = 1429, ["x"] = 41.5, ["y"] = 65.5 }},
			[10] = {{ ["name"] = "Eli", ["map"] = 1429, ["x"] = 10, ["y"] = 20 }},
			[11] = {{ ["name"] = "Auctioneer", ["map"] = 1429, ["x"] = 1, ["y"] = 2 }}, }},
""")
        code, out = self.run_tool(f)
        seen = json.loads((self.root / "tools" / "data" / "npcs_seen.json").read_text(encoding="utf-8"))
        self.assertEqual(["10"], sorted(seen["npcs"]))  # 9 is where the data has it; 11 is not in the data
        self.assertIn("Eli (NPC 10): position: nothing -> map 1429 at 10.0, 20.0", out)


if __name__ == "__main__":
    unittest.main()
