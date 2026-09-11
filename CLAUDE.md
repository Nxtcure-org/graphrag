# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A fork of Microsoft **GraphRAG** (uv workspace under `packages/`) with an **NCCN clinical-guideline demo** layered on top at the repo root. All recent commits touch the demo layer, not the upstream engine. Two very different things live here:

1. **Upstream GraphRAG engine** — `packages/*`, `tests/`, `docs/` (minus `docs/architecture/`), `unified-search-app/`. Treat as a vendored dependency: change it only when the demo needs a fix in the engine.
2. **NCCN demo** — everything else at the root: hand-drawn Graphviz flowcharts of NCCN oncology guidelines, a converter that injects them into GraphRAG *without* LLM extraction, five indexed GraphRAG projects, a Klein REST API, and a single-file Phoenix LiveView UI ("Luna").

NCCN content is copyrighted. The graphs, parquet, and PDFs are lossy derivatives for **local use only** — never publish or redistribute them.

## NCCN demo

### Data flow

```
nccn_<cancer>_guidelines.pdf  (source, read by a human)
   ▼  authored by hand, one .dot per algorithm page (e.g. BINV-4_adjuvant-triage.dot)
nccn_graphs[_<cancer>]/*.dot
   ▼  nccn_to_graphrag.py   (dot -Tjson → node=entity, edge=relationship, dedupe, page anchors)
nccn_graphrag[_<cancer>]/output/{entities,relationships,text_units,documents}.parquet   (PRE-finalize schema)
   ▼  index_external_graph.py   (workflows: finalize_graph → create_communities → create_community_reports → generate_text_embeddings)
nccn_graphrag[_<cancer>]/output/{communities,community_reports}.parquet + output/lancedb/
   ▼  api/app.py (Klein, :8899)  →  nccn_ui/nccn_ui.exs (LiveView, :5901)
```

Directory pairs per guideline (registry is `GUIDELINE_DEFS` in `api/app.py`):

| key | Graphviz dir | GraphRAG project |
|---|---|---|
| `testicular` (default) | `nccn_graphs/` | `nccn_graphrag/` |
| `breast` | `nccn_graphs_breast/` | `nccn_graphrag_breast/` |
| `prostate` | `nccn_graphs_prostate/` | `nccn_graphrag_prostate/` |
| `colon` | `nccn_graphs_colon/` | `nccn_graphrag_colon/` |
| `nsclc` | `nccn_graphs_nsclc/` | `nccn_graphrag_nsclc/` |

To add a guideline: create both dirs, run the converter and indexer, then add a row to `GUIDELINE_DEFS` and the `COPY` lines in `Dockerfile`. The API only loads a guideline if both `output/entities.parquet` and the graphs dir exist.

### Graph injection: the key design decision

The demo **skips the LLM extraction half of the pipeline**. `nccn_to_graphrag.py` writes the pre-finalize `entities`/`relationships` tables directly (see `poc_inject_graph.py` for the generic proof-of-concept), and `index_external_graph.py` runs only the back half by passing `workflows` via `cli_overrides` to `load_config` — so each project's `settings.yaml` stays the stock `graphrag init` output. It also sets `cluster_graph.use_lcc: false` because the injected graph has several connected components.

Conventions the converter and the API both depend on — keep them in sync:

- **Page code** = leading `[A-Z]{2,6}-\d+[A-Z]?` of the `.dot` filename (`CODE_RE` in `nccn_to_graphrag.py`, `_CODE` in `api/flowchart.py`). Files like `TEST-D_*.dot` (no digit) and `00_*.dot` are excluded from indexing.
- **Node fillcolor → entity type** (`COLOR_TYPE`, duplicated in `nccn_to_graphrag.py` and `api/flowchart.py`): Workup / Treatment / Decision / Management / Recurrence / Salvage / Reference; unknown color → `Step`. Nodes with shape `note`/`plaintext` or a name starting `note` are skipped.
- **Entity identity** = normalized first line of the label (`norm()`), so the same step on two pages dedupes into one entity. `text_unit_ids` on an entity/relationship are the **page codes** it appears on — the API uses this to pick which flowchart to show.
- **Page-anchor entities** (type `Protocol Page`, one per `.dot`) link every node on a page and link to pages referenced in node text. The API classifies a cited relationship as `structural` if either end is an anchor, else `clinical`.
- `.dot` house style: `rankdir=LR`, decision diamonds, edge labels for branch conditions, dashed cross-page reference nodes. See `nccn_graphs/README.md` and `nccn_multicancer_README.md`.

### API (`api/`)

`app.py` loads all five projects at import time (config + parquet, once) and exposes `/guidelines`, `/pages`, `/query` (POST/GET), `/graph`, `/flowchart`, `/health`. Every endpoint takes a `guideline` key. GraphRAG's query API is asyncio and Klein is Twisted, so each query runs via `deferToThread` + `asyncio.run`.

`/query` with `route: true` first runs `detect_guideline` (`ROUTE_TERMS`, word-boundary regexes; ties → the requested guideline) and answers from the guideline the question names, setting `routed_from`; the UI always sends `route: true` and `handle_async(:run)` calls `switch_guideline` when the answer's guideline differs, so asking about breast cancer while Testicular is selected moves the whole UI to Breast instead of returning a "no data" refusal. `/query` post-processes the markdown answer into a typed `QueryResponse`: `parse_sections` splits on headings, `parse_citations` extracts `[Data: Relationships (12, 34); Entities (5)]` blocks, and `resolve_evidence` maps those `human_readable_id`s back to rows, then elects `primary_page` by majority vote over the pages of *clinical* edges (falling back to the first cited entity's page). The UI uses `evidence` to decide which flowchart to load and which path to highlight.

`patients.py` backs `GET /patients`, the roster behind the person icon in the UI. The primary target is **InterSystems TrakCare** (what United Family Healthcare runs): its FHIR layer is the IRIS for Health FHIR repository at `https://<host>/csp/healthshare/<ns>/fhir/r4`, secured by the IRIS OAuth 2.0 server or HTTP Basic. Config is a `Config` dataclass from `load_config()` reading `FHIR_BASE_URL`, `FHIR_AUTH` (`auto|oauth|basic|apikey|none`), `FHIR_CLIENT_ID/SECRET`, `FHIR_TOKEN_URL`, `FHIR_SCOPE`, `FHIR_USERNAME/PASSWORD`, `FHIR_API_KEY`, `FHIR_PROFILE`, `FHIR_VERIFY_TLS` (`INTELLICARE_*` kept as aliases). `make_client()` returns an httpx client with the right auth; OAuth uses `client_credentials` with `client_secret_basic`, discovers the token endpoint from `.well-known/smart-configuration` (fallback `<origin>/oauth2/token`), and refreshes once on 401. `_fetch_fhir` does three bulk searches, and `GUIDELINE_MAP` maps each primary cancer diagnosis to a guideline key (ICD-10 prefix, then SNOMED, then keyword; small-cell lung is excluded from `nsclc`). Unset URL → the deterministic `MOCK_PATIENTS` roster. The route always returns 200; `source` is `trakcare`, `fhir`, `mock` or `error` and the payload carries `server`/`auth`; every path goes through `_summarize` so the JSON shape is identical. `load_roster(cfg=…, transport=…)` accepts an `httpx.MockTransport`, which is how the auth modes are tested without a server. TrakCare has no public sandbox (InterSystems grants access case by case); `scripts/trakcare_fhir_setup.py` is the human-in-the-loop Playwright walkthrough of the IRIS Management Portal that produces the credentials. `make_oncology_bundle.py` turns `MOCK_PATIENTS` into a FHIR transaction Bundle (`oncology_patients_bundle.json`) and can `--upload` it, so a sandbox can be seeded with the exact roster the mock shows. Keep `MOCK_PATIENTS`, `GUIDELINE_MAP`, and the bundle generator in sync; the round-trip check is to run the generated bundle through `normalize()` and expect zero unmapped patients.

`flowchart.py` parses `.dot` files with `dot -Tjson` and emits either Cytoscape.js elements (`build_graph`, with `hl` flags; edge highlight key is `"<src title>|<tgt title>"`) or a server-rendered SVG (`build_svg`, legacy). Graphviz `dot` must be on PATH.

`api/README.md` predates multi-guideline support and only documents the testicular `/query` shape; `nccn_ui/README.md` and `docs/architecture/` are current.

### UI (`nccn_ui/nccn_ui.exs`)

One Elixir script using `Mix.install` (no mix project). Modules: `NccnUi.Layouts` (root HTML, loads Tailwind/Cytoscape/dagre from CDN and defines the `Cyto` JS hook inline), `NccnUi.HomeLive` (all state and events), `Router`, `Endpoint` (Bandit). The LiveView calls the API with `Req`, runs queries in `start_async`, and pushes graph elements to the browser with `push_event("graph", ...)`; the hook renders and lays out with dagre. Step-by-step reveal uses a BFS rank (`add_order`/`bfs`) computed server-side. The patient roster modal is driven by the `patients_open/refresh/close/filter` and `patient_select` events plus a `:patients` async; `switch_guideline/2` is shared by the sidebar pills and patient selection. `patient_select` also sets the **active patient** (`@patient`, `@patient_detail` via `GET /patients/<id>` in a `:patient_detail` async, a "patient" tab, a header chip) and calls `do_ask(patient_question(p))`; while `@patient` is set, `do_ask` prepends `patient_context/1` to the query sent to the API (the chat bubble shows the typed text with a "for <name>" tag). `patient_clear` drops it. **Voice** follows the nxt-teach Elixir pattern (`../nxt-teach/nxt_teach_backend/lib/nxt_teach/voice/deepgram.ex` + its `VoiceRecorder` hook), inlined as `NccnUi.Voice` (Req to Deepgram `/v1/listen` and `/v1/speak`, key read per call from `DEEPGRAM_API_KEY`, never logged) and `NccnUi.VoiceController` (`POST /voice/transcribe` reads the raw `audio/*` body — the Endpoint's `Plug.Parsers` has `pass: ["audio/*"]` for exactly this — and `GET /voice/status`). The `VoiceRecorder` hook records with `MediaRecorder`, POSTs the blob with the page's CSRF token, and pushes `voice_recording/uploading/transcribed/failed`; `voice_transcribed` goes through `do_ask` (tagged "🎤 spoken"), and after an answer `maybe_speak` runs Aura TTS in a `:speak` async and `push_event("play_audio", %{audio: base64, mime})`. Audio never rides the LiveView websocket upward, only the whole reply clip downward. The UI container gets `DEEPGRAM_API_KEY` from compose. There is no catch-all `handle_event`, so every new `phx-*` binding needs a clause or the view crashes. Env: `NCCN_API` (default `http://127.0.0.1:8899`), `PORT`, `HTTP_IP`, `DEEPGRAM_API_KEY` (+ `DEEPGRAM_LISTEN_MODEL`, `DEEPGRAM_SPEAK_MODEL`).

### Commands (demo)

```shell
# convert one guideline's flowcharts to pre-finalize parquet
uv run python nccn_to_graphrag.py <graphs_dir> <out_dir> <doc_id> "<doc_name>"
uv run python nccn_to_graphrag.py nccn_graphs_breast nccn_graphrag_breast/output nccn-breast-v5.2026 "NCCN Breast Cancer"

# index (needs GRAPHRAG_API_KEY; idempotent; arg is the project root, default nccn_graphrag)
uv run python index_external_graph.py nccn_graphrag_breast

# query from the CLI
uv run python -m graphrag query --root nccn_graphrag_colon --method local "Treatment for dMMR/MSI-H metastatic colon cancer?"

# run the stack locally (Makefile has the same as runapi / runui / testapi / testcli)
uv run --with klein python api/app.py                      # :8899
NCCN_API=http://127.0.0.1:8899 elixir nccn_ui/nccn_ui.exs   # :5901 (first run compiles deps, ~1–2 min)
curl -s -X POST localhost:8899/query -H 'content-type: application/json' \
  -d '{"guideline":"colon","query":"...","method":"local"}' | jq

# containers (multi-stage Dockerfile: targets `api`, `ui`, `iris`). `iris` = IRIS for Health Community
# provisioned by fhir-dev/iris.script (FHIR R4 at :52773/csp/healthshare/fhirserver/fhir/r4, Basic user
# luna_fhir/lunapw, Management Portal _SYSTEM/SYS); `fhir-seed` loads the oncology bundle once. The api
# defaults to it; FHIR_BASE_URL= (empty) in .env -> mock roster; a TrakCare URL + creds -> TrakCare.
GRAPHRAG_API_KEY=sk-... docker compose up --build

# guided (human-in-the-loop, visible browser) TrakCare FHIR access via the IRIS Management Portal -> writes FHIR_* to .env
uv run --with playwright --with httpx python scripts/trakcare_fhir_setup.py --host https://<trakcare-test-host>   # --from verify to resume
uv run --with playwright --with httpx python scripts/trakcare_fhir_setup.py --dev-iris                           # autopilot against the compose `iris` dev server (no prompts)

# render a flowchart / rebuild the architecture deck (needs dot + typst ≥ 0.12)
dot -Tsvg nccn_graphs_breast/BINV-4_adjuvant-triage.dot -o /tmp/binv4.svg
docs/architecture/build.sh
```

`GRAPHRAG_API_KEY` (OpenAI) lives in `.env` at the root and is auto-loaded by tests and by `load_config`. `global` search = thematic (community reports); `local` = entity-specific (LanceDB embeddings).

### Root clutter to leave alone

`complete_demo_claude_logs.md`, `graphrag_injection_full.md`, `graphviz_conversion_work.md`, `nccn_fullstack.md` are session transcripts, and `graphrag_publication.*` / `nccn_*_guidelines.pdf|txt` are source material. Don't index, lint, or "clean up" them.

## Upstream GraphRAG engine

### Repository layout: uv workspace monorepo

This is a **uv workspace** (`[tool.uv.workspace]` in the root `pyproject.toml`), not a single package. `DEVELOPING.md`'s "Repository Structure" section describes the older flat layout — the real code lives under `packages/`:

- `packages/graphrag` — the main package (CLI, API, indexing engine, query engine, config, data model, prompts). Import root is `graphrag`.
- `packages/graphrag-common` — shared config/env utilities. Import root `graphrag_common`. Depended on by every other package.
- `packages/graphrag-cache`, `-storage`, `-vectors`, `-input`, `-chunking`, `-llm` — factory-based pluggable subsystems, each its own installable package.

Inter-package versions are pinned exactly (e.g. `graphrag-common==3.1.1`) and bumped together at release; `[tool.uv.sources]` maps them to the workspace so local edits are picked up without reinstalling.

`unified-search-app/` is a separate, unsupported Streamlit demo with its own `pyproject.toml` and `uv.lock` — not part of the workspace and unrelated to the NCCN UI.

### Commands (engine)

All commands run through `uv` + `poethepoet` (tasks in root `pyproject.toml` under `[tool.poe.tasks]`).

```shell
uv sync                        # install all workspace deps into the venv
uv run poe check               # format check + ruff lint + pyright — run before pushing
uv run poe fix                 # auto-fix lint issues (ruff --fix); poe format for formatting only
uv run poe test_unit           # unit tests (tests/unit)
uv run poe test_integration    # integration tests
uv run poe test_smoke          # smoke tests (end-to-end; some need Azurite: ./scripts/start-azurite.sh)
uv run poe test_verbs          # workflow/verb output tests
uv run poe test_only -- "<expr>"   # single test by pytest -k pattern
uv run poe index | query | init | update | prompt_tune   # = python -m graphrag <cmd>
```

Every PR to the engine needs a semversioner change file or CI fails:

```shell
uv run semversioner add-change -t <major|minor|patch> -d "<one sentence>"
```

### Architecture

**Factory + registration pattern (pervasive).** Each swappable subsystem exposes a `factory.py` with a registry and a `register(...)` classmethod: caches, storage, vector stores, loggers, and — most importantly — **indexing pipelines and workflows** (`packages/graphrag/graphrag/index/workflows/factory.py`). Register a variant with the factory rather than branching on an enum.

**Indexing engine.** An index run is an **ordered list of named workflow functions** assembled by `PipelineFactory.create_pipeline(config, method)` and executed by `index/run/run_pipeline.py`. Each workflow in `index/workflows/` reads/writes pandas DataFrames through the configured storage backend: raw text → text units → entities/relationships → Leiden communities → community reports → embeddings. Four built-in pipelines are registered via `IndexingMethod` (Standard = LLM `extract_graph`; Fast = NLP `extract_graph_nlp` + `prune_graph`; `*Update` variants wrap them with `load_update_documents` + `update_*`). **`config.workflows`, if set, overrides the method's default list entirely** — this is the hook the NCCN indexer uses.

> Leiden clustering is pinned to `graspologic-native>=1.2,<1.3` on purpose — 1.3.x changes community output and breaks golden regression data (comment in `packages/graphrag/pyproject.toml`). Don't bump it casually; it would also reshuffle the NCCN community reports.

**Query engine.** `query/structured_search/` has four strategies subclassing `base.py`: `global_search` (map-reduce over community reports), `local_search` (entity-centric), `drift_search`, `basic_search`. Context assembly is in `query/context_builder/`; `query/indexer_adapters.py` loads parquet into the query data model. Answers cite with `[Data: <Table> (<human_readable_id>, ...)]` — the demo API depends on this format.

**API is the stable seam.** `packages/graphrag/graphrag/api/` (`build_index`, `global_search`, `local_search`, `drift_search`, `basic_search`, plus `*_streaming`) is the programmatic interface; the Typer CLI in `cli/` is a thin wrapper. Add logic in `api/` so both get it. The NCCN scripts and Klein API call only this layer.

**Config.** Pydantic v2 models in `config/models/` (root `GraphRagConfig`). `load_config(root, cli_overrides=...)` merges `settings.yaml` + env vars + defaults; `init_content.py` is the `graphrag init` template.

**Data model.** `data_model/` defines `Document`, `TextUnit`, `Entity`, `Relationship`, `Community`, `CommunityReport`, `Covariate`; `schemas.py` holds the DataFrame column-name constants. The pre-finalize vs. post-finalize entity/relationship shapes (`finalize_graph` adds `id`, `human_readable_id`, `degree`) are what the NCCN converter targets.

**LLM calls.** `graphrag-llm` wraps **litellm** (pinned `==1.92.0`); prompts live in `packages/graphrag/graphrag/prompts/`.

### Conventions (engine)

- **Linting is strict.** Ruff with a large rule set and numpy-style docstrings (`D` rules); `T20` bans `print` in library code. Tests relax many rules via `per-file-ignores`. Ruff runs on `.`, so it also hits the root NCCN scripts and `api/` — those were written script-style (`print`, `subprocess`, no docstrings) and currently fail `poe check` with ~70 findings. Don't "fix" them to satisfy the engine's rules unless asked; if you touch the engine, lint just `packages/` and `tests/`.
- **Type-checked with pyright** over `graphrag*` package sources and `tests` only (`[tool.pyright] include`); the demo code is outside pyright's scope.
- Async-first: pytest runs with `asyncio_mode = "auto"`; API entry points are `async def`.
