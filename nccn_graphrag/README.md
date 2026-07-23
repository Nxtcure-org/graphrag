# NCCN Testicular Cancer — GraphRAG project (from injected Graphviz graph)

This project loads a **pre-built knowledge graph** (converted from the Graphviz
protocol diagrams in `../nccn_graphs/`) into GraphRAG — no LLM graph extraction
from text. It then builds communities + community reports and is queryable.

## Pipeline

```
../nccn_graphs/*.dot
   │  (dot -Tjson parse)
   ▼
../nccn_to_graphrag.py  ──►  output/{entities,relationships,text_units,documents}.parquet
   │  (finalize_graph → create_communities → create_community_reports → generate_text_embeddings)
   ▼
output/{communities,community_reports}.parquet  +  output/lancedb/  (embeddings)
```

- **152 entities** (133 flowchart nodes + 19 page anchors), **421 relationships**
  (clinical transitions + page-anchor links + cross-page references).
- **30 communities** across 2 hierarchy levels; all entities covered.

`settings.yaml` is the stock `graphrag init` output (OpenAI `gpt-4.1` +
`text-embedding-3-large`, keyed by `${GRAPHRAG_API_KEY}`). The graph injection is
done **without editing settings.yaml** — the driver overrides only the workflow
list and clustering at load time via `cli_overrides`.

## Reproduce

```sh
# 1. build the diagrams (if not already) — see ../nccn_graphs/
# 2. convert Graphviz → GraphRAG parquet
uv run python ../nccn_to_graphrag.py ../nccn_graphs output
# 3. index (needs GRAPHRAG_API_KEY in env)
uv run python ../index_external_graph.py
```

## Query

```sh
# Global search — best for sensemaking/thematic questions (uses community reports)
uv run python -m graphrag query --root . --method global \
  "How does risk classification change first-line chemotherapy for advanced disease?"

# Local search — best for specific entity/step questions (uses embeddings + vector store)
uv run python -m graphrag query --root . --method local \
  "What are the options for stage IIA/IIB seminoma with nodes <3 cm?"
```

## Notes / limitations

- Diagrams (and therefore this graph) compress footnote-level nuance; answers are
  a navigational aid, **not** a substitute for the source guideline.
- `drift`/`basic` search also available (embeddings exist). Global + local verified.
- The NCCN source content is copyrighted (EULA restricts redistribution / AI use);
  keep this project local.
