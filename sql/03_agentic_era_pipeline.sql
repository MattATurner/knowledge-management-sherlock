-- ============================================================================
-- BigQuery "Agentic Era" Reference Upgrades (April 2026 Release)
-- Maps directly to the 3 Jobs of the Governed Knowledge Layer:
--   Job 1: UNDERSTAND -> `AI.PARSE_DOCUMENT` + Autonomous Embedding Generation
--   Job 2: CONNECT    -> `AI.CLASSIFY` (Optimized AI Mode) for Knowledge Catalog
--                        controlled vocabulary standardization
--   Job 3: SERVE      -> `AI.SEARCH(..., mode => 'hybrid')` + `GRAPH_TABLE`
-- ============================================================================

-- ============================================================================
-- 1. UNDERSTAND: Native Layout-Aware Parsing (`AI.PARSE_DOCUMENT`) &
--    Autonomous Embedding Generation (`GENERATED ALWAYS AS (AI.EMBED(...))`)
-- ============================================================================
-- Replaces external PDF splitting/chunking with native BigQuery Object Table
-- parsing that preserves layout hierarchy, headings, and tables, while
-- automatically maintaining embeddings in sync as rows change.

CREATE TABLE IF NOT EXISTS `all-things-knowledge-mgmt.sherlock.2_book_passages_autonomous` (
  passage_id STRING,
  story_id STRING,
  story_title STRING,
  chapter_num INT64,
  chunk_num INT64,
  chunk_text STRING,
  -- Autonomous embedding column kept automatically in sync by BigQuery
  embedding ARRAY<FLOAT64> GENERATED ALWAYS AS (
    AI.EMBED(
      chunk_text,
      connection_id => 'us.vertex-ai-connection',
      model_name => 'text-embedding-005'
    )
  ) STORED
);

-- Example: Ingesting and layout-chunking raw PDFs directly from `0_books_raw`
-- using `AI.PARSE_DOCUMENT`:
/*
INSERT INTO `all-things-knowledge-mgmt.sherlock.2_book_passages_autonomous`
  (passage_id, story_id, story_title, chapter_num, chunk_num, chunk_text)
SELECT
  CONCAT(REGEXP_EXTRACT(uri, r'([^/]+)\.pdf$'), '_c', CAST(chunk_index AS STRING)) AS passage_id,
  REGEXP_EXTRACT(uri, r'([^/]+)\.pdf$') AS story_id,
  INITCAP(REPLACE(REGEXP_EXTRACT(uri, r'([^/]+)\.pdf$'), '_', ' ')) AS story_title,
  chapter_num,
  chunk_index AS chunk_num,
  chunk_text
FROM AI.PARSE_DOCUMENT(
  TABLE `all-things-knowledge-mgmt.sherlock.0_books_raw`,
  STRUCT(TRUE AS preserve_layout_hierarchy, 1500 AS max_chunk_tokens)
);
*/

-- ============================================================================
-- 2. CONNECT: Standardizing Uncontrolled LLM Relationship Verbs Against the
--    Knowledge Catalog Glossary Using `AI.CLASSIFY` (Optimized AI Mode)
-- ============================================================================
-- In `createAll.sh`, the `relationship-type` term in Knowledge Catalog notes:
--   "currently an uncontrolled vocabulary pending standardization against this
--    glossary - a live example of why glossaries exist."
-- Using `AI.CLASSIFY` with Optimized AI Mode, we map raw LLM-extracted verbs
-- (`rel_type`) into the governed Knowledge Catalog taxonomy at up to 230x lower
-- token cost.

CREATE OR REPLACE VIEW `all-things-knowledge-mgmt.sherlock.6_char_relationships_governed` AS
SELECT
  from_char_id,
  to_char_id,
  rel_type AS raw_rel_type,
  story_id,
  CASE
    WHEN LOWER(rel_type) IN ('married_to', 'engaged_to', 'in_love_with', 'wife_of', 'husband_of', 'fiance_of', 'courted_by', 'loves')
      THEN 'romantic'
    WHEN LOWER(rel_type) IN ('brother_of', 'sister_of', 'father_of', 'mother_of', 'son_of', 'daughter_of', 'uncle_of', 'niece_of', 'nephew_of', 'cousin_of', 'descendant_of', 'stepfather_of', 'twin_of')
      THEN 'familial'
    WHEN LOWER(rel_type) IN ('employed_by', 'works_for', 'employer_of', 'partner_of', 'colleague_of', 'assistant_to', 'client_of', 'landlady_of', 'housekeeper_for')
      THEN 'professional'
    WHEN LOWER(rel_type) IN ('enemy_of', 'blackmails', 'murdered', 'killed', 'threatens', 'conspires_against', 'victim_of', 'betrayed', 'pursued_by', 'rival_of')
      THEN 'adversarial'
    ELSE 'social_or_other'
  END AS canonical_relationship_category
FROM `all-things-knowledge-mgmt.sherlock.6_char_relationships`;

-- Native `AI.CLASSIFY` query for batch standardization of newly extracted relationships:
/*
SELECT
  from_char_id,
  to_char_id,
  rel_type AS raw_rel_type,
  AI.CLASSIFY(
    rel_type,
    categories => ['romantic', 'familial', 'professional', 'adversarial', 'social_or_other'],
    connection_id => 'us.vertex-ai-connection',
    options => STRUCT('OPTIMIZED' AS mode)
  ) AS canonical_relationship_category
FROM `all-things-knowledge-mgmt.sherlock.6_char_relationships`;
*/

-- ============================================================================
-- 3. SERVE: Single-Call `AI.SEARCH` Hybrid Retrieval Over Autonomous Embeddings
-- ============================================================================
-- When querying `2_book_passages_autonomous` (with autonomous embeddings enabled),
-- Steps 1 and 2 of `graphrag_answer` collapse into a single `AI.SEARCH` call:
/*
CREATE OR REPLACE TEMP TABLE hits AS
SELECT
  base.passage_id,
  base.story_id,
  base.chapter_num,
  base.chunk_text AS content,
  score AS distance
FROM AI.SEARCH(
  TABLE `all-things-knowledge-mgmt.sherlock.2_book_passages_autonomous`,
  'chunk_text',
  question,
  top_k => 8,
  mode => 'hybrid'
);
*/
