# pip install pypdf
from pypdf import PdfReader, PdfWriter
import os
import re

# ============================================================
# The complete canon: 4 novels + 56 short stories.
# Keys are UPPERCASE; includes common title variants (editions differ).
# ============================================================
TITLES = {
    # ---------- Novels ----------
    "A STUDY IN SCARLET":                    "study_in_scarlet",
    "THE SIGN OF THE FOUR":                  "sign_of_four",
    "THE SIGN OF FOUR":                      "sign_of_four",          # variant
    "THE HOUND OF THE BASKERVILLES":         "hound_of_baskervilles",
    "THE VALLEY OF FEAR":                    "valley_of_fear",

    # ---------- The Adventures of Sherlock Holmes (1892) ----------
    "A SCANDAL IN BOHEMIA":                  "scandal_in_bohemia",
    "THE RED-HEADED LEAGUE":                 "red_headed_league",
    "THE REDHEADED LEAGUE":                  "red_headed_league",     # variant
    "A CASE OF IDENTITY":                    "case_of_identity",
    "THE BOSCOMBE VALLEY MYSTERY":           "boscombe_valley_mystery",
    "THE FIVE ORANGE PIPS":                  "five_orange_pips",
    "THE MAN WITH THE TWISTED LIP":          "man_with_twisted_lip",
    "THE ADVENTURE OF THE BLUE CARBUNCLE":   "blue_carbuncle",
    "THE ADVENTURE OF THE SPECKLED BAND":    "speckled_band",
    "THE ADVENTURE OF THE ENGINEER'S THUMB": "engineers_thumb",
    "THE ADVENTURE OF THE NOBLE BACHELOR":   "noble_bachelor",
    "THE ADVENTURE OF THE BERYL CORONET":    "beryl_coronet",
    "THE ADVENTURE OF THE COPPER BEECHES":   "copper_beeches",

    # ---------- The Memoirs of Sherlock Holmes (1893) ----------
    "SILVER BLAZE":                          "silver_blaze",
    "THE YELLOW FACE":                       "yellow_face",
    "THE STOCK-BROKER'S CLERK":              "stockbrokers_clerk",
    "THE STOCKBROKER'S CLERK":               "stockbrokers_clerk",    # variant
    'THE "GLORIA SCOTT"':                    "gloria_scott",
    "THE GLORIA SCOTT":                      "gloria_scott",          # variant
    "THE MUSGRAVE RITUAL":                   "musgrave_ritual",
    "THE REIGATE SQUIRES":                   "reigate_squires",
    "THE REIGATE PUZZLE":                    "reigate_squires",       # US variant
    "THE REIGATE SQUIRE":                    "reigate_squires",       # variant
    "THE CROOKED MAN":                       "crooked_man",
    "THE RESIDENT PATIENT":                  "resident_patient",
    "THE GREEK INTERPRETER":                 "greek_interpreter",
    "THE NAVAL TREATY":                      "naval_treaty",
    "THE FINAL PROBLEM":                     "final_problem",

    # ---------- The Return of Sherlock Holmes (1905) ----------
    "THE ADVENTURE OF THE EMPTY HOUSE":      "empty_house",
    "THE ADVENTURE OF THE NORWOOD BUILDER":  "norwood_builder",
    "THE ADVENTURE OF THE DANCING MEN":      "dancing_men",
    "THE ADVENTURE OF THE SOLITARY CYCLIST": "solitary_cyclist",
    "THE ADVENTURE OF THE PRIORY SCHOOL":    "priory_school",
    "THE ADVENTURE OF BLACK PETER":          "black_peter",
    "THE ADVENTURE OF CHARLES AUGUSTUS MILVERTON": "charles_augustus_milverton",
    "THE ADVENTURE OF THE SIX NAPOLEONS":    "six_napoleons",
    "THE ADVENTURE OF THE THREE STUDENTS":   "three_students",
    "THE ADVENTURE OF THE GOLDEN PINCE-NEZ": "golden_pince_nez",
    "THE ADVENTURE OF THE MISSING THREE-QUARTER": "missing_three_quarter",
    "THE ADVENTURE OF THE ABBEY GRANGE":     "abbey_grange",
    "THE ADVENTURE OF THE SECOND STAIN":     "second_stain",

    # ---------- His Last Bow (1917) ----------
    "THE ADVENTURE OF WISTERIA LODGE":       "wisteria_lodge",
    "WISTERIA LODGE":                        "wisteria_lodge",        # variant
    "THE ADVENTURE OF THE CARDBOARD BOX":    "cardboard_box",
    "THE CARDBOARD BOX":                     "cardboard_box",         # variant (in Memoirs in some editions)
    "THE ADVENTURE OF THE RED CIRCLE":       "red_circle",
    "THE ADVENTURE OF THE BRUCE-PARTINGTON PLANS": "bruce_partington_plans",
    "THE ADVENTURE OF THE DYING DETECTIVE":  "dying_detective",
    "THE DISAPPEARANCE OF LADY FRANCES CARFAX": "lady_frances_carfax",
    "THE ADVENTURE OF THE DEVIL'S FOOT":     "devils_foot",
    "HIS LAST BOW":                          "his_last_bow",

    # ---------- The Case-Book of Sherlock Holmes (1927) ----------
    "THE ADVENTURE OF THE ILLUSTRIOUS CLIENT": "illustrious_client",
    "THE ADVENTURE OF THE BLANCHED SOLDIER": "blanched_soldier",
    "THE ADVENTURE OF THE MAZARIN STONE":    "mazarin_stone",
    "THE ADVENTURE OF THE THREE GABLES":     "three_gables",
    "THE ADVENTURE OF THE SUSSEX VAMPIRE":   "sussex_vampire",
    "THE ADVENTURE OF THE THREE GARRIDEBS":  "three_garridebs",
    "THE PROBLEM OF THOR BRIDGE":            "thor_bridge",
    "THE ADVENTURE OF THOR BRIDGE":          "thor_bridge",           # variant
    "THE ADVENTURE OF THE CREEPING MAN":     "creeping_man",
    "THE ADVENTURE OF THE LION'S MANE":      "lions_mane",
    "THE ADVENTURE OF THE VEILED LODGER":    "veiled_lodger",
    "THE ADVENTURE OF SHOSCOMBE OLD PLACE":  "shoscombe_old_place",
    "THE ADVENTURE OF THE RETIRED COLOURMAN": "retired_colourman",
    "THE ADVENTURE OF THE RETIRED COLORMAN": "retired_colourman",     # US spelling
}

# Stories whose title ALSO appears as a collection/section heading earlier
# in the book -> keep the LAST matching bookmark, not the first.
KEEP_LAST = {"his_last_bow"}

def normalize(s):
    """Uppercase, strip punctuation & extra whitespace, drop leading articles."""
    s = re.sub(r"[^\w\s]", "", (s or "").upper()).strip()
    s = re.sub(r"\s+", " ", s)
    s = re.sub(r"^(THE ADVENTURE OF THE |THE ADVENTURE OF |THE |A )", "", s)
    s = re.sub(r"^(THE |A )", "", s)
    return s

LOOKUP = {normalize(t): sid for t, sid in TITLES.items()}
ALL_IDS = set(TITLES.values())   # 60 unique story_ids

reader = PdfReader("source/canonical.pdf")

def walk(outline):
    for item in outline:
        if isinstance(item, list):
            yield from walk(item)
        else:
            yield item

# Collect ALL matching bookmarks (there may be duplicates)
matches = []
for bm in walk(reader.outline):
    sid = LOOKUP.get(normalize(bm.title))
    if sid:
        matches.append((reader.get_destination_page_number(bm), sid, bm.title))
matches.sort()

# Resolve duplicates: first occurrence wins, EXCEPT stories in KEEP_LAST
chosen = {}
for page, sid, title in matches:
    if sid not in chosen:
        chosen[sid] = page
    elif sid in KEEP_LAST:
        print(f"  note: {sid} re-matched at page {page+1}; keeping LAST (collection-title collision)")
        chosen[sid] = page
    else:
        print(f"  note: duplicate bookmark for {sid} at page {page+1}, ignored")

starts = sorted((page, sid) for sid, page in chosen.items())

print(f"\nMatched {len(starts)} of {len(ALL_IDS)} stories")
missing = ALL_IDS - set(chosen)
if missing:
    print(f"\n*** MISSING ({len(missing)}) - pages will be absorbed into the "
          f"preceding story! Reconcile before uploading: ***")
    for m in sorted(missing):
        print(f"  - {m}")
    print("\nAll outline titles in the PDF, for reconciliation:")
    for bm in walk(reader.outline):
        print(f"  {repr(bm.title)}")
else:
    print("All 60 stories matched.\n")

# Split into upload/ directory
os.makedirs("upload", exist_ok=True)
for i, (start, sid) in enumerate(starts):
    end = starts[i + 1][0] if i + 1 < len(starts) else len(reader.pages)
    writer = PdfWriter()
    for p in range(start, end):
        writer.add_page(reader.pages[p])
    out_path = os.path.join("upload", f"{sid}.pdf")
    with open(out_path, "wb") as f:
        writer.write(f)
    print(f"{out_path}: pages {start+1}-{end} ({end-start} pages)")
