# Sherlock Knowledge Management & Hybrid GraphRAG Reference Architecture

An end-to-end **Agentic Data Foundation** reference implementation on Google Cloud (`all-things-knowledge-mgmt.sherlock`), demonstrating how **BigQuery Hybrid Search**, **BigQuery Graph (`GRAPH_TABLE`)**, **BigQuery Knowledge Catalog**, and the **Agent Development Kit (ADK)** transform raw unstructured documents into a governed "business brain" for AI agents.

Using the complete **60-story Sherlock Holmes canon (4 novels + 56 short stories)** as a proxy for complex enterprise document estates, this repository showcases:
1. **Understand** — Layout-aware document parsing ([`holmes/parsepdf.py`](file:///usr/local/google/home/mattturner/Projects/knowledge-management-holmes/holmes/parsepdf.py), `AI.PARSE_DOCUMENT`) and autonomous embedding generation (`AI.EMBED`).
2. **Connect** — Vector-blocked entity resolution (`5_er_judged_pairs`), canonical golden records (`6_characters`, `6_locations`, `6_events_resolved`), controlled relationship standardization (`AI.CLASSIFY` $\rightarrow$ `6_char_relationships_governed`), and ISO GQL property graph modeling (`sherlock.story_graph`).
3. **Serve** — **BigQuery Hybrid Search** (Reciprocal Rank Fusion over `VECTOR_SEARCH` + full-text `SEARCH INDEX` / `AI.SEARCH`), **BigQuery Knowledge Catalog** semantic governance, and a 5-tool ADK agent ([`sherlock_agent/agent.py`](file:///usr/local/google/home/mattturner/Projects/knowledge-management-holmes/sherlock_agent/agent.py)).

---

## Repository Structure

```text
knowledge-management-holmes/
├── README.md
├── createAll.sh                 # Provisions the 3 categories & 12 business glossary terms in BigQuery Knowledge Catalog
├── attachTerms.sh               # Attaches the 12 Knowledge Catalog terms to physical BigQuery tables & columns
├── holmes/
│   ├── parsepdf.py              # Splits the anthology PDF (source/canonical.pdf) into all 60 canonical story PDFs
│   ├── source/canonical.pdf     # Complete Sherlock Holmes anthology PDF
│   └── upload/                  # All 60 extracted individual story PDFs ready for GCS Object Table ingestion
├── sql/
│   ├── 01_schema_and_property_graph.sql  # Full DDL for Stages 0–7, Search Indexes, and `sherlock.story_graph`
│   ├── 02_graphrag_answer_hybrid.sql     # Production Hybrid Search (Vector + Full-Text RRF) + `GRAPH_TABLE` stored procedure
│   └── 03_agentic_era_pipeline.sql       # BigQuery Agentic Era upgrades (`AI.PARSE_DOCUMENT`, `AI.CLASSIFY`, `AI.SEARCH`)
├── sherlock_agent/
│   └── agent.py                 # ADK `sherlock_investigator` agent with 5 tools over BigQuery & Knowledge Catalog
├── presentation/
│   └── km.html                  # Interactive 5-slide Technical Reference Architecture deck ("From Documents to Decisions")
└── [TT2 Knowledge Management]/
    ├── agentic-data-foundation-deck.html          # Interactive 5-slide Executive Solution Brief deck
    ├── solution-brief-knowledge-catalog.html      # Print-ready Solution Brief aligned with BigQuery Hybrid Search & Knowledge Catalog
    └── [Tiger Team 2] Knowledge Management aka Agentic Data Foundation.pdf
```

---

## BigQuery Pipeline & Knowledge Catalog Semantic Model

The `all-things-knowledge-mgmt.sherlock` dataset is governed by the `knowledge-management` business glossary in **BigQuery Knowledge Catalog** across three categories and twelve business terms:

| Knowledge Catalog Category | Business Term | Linked BigQuery Table / Column | Enterprise MDM / Governance Equivalent |
| :--- | :--- | :--- | :--- |
| **Entity Resolution** | `Mention` | `4_stg_character_mentions.name` | Raw record from a single source system prior to deduplication |
| **Entity Resolution** | `Alias` | `6_characters.aliases`, `6_locations.aliases` | Name variant, duplicate CRM identity, or disguise (*Sigerson*, *Vandeleur*) |
| **Entity Resolution** | `Canonical Entity` | `6_characters.char_id`, `6_locations.loc_id` | Golden customer / entity record |
| **Entity Resolution** | `Resolution Map` | `6_char_resolution_map`, `6_loc_resolution_map`, `6_event_resolution_map` | Survivorship crosswalk & lineage audit trail |
| **Entity Resolution** | `Match Adjudication` | `5_er_judged_pairs.is_same_entity` | LLM/steward pair-review decision (retaining rejected pairs for audit) |
| **Provenance** | `Source Document` | `1_books_processed`, `2_book_passages.passage_id` | Unstructured source contract, claim file, or ticket |
| **Provenance** | `Narrator / Source of Record` | `story_metadata.narrator` | System-of-record designation & narrator trust weighting |
| **Provenance** | `Record Date vs Event Date` | `story_metadata.publication_year`, `story_metadata.in_story_year` | Booking/publication date vs. underlying transaction/event date |
| **Graph Model** | `Event` | `6_events_resolved` | First-class graph node linking participants, roles, time, and location |
| **Graph Model** | `Participant Role` | `6_participated_in.role` | Controlled vocabulary role (*investigator, client, victim, perpetrator, witness*) |
| **Graph Model** | `Relationship Type` | `6_char_relationships.rel_type`, `6_char_relationships_governed` | Standardized character-to-character edges (`romantic`, `familial`, `professional`, `adversarial`) |
| **Graph Model** | `Location Hierarchy` | `6_located_in` | Containment roll-up (`221B Baker Street` $\rightarrow$ `Baker Street` $\rightarrow$ `London` $\rightarrow$ `England`) |

---

## ADK Investigative Agent (`sherlock_agent/agent.py`)

The [`sherlock_investigator`](file:///usr/local/google/home/mattturner/Projects/knowledge-management-holmes/sherlock_agent/agent.py) agent exposes five specialized tools:

1. **`ask_canon(question)`**: Invokes `CALL all-things-knowledge-mgmt.sherlock.graphrag_answer(@q)`, performing **BigQuery Hybrid Search** (Reciprocal Rank Fusion over `VECTOR_SEARCH` cosine similarity + `SEARCH` full-text index) followed by 2-tier **BigQuery Graph** (`GRAPH_TABLE` over `sherlock.story_graph`) expansion and `ML.GENERATE_TEXT` synthesis with citations.
2. **`character_profile(name)`**: Resolves canonical identities, aliases, story appearances, and governed relationship categories (`6_char_relationships_governed`).
3. **`lookup_knowledge_catalog(query)`**: Dynamically queries **BigQuery Knowledge Catalog** for business glossary definitions and linked schema assets.
4. **`audit_entity_resolution(name)`**: Queries `6_char_resolution_map` and `5_er_judged_pairs` to explain why aliases were merged or rejected.
5. **`inspect_provenance_and_hierarchy(mode, filter_value)`**: Audits narrator source-of-record / temporal reporting lag (`story_metadata`) or rolls up events across the location hierarchy (`6_located_in`).

### Running Locally
```bash
# 1. Split source/canonical.pdf into all 60 story PDFs in holmes/upload/
cd holmes && ../virtualenv/bin/python parsepdf.py && cd ..

# 2. Provision Knowledge Catalog glossary & attach schema links
./createAll.sh
./attachTerms.sh

# 3. Launch the ADK web interface for sherlock_agent
./virtualenv/bin/adk web
```
