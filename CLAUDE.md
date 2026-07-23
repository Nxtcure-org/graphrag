# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

GraphRAG is a data pipeline and transformation suite that extracts structured knowledge-graph data from unstructured text using LLMs, then serves that graph for retrieval-augmented generation. See `README.md` and `DEVELOPING.md` for user-facing context.

## Repository layout: uv workspace monorepo

This is a **uv workspace** (`[tool.uv.workspace]` in the root `pyproject.toml`), not a single package. Note that `DEVELOPING.md`'s "Repository Structure" section describes the older flat layout — the real code lives under `packages/`:

- `packages/graphrag` — the main package (CLI, API, indexing engine, query engine, config, data model, prompts). Import root is `graphrag`.
- `packages/graphrag-common` — shared config/env utilities. Import root `graphrag_common`. Depended on by every other package.
- `packages/graphrag-cache`, `-storage`, `-vectors`, `-input`, `-chunking`, `-llm` — factory-based pluggable subsystems, each its own installable package (`graphrag_cache`, etc.).

Inter-package versions are pinned exactly (e.g. `graphrag-common==3.1.1`) and bumped together at release; `[tool.uv.sources]` maps them to the workspace so local edits are picked up without reinstalling.

`unified-search-app/` is a separate, unsupported demo app (Streamlit) with its own `pyproject.toml` and `uv.lock` — not part of the workspace.

## Commands

All commands run through `uv` + `poethepoet` (tasks defined in root `pyproject.toml` under `[tool.poe.tasks]`).

```shell
uv sync                        # install all workspace deps into the venv
uv run poe check               # format check + ruff lint + pyright — run before pushing
uv run poe fix                 # auto-fix lint issues (ruff --fix); poe format for formatting only
uv run poe test_unit           # unit tests (tests/unit)
uv run poe test_integration    # integration tests
uv run poe test_smoke          # smoke tests (end-to-end; some need Azurite)
uv run poe test_verbs          # workflow/verb output tests
uv run poe test_notebook       # runs example notebooks
uv run poe test_only -- "<expr>"   # single test by pytest -k pattern
```

Run the pipelines directly (same as the published `graphrag` console script):

```shell
uv run poe index    # python -m graphrag index
uv run poe query
uv run poe init      # scaffold settings.yaml + prompts into a root dir
uv run poe update    # incremental re-index
uv run poe prompt_tune
```

`uv run poe test_only` maps to `pytest -s -k`; pass the expression after `--`.

### Azurite

Smoke/integration tests that exercise Azure blob storage use the Azurite emulator: `./scripts/start-azurite.sh` (or `azurite` if installed globally).

## Every PR needs a semversioner change file

CI **fails** without one. Generate it with:

```shell
uv run semversioner add-change -t <major|minor|patch> -d "<one sentence describing the change>"
```

This writes a JSON file under `.semversioner/next-release/`; the release process aggregates these into `CHANGELOG.md` and bumps every package version in lockstep.

## Architecture

### Factory + registration pattern (pervasive)

Each swappable subsystem exposes a `factory.py` with a registry and a `register(...)` classmethod so users can inject custom implementations: caches, storage backends, vector stores, loggers, and — most importantly — **indexing pipelines and workflows** (`packages/graphrag/graphrag/index/workflows/factory.py`). When adding a backend variant, register it with the factory rather than branching on an enum.

### Indexing engine

An index run is an **ordered list of named workflow functions** assembled by `PipelineFactory.create_pipeline(config, method)` and executed by `index/run/run_pipeline.py`. Each workflow (in `index/workflows/`, e.g. `create_base_text_units`, `extract_graph`, `create_communities`, `create_community_reports`, `generate_text_embeddings`) reads/writes pandas DataFrames through the configured storage backend, transforming raw text → text units → entities/relationships graph → Leiden communities → community reports → embeddings.

Four built-in pipelines are registered via `IndexingMethod` (see the bottom of `workflows/factory.py`):
- **Standard** — LLM-based graph extraction (`extract_graph`).
- **Fast** — NLP-based extraction (`extract_graph_nlp` + `prune_graph`), cheaper/no-LLM for extraction.
- **StandardUpdate / FastUpdate** — the above prefixed with `load_update_documents` and suffixed with the `update_*` workflows for incremental indexing.

`config.workflows`, if set, overrides the method's default workflow list entirely.

> Leiden clustering is pinned to `graspologic-native>=1.2,<1.3` on purpose — 1.3.x changes community output and breaks golden regression data. Don't bump it casually (see the comment in `packages/graphrag/pyproject.toml`).

### Query engine

`query/structured_search/` implements four search strategies, each a subclass of the base search in `base.py`: **global_search** (map-reduce over community reports), **local_search** (entity-centric), **drift_search** (iterative follow-up refinement), and **basic_search** (vanilla vector RAG). Context assembly lives in `query/context_builder/`; `query/indexer_adapters.py` loads indexer parquet output into the query data model.

### API is the stable seam

`packages/graphrag/graphrag/api/` (`index.py`, `query.py`, `prompt_tune.py`) is the programmatic interface — `build_index`, `global_search`, `local_search`, `drift_search`, `basic_search` (plus `*_streaming` variants). The CLI in `cli/` is a thin Typer wrapper over these functions; prefer adding logic in `api/` so both CLI and library callers get it.

### Config

`config/` uses Pydantic v2 models (`config/models/`, root `GraphRagConfig`). `load_config.py` merges `settings.yaml` + env vars + defaults; `init_content.py` is the template emitted by `graphrag init`. Config format changes across minor versions — the docs instruct users to re-run `init --force`.

### Data model

`data_model/` defines the knowledge-graph entities passed between workflows and query: `Document`, `TextUnit`, `Entity`, `Relationship`, `Community`, `CommunityReport`, `Covariate`. `schemas.py` holds the DataFrame column-name constants used throughout the pipeline.

### LLM calls

`graphrag-llm` wraps **litellm** (pinned `==1.92.0`) for provider-agnostic chat/embedding calls, integrated with the cache package. Prompts live in `packages/graphrag/graphrag/prompts/`.

## Conventions

- **Linting is strict.** Ruff runs a large rule set (see `[tool.ruff.lint]`) with numpy-style docstrings required (`D` rules). Test files relax many rules via `per-file-ignores`. `T20` bans stray `print` in library code.
- **Type-checked with pyright** over the `graphrag*` package sources and `tests` (see `[tool.pyright]`).
- Async-first: pytest runs in `asyncio_mode = "auto"`; API entry points are `async def`.
- `.env` is auto-loaded in tests (`env_files = [".env"]`).
