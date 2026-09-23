-- ============================================================================
-- Hybrid GraphRAG Stored Procedure: `all-things-knowledge-mgmt.sherlock.graphrag_answer`
-- Combines:
--   1. Dense Semantic Retrieval (`VECTOR_SEARCH` with cosine distance)
--   2. Sparse Lexical Retrieval (word-boundary TF/specificity scoring over `7_passage_embeddings`)
--   3. Reciprocal Rank Fusion (RRF) to guarantee proper-noun / alias recall
--   4. BigQuery Graph (`GRAPH_TABLE` ISO GQL) multi-hop context expansion
--   5. Grounded synthesis with story & retrieval-mode citations (`ML.GENERATE_TEXT`)
-- ============================================================================

CREATE OR REPLACE PROCEDURE `all-things-knowledge-mgmt.sherlock.graphrag_answer`(question STRING)
BEGIN
  -- Extract non-stopword tokens for lexical full-text matching
  DECLARE lexical_tokens ARRAY<STRING> DEFAULT (
    SELECT ARRAY_AGG(DISTINCT tok)
    FROM UNNEST(REGEXP_EXTRACT_ALL(LOWER(question), r'[a-z0-9]{3,}')) AS tok
    WHERE tok NOT IN (
      'who', 'what', 'where', 'when', 'why', 'how', 'which', 'did', 'does', 'was', 'were',
      'are', 'the', 'and', 'for', 'with', 'from', 'that', 'this', 'about', 'into', 'have',
      'had', 'has', 'his', 'her', 'their', 'they', 'them', 'she', 'him', 'been', 'being',
      'sherlock', 'holmes', 'watson', 'story', 'stories', 'canon', 'character', 'characters'
    )
  );

  -- ---------- 1. Embed the question (for dense vector search) ----------
  CREATE OR REPLACE TEMP TABLE q_emb AS
  SELECT ml_generate_embedding_result AS embedding
  FROM ML.GENERATE_EMBEDDING(
    MODEL `sherlock.embedding_model`,
    (SELECT question AS content),
    STRUCT('RETRIEVAL_QUERY' AS task_type));

  -- ---------- 2a. Dense Semantic Retrieval (VECTOR_SEARCH) ----------
  CREATE OR REPLACE TEMP TABLE semantic_hits AS
  SELECT
    base.passage_id, base.story_id, base.chapter_num,
    base.content, distance,
    ROW_NUMBER() OVER (ORDER BY distance ASC) AS sem_rank
  FROM VECTOR_SEARCH(
    TABLE `sherlock.7_passage_embeddings`, 'embedding',
    TABLE q_emb, 'embedding',
    top_k => 12, distance_type => 'COSINE');

  -- ---------- 2b. Sparse Lexical Full-Text Retrieval (BM25-style TF/IDF token scoring) ----------
  CREATE OR REPLACE TEMP TABLE lexical_hits AS
  WITH token_matches AS (
    SELECT
      p.passage_id,
      p.story_id,
      p.chapter_num,
      p.content,
      COUNT(DISTINCT tok) AS matched_tokens,
      -- Weight longer / rarer proper-noun tokens higher
      SUM(LENGTH(tok)) AS token_specificity_score
    FROM `sherlock.7_passage_embeddings` p,
    UNNEST(lexical_tokens) AS tok
    WHERE REGEXP_CONTAINS(LOWER(p.content), CONCAT(r'\b', tok, r'\b'))
    GROUP BY p.passage_id, p.story_id, p.chapter_num, p.content
  )
  SELECT
    passage_id,
    story_id,
    chapter_num,
    content,
    matched_tokens,
    ROW_NUMBER() OVER (
      ORDER BY matched_tokens DESC, token_specificity_score DESC, LENGTH(content) ASC
    ) AS lex_rank
  FROM token_matches
  ORDER BY lex_rank ASC
  LIMIT 12;

  -- ---------- 2c. Hybrid Search Fusion (Reciprocal Rank Fusion: Semantic + Lexical) ----------
  CREATE OR REPLACE TEMP TABLE hits AS
  WITH combined AS (
    SELECT
      COALESCE(s.passage_id, l.passage_id) AS passage_id,
      COALESCE(s.story_id, l.story_id) AS story_id,
      COALESCE(s.chapter_num, l.chapter_num) AS chapter_num,
      COALESCE(s.content, l.content) AS content,
      IFNULL(s.distance, 0.50) AS distance,
      -- Reciprocal Rank Fusion (k = 60)
      (IF(s.sem_rank IS NOT NULL, 1.0 / (60.0 + s.sem_rank), 0.0) +
       IF(l.lex_rank IS NOT NULL, 1.0 / (60.0 + l.lex_rank), 0.0)) AS rrf_score,
      CASE
        WHEN s.sem_rank IS NOT NULL AND l.lex_rank IS NOT NULL THEN 'hybrid (vector+lexical)'
        WHEN s.sem_rank IS NOT NULL THEN 'semantic (vector)'
        ELSE 'lexical (full-text)'
      END AS retrieval_mode
    FROM semantic_hits s
    FULL OUTER JOIN lexical_hits l USING (passage_id)
  )
  SELECT
    passage_id, story_id, chapter_num, content,
    (1.0 - rrf_score) AS distance,
    rrf_score,
    retrieval_mode
  FROM combined
  ORDER BY rrf_score DESC, distance ASC
  LIMIT 8;

  -- ---------- 3a. Characters mentioned in retrieved passages ----------
  CREATE OR REPLACE TEMP TABLE hit_chars AS
  SELECT entity_id AS char_id, COUNT(DISTINCT passage_id) AS passage_hits
  FROM `sherlock.7_passage_entities`
  WHERE entity_type = 'character'
    AND passage_id IN (SELECT passage_id FROM hits)
  GROUP BY entity_id;

  -- ---------- 3b. TIER 1: events DERIVED FROM the retrieved passages ----------
  CREATE OR REPLACE TEMP TABLE hit_events AS
  SELECT DISTINCT
    e.event_id, e.event_name, e.event_type, e.summary, e.story_id
  FROM `sherlock.7_passage_entities` pe
  JOIN `sherlock.6_events_resolved` e ON e.event_id = pe.entity_id
  WHERE pe.entity_type = 'event'
    AND pe.passage_id IN (SELECT passage_id FROM hits);

  -- Enrich Tier 1 events with participants (roles) and locations from the graph
  CREATE OR REPLACE TEMP TABLE tier1_detail AS
  SELECT g.*
  FROM GRAPH_TABLE(
    `sherlock.story_graph`
    MATCH (c:Character)-[p:PARTICIPATED_IN]->(e:Event)
    OPTIONAL MATCH (e)-[:OCCURRED_AT]->(l:Location)
    RETURN
      e.event_id,
      e.event_name, e.event_type, e.summary, e.story_id,
      c.canonical_name AS character_name, p.role,
      l.canonical_name AS location_name
  ) g
  JOIN hit_events USING (event_id);

  -- ---------- 3c. TIER 2: background events for mentioned characters ----------
  CREATE OR REPLACE TEMP TABLE tier2_detail AS
  SELECT g.*
  FROM GRAPH_TABLE(
    `sherlock.story_graph`
    MATCH (c:Character)-[p:PARTICIPATED_IN]->(e:Event)
    OPTIONAL MATCH (e)-[:OCCURRED_AT]->(l:Location)
    RETURN
      c.char_id, e.event_id,
      c.canonical_name AS character_name, p.role,
      e.event_name, e.summary, e.story_id,
      l.canonical_name AS location_name
  ) g
  JOIN hit_chars USING (char_id)
  WHERE g.event_id NOT IN (SELECT event_id FROM hit_events)
  ORDER BY hit_chars.passage_hits DESC
  LIMIT 50;

  -- ---------- 3d. Relationships around mentioned characters ----------
  CREATE OR REPLACE TEMP TABLE ctx_rels AS
  SELECT DISTINCT g.char_a, g.rel_type, g.char_b
  FROM GRAPH_TABLE(
    `sherlock.story_graph`
    MATCH (a:Character)-[r:RELATED_TO]-(b:Character)
    COLUMNS (a.char_id, a.canonical_name AS char_a,
             r.rel_type, b.canonical_name AS char_b)
  ) g
  JOIN hit_chars USING (char_id);

  -- ---------- 3e. Alias knowledge (the ER payoff) ----------
  CREATE OR REPLACE TEMP TABLE ctx_aliases AS
  SELECT c.canonical_name, c.aliases
  FROM `sherlock.6_characters` c
  JOIN hit_chars h ON h.char_id = c.char_id
  WHERE ARRAY_LENGTH(c.aliases) > 1;

  -- ---------- 4. Assemble prompt & synthesize ----------
  SELECT
    question,
    ml_generate_text_llm_result AS answer
  FROM ML.GENERATE_TEXT(
    MODEL `sherlock.gemini_model`,
    (
      SELECT CONCAT(
        'Answer the question about the Sherlock Holmes canon using ONLY ',
        'the evidence below. Evidence is tiered: EVENTS DESCRIBED IN THE ',
        'RETRIEVED PASSAGES are directly relevant; BACKGROUND EVENTS are ',
        'supporting context. Cite which story evidence comes from. ',
        'If the evidence is insufficient, say so.\n\n',
        '== QUESTION ==\n', question, '\n\n',
        '== KNOWN ALIASES (same person) ==\n',
        (SELECT IFNULL(STRING_AGG(
           CONCAT(canonical_name, ' = ', ARRAY_TO_STRING(aliases, ' = ')), '\n'),
           'none')
         FROM ctx_aliases), '\n\n',
        '== CHARACTER RELATIONSHIPS (knowledge graph) ==\n',
        (SELECT IFNULL(STRING_AGG(
           CONCAT(char_a, ' --', rel_type, '--> ', char_b), '\n'), 'none')
         FROM ctx_rels), '\n\n',
        '== EVENTS DESCRIBED IN THE RETRIEVED PASSAGES (graph-enriched) ==\n',
        (SELECT IFNULL(STRING_AGG(
           CONCAT('[', story_id, '] "', event_name, '" (', event_type,
                  ') at ', IFNULL(location_name, 'unknown location'), ': ',
                  summary, ' | ', character_name, ' as ', role), '\n'), 'none')
         FROM (SELECT DISTINCT story_id, event_name, event_type, summary,
                      location_name, character_name, role FROM tier1_detail)),
        '\n\n',
        '== BACKGROUND EVENTS (same characters, other contexts) ==\n',
        (SELECT IFNULL(STRING_AGG(
           CONCAT('[', story_id, '] ', character_name, ' (', role, ') in "',
                  event_name, '" at ', IFNULL(location_name, 'unknown'), ': ',
                  summary), '\n'), 'none')
         FROM (SELECT DISTINCT story_id, character_name, role, event_name,
                      location_name, summary FROM tier2_detail)), '\n\n',
        '== RELEVANT PASSAGES (hybrid vector + full-text retrieval) ==\n',
        (SELECT STRING_AGG(
           CONCAT('[', story_id, ' ch.', IFNULL(CAST(chapter_num AS STRING),'-'),
                  ' | ', retrieval_mode, ']\n', content), '\n---\n' ORDER BY distance)
         FROM hits)
      ) AS prompt
    ),
    STRUCT(2048 AS max_output_tokens, 0.2 AS temperature,
           TRUE AS flatten_json_output));

END;
