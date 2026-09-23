#!/usr/bin/env bash
set -uo pipefail
# ================= Environment (BigQuery Knowledge Catalog) =================
PROJECT="${PROJECT:-all-things-knowledge-mgmt}"
PROJECT_NUM=$(gcloud projects describe "${PROJECT}" --format="value(projectNumber)" 2>/dev/null || echo "613039203540")
LOCATION="${LOCATION:-us}"
DATASET="${DATASET:-sherlock}"
GLOSSARY_PATH="projects/${PROJECT}/locations/${LOCATION}/glossaries/knowledge-management"
ENTRY_GROUP="projects/${PROJECT}/locations/${LOCATION}/entryGroups/@bigquery"

# Knowledge Catalog term entries are canonicalized with the PROJECT NUMBER
TERM_ENTRY_PREFIX="projects/${PROJECT_NUM}/locations/${LOCATION}/entryGroups/@dataplex/entries/projects/${PROJECT_NUM}/locations/${LOCATION}/glossaries/knowledge-management/terms"

TOKEN=$(gcloud auth print-access-token)


entry_name () {  # table -> full catalog entry name for the BQ table
  echo "${ENTRY_GROUP}/entries/bigquery.googleapis.com/projects/${PROJECT}/datasets/${DATASET}/tables/$1"
}

# ================= Attachment function =================
attach () {  # table, column (empty string = table-level), term-id
  local table=$1 column=$2 term=$3

  # Deterministic, legal link id (hyphens only, <=63 chars)
  local link_id="tl-${table}-${column}-${term}"
  link_id=$(echo "${link_id}" | tr '_' '-' | tr -s '-' | cut -c1-63)

  # SOURCE reference: the table entry, with column path if provided
  local src="{\"name\": \"$(entry_name ${table})\", \"type\": \"SOURCE\""
  [[ -n "${column}" ]] && src="${src}, \"path\": \"Schema.${column}\""
  src="${src}}"
  # TARGET reference: the glossary term as its @dataplex catalog entry
  local tgt="{\"name\": \"${TERM_ENTRY_PREFIX}/${term}\", \"type\": \"TARGET\"}"

  local http_code
  http_code=$(curl -s -o /tmp/attach_resp.json -w "%{http_code}" -X POST \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    "https://dataplex.googleapis.com/v1/${ENTRY_GROUP}/entryLinks?entryLinkId=${link_id}" \
    -d "{
      \"entryLinkType\": \"projects/dataplex-types/locations/global/entryLinkTypes/definition\",
      \"entryReferences\": [ ${src}, ${tgt} ]
    }")

  if [[ "${http_code}" == "200" || "${http_code}" == "201" ]]; then
    echo "OK    ${table}.${column:-<table>} -> ${term}"
  elif [[ "${http_code}" == "409" ]]; then
    echo "SKIP  ${table}.${column:-<table>} -> ${term} (already exists)"
  else
    echo "FAIL  ${table}.${column:-<table>} -> ${term} (HTTP ${http_code})"
    cat /tmp/attach_resp.json; echo ""
  fi
}

# ================= PROBE: run ONE attachment first =================
echo "=== Probe attachment ==="
attach "6_characters" "char_id" "canonical-entity"
echo ""
echo "Check console: Knowledge Catalog -> 6_characters -> Schema ->"
echo "char_id should now show the 'Canonical Entity' term chip."
read -p "Probe OK? Continue with full set? (y/n) " -n 1 -r; echo ""
[[ ! $REPLY =~ ^[Yy]$ ]] && exit 1

# ================= Full attachment matrix =================
echo "=== Entity Resolution terms ==="
attach "6_characters"             "aliases"           "alias"
attach "6_locations"              "loc_id"            "canonical-entity"
attach "6_locations"              "aliases"           "alias"
attach "6_char_resolution_map"    ""                  "resolution-map"
attach "6_loc_resolution_map"     ""                  "resolution-map"
attach "6_event_resolution_map"   ""                  "resolution-map"
attach "5_er_judged_pairs"        "is_same_entity"    "match-adjudication"
attach "4_stg_character_mentions" "name"              "mention"

echo "=== Provenance terms ==="
attach "1_books_processed"        ""                  "source-document"
attach "2_book_passages"          "passage_id"        "source-document"
attach "story_metadata"           "narrator"          "source-of-record"
attach "story_metadata"           "publication_year"  "record-vs-event-date"
attach "story_metadata"           "in_story_year"     "record-vs-event-date"

echo "=== Graph Model terms ==="
attach "6_events_resolved"        ""                  "event"
attach "6_participated_in"        "role"              "participant-role"
attach "6_char_relationships"     "rel_type"          "relationship-type"
attach "6_located_in"             ""                  "location-hierarchy"

echo ""
echo "=== Done ==="
echo "Round-trip verification:"
echo "  1. Search catalog for 'Canonical Entity' -> term -> linked assets"
echo "     should list 6_characters.char_id and 6_locations.loc_id"
echo "  2. Open 6_participated_in -> Schema -> click 'role' term chip ->"
echo "     lands on Participant Role definition"
