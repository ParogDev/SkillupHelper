#!/usr/bin/env python3
"""Read the WoW: Forever pages of wow-professions.com (no llms.txt; a sitemap and plain HTML).

Facts only: skill ranges, Wowhead Forever spell / item / quest / npc ids, counts, factions, map coordinates and
trainer rank rows. No sentence of a page is kept, and nothing fetched is committed (see docs/data-sources.md).

    python tools/wowprof.py list                         # every Forever page in the sitemap, by kind
    python tools/wowprof.py guide leatherworking         # a leveling guide's route, as text
    python tools/wowprof.py guide cooking --json         # ... as JSON
    python tools/wowprof.py npc hahrana-ironhide         # an NPC: role, place, map + coords, trainer ranks
    python tools/wowprof.py guide cooking --html FILE    # parse a saved page instead of fetching
    python tools/wowprof.py trainers leatherworking cooking --out tools/data/npcs_site.json
                                                         # every NPC of the trainers pages and the guides' unlock
                                                         # records: name, role, map + coords, rank, rank rows

Page shapes this parser knows (checked 2026-11-22, the guides' data-steps-version="4"):
  * a route section is an <h2> whose title ends in "(from-to)" (Apprentice / Journeyman / Expert / Artisan);
  * a step is <div class="route-step"> with <div class="route-range">from-to</div>; a step without one takes its
    section's range (Cooking 1-50);
  * an option is "Nx <a href=wowhead.com/forever/spell=ID>" (N may be "65-75"); an <h4> inside a step starts the
    alternatives ("Alternative recipe(s)" or a pattern's name); a table row whose first cell is a range is a
    sub-step of that alternative; "(Horde only)" / "(Alliance only)" / "(Horde)" / "(Alliance)" in the same
    paragraph or row tags the option's faction;
  * the intro of a rank section (between its <h2> and the first step, table or tabs) says how the rank is learned:
    "<Profession> N" and "level N", trainer links <a href="/forever/npc/SLUG">, a wowhead quest= link (the rank is a
    quest reward) or a wowhead item= link in the same <p> as NPC links (a book they sell), and "Nx <item link>" for
    what a quest wants; an NPC's faction is its horde.png / alliance.png icon, "(Horde)" / "(Alliance)" after the
    link, or a "Horde trainers:" / "Alliance trainers:" column heading above it;
  * an NPC page has the h1 "Name - <Rank> <Profession> Trainer[ in Town]", data-clipboard-text="/way #MAP X Y NAME"
    and maybe a rank table (Rank, Required skill, Required level, Cost) whose cost cell is
    <span class="goldmoney|silvermoney|coppermoney">N</span>; no NPC id is on the page;
  * a trainers page (/forever/<profession>-trainers) links each of its NPCs as /forever/npc/SLUG.

parse_guide's "unlocks", one record per rank section after the first (Apprentice needs nothing): { section, from,
to, rank ("Expert"), skill, level, kind ("quest" | "book" | "trainer"), quest, questName, item (the book),
items [[id, count], ...], names {item id: name}, npcs [{ slug, name, faction "H" | "A" | None, quest }] }. For a
quest or a book, npcs are the ones in the same paragraph as its link; for a trainer rank, every NPC the intro links.
Horde / Alliance tabs (<div class="tab-content is-horde">) in a quest intro give their NPCs that faction, and when
the tabs name different quests each NPC carries its own `quest` (the record's quest is the first one).
A change of shape fails loudly (no route section, a step with no option) instead of returning a short route.
"""

from __future__ import annotations

import argparse
import html as htmllib
import json
import re
import sys
import time
import urllib.request

BASE = "https://www.wow-professions.com"
UA = "Mozilla/5.0 (compatible; SkillupHelper data tool)"

GUIDE_SLUGS = {
    "alchemy": "alchemy-leveling-guide",
    "blacksmithing": "blacksmithing-leveling-guide",
    "cooking": "cooking-leveling-guide",
    "enchanting": "enchanting-leveling-guide",
    "engineering": "engineering-leveling-guide",
    "first-aid": "first-aid-leveling-guide",
    "fishing": "fishing-leveling-guide",
    "herbalism": "herbalism-leveling-guide",
    "leatherworking": "leatherworking-leveling-guide",
    "lockpicking": "lockpicking-leveling-guide",
    "mining": "mining-leveling-guide",
    "skinning": "skinning-leveling-guide",
    "tailoring": "tailoring-leveling-guide",
}

# Skill line ids (Data/Recipes.lua) of the crafting guides
SKILL_LINE = {
    "alchemy": 171,
    "blacksmithing": 164,
    "cooking": 185,
    "enchanting": 333,
    "engineering": 202,
    "first-aid": 129,
    "leatherworking": 165,
    "tailoring": 197,
}


class ShapeError(Exception):
    """The page no longer has the shape this parser reads: fix the parser, never accept a short route."""


def fetch(path: str) -> str:
    url = path if path.startswith("http") else BASE + path
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read().decode("utf-8")


def text_of(fragment: str) -> str:
    t = re.sub(r"<[^>]+>", " ", fragment)
    return re.sub(r"\s+", " ", htmllib.unescape(t)).strip()


RANGE = re.compile(r"^\s*(\d+)\s*-\s*(\d+)\s*$")
SECTION = re.compile(r"\((\d+)\s*-\s*(\d+)\)\s*$")
OPTION = re.compile(
    r"(\d+(?:\s*-\s*\d+)?)x\s*<a\b[^>]*?wowhead\.com/forever/spell=(\d+)[^>]*>(?:\s*<img[^>]*>)?\s*([^<]*)</a>"
)
BARE_SPELL = re.compile(r"<a\b[^>]*?wowhead\.com/forever/spell=(\d+)[^>]*>(?:\s*<img[^>]*>)?\s*([^<]*)</a>")
FACTION = re.compile(r"\((Horde|Alliance)(?: only)?\)")


def _faction(fragment: str) -> str | None:
    # a row that names both factions' vendors ("Kendor Kabonka (Alliance) ... Keena (Horde)") is for both
    found = {m.group(1).lower() for m in FACTION.finditer(text_of(fragment))}
    return found.pop() if len(found) == 1 else None


def _blocks(step_html: str):
    """The step's paragraphs, headings, table rows and list items in order: (kind, html, list), where list is the
    offset and kind ("ul" / "ol") of the list a list item is in, else None."""
    for m in re.finditer(r"<(h4|p|tr|li)\b[^>]*>(.*?)</\1>", step_html, re.S):
        lst = None
        if m.group(1) == "li":
            opener = list(re.finditer(r"<(ul|ol)\b", step_html[: m.start()]))
            lst = (opener[-1].start(), opener[-1].group(1)) if opener else (0, "ul")
        yield m.group(1), m.group(2), lst


def _div_end(html: str, start: int) -> int:
    """The offset just past the </div> that closes the <div ...> opened at `start`."""
    depth = 0
    for m in re.compile(r"<div\b|</div>").finditer(html, start):
        depth += 1 if m.group(0) == "<div" else -1
        if depth == 0:
            return m.end()
    return len(html)


def _alt_tabs(section_html: str) -> list[tuple[int, int, str]]:
    """Spans (start, end, button label) of the tabs that hold another route than the active one (Enchanting's
    "Strange Dust" / "Lesser Magic Essence" tabs). Faction tabs (is-horde / is-alliance) are not routes."""
    out = []
    for m in re.finditer(r'<div class="tab-content( active)?"[^>]*\bid="([^"]+)"', section_html):
        if m.group(1):
            continue
        b = re.search(rf'data-tab="{re.escape(m.group(2))}"[^>]*>(.*?)</button>', section_html, re.S)
        out.append((m.start(), _div_end(section_html, m.start()), text_of(b.group(1)) if b else m.group(2)))
    return out


def _steps(section_html: str, srange):
    """Split a section into steps: route-step divs, or the whole section when it has none. (range, html, tab):
    tab is the label of the non-active route tab the step is in, else None."""
    starts = [m.start() for m in re.finditer(r'<div class="route-step">', section_html)]
    if not starts:
        return [(srange, section_html, None)]
    tabs = _alt_tabs(section_html)
    out = []
    # text before the first step (cooking 1-50 puts its table there) is a step of the section's range
    head = section_html[: starts[0]]
    if OPTION.search(head):
        out.append((srange, head, None))
    for i, st in enumerate(starts):
        end = starts[i + 1] if i + 1 < len(starts) else len(section_html)
        body = section_html[st:end]
        m = re.search(r'<div class="route-range">\s*([^<]*)</div>', body)
        r = RANGE.match(m.group(1)) if m else None
        tab = next((label for a, b, label in tabs if a <= st < b), None)
        out.append(((int(r.group(1)), int(r.group(2))) if r else srange, body, tab))
    return out


RANK_WORDS = ("apprentice", "journeyman", "expert", "artisan", "master")
NPC_LINK = re.compile(r'<a\b[^>]*?href="/forever/npc/([a-z0-9-]+)"[^>]*>(.*?)</a>', re.S)
QUEST_LINK = re.compile(r"<a\b[^>]*?wowhead\.com/forever/quest=(\d+)[^>]*>(.*?)</a>", re.S)
ITEM_LINK = re.compile(r"<a\b[^>]*?wowhead\.com/forever/item=(\d+)[^>]*>(.*?)</a>", re.S)
COUNTED_ITEM = re.compile(r"(\d+)x\s*<a\b[^>]*?wowhead\.com/forever/item=(\d+)[^>]*>(.*?)</a>", re.S)
SIDE = {"horde": "H", "alliance": "A"}


def _npc_faction(html: str, m) -> str | None:
    """H / A for the NPC link m: its icon, then "(Horde)" after it, then the column heading above it."""
    inner = m.group(2)
    if "horde.png" in inner:
        return "H"
    if "alliance.png" in inner:
        return "A"
    tail = html[m.end() :]
    stop = re.search(r"<a\b|</li>|</p>|</td>", tail)
    f = FACTION.search(text_of(tail[: stop.start() if stop else 200]))
    if f:
        return SIDE[f.group(1).lower()]
    before = text_of(html[: m.start()])
    h, a = before.rfind("Horde trainers:"), before.rfind("Alliance trainers:")
    if h >= 0 or a >= 0:
        return "H" if h > a else "A"
    return None


def _npcs(html: str) -> list[dict]:
    out, seen = [], set()
    for m in NPC_LINK.finditer(html):
        if m.group(1) not in seen:
            seen.add(m.group(1))
            out.append({"slug": m.group(1), "name": text_of(m.group(2)), "faction": _npc_faction(html, m)})
    return out


def parse_unlock(name: str, intro: str) -> dict:
    """How a rank section's rank is learned, read from the section's intro (see the module docstring)."""
    words = name.split()
    rank = words[0] if words and words[0].lower() in RANK_WORDS else None
    prof = SECTION.sub("", " ".join(words[1:] if rank else words)).strip()
    text = text_of(intro)
    skill = re.search(rf"\b{re.escape(prof)}\s+(\d+)", text) if prof else None
    level = re.search(r"\blevel\s+(\d+)", text, re.I)
    out = {"rank": rank, "skill": int(skill.group(1)) if skill else None,
           "level": int(level.group(1)) if level else None, "kind": "trainer", "quest": None, "questName": None,
           "item": None, "items": [], "names": {}, "npcs": []}
    paras = [p for _, p in re.findall(r"<(p|li)\b[^>]*>(.*?)</\1>", intro, re.S)]
    q = QUEST_LINK.search(intro)
    if q:
        out.update(kind="quest", quest=int(q.group(1)), questName=text_of(q.group(2)))
        # Horde / Alliance tabs may each name their own quest and quest giver (First Aid's Triage)
        cuts = [m for m in re.finditer(r'<div class="tab-content is-(horde|alliance)\b', intro)]
        parts = [(None, intro[: cuts[0].start()] if cuts else intro)]
        parts += [(SIDE[m.group(1)], intro[m.start() : cuts[i + 1].start() if i + 1 < len(cuts) else len(intro)])
                  for i, m in enumerate(cuts)]
        quests = set()
        for side, part in parts:
            for p in re.findall(r"<(?:p|li)\b[^>]*>(.*?)</(?:p|li)>", part, re.S):
                pq = QUEST_LINK.search(p)
                if not pq:
                    continue
                quests.add(int(pq.group(1)))
                for n in _npcs(p):
                    if n["slug"] not in {x["slug"] for x in out["npcs"]}:
                        n["faction"] = n["faction"] or side
                        n["quest"] = int(pq.group(1))
                        out["npcs"].append(n)
        if len(quests) <= 1:  # one quest for everyone: the record's quest says it
            for n in out["npcs"]:
                n.pop("quest", None)
    else:
        book = next((p for p in paras if ITEM_LINK.search(p) and NPC_LINK.search(p)), None)
        if book:
            it = ITEM_LINK.search(book)
            out.update(kind="book", item=int(it.group(1)))
            out["names"][int(it.group(1))] = text_of(it.group(2))
            out["npcs"] = _npcs(book)
        else:
            out["npcs"] = _npcs(intro)
    for m in COUNTED_ITEM.finditer(intro if out["kind"] == "quest" else ""):
        item = int(m.group(2))
        if item not in {i for i, _ in out["items"]}:
            out["items"].append([item, int(m.group(1))])
            out["names"][item] = text_of(m.group(3))
    return out


def _intro(section_html: str) -> str:
    """A section's text before its first step or route table."""
    cut = re.search(r'<div class="route-step"|<div class="table-container|<table\b', section_html)
    return section_html[: cut.start()] if cut else section_html


def parse_guide(page: str) -> dict:
    """The route of a leveling guide: sections, then steps with their options (main first, then alternatives)."""
    m = re.search(r"<main\b.*?</main>", page, re.S)
    body = m.group(0) if m else page
    version = re.search(r'data-steps-version="(\d+)"', page)
    title = re.search(r"<h1[^>]*>(.*?)</h1>", body, re.S)
    heads = list(re.finditer(r"<h2\b[^>]*>(.*?)</h2>", body, re.S))
    sections = []
    for i, h in enumerate(heads):
        name = text_of(h.group(1))
        r = SECTION.search(name)
        if not r:
            continue
        end = heads[i + 1].start() if i + 1 < len(heads) else len(body)
        sections.append((name, (int(r.group(1)), int(r.group(2))), body[h.end() : end]))
    if not sections:
        raise ShapeError("no route section: no <h2> title ends in '(from-to)'")
    steps = []
    for name, srange, shtml in sections:
        for (lo, hi), step_html, tab in _steps(shtml, srange):
            options = []
            # None: the main pick; else the <h4> that opened the alternative, or the route tab the step is in
            variant = tab
            lists_with_main = set()
            after_h4 = False
            for kind, frag, lst in _blocks(step_html):
                if kind == "h4":
                    variant, after_h4 = tab or text_of(frag), True
                    continue
                if lst and variant is None and OPTION.search(frag):
                    # "make one of these" (<ul>): the first item is the main pick, the others alternatives;
                    # "make both of these" (<ol>): every item is a main pick
                    if lst[1] == "ul" and lst[0] in lists_with_main:
                        for o in OPTION.finditer(frag):
                            count = o.group(1).replace(" ", "")
                            options.append({"spell": int(o.group(2)), "name": htmllib.unescape(o.group(3)).strip(),
                                            "count": int(count.partition("-")[2] or count.partition("-")[0]),
                                            "from": lo, "to": hi, "alt": True, "variant": "one of a list",
                                            "faction": _faction(frag)})
                        continue
                    lists_with_main.add(lst[0])
                sub = None
                if kind == "tr":
                    cells = re.findall(r"<t[dh]\b[^>]*>(.*?)</t[dh]>", frag, re.S)
                    r = RANGE.match(text_of(cells[0])) if cells else None
                    if r:
                        sub = (int(r.group(1)), int(r.group(2)))
                fac = _faction(frag)
                found = list(OPTION.finditer(frag))
                for o in found:
                    count = o.group(1).replace(" ", "")
                    a, _, b = count.partition("-")
                    options.append(
                        {
                            "spell": int(o.group(2)),
                            "name": htmllib.unescape(o.group(3)).strip(),
                            "count": int(b or a),
                            "from": (sub or (lo, hi))[0],
                            "to": (sub or (lo, hi))[1],
                            "alt": variant is not None,
                            "variant": variant,
                            "faction": fac,
                        }
                    )
                # "Make <spell> if you have ..." (an alternative with no count): an option for the step's range
                if not found and after_h4 and kind == "p":
                    for o in BARE_SPELL.finditer(frag):
                        options.append(
                            {
                                "spell": int(o.group(1)),
                                "name": htmllib.unescape(o.group(2)).strip(),
                                "count": None,
                                "from": lo,
                                "to": hi,
                                "alt": True,
                                "variant": variant,
                                "faction": fac,
                            }
                        )
            # one spell once per step and range (a table lists a recipe in its row and again in a note)
            seen, uniq = set(), []
            for o in options:
                key = (o["spell"], o["from"], o["to"])
                if key not in seen:
                    seen.add(key)
                    uniq.append(o)
            if not uniq:
                raise ShapeError(f"step {lo}-{hi} of '{name}' has no 'Nx <spell link>' option")
            # a table's first row is the main pick when the step has no main line (cooking's option tables)
            # (a step in another route tab is all alternatives: the active tab holds the main route)
            if all(o["alt"] for o in uniq) and tab is None:
                raise ShapeError(f"step {lo}-{hi} of '{name}' has alternatives but no main pick")
            steps.append({"section": name, "from": lo, "to": hi, "options": uniq})
    unlocks = []
    for name, (lo, hi), shtml in sections[1:]:  # the first rank (Apprentice) needs nothing
        unlocks.append({"section": name, "from": lo, "to": hi, **parse_unlock(name, _intro(shtml))})
    return {
        "title": text_of(title.group(1)) if title else None,
        "stepsVersion": int(version.group(1)) if version else None,
        "steps": steps,
        "unlocks": unlocks,
    }


def _rank_word(text: str | None) -> str | None:
    w = (text or "").split()
    return w[0].lower() if w and w[0].lower() in RANK_WORDS else None


def _copper(cell: str) -> int | None:
    """A cost cell in copper: the site's gold / silver / copper spans, else "1g 50s" text."""
    unit = {"gold": 10000, "silver": 100, "copper": 1, "g": 10000, "s": 100, "c": 1}
    spans = re.findall(r'class="(gold|silver|copper)money"[^>]*>\s*(\d+)\s*<', cell)
    if not spans:
        spans = [(k, n) for n, k in re.findall(r"(\d+)\s*([gsc])\b", text_of(cell))]
    return sum(int(n) * unit[k] for k, n in spans) if spans else None


def parse_npc(page: str) -> dict:
    """An NPC page: name, role (the h1 after " - "), map + x / y, rank (lowercase: from the title, else the highest
    rank row) and the rank rows [{ rank (lowercase), skill, level, cost (copper) }]."""
    m = re.search(r"<main\b.*?</main>", page, re.S)
    body = m.group(0) if m else page
    out = {}
    h1 = re.search(r"<h1[^>]*>(.*?)</h1>", body, re.S)
    if h1:
        name, _, role = text_of(h1.group(1)).partition(" - ")
        out["name"], out["role"] = name, role or None
    way = re.search(r'data-clipboard-text="/way #(\d+) ([\d.]+) ([\d.]+)', page)
    if way:
        out["map"], out["x"], out["y"] = int(way.group(1)), float(way.group(2)), float(way.group(3))
    ranks = []
    for t in re.finditer(r"<table\b.*?</table>", body, re.S):
        rows = [re.findall(r"<t[dh]\b[^>]*>(.*?)</t[dh]>", r, re.S)
                for r in re.findall(r"<tr\b.*?</tr>", t.group(0), re.S)]
        if rows and [text_of(c) for c in rows[0][:2]] == ["Rank", "Required skill"]:
            for raw in rows[1:]:
                r = [text_of(c) for c in raw]
                if len(r) >= 4 and r[1].isdigit():
                    ranks.append({"rank": _rank_word(r[0]) or r[0], "skill": int(r[1]),
                                  "level": int(r[2]) if r[2].isdigit() else None, "cost": _copper(raw[3])})
    out["ranks"] = ranks
    top = max(ranks, key=lambda r: r["skill"]) if ranks else None
    out["rank"] = _rank_word(out.get("role")) or (_rank_word(top["rank"]) if top else None)
    return out


def trainer_slugs(page: str) -> list[str]:
    """The NPC slugs a trainers page links, in page order."""
    m = re.search(r"<main\b.*?</main>", page, re.S)
    out = []
    for slug in re.findall(r'href="/forever/npc/([a-z0-9-]+)"', m.group(0) if m else page):
        if slug not in out:
            out.append(slug)
    if not out:
        raise ShapeError("the trainers page links no /forever/npc/ page")
    return out


def trainers(profs: list[str], pause: float = 0.3) -> dict:
    """Every NPC of the professions' trainers pages and of their guides' unlock records, read from its own page.
    An NPC page that names no rank takes the rank of the guide section that sends the player to it."""
    want: dict[str, int | None] = {}
    taught: dict[str, str] = {}  # slug -> the rank a guide's trainer section sends the player to it for
    for prof in profs:
        line = SKILL_LINE.get(prof)
        for slug in trainer_slugs(fetch(f"/forever/{prof}-trainers")):
            want.setdefault(slug, line)
        for u in guide(prof)["unlocks"]:
            for n in u["npcs"]:
                want.setdefault(n["slug"], line)
                if u["kind"] == "trainer" and u["rank"]:
                    taught.setdefault(n["slug"], u["rank"].lower())
    npcs = {}
    for slug, line in want.items():
        time.sleep(pause)
        n = parse_npc(fetch(f"/forever/npc/{slug}"))
        if "map" not in n:
            raise ShapeError(f"npc/{slug}: no /way button (data-clipboard-text)")
        npcs[slug] = {"name": n.get("name"), "role": n.get("role"), "map": n["map"], "x": n["x"], "y": n["y"],
                      "rank": n["rank"] or taught.get(slug), "ranks": n["ranks"], "skillLine": line}
    return {"source": f"{BASE}/forever: " + ", ".join(f"{p}-trainers" for p in profs) + ", the guides, npc pages",
            "checked": time.strftime("%Y-%m-%d"), "npcs": npcs}


def list_pages() -> dict:
    xml = fetch("/sitemap.xml")
    urls = [u for u in re.findall(r"<loc>([^<]+)</loc>", xml) if "/forever" in u]
    kinds: dict[str, list[str]] = {}
    for u in urls:
        rest = u.split("/forever", 1)[1].strip("/")
        kind = "npc" if rest.startswith("npc/") else ("guide" if rest.endswith("leveling-guide") else
                                                      "trainers" if rest.endswith("-trainers") else "page")
        kinds.setdefault(kind, []).append(rest or "(index)")
    return kinds


def guide(prof: str, html_file: str | None = None) -> dict:
    slug = GUIDE_SLUGS.get(prof, prof)
    if html_file:
        with open(html_file, encoding="utf-8") as fh:
            page = fh.read()
    else:
        page = fetch(f"/forever/{slug}")
    out = parse_guide(page)
    out["url"] = f"{BASE}/forever/{slug}"
    out["skillLine"] = SKILL_LINE.get(prof)
    return out


def show_guide(g: dict) -> str:
    lines = [f"{g['title']}  ({g['url']}, steps v{g['stepsVersion']})"]
    section = None
    for st in g["steps"]:
        if st["section"] != section:
            section = st["section"]
            lines.append(f"\n## {section}")
        lines.append(f"  {st['from']}-{st['to']}")
        for o in st["options"]:
            tag = f"  [alt: {o['variant']}]" if o["alt"] else ""
            sub = f" ({o['from']}-{o['to']})" if (o["from"], o["to"]) != (st["from"], st["to"]) else ""
            fac = f" ({o['faction']})" if o["faction"] else ""
            n = f"{o['count']}x " if o["count"] else ""
            lines.append(f"    {n}{o['name']} spell={o['spell']}{sub}{fac}{tag}")
    return "\n".join(lines)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list")
    g = sub.add_parser("guide")
    g.add_argument("profession", help=", ".join(GUIDE_SLUGS))
    g.add_argument("--json", action="store_true")
    g.add_argument("--html", help="a saved page instead of fetching")
    n = sub.add_parser("npc")
    n.add_argument("slug", help="the page name, e.g. hahrana-ironhide")
    n.add_argument("--html")
    t = sub.add_parser("trainers")
    t.add_argument("professions", nargs="+", help="e.g. leatherworking cooking")
    t.add_argument("--out", help="write the JSON here (default: print it)")
    a = ap.parse_args(argv)
    if a.cmd == "list":
        for kind, pages in sorted(list_pages().items()):
            print(f"{kind} ({len(pages)})")
            for p in pages if kind != "npc" else pages[:5] + ["..."]:
                print("  " + p)
    elif a.cmd == "guide":
        out = guide(a.profession, a.html)
        print(json.dumps(out, indent=1) if a.json else show_guide(out))
    elif a.cmd == "trainers":
        text = json.dumps(trainers(a.professions), indent=1, ensure_ascii=False) + "\n"
        if a.out:
            with open(a.out, "w", encoding="utf-8", newline="\n") as fh:
                fh.write(text)
            print(f"wrote {a.out}")
        else:
            print(text, end="")
    else:
        page = open(a.html, encoding="utf-8").read() if a.html else fetch(f"/forever/npc/{a.slug}")
        print(json.dumps(parse_npc(page), indent=1))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except ShapeError as e:
        print(f"wowprof: the page changed shape: {e}", file=sys.stderr)
        sys.exit(2)
