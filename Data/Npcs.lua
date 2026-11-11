-- Where the guide looks first: Horde trade-supply and cooking vendors, Leatherworking and Cooking trainers and
-- auctioneers. Coordinates are Wowhead Classic first spawn points (percent on uiMap `map`), so approximate: an NPC
-- the player opens is learned (SkillupHelperDB.guide.npcs) and that record replaces the seed with the same id.
-- role: trade (trade supplies), cook (spice vendor, sells only), lwtrainer, cooktrainer, auction.
local _, ns = ...
ns.Data = ns.Data or {}

ns.Data.npcs = {
	{ id = 8673, name = "Auctioneer Thathung", map = 1454, x = 55.6, y = 62.8, role = "auction", place = "Orgrimmar" }, -- https://www.wowhead.com/classic/npc=8673
	{ id = 8724, name = "Auctioneer Wabang", map = 1454, x = 55.4, y = 64.8, role = "auction", place = "Orgrimmar" }, -- https://www.wowhead.com/classic/npc=8724
	{ id = 3399, name = "Zamja", map = 1454, x = 57.4, y = 53.4, role = "cooktrainer", place = "Orgrimmar" }, -- https://www.wowhead.com/classic/npc=3399
	{ id = 3400, name = "Xen'to", map = 1454, x = 57.4, y = 53.2, role = "cook", place = "Orgrimmar", sells = { 2678, 2692, 3713 } }, -- https://www.wowhead.com/classic/npc=3400
	{ id = 5811, name = "Kamari", map = 1454, x = 63, y = 45, role = "lwtrainer", place = "Orgrimmar" }, -- https://www.wowhead.com/classic/npc=5811
	{ id = 3365, name = "Karolek", map = 1454, x = 62.8, y = 44.4, role = "lwtrainer", place = "Orgrimmar" }, -- https://www.wowhead.com/classic/npc=3365
	{ id = 3366, name = "Tamar", map = 1454, x = 62.4, y = 45.4, role = "trade", place = "Orgrimmar", sells = { 2320, 2321, 4289, 4291, 4340, 8343 } }, -- https://www.wowhead.com/classic/npc=3366
	{ id = 5817, name = "Shimra", map = 1454, x = 48, y = 80.2, role = "trade", place = "Orgrimmar", sells = { 2320, 2321, 2324, 2678, 2692, 3713, 4289, 4291, 4340, 8343 } }, -- https://www.wowhead.com/classic/npc=5817
	{ id = 3364, name = "Borya", map = 1454, x = 63, y = 51.2, role = "trade", place = "Orgrimmar", sells = { 2320, 2321, 2324, 4291, 4340, 8343 } }, -- https://www.wowhead.com/classic/npc=3364
	{ id = 8674, name = "Auctioneer Stampi", map = 1456, x = 40.4, y = 52.2, role = "auction", place = "Thunder Bluff" }, -- https://www.wowhead.com/classic/npc=8674
	{ id = 8722, name = "Auctioneer Gullem", map = 1456, x = 38.8, y = 50.4, role = "auction", place = "Thunder Bluff" }, -- https://www.wowhead.com/classic/npc=8722
	{ id = 3026, name = "Aska Mistrunner", map = 1456, x = 51, y = 52.8, role = "cooktrainer", place = "Thunder Bluff" }, -- https://www.wowhead.com/classic/npc=3026
	{ id = 3008, name = "Mak", map = 1456, x = 42.2, y = 43.2, role = "lwtrainer", place = "Thunder Bluff" }, -- https://www.wowhead.com/classic/npc=3008
	{ id = 11084, name = "Tarn", map = 1456, x = 42.4, y = 43, role = "lwtrainer", place = "Thunder Bluff" }, -- https://www.wowhead.com/classic/npc=11084
	{ id = 3007, name = "Una", map = 1456, x = 41.6, y = 42.4, role = "lwtrainer", place = "Thunder Bluff" }, -- https://www.wowhead.com/classic/npc=3007
	{ id = 3005, name = "Mahu", map = 1456, x = 43.4, y = 43.8, role = "trade", place = "Thunder Bluff", sells = { 2320, 2321, 2324, 4289, 4291, 4340, 8343 } }, -- https://www.wowhead.com/classic/npc=3005
	{ id = 8363, name = "Shadi Mistrunner", map = 1456, x = 40.4, y = 63.4, role = "trade", place = "Thunder Bluff", sells = { 2320, 2321, 2324, 2678, 2692, 3713, 4289, 4291, 4340, 8343 } }, -- https://www.wowhead.com/classic/npc=8363
	{ id = 8672, name = "Auctioneer Leeka", map = 1458, x = 67.8, y = 52.2, role = "auction", place = "Undercity" }, -- https://www.wowhead.com/classic/npc=8672
	{ id = 8721, name = "Auctioneer Epitwee", map = 1458, x = 63.4, y = 51.8, role = "auction", place = "Undercity" }, -- https://www.wowhead.com/classic/npc=8721
	{ id = 4552, name = "Eunice Burch", map = 1458, x = 62.2, y = 44.4, role = "cooktrainer", place = "Undercity" }, -- https://www.wowhead.com/classic/npc=4552
	{ id = 4553, name = "Ronald Burch", map = 1458, x = 62.4, y = 43.4, role = "cook", place = "Undercity", sells = { 2678, 2692, 3713 } }, -- https://www.wowhead.com/classic/npc=4553
	{ id = 223, name = "Dan Golthas", map = 1458, x = 70.4, y = 58.4, role = "lwtrainer", place = "Undercity" }, -- https://www.wowhead.com/classic/npc=223
	{ id = 4588, name = "Arthur Moore", map = 1458, x = 70.2, y = 57.4, role = "lwtrainer", place = "Undercity" }, -- https://www.wowhead.com/classic/npc=4588
	{ id = 4589, name = "Joseph Moore", map = 1458, x = 70.2, y = 58, role = "trade", place = "Undercity", sells = { 2320, 2321, 4289, 4291, 4340, 8343 } }, -- https://www.wowhead.com/classic/npc=4589
	{ id = 4561, name = "Daniel Bartlett", map = 1458, x = 64.2, y = 37.4, role = "trade", place = "Undercity", sells = { 2320, 2321, 2324, 2678, 2692, 3713, 4289, 4291, 4340, 8343 } }, -- https://www.wowhead.com/classic/npc=4561
	{ id = 4775, name = "Felicia Doan", map = 1458, x = 64.2, y = 50.2, role = "trade", place = "Undercity", sells = { 2320, 2321, 2324, 2678, 2692, 3713, 4289, 4291 } }, -- https://www.wowhead.com/classic/npc=4775
	{ id = 4577, name = "Millie Gregorian", map = 1458, x = 70.4, y = 29.4, role = "trade", place = "Undercity", sells = { 2320, 2321, 2324, 4291, 4340, 8343 } }, -- https://www.wowhead.com/classic/npc=4577
	{ id = 3081, name = "Wunna Darkmane", map = 1412, x = 46.2, y = 58.2, role = "trade", place = "Bloodhoof Village", sells = { 2320, 2324, 2678, 4289 } }, -- https://www.wowhead.com/classic/npc=3081
	{ id = 3067, name = "Pyall Silentstride", map = 1412, x = 45.4, y = 58, role = "cooktrainer", place = "Bloodhoof Village" }, -- https://www.wowhead.com/classic/npc=3067
	{ id = 3069, name = "Chaw Stronghide", map = 1412, x = 45.4, y = 57.8, role = "lwtrainer", place = "Bloodhoof Village" }, -- https://www.wowhead.com/classic/npc=3069
	{ id = 3482, name = "Tari'qa", map = 1413, x = 51.6, y = 30, role = "trade", place = "Crossroads", sells = { 2320, 2321, 2324, 2678, 2692, 4289 } }, -- https://www.wowhead.com/classic/npc=3482
	{ id = 3485, name = "Wrahk", map = 1413, x = 52.2, y = 31.6, role = "trade", place = "Crossroads", sells = { 2320, 2321, 2324, 4291, 4340, 8343 } }, -- https://www.wowhead.com/classic/npc=3485
	{ id = 8306, name = "Duhng", map = 1413, x = 55.2, y = 31.8, role = "cooktrainer", place = "Crossroads" }, -- https://www.wowhead.com/classic/npc=8306
	{ id = 8307, name = "Tarban Hearthgrain", map = 1413, x = 55, y = 32, role = "cook", place = "Crossroads", sells = { 2678, 2692, 3713 } }, -- https://www.wowhead.com/classic/npc=8307
	{ id = 3703, name = "Krulmoo Fullmoon", map = 1413, x = 44.8, y = 59.4, role = "lwtrainer", place = "Camp Taurajo" }, -- https://www.wowhead.com/classic/npc=3703
	{ id = 5944, name = "Yonada", map = 1413, x = 45, y = 59.2, role = "trade", place = "Camp Taurajo", sells = { 2320, 2321, 2324, 4289, 4291, 4340, 8343 } }, -- https://www.wowhead.com/classic/npc=5944
	{ id = 3499, name = "Ranik", map = 1413, x = 61.8, y = 38.6, role = "trade", place = "Ratchet", sells = { 2320, 2321, 2324, 2678, 2692, 4289 } }, -- https://www.wowhead.com/classic/npc=3499
	{ id = 4877, name = "Jandia", map = 1441, x = 46, y = 51.4, role = "trade", place = "Freewind Post", sells = { 2320, 2321, 2324, 2678, 2692, 3713, 4289, 4291 } }, -- https://www.wowhead.com/classic/npc=4877
	{ id = 12043, name = "Kulwia", map = 1442, x = 45.4, y = 59.4, role = "trade", place = "Sun Rock Retreat", sells = { 2320, 2321, 2324, 2678, 2692, 4289 } }, -- https://www.wowhead.com/classic/npc=12043
	{ id = 2819, name = "Tunkk", map = 1417, x = 74.8, y = 34.4, role = "trade", place = "Hammerfall", sells = { 2320, 2321, 4289, 4291, 4340, 8343 } }, -- https://www.wowhead.com/classic/npc=2819
	{ id = 2821, name = "Keena", map = 1417, x = 74, y = 32.6, role = "trade", place = "Hammerfall", sells = { 2320, 2321, 2678, 2692, 3713, 4289, 4291, 4340, 8343 } }, -- https://www.wowhead.com/classic/npc=2821
	{ id = 6574, name = "Jun'ha", map = 1417, x = 72.6, y = 36.4, role = "trade", place = "Hammerfall", sells = { 2320, 2321, 2324, 4291, 4340, 8343 } }, -- https://www.wowhead.com/classic/npc=6574
	{ id = 2393, name = "Christoph Jeffcoat", map = 1424, x = 62.2, y = 19, role = "trade", place = "Tarren Mill", sells = { 2320, 2321, 2324, 2678, 2692, 3713, 4289, 4291 } }, -- https://www.wowhead.com/classic/npc=2393
	{ id = 2394, name = "Mallen Swain", map = 1424, x = 62, y = 21, role = "trade", place = "Tarren Mill", sells = { 2320, 2321, 2324, 4291, 4340, 8343 } }, -- https://www.wowhead.com/classic/npc=2394
	{ id = 2397, name = "Derak Nightfall", map = 1424, x = 63, y = 19.4, role = "cook", place = "Tarren Mill", sells = { 2678, 2692, 3713 } }, -- https://www.wowhead.com/classic/npc=2397
	{ id = 1148, name = "Nerrist", map = 1434, x = 32.6, y = 29.2, role = "trade", place = "Grom'gol", sells = { 2320, 2321, 2678, 2692, 3713, 4289, 4291, 4340, 8343 } }, -- https://www.wowhead.com/classic/npc=1148
	{ id = 1382, name = "Mudduk", map = 1434, x = 31.4, y = 28, role = "cooktrainer", place = "Grom'gol" }, -- https://www.wowhead.com/classic/npc=1382
	{ id = 1385, name = "Brawn", map = 1434, x = 31.6, y = 28.8, role = "lwtrainer", place = "Grom'gol" }, -- https://www.wowhead.com/classic/npc=1385
	{ id = 2664, name = "Kelsey Yance", map = 1434, x = 28.2, y = 74.4, role = "cook", place = "Booty Bay", sells = { 2678, 2692, 3713 } }, -- https://www.wowhead.com/classic/npc=2664
	{ id = 2699, name = "Rikqiz", map = 1434, x = 28.4, y = 76, role = "trade", place = "Booty Bay", sells = { 2320, 2321, 4289, 4291, 4340, 8343 } }, -- https://www.wowhead.com/classic/npc=2699
	{ id = 2846, name = "Blixrez Goodstitch", map = 1434, x = 28.2, y = 77.4, role = "trade", place = "Booty Bay", sells = { 2320, 2321, 4289, 4291, 4340, 8343 } }, -- https://www.wowhead.com/classic/npc=2846
	{ id = 9858, name = "Auctioneer Kresky", map = 1434, x = 27.8, y = 77, role = "auction", place = "Booty Bay" }, -- https://www.wowhead.com/classic/npc=9858
	{ id = 15677, name = "Auctioneer Graves", map = 1434, x = 28.4, y = 75.8, role = "auction", place = "Booty Bay" }, -- https://www.wowhead.com/classic/npc=15677
	{ id = 6567, name = "Ghok'kah", map = 1445, x = 35.2, y = 30.8, role = "trade", place = "Brackenwall Village", sells = { 2320, 2321, 2324, 4291, 4340, 8343 } }, -- https://www.wowhead.com/classic/npc=6567
	{ id = 6568, name = "Vizzklick", map = 1446, x = 51, y = 27.4, role = "trade", place = "Gadgetzan", sells = { 2320, 2321, 2324, 4291, 4340, 8343 } }, -- https://www.wowhead.com/classic/npc=6568
	{ id = 8661, name = "Auctioneer Beardo", map = 1446, x = 52, y = 29.6, role = "auction", place = "Gadgetzan" }, -- https://www.wowhead.com/classic/npc=8661
	{ id = 8145, name = "Sheendra Tallgrass", map = 1444, x = 74.4, y = 42.8, role = "trade", place = "Camp Mojache", sells = { 2320, 2321, 2324, 2678, 2692, 3713, 4289, 4291, 4340, 8343 } }, -- https://www.wowhead.com/classic/npc=8145
	{ id = 7854, name = "Jangdor Swiftstrider", map = 1444, x = 74.4, y = 42.8, role = "trade", place = "Camp Mojache", sells = { 2320, 2321, 4289, 4291, 4340, 8343 } }, -- https://www.wowhead.com/classic/npc=7854
	{ id = 11098, name = "Hahrana Ironhide", map = 1444, x = 74.4, y = 43, role = "lwtrainer", place = "Camp Mojache" }, -- https://www.wowhead.com/classic/npc=11098
	{ id = 12028, name = "Lah'Mawhani", map = 1443, x = 23, y = 71.6, role = "trade", place = "Shadowprey Village", sells = { 2320, 2321, 2324, 2678, 2692, 3713, 4289, 4291, 4340, 8343 } }, -- https://www.wowhead.com/classic/npc=12028
	{ id = 12033, name = "Wulan", map = 1443, x = 26.2, y = 69.8, role = "cook", place = "Shadowprey Village", sells = { 2678, 2692, 3713 } }, -- https://www.wowhead.com/classic/npc=12033
	{ id = 8153, name = "Narv Hidecrafter", map = 1443, x = 55.2, y = 56.2, role = "lwtrainer", place = "Ghost Walker Post" }, -- https://www.wowhead.com/classic/npc=8153
	{ id = 9636, name = "Kireena", map = 1443, x = 51, y = 53.4, role = "trade", place = "Ghost Walker Post", sells = { 2320, 2321, 2324, 2678, 2692, 3713, 4289, 4291, 4340, 8343 } }, -- https://www.wowhead.com/classic/npc=9636
}
