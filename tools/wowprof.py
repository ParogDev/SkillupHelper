#!/usr/bin/env python3
"""Read the WoW: Forever pages of wow-professions.com (no llms.txt; a sitemap and plain HTML).

Facts only: skill ranges, Wowhead Forever spell / item / quest / npc ids, counts, factions, map coordinates and
trainer rank rows. No sentence of a page is kept, and nothing fetched is committed (see docs/data-sources.md).

    python tools/wowprof.py list                         # every Forever page in the sitemap, by kind
    python tools/wowprof.py guide leatherworking         # a leveling guide's route, as text
    python tools/wowprof.py guide cooking --json         # ... as JSON
    python tools/wowprof.py npc hahrana-ironhide         # an NPC: role, place, map + coords, trainer ranks
    python tools/wowprof.py guide cooking --html FILE    # parse a saved page instead of fetching

Page shapes this parser knows (checked 2026-11-22, the guides' data-steps-version="4"):
  * a route section is an <h2> whose title ends in "(from-to)" (Apprentice / Journeyman / Expert / Artisan);
  * a step is <div class="route-step"> with <div class="route-range">from-to</div>; a step without one takes its
    section's range (Cooking 1-50);
  * an option is "Nx <a href=wowhead.com/forever/spell=ID>" (N may be "65-75"); an <h4> inside a step starts the
    alternatives ("Alternative recipe(s)" or a pattern's name); a table row whose first cell is a range is a
    sub-step of that alternative; "(Horde only)" / "(Alliance only)" / "(Horde)" / "(Alliance)" in the same
    paragraph or row tags the option's faction;
  * an NPC page carries data-clipboard-text="/way #MAP X Y NAME" and a rank table (Rank, Required skill, Required
    level, Cost).
A change of shape fails loudly (no route section, a step with no option) instead of returning a short route.
"""

from __future__ import annotations

import argparse
import html as htmllib
import json
import re
import sys
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
    """The step's paragraphs, headings and table rows in order: (kind, html)."""
    for m in re.finditer(r"<(h4|p|tr)\b[^>]*>(.*?)</\1>", step_html, re.S):
        yield m.group(1), m.group(2)


def _steps(section_html: str, srange):
    """Split a section into steps: route-step divs, or the whole section when it has none."""
    starts = [m.start() for m in re.finditer(r'<div class="route-step">', section_html)]
    if not starts:
        return [(srange, section_html)]
    out = []
    # text before the first step (cooking 1-50 puts its table there) is a step of the section's range
    head = section_html[: starts[0]]
    if OPTION.search(head):
        out.append((srange, head))
    for i, st in enumerate(starts):
        end = starts[i + 1] if i + 1 < len(starts) else len(section_html)
        body = section_html[st:end]
        m = re.search(r'<div class="route-range">\s*([^<]*)</div>', body)
        r = RANGE.match(m.group(1)) if m else None
        out.append(((int(r.group(1)), int(r.group(2))) if r else srange, body))
    return out


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
        for (lo, hi), step_html in _steps(shtml, srange):
            options = []
            variant = None  # None: the main pick; else the <h4> that opened the alternative
            for kind, frag in _blocks(step_html):
                if kind == "h4":
                    variant = text_of(frag)
                    continue
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
                if not found and variant is not None and kind == "p":
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
            if all(o["alt"] for o in uniq):
                raise ShapeError(f"step {lo}-{hi} of '{name}' has alternatives but no main pick")
            steps.append({"section": name, "from": lo, "to": hi, "options": uniq})
    return {
        "title": text_of(title.group(1)) if title else None,
        "stepsVersion": int(version.group(1)) if version else None,
        "steps": steps,
    }


def parse_npc(page: str) -> dict:
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
        rows = [
            [text_of(c) for c in re.findall(r"<t[dh]\b[^>]*>(.*?)</t[dh]>", r, re.S)]
            for r in re.findall(r"<tr\b.*?</tr>", t.group(0), re.S)
        ]
        if rows and rows[0][:2] == ["Rank", "Required skill"]:
            for r in rows[1:]:
                if len(r) >= 4 and r[1].isdigit():
                    ranks.append({"rank": r[0], "skill": int(r[1]), "level": int(r[2]) if r[2].isdigit() else None,
                                  "cost": r[3]})
    out["ranks"] = ranks
    return out


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
    page = open(html_file, encoding="utf-8").read() if html_file else fetch(f"/forever/{slug}")
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
    a = ap.parse_args(argv)
    if a.cmd == "list":
        for kind, pages in sorted(list_pages().items()):
            print(f"{kind} ({len(pages)})")
            for p in pages if kind != "npc" else pages[:5] + ["..."]:
                print("  " + p)
    elif a.cmd == "guide":
        out = guide(a.profession, a.html)
        print(json.dumps(out, indent=1) if a.json else show_guide(out))
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
