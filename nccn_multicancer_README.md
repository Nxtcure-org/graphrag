# NCCN multi-cancer → Graphviz → GraphRAG parquet

Four more NCCN guidelines converted to Graphviz flowcharts and then to GraphRAG
input tables, using the same pipeline as the testicular set (`nccn_graphs/` +
`nccn_to_graphrag.py`).

## Artifacts

| Cancer | Graphviz dir | Flowcharts | Parquet dir | Entities | Relationships |
|--------|--------------|-----------:|-------------|---------:|--------------:|
| Breast (v5.2026)   | `nccn_graphs_breast/`   | 24 | `nccn_graphrag_breast/output/`   | 217 | 534 |
| Prostate (v2.2026) | `nccn_graphs_prostate/` | 18 | `nccn_graphrag_prostate/output/` | 143 | 487 |
| Colon (v2.2026)    | `nccn_graphs_colon/`    | 17 | `nccn_graphrag_colon/output/`    | 128 | 356 |
| NSCLC (v6.2026)    | `nccn_graphs_nsclc/`    | 26 | `nccn_graphrag_nsclc/output/`    | 274 | 687 |

Each `<cancer>/output/` holds the pre-finalize GraphRAG tables:
`entities.parquet`, `relationships.parquet`, `text_units.parquet`,
`documents.parquet` (schema: `graphrag/data_model/schemas.py`).

## How it was built

1. **Graphviz** — one `.dot` flowchart per algorithm page (`<CODE>_<slug>.dot`),
   authored from the PDF algorithm pages, following the testicular house style:
   `rankdir=LR`, decision diamonds, fill-color → type encoding
   (Workup/Treatment/Decision/Management/Recurrence/Salvage/Reference), edge
   labels for branch conditions, dashed cross-page reference nodes.
2. **Parquet** — the generalized converter turns every node into an entity and
   every edge into a relationship, dedupes concepts across pages, and adds a
   page-anchor entity + cross-page reference edges for connectivity:
   ```sh
   uv run python nccn_to_graphrag.py <graphs_dir> <out_dir> <doc_id> "<doc_name>"
   # e.g.
   uv run python nccn_to_graphrag.py nccn_graphs_breast nccn_graphrag_breast/output nccn-breast-v5.2026 "NCCN Breast Cancer"
   ```

## Verified

- Every `.dot` renders (`dot -Tsvg`, 0 failures across all four).
- Every parquet set round-trips through the real `finalize_graph` +
  `create_communities` with **100% entity coverage** (breast 52 / prostate 33 /
  colon 31 / nsclc 50 communities), so they are valid GraphRAG index inputs.

## Render a flowchart

```sh
dot -Tsvg nccn_graphs_breast/BINV-4_adjuvant-triage.dot -o /tmp/binv4.svg
```

## Indexed & queryable

All four are fully indexed GraphRAG projects (stock `graphrag init` settings —
OpenAI `gpt-4.1` + `text-embedding-3-large`, keyed by `${GRAPHRAG_API_KEY}`):

| Project root | Community reports | Vector store |
|--------------|------------------:|--------------|
| `nccn_graphrag_breast/`   | 51 | `output/lancedb/` |
| `nccn_graphrag_prostate/` | 33 | `output/lancedb/` |
| `nccn_graphrag_colon/`    | 31 | `output/lancedb/` |
| `nccn_graphrag_nsclc/`    | 52 | `output/lancedb/` |

Re-index (idempotent) with the generalized driver (takes a project root):

```sh
uv run python index_external_graph.py nccn_graphrag_breast
```

Query (needs `GRAPHRAG_API_KEY`):

```sh
uv run python -m graphrag query --root nccn_graphrag_nsclc --method global \
  "How does biomarker testing guide first-line therapy in advanced NSCLC?"
uv run python -m graphrag query --root nccn_graphrag_colon --method local \
  "Treatment for dMMR/MSI-H metastatic colon cancer?"
```

`global` = thematic (community reports); `local` = entity-specific (embeddings).

## Scope & caveats

- Coverage is the **primary pathways** of each guideline (workup → staging →
  primary treatment → adjuvant/systemic → surveillance → recurrence/later-line),
  ~17–26 flowcharts each — representative, not every sub-page of the
  ~250-page guidelines. Undrawn sub-pages appear as dashed cross-page references.
- Lossy derivatives of copyrighted NCCN content — for local use, not
  redistribution; not a substitute for the guideline.
