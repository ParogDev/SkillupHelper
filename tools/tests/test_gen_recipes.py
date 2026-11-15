"""gen_recipes.py and import_wowhead.py on tiny tables. Run: python -m unittest discover -s tools/tests -v"""
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import gen_recipes as G  # noqa: E402
import import_wowhead as W  # noqa: E402

BAR, STONE, PLANS, BOP_PLANS, THREAD, GHOST = 1, 2, 10, 11, 2320, 999


def item(i, name, sell=0, buy=0, lot=1, stack=1, bonding=0, req=0, faction=0, rep=0):
    return {"ID": str(i), "Display_lang": name, "SellPrice": str(sell), "BuyPrice": str(buy),
            "VendorStackCount": str(lot), "Stackable": str(stack), "RequiredSkillRank": str(req),
            "Bonding": str(bonding), "MinFactionID": str(faction), "MinReputation": str(rep)}


def ability(i, line, spell, low, high, acquire=0):
    return {"ID": str(i), "SkillLine": str(line), "Spell": str(spell), "TrivialSkillLineRankLow": str(low),
            "TrivialSkillLineRankHigh": str(high), "AcquireMethod": str(acquire), "NumSkillUps": "1"}


def reagents(spell, *pairs):
    row = {"SpellID": str(spell)}
    for k in range(8):
        row[f"Reagent_{k}"] = str(pairs[k][0]) if k < len(pairs) else "0"
        row[f"ReagentCount_{k}"] = str(pairs[k][1]) if k < len(pairs) else "0"
    return row


def tables():
    """Line 164: 100 auto, 101 trainer, 102 from tradeable plans, 103 from bind-on-pickup plans, 104 needs an item
    the build lacks, 105 a dead name, 106 no skill range. Line 186: one smelt that turns grey at 50."""
    spells = {100: "Rough Stone", 101: "Copper Belt", 102: "Copper Axe", 103: "Fine Axe", 104: "Ghost Blade",
              105: "OLD Belt", 106: "Polish", 200: "Smelt Copper"}
    return {
        "SkillLine": [{"ID": "164", "DisplayName_lang": "Blacksmithing"}, {"ID": "186", "DisplayName_lang": "Mining"},
                      {"ID": "633", "DisplayName_lang": "Lockpicking"}],
        "SpellName": [{"ID": str(k), "Name_lang": v} for k, v in spells.items()],
        "ItemSparse": [item(BAR, "Bar", sell=5, stack=20), item(STONE, "Stone", sell=2),
                       item(PLANS, "Plans: Copper Axe", sell=25, buy=100, req=40),
                       item(BOP_PLANS, "Plans: Fine Axe", buy=500, bonding=1, req=60, faction=529, rep=5),
                       item(THREAD, "Coarse Thread", buy=50, lot=5)],
        "SpellReagents": [reagents(100, (BAR, 1)), reagents(101, (BAR, 2), (THREAD, 1)), reagents(102, (BAR, 3)),
                          reagents(103, (BAR, 4)), reagents(104, (GHOST, 1)), reagents(105, (BAR, 1)),
                          reagents(106, (BAR, 1)), reagents(200, (BAR, 1))],
        "SpellEffect": [{"SpellID": "100", "Effect": "24", "EffectItemType": str(STONE), "EffectBasePointsF": "2"}],
        "ItemXItemEffect": [{"ItemEffectID": "1", "ItemID": str(PLANS)}, {"ItemEffectID": "2", "ItemID": str(BOP_PLANS)}],
        "ItemEffect": [{"ID": "1", "TriggerType": "6", "SpellID": "102"}, {"ID": "2", "TriggerType": "6", "SpellID": "103"}],
        "SkillLineAbility": [ability(1, 164, 100, 15, 55, acquire=1), ability(2, 164, 101, 45, 65),
                             ability(3, 164, 102, 60, 80), ability(4, 164, 103, 80, 100), ability(5, 164, 104, 90, 110),
                             ability(6, 164, 105, 1, 20), ability(7, 164, 106, 0, 0), ability(8, 164, 100, 15, 55),
                             ability(9, 186, 200, 25, 50, acquire=1)],
    }


def overlay(**over):
    return {**G.EMPTY_OVERLAY, **over}


class BuildData(unittest.TestCase):
    def test_client_tables_alone(self):
        data, warnings = G.build_data(tables(), "1.0.0.1")
        bs = data["professions"][164]["recipes"]
        self.assertEqual(sorted(bs), [100, 101, 102, 103, 104])  # dead name, no range and the duplicate row are out
        self.assertEqual((bs[100]["src"], bs[100]["makes"], bs[100]["n"]), ("auto", STONE, 2))
        self.assertEqual((bs[101]["src"], bs[101]["learn"], bs[101]["mats"]), ("trainer", None, [BAR, 2, THREAD, 1]))
        # a recipe item: its required skill is the learn rank; BuyPrice is what a vendor would ask
        self.assertEqual((bs[102]["src"], bs[102]["item"], bs[102]["learn"], bs[102]["buy"], bs[102]["bop"]),
                         ("item", PLANS, 40, 100, None))
        self.assertTrue(any("no ItemSparse row" in w for w in warnings))

    def test_bonding_one_is_bind_on_pickup_and_nothing_else_is(self):
        t = tables()
        t["ItemSparse"].append(item(12, "Plans: Other", bonding=2))
        t["ItemXItemEffect"].append({"ItemEffectID": "3", "ItemID": "12"})
        t["ItemEffect"].append({"ID": "3", "TriggerType": "6", "SpellID": "101"})
        bs = G.build_data(t, "b")[0]["professions"][164]["recipes"]
        self.assertIs(bs[103]["bop"], True)
        self.assertEqual((bs[103]["faction"], bs[103]["rep"]), (529, 5))
        self.assertIsNone(bs[101]["bop"])  # Bonding 2 (when equipped) is tradeable
        self.assertIsNone(bs[102]["bop"])

    def test_gone_without_an_overlay_and_kept_when_the_overlay_lists_it(self):
        bs = G.build_data(tables(), "b")[0]["professions"][164]["recipes"]
        self.assertIs(bs[104]["gone"], True)
        listed = overlay(listed={164}, recipes={100: {}, 101: {}, 102: {}, 103: {}, 104: {"src": "trainer"}})
        data, _ = G.build_data(tables(), "b", listed)
        self.assertIsNone(data["professions"][164]["recipes"][104]["gone"])
        self.assertEqual(data["stats"]["listed_gone"], 1)

    def test_vendor_price_is_per_item_of_the_vendor_lot(self):
        data, _ = G.build_data(tables(), "b", overlay(vendor={BAR}))
        self.assertEqual(data["vendor"][THREAD], 10)  # 50 copper for a lot of 5
        self.assertNotIn(BAR, data["vendor"])  # no BuyPrice: not a vendor item, and the overlay is told

    def test_overlay_wins_over_the_client_tables(self):
        over = overlay(listed={164}, recipes={
            100: {}, 101: {"src": "trainer", "learn": 30, "cost": 250, "g": 90},
            102: {"src": "vendor", "learn": 45, "vendor": {"name": "Smith", "npc": 7, "h": -1}},
            103: {"src": "quest"}})
        data, _ = G.build_data(tables(), "b", over)
        bs = data["professions"][164]["recipes"]
        self.assertEqual((bs[101]["learn"], bs[101]["cost"], bs[101]["y"], bs[101]["g"]), (30, 250, 45, 90))
        self.assertEqual(data["stats"]["thresholds"], 1)
        self.assertEqual((bs[102]["src"], bs[102]["from"], bs[102]["learn"], bs[102]["vendor"]["name"]),
                         ("item", "vendor", 45, "Smith"))
        self.assertEqual((bs[103]["src"], bs[103]["from"], bs[103]["bop"]), ("item", "quest", True))
        # a source with no recipe item in the client data teaches it itself: a special recipe
        t = tables()
        t["ItemEffect"] = []
        special = G.build_data(t, "b", over)[0]["professions"][164]["recipes"][103]
        self.assertEqual((special["src"], special["teacher"]), ("special", "a quest"))

    def test_unlisted_only_in_a_listed_profession(self):
        data, _ = G.build_data(tables(), "b", overlay(listed={164}, recipes={100: {}, 101: {}}))
        bs = data["professions"][164]["recipes"]
        self.assertEqual([bs[s]["src"] for s in (100, 101, 102, 103)], ["auto", "trainer", "unlisted", "unlisted"])
        self.assertIs(bs[101]["unc"], True)  # listed with no source: a trainer recipe nothing confirms
        self.assertEqual(data["professions"][186]["recipes"][200]["src"], "auto")  # Mining is not a listed line
        self.assertTrue(any("Copper Axe" in line for line in G.summary(data)))

    def test_level_gate_ranks_world_and_counts(self):
        over = overlay(listed={164}, recipes={101: {"level": 30}},
                       ranks={164: [{"name": "Journeyman", "cap": 150, "skill": 50, "cost": 400},
                                    {"name": "Artisan", "cap": 300, "where": "quest"}]})
        data, _ = G.build_data(tables(), "b", over)
        prof = data["professions"][164]
        self.assertEqual(prof["recipes"][101]["level"], 30)
        self.assertIsNone(prof["recipes"][101]["unc"])
        ranks = {r["name"]: r for r in prof["ranks"]}
        self.assertEqual((ranks["Journeyman"]["cost"], ranks["Journeyman"]["where"]), (400, "trainer"))
        self.assertEqual((ranks["Expert"]["where"], ranks["Expert"]["skill"]), ("unknown", 125))
        self.assertEqual((ranks["Artisan"]["where"], ranks["Artisan"]["cost"], ranks["Artisan"]["skill"]),
                         ("quest", None, 200))
        self.assertTrue(all(r["confirmed"] is False for r in prof["ranks"]))
        # Mining and Lockpicking are raised in the world; Lockpicking has no recipe and still gets an entry
        self.assertIs(data["professions"][186]["world"], True)
        self.assertEqual((data["professions"][633]["recipes"], data["professions"][633]["ranks"]), ({}, None))
        text = G.render(data)
        self.assertIn("counts = { [164] = 5, [186] = 1, [633] = 0 }", text)
        self.assertIn("world = true", text)


class Check(unittest.TestCase):
    def prof(self, *rows, **extra):
        recipes = {i: {"y": y, "g": g, "src": src, "learn": learn, "bop": bop, "gone": None}
                   for i, (y, g, src, learn, bop) in enumerate(rows)}
        return {"name": "Test", "recipes": recipes, **extra}

    def test_coverage_counts_a_recipe_from_where_it_can_be_learned(self):
        prof = self.prof((1, 40, "auto", None, None), (60, 90, "trainer", 35, None), (120, 300, "item", 100, None),
                         (90, 130, "item", 80, True), (85, 125, "unlisted", 1, None))
        self.assertEqual(G.coverage(prof), [(90, 99)])  # the bind-on-pickup and the unlisted recipe do not count
        self.assertEqual(G.coverage(prof, items=False), [(90, 299)])
        no_learn = self.prof((1, 40, "auto", None, None), (60, 90, "trainer", None, None))
        self.assertEqual(G.coverage(no_learn, top=90), [(40, 59)])  # no learn rank: from yellow

    def test_a_hole_is_an_error_and_a_world_skill_needs_spots(self):
        hole = {"professions": {1: self.prof((1, 40, "auto", None, None))}}
        lines, bad = G.check(hole)
        self.assertTrue(bad)
        self.assertIn("HOLE: nothing gives skill at 40-300", lines[0])
        world = {"professions": {186: self.prof((1, 50, "auto", None, None), world=True)}}
        lines, bad = G.check(world)
        self.assertFalse(bad)
        self.assertIn("needs world spots", lines[0])
        # with the spots file: a target covers its requirement and the 100 points above it
        lines, bad = G.check(world, {186: [1, 65, 150, 245]})
        self.assertFalse(bad)
        lines, bad = G.check(world, {186: [1, 65, 245]})
        self.assertTrue(bad)
        self.assertIn("165-245", lines[0])

    def test_reads_the_requirements_out_of_a_spots_file(self):
        text = ("ns.Data.spots = {\n\tskills = {\n\t\t[186] = {\n\t\t\tname = \"Mining\",\n\t\t\ttargets = {\n"
                "\t\t\t\t[\"copper\"] = { name = \"Copper Vein\", req = 1, n = 3 },\n"
                "\t\t\t\t[\"tin\"] = { name = \"Tin Vein\", req = 65 },\n\t\t\t},\n"
                "\t\t\tspots = {\n\t\t\t\t{ req = 999 },\n\t\t\t},\n\t\t},\n\t},\n}\n")
        self.assertEqual(G.spot_requirements(text), {186: [1, 65]})


class Overlay(unittest.TestCase):
    def write(self, obj):
        f = Path(tempfile.mkdtemp()) / "overlay.json"
        f.write_text(json.dumps(obj), encoding="utf-8")
        return f

    def test_a_missing_file_is_an_empty_overlay(self):
        self.assertEqual(G.load_overlay(Path(tempfile.mkdtemp()) / "none.json")["recipes"], {})

    def test_bad_entries_are_named(self):
        for bad, text in (({"recipes": {"x": {}}}, "spell id"), ({"recipes": {"1": {"learn": -1}}}, "learn"),
                          ({"recipes": {"1": {"src": "gift"}}}, "src"), ({"recipes": {"1": {"colour": 1}}}, "colour"),
                          ({"vendor": ["a"]}, "vendor"), ({"ranks": {"164": [{"name": "A"}]}}, "rank row")):
            with self.assertRaises(G.GenError) as e:
                G.load_overlay(self.write(bad))
            self.assertIn(text, str(e.exception))

    def test_a_numbered_source_is_kept(self):
        got = G.load_overlay(self.write({"recipes": {"5": {"src": 16}}, "listed": [164]}))
        self.assertEqual((got["recipes"][5]["src"], got["listed"]), (16, {164}))


class ImportWowhead(unittest.TestCase):
    def test_facts_only_and_only_where_they_differ(self):
        db2, _ = G.build_data(tables(), "b")
        research = {
            "ranks": {"164": [{"rank": "Journeyman", "learn": 50, "cost": 500, "source": [6]},
                              {"rank": "Apprentice", "learn": 9999, "cost": 10, "source": [6]},
                              {"rank": "Artisan", "learn": 9999, "cost": None, "source": [4]},
                              {"rank": "Artisan", "learn": 9999, "cost": None, "source": None}]},
            "recipes": {
                "101": {"skill": 164, "learn": 30, "colors": [30, 45, 55, 90], "cost": 250, "source": [5, 6]},
                "102": {"skill": 164, "learn": 40, "colors": [40, 60, 70, 80], "cost": None, "source": [2]},
                "100": {"skill": 164, "learn": 9999, "colors": [0, 15, 35, 55], "source": None},
                "200": {"skill": 186, "learn": None, "colors": None, "level": 20, "source": [16]},
                "777": {"skill": 164, "learn": 1, "colors": [1, 1, 1, 1], "source": [6]},
            },
        }
        items = {str(PLANS): {"source": [5], "sourcemore": [{"n": "Smith", "t": 1, "ti": 7, "z": 3}]}}
        npcs = {"7": {"react": [1, -1]}}
        manual = {"recipes": {"100": {"src": "special", "teacher": "a quest", "note": "seen in game"}}, "vendor": [BAR]}
        out, stats = W.convert(research, items, npcs, db2, "2026-01-02", "b", manual)
        r = out["recipes"]
        self.assertEqual(r[101], {"src": "trainer", "learn": 30, "cost": 250, "g": 90})  # y equals the build's
        # the recipe item's own source and vendor, linked through the client data; learn 40 is the item's
        self.assertEqual(r[102], {"src": "vendor", "vendor": {"name": "Smith", "npc": 7, "zone": 3, "a": 1, "h": -1}})
        self.assertEqual(r[100]["src"], "special")  # the hand-kept entry goes on top
        self.assertEqual(r[200], {"src": 16, "level": 20})  # an unnamed code stays a number; learned by level
        self.assertNotIn(777, r)
        self.assertEqual((stats["thresholds"], stats["not_in_build"], out["listed"]), (1, 1, [164, 186]))
        self.assertEqual(out["source"], {"name": "Wowhead, Forever section", "retrieved": "2026-01-02",
                                         "compared_with_build": "b"})
        self.assertEqual(out["ranks"][164], [
            {"name": "Apprentice", "cap": 75, "skill": None, "cost": 10},
            {"name": "Journeyman", "cap": 150, "skill": 50, "cost": 500},
            {"name": "Artisan", "cap": 300, "where": "quest"}])
        # what is written is what the generator reads
        f = Path(tempfile.mkdtemp()) / "overlay.json"
        f.write_text(W.render(out), encoding="utf-8")
        back = G.load_overlay(f)
        self.assertEqual((back["recipes"][101]["g"], back["vendor"], back["listed"]), (90, {BAR}, {164, 186}))


if __name__ == "__main__":
    unittest.main()
