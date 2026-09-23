#!/usr/bin/env bash
set -uo pipefail   # deliberately no -e: let "already exists" errors pass through

# ================= BigQuery Knowledge Catalog Environment =================
export PROJECT="${PROJECT:-all-things-knowledge-mgmt}"
export LOCATION="${LOCATION:-us}"
export GLOSSARY="${GLOSSARY:-knowledge-management}"
export GLOSSARY_PATH="projects/${PROJECT}/locations/${LOCATION}/glossaries/${GLOSSARY}"

# ================= Knowledge Catalog Glossary (skip if already created) =================
gcloud dataplex glossaries create ${GLOSSARY} \
  --project=${PROJECT} --location=${LOCATION} \
  --display-name="Knowledge Management" \
  --description="BigQuery Knowledge Catalog semantic model for the entity-resolution and hybrid GraphRAG pipeline (Sherlock demo)" \
  || echo ">> glossary exists, continuing"

# ================= Categories =================
create_category () {  # id, display-name, description
  gcloud dataplex glossaries categories create "$1" \
    --project=${PROJECT} \
    --location=${LOCATION} \
    --glossary=${GLOSSARY} \
    --parent="${GLOSSARY_PATH}" \
    --display-name="$2" \
    --description="$3" \
    || echo ">> category $1 exists, continuing"
}

create_category entity-resolution "Entity Resolution" \
  "Concepts for merging raw mentions into canonical golden records"

create_category provenance "Provenance" \
  "Concepts describing where knowledge came from and how much to trust it"

create_category graph-model "Graph Model" \
  "Concepts defining the knowledge graph's nodes, edges, and vocabularies"

# ================= Terms =================
create_term () {  # id, category-id, display-name, description
  gcloud dataplex glossaries terms create "$1" \
    --project=${PROJECT} \
    --location=${LOCATION} \
    --glossary=${GLOSSARY} \
    --parent="${GLOSSARY_PATH}/categories/$2" \
    --display-name="$3" \
    --description="$4" \
    || echo ">> term $1 exists, continuing"
}

# ---------- Entity Resolution ----------
create_term mention entity-resolution "Mention" \
"A raw name exactly as it appears in a source document, before resolution. Holmes: 'Sigerson' in His Last Bow. Enterprise: a raw record from a single source system."

create_term alias entity-resolution "Alias" \
"An alternative name for a resolved entity. Holmes: 'Vandeleur' for Stapleton. Enterprise: duplicate CRM record, name variant, or fraud alias."

create_term canonical-entity entity-resolution "Canonical Entity" \
"The single golden record produced by entity resolution, merging all mentions and aliases. Holmes: one char_id unifying Holmes, Sigerson, Captain Basil, Altamont. Enterprise: MDM golden customer record."

create_term resolution-map entity-resolution "Resolution Map" \
"Lookup table from raw mention to canonical ID; the audit trail of every merge decision. Enterprise: crosswalk or survivorship record in MDM."

create_term match-adjudication entity-resolution "Match Adjudication" \
"An LLM or human judgment on whether two mentions refer to the same real-world entity, applied to vector-search candidate pairs. Rejected pairs are retained for auditability. Enterprise: match review in KYC/AML or MDM stewardship."

# ---------- Provenance ----------
create_term source-document provenance "Source Document" \
"The original unstructured artifact from which knowledge was extracted. Holmes: a story PDF from the canon. Enterprise: contract, claim file, support ticket."

create_term source-of-record provenance "Narrator / Source of Record" \
"Who reported the information; drives trust weighting. Holmes: Watson narrates 53 stories, Holmes 2, third-person 2 - and Watson makes mistakes. Enterprise: system of record designation."

create_term record-vs-event-date provenance "Record Date vs Event Date" \
"When information was recorded or published versus when the underlying event occurred. Holmes: publication_year vs in_story_year - The Gloria Scott published 1893, set 1874. Enterprise: booking date vs transaction date."

# ---------- Graph Model ----------
create_term event graph-model "Event" \
"A discrete occurrence linking participants to a place and time; modeled as a first-class graph node rather than an edge. Holmes: the confrontation at Grimpen Mire. Enterprise: transaction, incident, claim."

create_term participant-role graph-model "Participant Role" \
"The capacity in which an entity took part in an event: investigator, client, victim, perpetrator, witness, other. A controlled vocabulary enforced by data quality scan. Enterprise: party role on a transaction or claim."

create_term relationship-type graph-model "Relationship Type" \
"Character-to-character relation extracted by the LLM (married_to, brother_of, employed_by). NOTE: currently an uncontrolled vocabulary pending standardization against this glossary - a live example of why glossaries exist."

create_term location-hierarchy graph-model "Location Hierarchy" \
"Containment roll-up of places: 221B Baker Street -> Baker Street -> London -> England. Enables aggregation at any level. Enterprise: geographic or organizational hierarchy."

# ================= Verification =================
echo ""
echo "==================== VERIFICATION ===================="
echo "--- Categories (expect 3) ---"
gcloud dataplex glossaries categories list \
  --glossary=${GLOSSARY} --location=${LOCATION} --project=${PROJECT} \
  --format="table(name.basename(), displayName)"

echo "--- Terms (expect 12) ---"
gcloud dataplex glossaries terms list \
  --glossary=${GLOSSARY} --location=${LOCATION} --project=${PROJECT} \
  --format="table(name.basename(), displayName, parent.basename())"
