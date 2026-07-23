╭─── Claude Code v2.1.217 ─────────────────────────────────────────────────────╮
│                                  │ Tips for getting started                  │
│           Welcome back!          │ Run /init to create a CLAUDE.md file wit… │
│                                  │ ───────────────────────────────────────── │
│              ▐▛███▜▌             │ What's new                                │
│             ▝▜█████▛▘            │ Added emoji shortcode autocomplete in th… │
│               ▘▘ ▝▝              │ Added warnings when transcript writes ar… │
│                                  │ Fixed a memory leak where truncated MCP … │
│   Opus 4.8 · API Usage Billing   │ /release-notes for more                   │
│     ~/void/www/git/graphrag      │                                           │
╰──────────────────────────────────────────────────────────────────────────────╯


❯ /init                                                                         

⏺ I'll analyze the codebase to create a CLAUDE.md file. Let me start by
  exploring the structure and key files.

  Read 1 file, listed 2 directories (ctrl+o to expand)

⏺ The GraphRAG codebase. Let me read the key development docs and explore the
  package structure.

  Searched for 1 pattern, read 2 files (ctrl+o to expand)

⏺ The repo is now a monorepo (DEVELOPING.md describes the older single-package
  layout). Let me explore the main package's internal architecture.

  Ran 2 shell commands (ctrl+o to expand)

⏺ Now let me look at the workflows (indexing pipeline core), the API layer, and
  query search methods to understand the big picture.

  Ran 3 shell commands (ctrl+o to expand)

⏺ Let me look at a few more key files: the API entry points, the run pipeline,
  and the unified-search-app.

  Ran 3 shell commands (ctrl+o to expand)

⏺ I have enough to write a focused CLAUDE.md. Let me verify the data model dir
  and the run entrypoint quickly.

  Ran 1 shell command (ctrl+o to expand)

⏺ Now I'll write the CLAUDE.md.

⏺ Write(CLAUDE.md)
  ⎿  Wrote 105 lines to CLAUDE.md
      1 # CLAUDE.md
      3 This file provides guidance to Claude Code (claude.ai/code) when 
        working with code in this repository.
      5 GraphRAG is a data pipeline and transformation suite that extract
        Ms, then serves that graph for retrieval-augmented generation. Se
        e `README.md` and `DEVELOPING.md` for user-facing context.
      7 ## Repository layout: uv workspace monorepo
      8 
        project.toml`), not a single package. Note that `DEVELOPING.md`'s
         the real code lives under `packages/`:
     … +170 lines (ctrl+o to expand)

⏺ I've created CLAUDE.md. Here's what it captures — focused on things that
  require reading multiple files to understand:

  Key findings that shaped it:

  1. It's a uv workspace monorepo, not the flat layout DEVELOPING.md describes.
  I called this discrepancy out explicitly since future instances would be
  misled — the real code is under packages/ split into 8 packages (graphrag plus
  modular graphrag-common/-cache/-storage/-vectors/-input/-chunking/-llm), with
  versions pinned in lockstep.
  2. Commands run through uv + poethepoet: uv run poe check / test_unit /
  test_only -- "<expr>" for a single test, plus the index/query/init/update
  pipeline entrypoints and the Azurite requirement for some tests.
  3. The semversioner requirement — CI fails without a change file per PR —
  which is easy to miss and non-obvious.
  4. Architecture big picture:
    - The pervasive factory + register() pattern.
    - Indexing as an ordered list of workflow functions passing DataFrames, with
  the four IndexingMethod pipelines (Standard/Fast/±Update) and the LLM-vs-NLP
  extraction distinction.
    - The four query strategies.
    - api/ being the stable seam that the CLI wraps.
    - Pydantic config, the data model, and litellm.
  5. A gotcha I found in the code: the graspologic-native pin is deliberate
  (bumping it breaks golden regression data).

  I favored explaining relationships and rationale over listing files that are
  easily discoverable. Want me to adjust the depth anywhere, or drop the
  conventions section?

✻ Cooked for 1m 32s

❯ read the contents of graphrag_publication.txt and tell me how to provide      
  graphs compiled externally from the processes in this repo rather than        
  generating the graphs from text input                                         

  Read 1 file, ran 2 shell commands (ctrl+o to expand)

⏺ I've read the paper's methodology (the indexing pipeline: Source Documents →
  Text Chunks → Entities & Relationships → Knowledge Graph → Graph Communities →
  Community Summaries). Now let me examine the actual repo workflows to tell
  you precisely how to inject an externally-compiled graph and skip LLM
  extraction.

  Ran 2 shell commands (ctrl+o to expand)

⏺ The data flow is clear. Let me confirm the exact schemas the graph tables need
  and check whether there's existing guidance/config for custom pipelines.

  Ran 2 shell commands (ctrl+o to expand)

⏺ Let me confirm the build_index API surface and how the workflow-list override
  / custom registration works, plus what the downstream report/text-unit
  workflows require.

  Ran 2 shell commands (ctrl+o to expand)

⏺ Let me confirm the on-disk table format/filenames the table provider uses, so
  the "pre-place your parquet" instructions are accurate.

  Ran 1 shell command (ctrl+o to expand)

⏺ I've read the paper and traced the actual pipeline in the repo. Here's how to
  feed a pre-built graph instead of extracting it from text.

  The key idea

  The paper's indexing pipeline (Figure 1, §3.1) is: Source Documents → Text 
  Chunks → Entities & Relationships → Knowledge Graph → Graph Communities → 
  Community Summaries. In this repo, each arrow is a named workflow that reads
  and writes named parquet tables through a storage layer. Only two workflows
  actually create the graph from text:

  - extract_graph (Standard method) — the LLM extraction described in
  §3.1.2–3.1.3
  - extract_graph_nlp + prune_graph (Fast method) — the NLP-based alternative

  Both do nothing but produce two tables: entities and relationships. Everything
  downstream (Leiden communities → community reports → embeddings) consumes
  those tables and never looks at the source text again — exactly matching the
  paper's staged flow.

  So "provide an externally-compiled graph" = write entities.parquet and 
  relationships.parquet yourself, then run the pipeline starting from 
  finalize_graph, skipping extraction.

  The override hook is built in. PipelineFactory.create_pipeline
  (index/workflows/factory.py:46) does:
  workflows = config.workflows or cls.pipelines.get(method, [])
  Setting workflows: in config completely replaces the built-in method's
  workflow list (config/models/graph_rag_config.py:171).

  Approach A — config-only, no code (recommended)

  1. Write your graph as parquet into the output storage dir (default output/;
  tables are stored as {name}.parquet, see parquet_table_provider.py:59).

  entities.parquet — the pre-finalize schema (finalize_graph fills in id,
  human_readable_id, degree):

  ┌───────────────┬───────────┬──────────────────────────────────────────────┐
  │    column     │   type    │                    notes                     │
  ├───────────────┼───────────┼──────────────────────────────────────────────┤
  │ title         │ str       │ entity name — the join key used everywhere   │
  ├───────────────┼───────────┼──────────────────────────────────────────────┤
  │ type          │ str       │ e.g. PERSON, ORG                             │
  ├───────────────┼───────────┼──────────────────────────────────────────────┤
  │ description   │ str       │                                              │
  ├───────────────┼───────────┼──────────────────────────────────────────────┤
  │ text_unit_ids │ list[str] │ may be [] if you have no source text         │
  ├───────────────┼───────────┼──────────────────────────────────────────────┤
  │ frequency     │ int       │ optional; not recomputed by finalize, so set │
  │               │           │  it (or 0)                                   │
  └───────────────┴───────────┴──────────────────────────────────────────────┘

  relationships.parquet (finalize fills id, human_readable_id, combined_degree):

  ┌───────────────┬───────────┬──────────────────────────────────────────────┐
  │    column     │   type    │                    notes                     │
  ├───────────────┼───────────┼──────────────────────────────────────────────┤
  │ source        │ str       │ must match an entity title                   │
  ├───────────────┼───────────┼──────────────────────────────────────────────┤
  │ target        │ str       │ must match an entity title                   │
  ├───────────────┼───────────┼──────────────────────────────────────────────┤
  │ description   │ str       │                                              │
  ├───────────────┼───────────┼──────────────────────────────────────────────┤
  │ weight        │ float     │ used as the edge weight in Leiden clustering │
  │               │           │  (§3.1.4)                                    │
  ├───────────────┼───────────┼──────────────────────────────────────────────┤
  │ text_unit_ids │ list[str] │ may be []                                    │
  └───────────────┴───────────┴──────────────────────────────────────────────┘

  Column contracts are in data_model/schemas.py (ENTITIES_FINAL_COLUMNS,
  RELATIONSHIPS_FINAL_COLUMNS); the finalize logic that consumes them is
  index/operations/finalize_entities.py / finalize_relationships.py. Let
  finalize_graph assign the ids — create_communities builds its title → 
  entity_id map from the entities table's id column (create_communities.py), so
  IDs must be internally consistent, and finalize guarantees that.

  2. In settings.yaml, override the workflow list to start after extraction:
  workflows:
    - finalize_graph            # compute degrees, assign ids
    - create_communities        # Leiden hierarchy (§3.1.4)
    - create_community_reports   # graph-based summaries (§3.1.5) — LLM
    - generate_text_embeddings

  3. Run graphrag index --root <path>. Because config.workflows is set,
  extraction never runs; finalize_graph reads the entities/relationships parquet
  you placed and the rest proceeds normally.

  Approach B — programmatic

  Register a custom pipeline (the factory's documented extension point) and call
  the API:
  from graphrag.index.workflows.factory import PipelineFactory
  from graphrag.api import build_index

  PipelineFactory.register_pipeline("external_graph", [
      "finalize_graph", "create_communities",
      "create_community_reports", "generate_text_embeddings",
  ])
  await build_index(config, method="external_graph")
  You can also PipelineFactory.register("load_external_graph", fn) a custom
  workflow that pulls your graph from anywhere (Neo4j, an API) and writes the
  entities/relationships tables, then put it first in the list instead of
  pre-staging parquet.

  Two caveats about source text

  Since you're skipping create_base_text_units, there are no text_units, which
  matters for the query side:

  1. Use the graph-based create_community_reports, not 
  create_community_reports_text. The former reads only
  entities/relationships/communities; the _text variant (and
  create_final_text_units) require a text_units table and will fail without one.
  2. Global search works with graph-only data; local/basic search will be 
  degraded. Local and basic search retrieve source text chunks. If you want
  those, also pre-place text_units.parquet (and documents.parquet) with your
  source text and add create_final_text_units back in. If you have no text at
  all, restrict yourself to global_search, which is precisely the
  community-summary map-reduce the paper evaluates (§3.1.6).

  One more: generate_text_embeddings embeds whatever targets your config's
  embedding settings list (entity descriptions, community report content, text
  units). If you have no text units, make sure text-unit embeddings aren't in
  the enabled target set, or that step can error.

  Want me to scaffold a small script that takes an edge list / Neo4j export and
  writes conformant entities.parquet + relationships.parquet?
✻ Cooked for 2m 3s

❯ /export                                                                       
  ⎿  Conversation exported to:
     /Users/keanu/void/www/git/graphrag/graphrag_injection.md

❯ yes write a small proof of concept script to provide graphs rather than       
  mining them from unstructured textual data                                    

⏺ I'll write a self-contained PoC that converts a simple node/edge list into the
  two parquet tables the pipeline expects, using the paper's NeoChip example
  (§3.1.2) as the built-in demo graph so it runs out of the box.

  Ran 1 shell command (ctrl+o to expand)

⏺ Default output dir confirmed as output/. Now I'll write the PoC.

⏺ Write(poc_inject_graph.py)
  ⎿  Wrote 231 lines to poc_inject_graph.py
       1 #!/usr/bin/env python
       3 # Licensed under the MIT License
       4 
         ph into GraphRAG.
       6 
         ext with an LLM
       8 (the ``extract_graph`` / ``extract_graph_nlp`` workflows), this 
       9 two tables those workflows would produce -- ``entities`` and ``r
         elationships`` --
          etc.).
     … +273 lines (ctrl+o to expand)

⏺ Now let me verify it runs and produces parquet with the right schema, then
  confirm those tables round-trip through the actual
  finalize_graph/create_communities code paths.

  Ran 1 shell command (ctrl+o to expand)

⏺ The root env doesn't have the workspace packages installed. Let me sync all
  packages first (the repo's _sync task), then run.

  Ran 2 shell commands (ctrl+o to expand)

⏺ Now let me verify the parquet actually round-trips through the real
  finalize_graph and create_communities code — the true test that the schema is
  conformant.

  Ran 1 shell command (ctrl+o to expand)

⏺ Verified end-to-end. Let me clean up the temp artifacts.

  Ran 1 shell command (ctrl+o to expand)

⏺ Done. I wrote poc_inject_graph.py at the repo root and verified it against the
  real pipeline code — not just that it emits parquet, but that the parquet
  round-trips cleanly through the actual finalize_graph and create_communities
  workflows.

  What it does

  Converts a node/edge list into the two tables that LLM extraction would
  otherwise produce (entities.parquet, relationships.parquet), writing them into
  the project's output/ dir so the pipeline can skip mining the graph from text
  and start at finalize_graph.

  - Built-in demo graph: the NeoChip example from the paper (§3.1.2) — runs with
  zero input files.
  - Your own data: --nodes nodes.csv --edges edges.csv (title,type,description /
  source,target,description,weight).
  - Handles the details that matter to downstream code: entities named only in
  edges are auto-created (since create_communities joins on title),
  text_unit_ids are empty lists (no source text), weight becomes the Leiden edge
  weight, and frequency is filled from edge incidence.
  - --emit-settings prints the exact workflows: snippet for settings.yaml.

  Verification (against actual repo code)

  Fed the demo output through the real operations:

  finalize_graph  → entities:      [id, human_readable_id, title, type,
  description, text_unit_ids, frequency, degree]  ✓
                  → relationships: [id, human_readable_id, source, target,
  description, weight, combined_degree, text_unit_ids]  ✓
                    (degree=2, combined_degree=3 computed correctly)
  create_communities → Leiden ran, produced communities table with all 12
  COMMUNITIES_FINAL_COLUMNS  ✓

  Columns match ENTITIES_FINAL_COLUMNS / RELATIONSHIPS_FINAL_COLUMNS /
  COMMUNITIES_FINAL_COLUMNS from data_model/schemas.py exactly.

  Workflow to use it

  uv run poe init -- --root ./ragtest              # scaffold (if needed)
  uv run python poc_inject_graph.py --root ./ragtest   # write the graph tables
  # add the workflows: block to ragtest/settings.yaml
  uv run poe index -- --root ./ragtest             # extraction skipped; reads
  your parquet
  uv run poe query -- --root ./ragtest --method global "What are the main
  themes?"

  The header docstring documents all of this plus the two caveats (use global
  search and the graph-based create_community_reports, since no text_units
  exist).

  One note: poc_inject_graph.py sits at the repo root and depends on the
  workspace being synced (uv sync --all-packages, which I ran). If you'd rather
  keep the root clean, I can move it under scripts/ or an examples/ dir — say
  the word.

✻ Sautéed for 3m 16s