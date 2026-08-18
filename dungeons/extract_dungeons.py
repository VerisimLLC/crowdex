"""Extract the Crows Playtest 2 Dungeons book into per-dungeon markdown.

Uses PyMuPDF span coordinates rather than flat text, because the three-column
test tables cannot be reconstructed from a flat dump: each cell wraps onto a
variable number of lines, so "which line belongs to which tier" is only
recoverable from the x position.

Layout facts this relies on (verified against page 2):
  * ConnemaraOldStyle-Bold at 16pt  -> section heading  ("POI: Ruined Tower")
  * ConnemaraOldStyle-Bold at 13pt+ -> area heading     ("Collapsed Tower", "1. Entrance")
  * CrimsonText-* at 9pt            -> body, x=36 for the single text column
  * A table starts at a bold "2d10 + X" line; its tier headers and cells sit in
    three x bands, which is what separates the cells.
"""
import io, re, sys, fitz

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

PDF = (r"C:\Users\theli\Downloads\MCDM Crows Public Playtest August-Sept 2026"
       r"\04 Crows Dungeons Book for Playtest 2.pdf")

FIXES = [("\u2019", "'"), ("\u2018", "'"), ("\u201c", '"'), ("\u201d", '"'),
         ("\u2014", " -- "), ("\u2013", "-"), ("\u00d7", "x"), ("\u2264", "<="),
         ("\u2265", ">="), ("\u2022", "*"), ("\u00a0", " "), ("\t", " ")]


def clean(s):
    for a, b in FIXES:
        s = s.replace(a, b)
    return re.sub(r"\s+", " ", s).strip()


COLUMN_SPLIT = 216.0     # page is 432pt wide; the two text columns start at 36 and 222


def load_lines():
    """Every text line in reading order, with position and style info.

    The book is two-column, so reading order is the whole left column of a page
    followed by the whole right column -- sorting by y alone interleaves them
    and scrambles the text.
    """
    doc = fitz.open(PDF)
    out = []
    for pno, page in enumerate(doc):
        raw = []
        for b in page.get_text("dict")["blocks"]:
            if b["type"] != 0:
                continue
            for l in b["lines"]:
                spans = [s for s in l["spans"] if s["text"].strip()]
                if not spans:
                    continue
                y = round(min(s["bbox"][1] for s in spans), 1)
                x = min(s["bbox"][0] for s in spans)
                size = max(s["size"] for s in spans)
                font = spans[0]["font"]
                # Keep bold/italic runs as markdown. Join spans WITHOUT a space
                # when their boxes touch: the book sometimes opens a bold run one
                # character into a word ("l" + "ore books..."), and a blind space
                # join would split the word.
                # Whether a space belongs between two spans is decided by the RAW
                # span text, not by geometry: clean() strips the trailing space,
                # so the boxes abut whether or not a space was there.
                text, prev_raw = "", ""
                for s in spans:
                    sraw = s["text"]
                    t = clean(sraw)
                    if not t:
                        prev_raw = sraw
                        continue
                    f = s["font"]
                    if "Bold" in f and "Connemara" not in f:
                        piece = "**%s**" % t
                    elif "Italic" in f:
                        piece = "*%s*" % t
                    else:
                        piece = t
                    if text:
                        need = prev_raw[-1:].isspace() or sraw[:1].isspace()
                        text += (" " if need else "") + piece
                    else:
                        text = piece
                    prev_raw = sraw
                text = re.sub(r"\*\*\s*\*\*", " ", text)
                # fold neighbouring runs of the same style back together
                text = re.sub(r"\*\*(\s?)\*\*", lambda m: m.group(1), text)
                text = re.sub(r"(?<!\*)\*(\s?)\*(?!\*)", lambda m: m.group(1), text)
                text = re.sub(r"\s+([.,;:])", r"\1", text)
                col = 0 if x < COLUMN_SPLIT else 1
                # Keep the individual spans too: PyMuPDF groups everything on one
                # baseline into a single line, so the three cells of a table row
                # arrive as one line. Only per-span x can separate them again.
                cells = [dict(x=s["bbox"][0], text=clean(s["text"])) for s in spans
                         if clean(s["text"])]
                raw.append(dict(page=pno + 1, y=y, x=x, size=size, font=font, col=col,
                                colx=36.0 if col == 0 else 222.0, spans=cells,
                                text=text, plain=clean("".join(s["text"] for s in spans))))
        raw.sort(key=lambda r: (r["col"], r["y"], r["x"]))
        out.extend(raw)
    return out


def is_heading(l):
    # Three display sizes: 16 section, 14 area ("1. Entrance"), 12 sub-area
    # ("Cabinet", "Shared Details"). All are set in Connemara.
    return "Connemara" in l["font"] and l["size"] >= 11.5


def heading_level(l):
    return 2 if l["size"] >= 13 else 3


def is_section(l):
    return is_heading(l) and l["size"] >= 15.5


def is_footer(l):
    return "MCDM Productions" in l["plain"] or re.fullmatch(r"\d{1,2}", l["plain"])


TIER_HDR = {"<=11", "12-16", "17+", "1", "2", "3"}


def build():
    lines = [l for l in load_lines() if not is_footer(l)]
    sections = []          # (title, [blocks])
    cur = None
    i = 0
    n = len(lines)

    def push(kind, **kw):
        if cur is not None:
            cur["blocks"].append(dict(kind=kind, **kw))

    while i < n:
        l = lines[i]

        if is_section(l):
            title = l["plain"]
            # "Dungeon:" / "Blood Library" are set as two section-sized lines.
            if title.endswith(":") and i + 1 < n and is_section(lines[i + 1]):
                i += 1
                title = "%s %s" % (title, lines[i]["plain"])
            cur = dict(title=title, blocks=[])
            sections.append(cur)
            i += 1
            continue

        if cur is None:
            cur = dict(title="Front Matter", blocks=[])
            sections.append(cur)

        if is_heading(l):
            push("h", text=l["plain"], level=heading_level(l))
            i += 1
            continue

        # --- a test table: bold roll line, then tier headers, then cells ----
        if re.match(r"^\**2d10\s*\+", l["plain"]) and l["page"] == lines[i]["page"]:
            roll = l["plain"].replace("*", "").strip()
            j = i + 1
            hdrs, hdrx = [], []
            hcol, hcolx = l["col"], l["colx"]
            while j < n and all(sp["text"].replace("*", "").strip() in TIER_HDR
                                for sp in lines[j]["spans"]):
                # A table can straddle the column break: the roll line ends one
                # column and the headers and cells open the next. The cells
                # belong to the HEADERS' column, not the roll line's.
                hcol, hcolx = lines[j]["col"], lines[j]["colx"]
                for sp in lines[j]["spans"]:
                    hdrs.append(sp["text"].replace("*", "").strip())
                    hdrx.append(sp["x"])
                j += 1
            if len(hdrs) >= 3:
                # Every table sizes its own columns to its content, so there are
                # no fixed band edges. Each table's tier headers ARE its column
                # anchors: assign each cell span to the nearest one. (Both the
                # headers and the cells are centred, so nearest-anchor beats any
                # left-edge rule.)
                anchors = hdrx[:3]
                bands = [[], [], []]
                while j < n:
                    m = lines[j]
                    if is_heading(m) or re.match(r"^\**2d10\s*\+", m["plain"]):
                        break
                    if m["col"] != hcol:
                        break
                    # Cells are centred inside their column and so always sit a
                    # few points in from the column edge (rel >= ~5); body prose
                    # starts hard against it. That, not the span count, is what
                    # ends the table -- a following paragraph containing bold
                    # runs arrives as several spans and would otherwise be read
                    # as another row of cells.
                    rel0 = m["spans"][0]["x"] - hcolx
                    if rel0 < 3.5 and all(bands):
                        break
                    for sp in m["spans"]:
                        idx = min(range(3), key=lambda k: abs(sp["x"] - anchors[k]))
                        bands[idx].append(sp["text"])
                    j += 1
                cells = [" ".join(b).strip() for b in bands]
                push("table", roll=roll, hdrs=hdrs[:3], cells=cells)
                i = j
                continue

        # --- bullets and paragraphs ----------------------------------------
        if l["text"].lstrip("*").startswith("* ") or l["plain"].startswith("*"):
            text = re.sub(r"^\*+\s*", "", l["text"]).strip()
            j = i + 1
            # A bullet's continuation lines are indented ~4.5pt from the column
            # edge; measure against the column, not the page.
            while j < n and not is_heading(lines[j]) \
                    and lines[j]["col"] == l["col"] \
                    and lines[j]["x"] - lines[j]["colx"] > 2.5 \
                    and not lines[j]["plain"].startswith("*") \
                    and not re.match(r"^\**2d10\s*\+", lines[j]["plain"]) \
                    and lines[j]["y"] - lines[j - 1]["y"] < 14:
                text += " " + lines[j]["text"]
                j += 1
            push("li", text=text)
            i = j
            continue

        text = l["text"]
        j = i + 1
        while j < n:
            m = lines[j]
            if is_heading(m) or m["plain"].startswith("*") \
                    or re.match(r"^\**2d10\s*\+", m["plain"]):
                break
            if m["y"] - lines[j - 1]["y"] > 14 or m["page"] != lines[j - 1]["page"]:
                break
            text += " " + m["text"]
            j += 1
        push("p", text=text)
        i = j

    return sections


def render(sec):
    out = ["# %s" % sec["title"], ""]
    for b in sec["blocks"]:
        if b["kind"] == "h":
            out += ["%s %s" % ("#" * b.get("level", 2), b["text"]), ""]
        elif b["kind"] == "p":
            out += [b["text"], ""]
        elif b["kind"] == "li":
            out += ["- %s" % b["text"]]
        elif b["kind"] == "table":
            hdrs = ["11 or less" if h == "<=11" else h for h in b["hdrs"]]
            out += ["", "**%s**" % b["roll"], "",
                    "| %s | %s | %s |" % tuple(hdrs),
                    "| --- | --- | --- |",
                    "| %s | %s | %s |" % tuple(c or "--" for c in b["cells"]), ""]
    # tidy: collapse runs of blank lines, ensure a blank after bullet runs
    text, prev = [], None
    for line in out:
        if line == "" and prev == "":
            continue
        if prev is not None and prev.startswith("- ") and not line.startswith("- ") and line != "":
            text.append("")
        text.append(line)
        prev = line
    return "\n".join(text).strip() + "\n"


if __name__ == "__main__":
    secs = build()
    print("sections found:")
    for s in secs:
        tables = sum(1 for b in s["blocks"] if b["kind"] == "table")
        heads = sum(1 for b in s["blocks"] if b["kind"] == "h")
        print("  %-28s blocks=%-4d headings=%-3d tables=%d"
              % (s["title"], len(s["blocks"]), heads, tables))
        io.open("dungeon-%s.md" % re.sub(r"[^a-z0-9]+", "-", s["title"].lower()).strip("-"),
                "w", encoding="utf-8").write(render(s))
