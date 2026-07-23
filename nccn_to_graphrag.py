#!/usr/bin/env python
# Copyright (c) 2024 Microsoft Corporation.
# Licensed under the MIT License

"""Convert the NCCN Graphviz flowcharts into GraphRAG input tables.

Reads the .dot files in nccn_graphs/ (via `dot -Tjson` for a robust parse),
turns every flowchart NODE into a GraphRAG *entity* and every EDGE into a
*relationship*, deduplicates concepts that recur across pages, and writes the
pre-finalize tables GraphRAG expects:

    <output>/entities.parquet
    <output>/relationships.parquet
    <output>/text_units.parquet     (one per protocol page, for provenance)
    <output>/documents.parquet

The indexing pipeline then runs finalize_graph -> create_communities ->
create_community_reports on top of these (see build_and_query notes in the
project README). Schema contracts: graphrag/data_model/schemas.py.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

import pandas as pd

# Flowchart pages only. Exclude 00_overview (meta-map) and TEST-D (an HTML
# table node, not a flow). These 19 are the clinical decision algorithms.
INCLUDE_PREFIXES = ("TEST-1", "SEM-", "NSEM-")

# fillcolor -> entity type
COLOR_TYPE = {
    "#D6EAF8": "Workup",
    "#D5F5E3": "Treatment",
    "#ABEBC6": "Treatment",
    "#EAFAF1": "Treatment",
    "#F9E79F": "Decision",
    "#FCF3CF": "Decision",
    "#EAECEE": "Management",
    "#F5B7B1": "Recurrence",
    "#FDEDEC": "Recurrence",
    "#F1948A": "Salvage",
    "#FDEBD0": "Reference",
}

# node names / shapes to skip (annotations, not clinical entities)
SKIP_SHAPES = {"note", "plaintext"}


def clean(text: str) -> str:
    """Turn a Graphviz label into readable text.

    dot -Tjson keeps line breaks as the literal 2-char escapes \\n and \\l.
    """
    if not text:
        return ""
    text = text.replace("\\l", "\n").replace("\\n", "\n").replace("\\r", "")
    lines = [re.sub(r"[ \t]+", " ", ln).strip() for ln in text.split("\n")]
    lines = [ln for ln in lines if ln]
    return "\n".join(lines)


def norm(title: str) -> str:
    """Normalization key for deduping concepts across pages."""
    return re.sub(r"\s+", " ", title.lower()).strip(" .:")


def page_code(path: Path) -> str:
    """SEM-3_stageIIA-IIB.dot -> SEM-3."""
    m = re.match(r"(TEST-1|SEM-\d+|NSEM-\d+[A-Z]?)", path.stem)
    return m.group(1) if m else path.stem


def parse_dot(path: Path):
    """Return (nodes_by_gvid, edges, graph_label) from a .dot via dot -Tjson."""
    out = subprocess.run(
        ["dot", "-Tjson", str(path)],
        capture_output=True, text=True, check=True,
    ).stdout
    doc = json.loads(out)
    graph_label = clean(doc.get("label", "")).replace("\n", " ")
    nodes = {}
    for obj in doc.get("objects", []):
        # subgraphs/clusters carry 'nodes'/'subgraphs'; real nodes don't
        if "nodes" in obj or "subgraphs" in obj:
            continue
        if obj.get("shape") in SKIP_SHAPES or obj.get("name", "").startswith("note"):
            continue
        label = clean(obj.get("label", obj.get("name", "")))
        if not label:
            continue
        title = label.split("\n", 1)[0].strip()
        if not title:
            continue
        nodes[obj["_gvid"]] = {
            "title": title,
            "description": label,
            "type": COLOR_TYPE.get(obj.get("fillcolor", ""), "Step"),
        }
    edges = []
    for e in doc.get("edges", []):
        if "invis" in (e.get("style") or ""):
            continue
        edges.append((e.get("tail"), e.get("head"), clean(e.get("label", "") or "")))
    return nodes, edges, graph_label


def main(argv: list[str] | None = None) -> int:
    argv = argv if argv is not None else sys.argv[1:]
    graphs_dir = Path(argv[0]) if argv else Path("nccn_graphs")
    out_dir = Path(argv[1]) if len(argv) > 1 else Path("nccn_graphrag/output")
    out_dir.mkdir(parents=True, exist_ok=True)

    files = sorted(
        f for f in graphs_dir.glob("*.dot")
        if f.stem.startswith(INCLUDE_PREFIXES)
    )
    if not files:
        print(f"error: no matching .dot files in {graphs_dir}", file=sys.stderr)
        return 2

    page_codes = {page_code(f) for f in files}
    # regex to detect references to other protocol pages in node text
    ref_re = re.compile(r"\b(TEST-1|SEM-\d+|NSEM-\d+[A-Z]?)\b")

    # entities keyed by normalized title (dedupe across pages)
    ents: dict[str, dict] = {}
    # relationships keyed by (src_norm, tgt_norm)
    rels: dict[tuple[str, str], dict] = {}
    text_units: list[dict] = []

    def add_entity(key, title, etype, desc, page):
        e = ents.get(key)
        if e is None:
            ents[key] = e = {"title": title, "type": etype,
                             "description": desc, "pages": set()}
        e["pages"].add(page)
        if e["type"] == "Step" and etype != "Step":
            e["type"] = etype
        if len(desc) > len(e["description"]):
            e["description"] = desc
        return e

    def add_rel(s_title, t_title, desc, page, weight=1.0):
        s, t = norm(s_title), norm(t_title)
        if s == t:
            return
        r = rels.get((s, t))
        if r is None:
            rels[(s, t)] = {"source": s_title, "target": t_title,
                            "description": desc, "weight": weight, "pages": {page}}
        else:
            r["weight"] += weight
            r["pages"].add(page)
            if desc and desc not in r["description"]:
                r["description"] += f"; {desc}"

    # Pass 1: parse every page, resolve each page's anchor title up front so
    # cross-page reference edges (including forward references) can be wired.
    parsed = []
    code2anchor: dict[str, str] = {}
    for path in files:
        code = page_code(path)
        nodes, edges, graph_label = parse_dot(path)
        anchor_title = graph_label or f"NCCN Testicular Cancer {code}"
        code2anchor[code] = anchor_title
        parsed.append((code, nodes, edges, anchor_title))

    # Pass 2: build entities + relationships
    for code, nodes, edges, anchor_title in parsed:
        # a page-anchor entity connects everything documented on this page and
        # gives the otherwise-fragmented pages a connected spine via references
        add_entity(f"__page__{code.lower()}", anchor_title, "Protocol Page",
                   f"NCCN Testicular Cancer protocol page {code}. {anchor_title}", code)

        page_lines = []
        referenced: set[str] = set()

        for gv, n in nodes.items():
            add_entity(norm(n["title"]), n["title"], n["type"], n["description"], code)
            # link every step on the page to the page anchor (intra-page connectivity)
            add_rel(anchor_title, n["title"], f"step in {code}", code, weight=0.5)
            for m in ref_re.findall(n["title"] + " " + n["description"]):
                if m != code and m in page_codes:
                    referenced.add(m)

        for tail, head, label in edges:
            if tail not in nodes or head not in nodes:
                continue
            s_title, t_title = nodes[tail]["title"], nodes[head]["title"]
            desc = label or f"{s_title} → {t_title}"
            add_rel(s_title, t_title, desc, code)
            page_lines.append(f"- {s_title} → {t_title}"
                              + (f" [{label}]" if label else ""))

        # connect this page's anchor to the anchors of pages it references
        for ref in referenced:
            add_rel(anchor_title, code2anchor[ref], f"{code} refers to {ref}", code)

        graph_title = f"NCCN Testicular Cancer — {code}"
        page_text = graph_title + "\n" + "\n".join(page_lines)
        text_units.append({
            "id": code,
            "human_readable_id": len(text_units),
            "text": page_text,
            "n_tokens": max(1, len(page_text.split())),
            "document_id": "nccn-testicular-v2.2026",
            "entity_ids": [],          # backlinks not needed for global search
            "relationship_ids": [],
            "covariate_ids": [],
        })

    # ---- entities.parquet (pre-finalize schema) ----
    entities_df = pd.DataFrame([
        {
            "title": e["title"],
            "type": e["type"],
            "description": e["description"],
            "text_unit_ids": sorted(e["pages"]),
            "frequency": len(e["pages"]),
        }
        for e in ents.values()
    ])

    # ---- relationships.parquet (pre-finalize schema) ----
    relationships_df = pd.DataFrame([
        {
            "source": r["source"],
            "target": r["target"],
            "description": r["description"],
            "weight": r["weight"],
            "text_unit_ids": sorted(r["pages"]),
        }
        for r in rels.values()
    ])

    text_units_df = pd.DataFrame(text_units)

    documents_df = pd.DataFrame([{
        "id": "nccn-testicular-v2.2026",
        "human_readable_id": 0,
        "title": "NCCN Testicular Cancer Guidelines v2.2026",
        "text": "\n\n".join(t["text"] for t in text_units),
        "text_unit_ids": [t["id"] for t in text_units],
        "creation_date": "2026-06-16",
        "raw_data": None,
    }])

    entities_df.to_parquet(out_dir / "entities.parquet", index=False)
    relationships_df.to_parquet(out_dir / "relationships.parquet", index=False)
    text_units_df.to_parquet(out_dir / "text_units.parquet", index=False)
    documents_df.to_parquet(out_dir / "documents.parquet", index=False)

    print(f"Parsed {len(files)} protocol pages -> {out_dir}")
    print(f"  entities.parquet      {len(entities_df):>4} entities")
    print(f"  relationships.parquet {len(relationships_df):>4} relationships")
    print(f"  text_units.parquet    {len(text_units_df):>4} pages")
    print(f"  documents.parquet        1 document")
    print("\nEntity types:")
    print(entities_df["type"].value_counts().to_string())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
