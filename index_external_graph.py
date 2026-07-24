#!/usr/bin/env python
# Copyright (c) 2024 Microsoft Corporation.
# Licensed under the MIT License

"""Index the injected NCCN graph without touching settings.yaml.

Loads the project config and overrides ONLY the workflow list (via
cli_overrides) so the pipeline skips text loading + LLM graph extraction and
instead builds on the entities/relationships parquet written by
nccn_to_graphrag.py:

    finalize_graph -> create_communities -> create_community_reports
    -> generate_text_embeddings

Run with GRAPHRAG_API_KEY set in the environment.
"""

from __future__ import annotations

import asyncio
import sys
from pathlib import Path

import graphrag.index.workflows  # noqa: F401  (registers built-in workflows)
from graphrag.api import build_index
from graphrag.config.load_config import load_config

# project root: first CLI arg, else the testicular default
ROOT = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).parent / "nccn_graphrag"
WORKFLOWS = [
    "finalize_graph",
    "create_communities",
    "create_community_reports",
    "generate_text_embeddings",
]


async def main() -> None:
    config = load_config(ROOT, cli_overrides={
        "workflows": WORKFLOWS,
        # cluster ALL connected components (our graph has several), not just the
        # largest; and allow slightly bigger communities than the default.
        "cluster_graph": {"use_lcc": False, "max_cluster_size": 12},
    })
    results = await build_index(config, verbose=False)
    print("\n=== pipeline results ===")
    for r in results:
        status = "OK" if r.error is None else f"ERROR: {r.error}"
        print(f"  {r.workflow:<28} {status}")


if __name__ == "__main__":
    asyncio.run(main())
