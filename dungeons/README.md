# Crows dungeons

The six journal documents extracted from `04 Crows Dungeons Book for Playtest 2.pdf`,
plus the extractor that produced them.

These live in the game as MarkdownDocuments in a **Crows Dungeons** folder under
Private Documents. The Dungeons book says it is "meant for the Ref's eyes only",
so they are deliberately not in Shared Documents.

| Document | Areas | Map |
|---|---|---|
| Running These Dungeons | -- | -- |
| Village: Gadwick | -- | -- |
| POI: Ruined Tower | Collapsed Tower, Well | -- |
| POI: Ruined Windmill | Mill First Floor, Cellar, Second Floor, The Shaft | -- |
| Dungeon: Blood Library | 8 keyed areas | Blood Library Upper / Lower |
| Dungeon: Floating Manor | 15 keyed areas | Floating Manor |

## Re-running the extraction

    python extract_dungeons.py

It writes `dungeon-<section>.md` next to itself. The `doc-*.md` files here are
those outputs with the four short front-matter sections merged into
`doc-running-these-dungeons.md`.

## Why the extractor is not a text dump

Three properties of the source PDF make a flat `get_text()` dump unusable, and
each one silently corrupts content rather than failing loudly:

1. **The book is two-column** (text columns start at x=36 and x=222). Sorting
   lines by y interleaves the columns and scrambles every page. Page 2 happens
   to be single-column, which hides the problem if that is the page you check.
2. **Each test table sizes its own columns to its content**, so there are no
   fixed x bands. Every table's three tier headers are its own column anchors;
   cells are assigned to the nearest anchor. A cell wraps onto a variable number
   of lines, so nothing about the line order tells you which tier a line belongs
   to.
3. **PyMuPDF groups everything on one baseline into a single line**, so the
   three cells of a table row arrive as one line object. Only per-span x
   separates them again.

Two smaller traps: a table can straddle the column break (the roll line ends the
left column, the headers and cells open the right), so the cells belong to the
*headers'* column; and the book sometimes opens a bold run one character into a
word ("l" + "ore books"), so spans are joined using the raw span text to decide
whether a space belongs, never geometry.

Verified at 99.7% word coverage against the raw PDF text, with the only missing
tokens being the stripped page numbers and copyright footers, and no spurious
words. All 30 test tables were checked for empty or over-long cells.

## Loading into a game

Documents are created through `MarkdownDocument.new` + `SetTextContent` +
`Upload`, **one per frame** -- `SetAndUploadTableItem` keeps only the last write
to a table in a given frame, so creating them in a tight loop persists just the
final document. Text must be LF-only: TMP draws a bare CR as a real carriage
return and overprints the line.
