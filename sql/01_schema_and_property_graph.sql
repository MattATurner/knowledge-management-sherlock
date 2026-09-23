-- ============================================================================
-- Sherlock Knowledge Management & GraphRAG Pipeline Schema (BigQuery)
-- Project: all-things-knowledge-mgmt | Dataset: sherlock
-- Governed by: BigQuery Knowledge Catalog ('knowledge-management' glossary)
-- ============================================================================

-- ---------- Stage 0 & 1: Unstructured Document Ingestion ----------
CREATE TABLE IF NOT EXISTS `all-things-knowledge-mgmt.sherlock.0_books_raw` (
  uri STRING,
  generation INT64,
  content_type STRING,
  size INT64,
  md5_hash STRING,
  updated TIMESTAMP,
  metadata ARRAY<STRUCT<name STRING, value STRING>>,
  ref STRUCT<uri STRING, version STRING, authorizer STRING, details JSON>
);

CREATE TABLE IF NOT EXISTS `all-things-knowledge-mgmt.sherlock.1_books_processed_docai_raw` (
  uri STRING,
  ml_process_document_result JSON,
  ml_process_document_status STRING
);

-- ---------- Stage 2: Layout-Aware Document Passages ----------
CREATE TABLE IF NOT EXISTS `all-things-knowledge-mgmt.sherlock.2_book_passages` (
  passage_id STRING,
  story_id STRING,
  story_title STRING,
  chapter_num INT64,
  chunk_num INT64,
  chunk_text STRING
);

-- Full-text Search Index for lexical / hybrid retrieval
CREATE SEARCH INDEX IF NOT EXISTS `idx_book_passages_search`
ON `all-things-knowledge-mgmt.sherlock.2_book_passages`(chunk_text);

-- ---------- Stage 3: Raw LLM Graph Extraction ----------
CREATE TABLE IF NOT EXISTS `all-things-knowledge-mgmt.sherlock.3_extracted_graph_raw` (
  passage_id STRING,
  story_id STRING,
  chapter_num INT64,
  characters ARRAY<STRUCT<description STRING, name STRING>>,
  locations ARRAY<STRUCT<loc_type STRING, name STRING, parent_location STRING>>,
  events ARRAY<STRUCT<
    event_name STRING,
    event_type STRING,
    location_name STRING,
    participants ARRAY<STRUCT<name STRING, role STRING>>,
    summary STRING
  >>,
  relationships ARRAY<STRUCT<obj STRING, rel STRING, subj STRING>>
);

-- ---------- Stage 4: Staging Mentions & Unresolved Graph Edges ----------
CREATE TABLE IF NOT EXISTS `all-things-knowledge-mgmt.sherlock.4_stg_character_mentions` (
  name STRING,
  description STRING,
  passage_id STRING,
  story_id STRING
);

CREATE TABLE IF NOT EXISTS `all-things-knowledge-mgmt.sherlock.4_stg_location_mentions` (
  name STRING,
  loc_type STRING,
  parent_location STRING,
  passage_id STRING,
  story_id STRING
);

CREATE TABLE IF NOT EXISTS `all-things-knowledge-mgmt.sherlock.4_stg_events` (
  event_id STRING,
  passage_id STRING,
  story_id STRING,
  chapter_num INT64,
  event_name STRING,
  event_type STRING,
  location_name STRING,
  summary STRING,
  participants ARRAY<STRUCT<name STRING, role STRING>>
);

CREATE TABLE IF NOT EXISTS `all-things-knowledge-mgmt.sherlock.4_stg_participated_in` (
  event_id STRING,
  character_mention STRING,
  role STRING,
  story_id STRING,
  chapter_num INT64
);

CREATE TABLE IF NOT EXISTS `all-things-knowledge-mgmt.sherlock.4_stg_occurred_at` (
  event_id STRING,
  location_mention STRING,
  story_id STRING
);

-- ---------- Stage 5: Entity Resolution (Embeddings, Candidates, Adjudication, Clusters) ----------
CREATE TABLE IF NOT EXISTS `all-things-knowledge-mgmt.sherlock.5_char_mention_embeddings` (
  mention_id STRING,
  name STRING,
  content STRING,
  embedding ARRAY<FLOAT64>,
  embed_status STRING
);

CREATE TABLE IF NOT EXISTS `all-things-knowledge-mgmt.sherlock.5_er_candidate_pairs` (
  mention_a_id STRING,
  mention_a STRING,
  context_a STRING,
  mention_b_id STRING,
  mention_b STRING,
  context_b STRING,
  distance FLOAT64
);

CREATE TABLE IF NOT EXISTS `all-things-knowledge-mgmt.sherlock.5_er_judged_pairs` (
  mention_a_id STRING,
  mention_a STRING,
  mention_b_id STRING,
  mention_b STRING,
  distance FLOAT64,
  is_same_entity BOOL
);

CREATE TABLE IF NOT EXISTS `all-things-knowledge-mgmt.sherlock.5_er_clusters` (
  mention_id STRING,
  cluster_id STRING
);

CREATE TABLE IF NOT EXISTS `all-things-knowledge-mgmt.sherlock.5_loc_mention_embeddings` (
  mention_id STRING,
  name STRING,
  content STRING,
  embedding ARRAY<FLOAT64>
);

CREATE TABLE IF NOT EXISTS `all-things-knowledge-mgmt.sherlock.5_loc_candidate_pairs` (
  mention_a_id STRING,
  mention_a STRING,
  context_a STRING,
  mention_b_id STRING,
  mention_b STRING,
  context_b STRING,
  distance FLOAT64
);

CREATE TABLE IF NOT EXISTS `all-things-knowledge-mgmt.sherlock.5_loc_judged_pairs` (
  mention_a_id STRING,
  mention_a STRING,
  mention_b_id STRING,
  mention_b STRING,
  distance FLOAT64,
  is_same_entity BOOL
);

CREATE TABLE IF NOT EXISTS `all-things-knowledge-mgmt.sherlock.5_loc_clusters` (
  mention_id STRING,
  cluster_id STRING
);

CREATE TABLE IF NOT EXISTS `all-things-knowledge-mgmt.sherlock.5_event_judged_pairs` (
  event_a_id STRING,
  event_b_id STRING,
  is_same_event BOOL
);

CREATE TABLE IF NOT EXISTS `all-things-knowledge-mgmt.sherlock.5_event_clusters` (
  event_id STRING,
  cluster_id STRING
);

-- ---------- Stage 6: Canonical Golden Entities, Resolution Maps & Graph Edges ----------
CREATE TABLE IF NOT EXISTS `all-things-knowledge-mgmt.sherlock.6_characters` (
  char_id STRING,
  canonical_name STRING,
  aliases ARRAY<STRING>,
  total_mentions INT64
);

CREATE TABLE IF NOT EXISTS `all-things-knowledge-mgmt.sherlock.6_char_resolution_map` (
  mention_name STRING,
  char_id STRING
);

CREATE TABLE IF NOT EXISTS `all-things-knowledge-mgmt.sherlock.6_locations` (
  loc_id STRING,
  canonical_name STRING,
  aliases ARRAY<STRING>,
  loc_type STRING
);

CREATE TABLE IF NOT EXISTS `all-things-knowledge-mgmt.sherlock.6_loc_resolution_map` (
  mention_name STRING,
  loc_id STRING
);

CREATE TABLE IF NOT EXISTS `all-things-knowledge-mgmt.sherlock.6_events_resolved` (
  event_id STRING,
  event_name STRING,
  event_type STRING,
  summary STRING,
  story_id STRING,
  chapter_num INT64
);

CREATE TABLE IF NOT EXISTS `all-things-knowledge-mgmt.sherlock.6_event_resolution_map` (
  event_id STRING,
  resolved_event_id STRING
);

CREATE TABLE IF NOT EXISTS `all-things-knowledge-mgmt.sherlock.6_participated_in` (
  char_id STRING,
  event_id STRING,
  role STRING,
  story_id STRING,
  chapter_num INT64
);

CREATE TABLE IF NOT EXISTS `all-things-knowledge-mgmt.sherlock.6_occurred_at` (
  event_id STRING,
  loc_id STRING,
  story_id STRING
);

CREATE TABLE IF NOT EXISTS `all-things-knowledge-mgmt.sherlock.6_part_of_case` (
  event_id STRING,
  story_id STRING
);

CREATE TABLE IF NOT EXISTS `all-things-knowledge-mgmt.sherlock.6_located_in` (
  child_loc_id STRING,
  parent_loc_id STRING
);

CREATE TABLE IF NOT EXISTS `all-things-knowledge-mgmt.sherlock.6_char_relationships` (
  from_char_id STRING,
  to_char_id STRING,
  rel_type STRING,
  story_id STRING
);

CREATE TABLE IF NOT EXISTS `all-things-knowledge-mgmt.sherlock.story_metadata` (
  story_id STRING NOT NULL,
  story_title STRING NOT NULL,
  story_type STRING,
  collection STRING,
  publication_year INT64,
  narrator STRING,
  in_story_year INT64,
  gutenberg_id INT64
);

-- ---------- Stage 7: Hybrid Retrieval Index & Passage-to-Entity Provenance ----------
CREATE TABLE IF NOT EXISTS `all-things-knowledge-mgmt.sherlock.7_passage_embeddings` (
  passage_id STRING,
  story_id STRING,
  chapter_num INT64,
  chunk_num INT64,
  content STRING,
  embedding ARRAY<FLOAT64>
);

CREATE SEARCH INDEX IF NOT EXISTS `idx_passage_content_search`
ON `all-things-knowledge-mgmt.sherlock.7_passage_embeddings`(content);

CREATE TABLE IF NOT EXISTS `all-things-knowledge-mgmt.sherlock.7_passage_entities` (
  passage_id STRING,
  entity_type STRING,
  entity_id STRING
);

-- ---------- BigQuery Property Graph (ISO GQL / GRAPH_TABLE) ----------
CREATE OR REPLACE PROPERTY GRAPH `all-things-knowledge-mgmt.sherlock.story_graph`
NODE TABLES (
  `all-things-knowledge-mgmt.sherlock.6_characters` AS characters
    KEY (char_id)
    LABEL Character PROPERTIES (char_id, canonical_name, aliases, total_mentions),

  `all-things-knowledge-mgmt.sherlock.6_locations` AS locations
    KEY (loc_id)
    LABEL Location PROPERTIES (loc_id, canonical_name, loc_type),

  `all-things-knowledge-mgmt.sherlock.6_events_resolved` AS events
    KEY (event_id)
    LABEL Event PROPERTIES (event_id, event_name, event_type, summary, story_id, chapter_num),

  `all-things-knowledge-mgmt.sherlock.story_metadata` AS stories
    KEY (story_id)
    LABEL Story PROPERTIES (story_id, story_title, collection, publication_year, narrator, in_story_year)
)
EDGE TABLES (
  `all-things-knowledge-mgmt.sherlock.6_participated_in` AS `sherlock.6_participated_in`
    KEY (char_id, event_id, role)
    SOURCE KEY (char_id) REFERENCES characters (char_id)
    DESTINATION KEY (event_id) REFERENCES events (event_id)
    LABEL PARTICIPATED_IN PROPERTIES (role, chapter_num),

  `all-things-knowledge-mgmt.sherlock.6_occurred_at` AS `sherlock.6_occurred_at`
    KEY (event_id, loc_id)
    SOURCE KEY (event_id) REFERENCES events (event_id)
    DESTINATION KEY (loc_id) REFERENCES locations (loc_id)
    LABEL OCCURRED_AT PROPERTIES (event_id, loc_id, story_id),

  `all-things-knowledge-mgmt.sherlock.6_part_of_case` AS `sherlock.6_part_of_case`
    KEY (event_id)
    SOURCE KEY (event_id) REFERENCES events (event_id)
    DESTINATION KEY (story_id) REFERENCES stories (story_id)
    LABEL PART_OF_CASE PROPERTIES (event_id, story_id),

  `all-things-knowledge-mgmt.sherlock.6_located_in` AS `sherlock.6_located_in`
    KEY (child_loc_id, parent_loc_id)
    SOURCE KEY (child_loc_id) REFERENCES locations (loc_id)
    DESTINATION KEY (parent_loc_id) REFERENCES locations (loc_id)
    LABEL LOCATED_IN PROPERTIES (child_loc_id, parent_loc_id),

  `all-things-knowledge-mgmt.sherlock.6_char_relationships` AS `sherlock.6_char_relationships`
    KEY (from_char_id, to_char_id, rel_type, story_id)
    SOURCE KEY (from_char_id) REFERENCES characters (char_id)
    DESTINATION KEY (to_char_id) REFERENCES characters (char_id)
    LABEL RELATED_TO PROPERTIES (rel_type, story_id)
);
