#!/usr/bin/env python
# Copyright (c) 2024 Microsoft Corporation.
# Licensed under the MIT License

"""Proof-of-concept: inject an externally-compiled knowledge graph into GraphRAG.

Instead of mining entities and relationships from unstructured text with an LLM
(the ``extract_graph`` / ``extract_graph_nlp`` workflows), this script writes the
two tables those workflows would produce -- ``entities`` and ``relationships`` --
directly from a graph you already have (edge list, Neo4j export, etc.).

Pipeline context (see the GraphRAG paper, Fig. 1 / sec. 3.1):

    Source Docs -> Text Chunks -> [Entities & Relationships] -> Knowledge Graph
                -> Graph Communities -> Community Summaries -> Answers

Everything from "Knowledge Graph" onward consumes only the entities/relationships
tables. So we write those, then run the pipeline starting at ``finalize_graph``.

Schemas produced here are the PRE-finalize shape. ``finalize_graph`` fills in the
remaining columns (``id``, ``human_readable_id``, ``degree`` / ``combined_degree``).
Contracts live in ``graphrag/data_model/schemas.py``.

--------------------------------------------------------------------------------
USAGE
--------------------------------------------------------------------------------

1. Scaffold a project if you don't have one:

       uv run poe init -- --root ./ragtest

2. Write the graph tables (built-in demo graph -- the NeoChip example from the
   paper, sec. 3.1.2):

       uv run python poc_inject_graph.py --root ./ragtest

   ...or from your own CSVs:

       uv run python poc_inject_graph.py --root ./ragtest \\
           --nodes nodes.csv --edges edges.csv

   nodes.csv  columns: title,type,description         (title required)
   edges.csv  columns: source,target,description,weight  (source/target required)

3. Override the workflow list in ragtest/settings.yaml so extraction is skipped:

       workflows:
         - finalize_graph
         - create_communities
         - create_community_reports     # graph-based; do NOT use *_text variant
         - generate_text_embeddings

4. Index (extraction never runs; finalize_graph reads the parquet written here):

       uv run poe index -- --root ./ragtest

5. Query the community structure (global search matches the paper's map-reduce):

       uv run poe query -- --root ./ragtest --method global \\
           "What are the main themes?"

Pass --emit-settings to print the exact YAML snippet for step 3.

CAVEATS
    - No text_units are created here, so use global search. Local/basic search and
      the create_community_reports_text workflow require a text_units table.
    - Ensure your embedding config does not target text_units (there are none).
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import pandas as pd

# Columns each table must carry INTO finalize_graph. Mirrors the tail of
# ENTITIES_FINAL_COLUMNS / RELATIONSHIPS_FINAL_COLUMNS minus the fields
# finalize_graph computes itself.
ENTITY_INPUT_COLUMNS = ["title", "type", "description", "text_unit_ids", "frequency"]
RELATIONSHIP_INPUT_COLUMNS = ["source", "target", "description", "weight", "text_unit_ids"]

WORKFLOW_SNIPPET = """\
workflows:
  - finalize_graph
  - create_communities
  - create_community_reports
  - generate_text_embeddings
"""

# The paper's worked example (sec. 3.1.2) as a tiny standalone graph.
DEMO_NODES = [
    ("NeoChip", "ORGANIZATION",
     "NeoChip is a publicly traded company specializing in low-power "
     "processors for wearables and IoT devices."),
    ("Quantum Systems", "ORGANIZATION",
     "Quantum Systems is a firm that previously owned NeoChip."),
    ("NewTech Exchange", "ORGANIZATION",
     "The stock exchange on which NeoChip made its public debut."),
]
DEMO_EDGES = [
    ("NeoChip", "Quantum Systems",
     "Quantum Systems owned NeoChip from 2016 until NeoChip became publicly traded.",
     2.0),
    ("NeoChip", "NewTech Exchange",
     "NeoChip's shares surged in their first week of trading on the NewTech Exchange.",
     1.0),
]


def _load_nodes(path: Path | None) -> pd.DataFrame:
    if path is None:
        return pd.DataFrame(DEMO_NODES, columns=["title", "type", "description"])
    df = pd.read_csv(path)
    if "title" not in df.columns:
        _fail(f"{path}: nodes file must have a 'title' column")
    return df


def _load_edges(path: Path | None) -> pd.DataFrame:
    if path is None:
        return pd.DataFrame(
            DEMO_EDGES, columns=["source", "target", "description", "weight"]
        )
    df = pd.read_csv(path)
    missing = {"source", "target"} - set(df.columns)
    if missing:
        _fail(f"{path}: edges file must have {sorted(missing)} column(s)")
    return df


def build_entities(nodes: pd.DataFrame, edges: pd.DataFrame) -> pd.DataFrame:
    """Assemble the pre-finalize entities table, keyed on 'title'."""
    entities = nodes.copy()

    # Any node named in an edge but absent from the nodes table is still a real
    # entity -- create_communities joins on title, so it must exist here.
    edge_titles = pd.unique(pd.concat([edges["source"], edges["target"]]))
    known = set(entities["title"])
    for title in edge_titles:
        if title not in known:
            entities.loc[len(entities)] = {"title": title}

    if "type" not in entities:
        entities["type"] = ""
    if "description" not in entities:
        entities["description"] = ""
    entities["type"] = entities["type"].fillna("")
    entities["description"] = entities["description"].fillna("")

    # No source text is being injected, so text_unit_ids are empty lists.
    entities["text_unit_ids"] = [[] for _ in range(len(entities))]

    # 'frequency' is copied through finalize (not recomputed): use edge incidence
    # as a reasonable stand-in for how often the entity appeared in the corpus.
    incidence = (
        pd.concat([edges["source"], edges["target"]]).value_counts().to_dict()
    )
    entities["frequency"] = entities["title"].map(incidence).fillna(1).astype(int)

    return entities[ENTITY_INPUT_COLUMNS]


def build_relationships(edges: pd.DataFrame) -> pd.DataFrame:
    """Assemble the pre-finalize relationships table."""
    rels = edges.copy()
    if "description" not in rels:
        rels["description"] = ""
    rels["description"] = rels["description"].fillna("")
    if "weight" not in rels:
        rels["weight"] = 1.0
    rels["weight"] = rels["weight"].fillna(1.0).astype(float)
    rels["text_unit_ids"] = [[] for _ in range(len(rels))]
    return rels[RELATIONSHIP_INPUT_COLUMNS]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Write entities.parquet / relationships.parquet from an "
        "external graph so GraphRAG can skip LLM extraction.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--root", type=Path, default=Path("./ragtest"),
        help="GraphRAG project root (default: ./ragtest)",
    )
    parser.add_argument(
        "--output-subdir", default="output",
        help="Output storage dir under --root (default: output). Must match "
        "the storage.base_dir in settings.yaml.",
    )
    parser.add_argument("--nodes", type=Path, help="CSV of nodes (optional)")
    parser.add_argument("--edges", type=Path, help="CSV of edges (optional)")
    parser.add_argument(
        "--emit-settings", action="store_true",
        help="Print the settings.yaml workflow snippet and exit.",
    )
    args = parser.parse_args(argv)

    if args.emit_settings:
        print(WORKFLOW_SNIPPET)
        return 0

    nodes = _load_nodes(args.nodes)
    edges = _load_edges(args.edges)

    entities = build_entities(nodes, edges)
    relationships = build_relationships(edges)

    out_dir = args.root / args.output_subdir
    out_dir.mkdir(parents=True, exist_ok=True)
    entities.to_parquet(out_dir / "entities.parquet", index=False)
    relationships.to_parquet(out_dir / "relationships.parquet", index=False)

    print(f"Wrote {len(entities)} entities  -> {out_dir / 'entities.parquet'}")
    print(f"Wrote {len(relationships)} relationships -> {out_dir / 'relationships.parquet'}")
    print()
    print("Next: set this in", args.root / "settings.yaml", "then run 'poe index':")
    print()
    print(WORKFLOW_SNIPPET)
    return 0


def _fail(msg: str) -> None:
    print(f"error: {msg}", file=sys.stderr)
    raise SystemExit(2)


if __name__ == "__main__":
    raise SystemExit(main())
