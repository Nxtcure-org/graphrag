# Architecture diagrams & slides

A component-by-component walkthrough of the NCCN GraphRAG implementation:
seven Graphviz diagrams and a [Touying](https://touying-typ.github.io)
(Typst) slide deck that explains them. Same format as the deck in the
sibling `medicalapps/nxtcureapp-backend/docs/architecture/`.

## Contents

| File | What it shows |
| --- | --- |
| `diagrams/01-system-context.dot` | The running stack (browser → LiveView → Klein API → GraphRAG engine → OpenAI) plus the offline authoring path that feeds it |
| `diagrams/02-workspace.dot` | The uv-workspace monorepo underneath, and the thin NCCN layer sitting on its stable seams |
| `diagrams/03-injection.dot` | `nccn_to_graphrag.py`: hand-drawn `.dot` flowcharts → deduped entities/relationships → pre-finalize parquet, no extraction LLM |
| `diagrams/04-indexing.dot` | `index_external_graph.py`: the four workflows that run, the front half that is skipped on purpose |
| `diagrams/05-query-api.dot` | `api/app.py`: five-guideline registry, global/local dispatch, markdown → sections → typed citations → QueryResponse |
| `diagrams/06-evidence.dot` | Citation ids → clinical vs structural edges → `primary_page` election → highlighted Cytoscape/SVG render |
| `diagrams/07-ui.dot` | `nccn_ui/nccn_ui.exs`: the single-file LiveView copilot where the chat drives the diagram |
| `diagrams/08-trakcare-roster.dot` | `api/patients.py`: TrakCare / IRIS for Health / cloud FHIR → auth-aware client → three bulk searches → `GUIDELINE_MAP` → roster modal; the compose `iris` dev stand-in |
| `diagrams/09-patient-inference.dot` | Treatment-plan inference: roster row → active patient context → `GET /patients/<id>` + auto-asked NCCN question with patient context → local search → cited path on the patient's protocol page |
| `slides.typ` | The Touying deck — one section per diagram, with the design rationale as bullets |
| `nccn_graphrag_slides.pdf` | The compiled deck (16:9) |

## Rebuilding

```bash
./build.sh
```

Requires `dot` (Graphviz) and `typst` ≥ 0.12. The Touying package
(`@preview/touying:0.7.4`) is fetched automatically by Typst on first
compile.

To edit a diagram, change its `.dot` file and re-run `build.sh` — the SVGs
are generated artifacts, and the deck embeds them by relative path.

## Keeping the diagrams readable on slides

The content area of a 16:9 slide is roughly 2.4:1, so a diagram much wider
than that gets scaled down until its labels are unreadable. The `.dot` files
manage this with `rankdir=LR` plus explicit `{ rank=same; ... }` groups that
stack related nodes into columns instead of letting chains sprawl into one
long row, and `constraint=false` on back-edges (the JSON response, the
UI's follow-up fetch) so they don't stretch the layout. `06-evidence.dot`
goes further and folds its long pipeline into two rows with a wrap edge.
Keep that discipline when adding nodes.
