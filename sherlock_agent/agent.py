"""Sherlock Canon Investigator - ADK agent over BigQuery Hybrid GraphRAG & Knowledge Catalog."""

import json
import urllib.request
from google.adk.agents import Agent
import google.auth
import google.auth.transport.requests
from google.cloud import bigquery

PROJECT = "all-things-knowledge-mgmt"
LOCATION = "us"
DATASET = "sherlock"
GLOSSARY_ID = "knowledge-management"

# Lazily initialized client, reused across tool calls.
_bq_client = None


def _get_bq() -> bigquery.Client:
    global _bq_client
    if _bq_client is None:
        _bq_client = bigquery.Client(project=PROJECT, location="US")
    return _bq_client

# Governed Knowledge Catalog schema-attachment index (mirrors attachTerms.sh)
_CATALOG_LINKED_ASSETS = {
    "mention": ["4_stg_character_mentions.name"],
    "alias": ["6_characters.aliases", "6_locations.aliases"],
    "canonical-entity": ["6_characters.char_id", "6_locations.loc_id"],
    "resolution-map": [
        "6_char_resolution_map",
        "6_loc_resolution_map",
        "6_event_resolution_map",
    ],
    "match-adjudication": ["5_er_judged_pairs.is_same_entity"],
    "source-document": ["1_books_processed", "2_book_passages.passage_id"],
    "source-of-record": ["story_metadata.narrator"],
    "record-vs-event-date": [
        "story_metadata.publication_year",
        "story_metadata.in_story_year",
    ],
    "event": ["6_events_resolved"],
    "participant-role": ["6_participated_in.role"],
    "relationship-type": [
        "6_char_relationships.rel_type",
        "6_char_relationships_governed.canonical_relationship_category",
    ],
    "location-hierarchy": ["6_located_in"],
}


# ================= Tool 1: Hybrid GraphRAG procedure =================
def ask_canon(question: str) -> dict:
    """Answers narrative questions about the Sherlock Holmes canon using
    BigQuery Hybrid GraphRAG: Reciprocal Rank Fusion (dense VECTOR_SEARCH +
    sparse full-text SEARCH index) + BigQuery Graph (GRAPH_TABLE over
    story_graph for aliases, relationships, and tiered events) + grounded
    synthesis with citations.

    Use for 'why', 'how', 'what happened', identity, and motive questions.

    Args:
        question: The user's question, passed through verbatim.

    Returns:
        dict with 'status' and 'answer' (grounded, with story citations).
    """
    try:
        job = _get_bq().query(
            f"CALL `{PROJECT}.{DATASET}.graphrag_answer`(@q)",
            job_config=bigquery.QueryJobConfig(
                query_parameters=[
                    bigquery.ScalarQueryParameter("q", "STRING", question)
                ]
            ),
        )
        rows = list(job.result())

        if rows:
            return {"status": "success", "answer": rows[0]["answer"]}

        # Fallback: some client versions surface script results on a child job
        for child in _get_bq().list_jobs(parent_job=job.job_id):
            result = list(child.result())
            if result and "answer" in result[0].keys():
                return {"status": "success", "answer": result[0]["answer"]}

        return {
            "status": "error",
            "answer": "The procedure returned no result set.",
        }
    except Exception as e:
        return {"status": "error", "answer": f"BigQuery error: {e}"}


# ================= Tool 2: Canonical identity & governed relationships =================
def character_profile(name: str) -> dict:
    """Looks up a character's canonical identity in `6_characters`: resolved
    aliases, mention count, which stories they appear in, and their governed
    relationship categories (`6_char_relationships_governed`).

    Use for 'who is X', alias/disguise questions, and to resolve a name
    before asking a follow-up narrative question.

    Args:
        name: Any name or alias for the character (e.g. 'Sigerson', 'Vandeleur').

    Returns:
        dict with canonical_name, aliases, stories, and relationships.
    """
    try:
        job = _get_bq().query(
            f"""
            WITH matched_chars AS (
              SELECT
                c.char_id,
                c.canonical_name,
                c.aliases,
                c.total_mentions,
                CASE
                  WHEN LOWER(c.canonical_name) = LOWER(@name) THEN 1
                  WHEN EXISTS (
                    SELECT 1 FROM UNNEST(c.aliases) a WHERE LOWER(a) = LOWER(@name)
                  ) THEN 2
                  WHEN LOWER(c.canonical_name) LIKE CONCAT(LOWER(@name), '%') THEN 3
                  ELSE 4
                END AS match_priority
              FROM `{PROJECT}.{DATASET}.6_characters` c
              WHERE EXISTS (
                SELECT 1 FROM UNNEST(c.aliases) a
                WHERE LOWER(a) LIKE CONCAT('%', LOWER(@name), '%')
              )
              OR LOWER(c.canonical_name) LIKE CONCAT('%', LOWER(@name), '%')
              ORDER BY match_priority ASC, c.total_mentions DESC
              LIMIT 3
            )
            SELECT
              mc.char_id,
              mc.canonical_name,
              mc.aliases,
              mc.total_mentions,
              ARRAY_AGG(DISTINCT p.story_id IGNORE NULLS) AS stories,
              ARRAY(
                SELECT AS STRUCT
                  r.canonical_relationship_category AS category,
                  r.raw_rel_type AS relation,
                  c2.canonical_name AS related_character,
                  r.story_id
                FROM `{PROJECT}.{DATASET}.6_char_relationships_governed` r
                JOIN `{PROJECT}.{DATASET}.6_characters` c2
                  ON c2.char_id = r.to_char_id
                WHERE r.from_char_id = mc.char_id
                LIMIT 10
              ) AS relationships
            FROM matched_chars mc
            LEFT JOIN `{PROJECT}.{DATASET}.6_participated_in` p
              USING (char_id)
            GROUP BY mc.char_id, mc.canonical_name, mc.aliases, mc.total_mentions, mc.match_priority
            ORDER BY mc.match_priority ASC, mc.total_mentions DESC
            """,
            job_config=bigquery.QueryJobConfig(
                query_parameters=[
                    bigquery.ScalarQueryParameter("name", "STRING", name)
                ]
            ),
        )
        matches = [dict(r) for r in job.result()]
        if not matches:
            return {
                "status": "not_found",
                "answer": f"No character matching '{name}'.",
            }
        return {"status": "success", "matches": matches}
    except Exception as e:
        return {"status": "error", "answer": f"BigQuery error: {e}"}


# ================= Tool 3: Live Knowledge Catalog glossary lookup =================
def lookup_knowledge_catalog(query: str = "") -> dict:
    """Queries BigQuery Knowledge Catalog for governed business glossary terms,
    definitions, categories ('Entity Resolution', 'Provenance', 'Graph Model'),
    and their linked physical BigQuery tables/columns in `sherlock`.

    Use when users ask about the semantic model, business glossary definitions,
    data governance, schema lineage, or controlled vocabularies.

    Args:
        query: Optional keyword or term ID to filter (e.g. 'canonical-entity',
               'provenance', 'relationship-type', or empty for all 12 terms).

    Returns:
        dict with live Knowledge Catalog terms, definitions, and linked BigQuery assets.
    """
    try:
        creds, _ = google.auth.default(
            scopes=["https://www.googleapis.com/auth/cloud-platform"]
        )
        creds.refresh(google.auth.transport.requests.Request())
        url = (
            f"https://dataplex.googleapis.com/v1/projects/{PROJECT}/"
            f"locations/{LOCATION}/glossaries/{GLOSSARY_ID}/terms?pageSize=50"
        )
        req = urllib.request.Request(
            url, headers={"Authorization": f"Bearer {creds.token}"}
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            payload = json.loads(resp.read().decode("utf-8"))

        terms = []
        q_lower = (query or "").strip().lower()
        for t in payload.get("terms", []):
            term_id = t.get("name", "").split("/")[-1]
            display_name = t.get("displayName", "")
            description = t.get("description", "")
            category = t.get("parent", "").split("/")[-1]
            linked = _CATALOG_LINKED_ASSETS.get(term_id, [])
            blob = f"{term_id} {display_name} {description} {category} {' '.join(linked)}".lower()
            if not q_lower or q_lower in blob:
                terms.append(
                    {
                        "term_id": term_id,
                        "display_name": display_name,
                        "category": category,
                        "description": description,
                        "linked_bigquery_assets": linked,
                    }
                )
        return {
            "status": "success",
            "catalog": "BigQuery Knowledge Catalog",
            "glossary": GLOSSARY_ID,
            "term_count": len(terms),
            "terms": terms,
        }
    except Exception as e:
        return {
            "status": "fallback",
            "note": f"Live Knowledge Catalog API returned {e}; returning governed asset mappings.",
            "linked_assets": _CATALOG_LINKED_ASSETS,
        }


# ================= Tool 4: Entity Resolution & Match Adjudication Audit =================
def audit_entity_resolution(name: str) -> dict:
    """Audits the entity-resolution crosswalk (`6_char_resolution_map`) and LLM
    match adjudication decisions (`5_er_judged_pairs`) for a character or alias.
    Shows both accepted merges (`is_same_entity = TRUE`) and rejected candidate
    pairs (`is_same_entity = FALSE`) retained for governance auditability.

    Use when asked *why* or *how* aliases/mentions (like 'Sigerson', 'Vandeleur',
    or 'Altamont') were resolved into a single canonical entity, or which
    candidate matches were rejected.

    Args:
        name: Character name or alias to audit.

    Returns:
        dict with resolution crosswalk entries and judged candidate pairs.
    """
    try:
        crosswalk_job = _get_bq().query(
            f"""
            SELECT
              m.mention_name,
              m.char_id,
              c.canonical_name,
              c.aliases
            FROM `{PROJECT}.{DATASET}.6_char_resolution_map` m
            JOIN `{PROJECT}.{DATASET}.6_characters` c USING (char_id)
            WHERE LOWER(m.mention_name) LIKE CONCAT('%', LOWER(@name), '%')
               OR LOWER(c.canonical_name) LIKE CONCAT('%', LOWER(@name), '%')
            ORDER BY c.total_mentions DESC
            LIMIT 15
            """,
            job_config=bigquery.QueryJobConfig(
                query_parameters=[
                    bigquery.ScalarQueryParameter("name", "STRING", name)
                ]
            ),
        )
        judged_job = _get_bq().query(
            f"""
            SELECT
              mention_a,
              mention_b,
              ROUND(distance, 4) AS cosine_distance,
              is_same_entity
            FROM `{PROJECT}.{DATASET}.5_er_judged_pairs`
            WHERE LOWER(mention_a) LIKE CONCAT('%', LOWER(@name), '%')
               OR LOWER(mention_b) LIKE CONCAT('%', LOWER(@name), '%')
            ORDER BY is_same_entity DESC, distance ASC
            LIMIT 15
            """,
            job_config=bigquery.QueryJobConfig(
                query_parameters=[
                    bigquery.ScalarQueryParameter("name", "STRING", name)
                ]
            ),
        )
        return {
            "status": "success",
            "resolution_crosswalk": [dict(r) for r in crosswalk_job.result()],
            "judged_candidate_pairs": [dict(r) for r in judged_job.result()],
        }
    except Exception as e:
        return {"status": "error", "answer": f"BigQuery error: {e}"}


# ================= Tool 5: Provenance & Location Hierarchy Roll-Up =================
def inspect_provenance_and_hierarchy(
    mode: str, filter_value: str = ""
) -> dict:
    """Inspects either (1) story provenance (`story_metadata`: narrator / source
    of record, publication_year vs. in_story_year chronological gaps) or
    (2) location containment hierarchies (`6_located_in` & `6_occurred_at` roll-ups,
    e.g., 221B Baker Street -> Baker Street -> London -> England).

    Args:
        mode: Either 'provenance' (to check narrator reliability and record-vs-event
              dates) or 'location_hierarchy' (to traverse child -> parent locations
              and roll up events).
        filter_value: Optional story/narrator filter (for 'provenance', e.g.
                      'Sherlock Holmes', 'third', 'gloria_scott') or location name
                      (for 'location_hierarchy', e.g. 'London', 'Baker Street').

    Returns:
        dict with provenance records or hierarchical location roll-ups.
    """
    try:
        if mode.lower().startswith("prov"):
            job = _get_bq().query(
                f"""
                SELECT
                  story_id,
                  story_title,
                  collection,
                  narrator AS source_of_record,
                  publication_year AS record_date,
                  in_story_year AS event_date,
                  (publication_year - in_story_year) AS reporting_lag_years
                FROM `{PROJECT}.{DATASET}.story_metadata`
                WHERE @f = ''
                   OR LOWER(story_id) LIKE CONCAT('%', LOWER(@f), '%')
                   OR LOWER(story_title) LIKE CONCAT('%', LOWER(@f), '%')
                   OR LOWER(narrator) LIKE CONCAT('%', LOWER(@f), '%')
                ORDER BY ABS(IFNULL(publication_year - in_story_year, 0)) DESC, publication_year ASC
                LIMIT 20
                """,
                job_config=bigquery.QueryJobConfig(
                    query_parameters=[
                        bigquery.ScalarQueryParameter(
                            "f", "STRING", filter_value or ""
                        )
                    ]
                ),
            )
            return {
                "status": "success",
                "mode": "provenance",
                "records": [dict(r) for r in job.result()],
            }
        else:
            job = _get_bq().query(
                f"""
                SELECT
                  child.canonical_name AS child_location,
                  child.loc_type AS child_type,
                  parent.canonical_name AS parent_location,
                  parent.loc_type AS parent_type,
                  COUNT(DISTINCT oa.event_id) AS child_event_count
                FROM `{PROJECT}.{DATASET}.6_located_in` li
                JOIN `{PROJECT}.{DATASET}.6_locations` child
                  ON child.loc_id = li.child_loc_id
                JOIN `{PROJECT}.{DATASET}.6_locations` parent
                  ON parent.loc_id = li.parent_loc_id
                LEFT JOIN `{PROJECT}.{DATASET}.6_occurred_at` oa
                  ON oa.loc_id = child.loc_id
                WHERE @f = ''
                   OR LOWER(parent.canonical_name) LIKE CONCAT('%', LOWER(@f), '%')
                   OR LOWER(child.canonical_name) LIKE CONCAT('%', LOWER(@f), '%')
                GROUP BY child_location, child_type, parent_location, parent_type
                ORDER BY child_event_count DESC, parent_location ASC
                LIMIT 20
                """,
                job_config=bigquery.QueryJobConfig(
                    query_parameters=[
                        bigquery.ScalarQueryParameter(
                            "f", "STRING", filter_value or ""
                        )
                    ]
                ),
            )
            return {
                "status": "success",
                "mode": "location_hierarchy",
                "hierarchy_links": [dict(r) for r in job.result()],
            }
    except Exception as e:
        return {"status": "error", "answer": f"BigQuery error: {e}"}


# ================= The agent =================
root_agent = Agent(
    name="sherlock_investigator",
    model="gemini-2.5-flash",
    description=(
        "Answers questions about the Sherlock Holmes canon from a governed "
        "BigQuery Knowledge Graph, Hybrid Search index, and Knowledge Catalog."
    ),
    instruction="""You are a consulting detective's assistant with access to a
governed knowledge graph built from the complete Sherlock Holmes canon (60 stories)
in BigQuery and governed by BigQuery Knowledge Catalog.

TOOL ROUTING:
- ask_canon: narrative questions — why, how, motives, identities, what
  happened. Uses BigQuery Hybrid Search (Reciprocal Rank Fusion over vector +
  full-text SEARCH index) + BigQuery Graph (`GRAPH_TABLE` over `story_graph`).
  Pass the user's question through essentially verbatim; never call it more than
  once per user turn unless the user asks a new question.
- character_profile: fast identity & governed relationship lookups — "who is X",
  aliases/disguises, which stories someone appears in, and their governed
  relationship categories (`romantic`, `familial`, `professional`, `adversarial`).
- lookup_knowledge_catalog: live BigQuery Knowledge Catalog lookup for the
  `knowledge-management` business glossary (`Entity Resolution`, `Provenance`,
  `Graph Model`) and the physical BigQuery tables/columns linked to each term.
- audit_entity_resolution: governance audit trail over `6_char_resolution_map`
  and `5_er_judged_pairs` — explains *why* aliases were merged into a canonical
  entity and which candidate matches were rejected.
- inspect_provenance_and_hierarchy: queries `story_metadata` (narrator / source
  of record, publication_year vs. in_story_year lag) or `6_located_in`
  (location hierarchy roll-ups such as 221B Baker Street -> Baker Street -> London).

SEMANTIC VOCABULARY (governed by Knowledge Catalog):
When users ask in business-flavored language, map to the governed graph vocabulary:
- "lovers", "romance", "affairs" -> `romantic` relationships
  (married_to, engaged_to, in_love_with)
- "family", "relatives" -> `familial` (brother_of, sister_of, descendant_of)
- "worked for", "colleagues" -> `professional` (employed_by, works_for)
- "enemies", "rivals" -> `adversarial` (enemy_of, blackmails)

ANSWER STYLE:
- Always refer to the metadata and glossary layer as **Knowledge Catalog** (or
  **BigQuery Knowledge Catalog**), never Dataplex.
- Relay `ask_canon`'s story citations and retrieval modes (`hybrid`, `semantic`,
  `lexical`); never invent story sources.
- Highlight aliases and entity-resolution audit trails when relevant (e.g.
  "Stapleton, resolved with alias Vandeleur via Knowledge Catalog's Canonical Entity model").""",
    tools=[
        ask_canon,
        character_profile,
        lookup_knowledge_catalog,
        audit_entity_resolution,
        inspect_provenance_and_hierarchy,
    ],
)
