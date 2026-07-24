# Copyright (c) 2024 Microsoft Corporation.
# Licensed under the MIT License

"""Render a protocol flowchart as SVG or Cytoscape JSON, optionally highlighting
a cited path. All functions take the guideline's Graphviz directory so one
backend can serve multiple guidelines.

Rebuilds a page's DOT from its source .dot (via `dot -Tjson`), recolors the
requested nodes/edges, and re-runs `dot -Tsvg`. Footnote annotations are
dropped so the rendered chart is the clinical algorithm only.
"""

from __future__ import annotations

import json
import re
import subprocess
from functools import lru_cache
from pathlib import Path

_CODE = re.compile(r"^([A-Z]{2,6}-\d+[A-Z]?)")
HL = "#c0392b"  # highlight color (server-rendered SVG variant)

COLOR_TYPE = {
    "#D6EAF8": "Workup", "#D5F5E3": "Treatment", "#ABEBC6": "Treatment",
    "#EAFAF1": "Treatment", "#F9E79F": "Decision", "#FCF3CF": "Decision",
    "#EAECEE": "Management", "#F5B7B1": "Recurrence", "#FDEDEC": "Recurrence",
    "#F1948A": "Salvage", "#FDEBD0": "Reference",
}


def _first_line(label: str) -> str:
    text = label.replace("\\l", "\n").replace("\\n", "\n")
    for ln in text.split("\n"):
        ln = ln.strip()
        if ln:
            return ln
    return ""


def _natkey(code: str):
    m = re.match(r"([A-Za-z]+)-?(\d+)?([A-Za-z]*)", code)
    if not m:
        return (code, 0, "")
    return (m.group(1), int(m.group(2) or 0), m.group(3) or "")


@lru_cache(maxsize=None)
def page_files(graphs_dir: str) -> dict[str, str]:
    """code -> dot path for a guideline's directory."""
    out: dict[str, str] = {}
    for f in sorted(Path(graphs_dir).glob("*.dot")):
        if f.stem.startswith("00_"):
            continue
        m = _CODE.match(f.stem)
        if m:
            out.setdefault(m.group(1), str(f))
    return out


@lru_cache(maxsize=None)
def page_index(graphs_dir: str) -> tuple:
    """Ordered tuple of {code,label} for a guideline (natural-sorted by code)."""
    items = []
    for code, path in page_files(graphs_dir).items():
        _, _, label = _parse(path)
        items.append({"code": code, "label": label or code})
    items.sort(key=lambda it: _natkey(it["code"]))
    return tuple(items)


def _parse(path: str):
    doc = json.loads(subprocess.run(
        ["dot", "-Tjson", path], capture_output=True, text=True, check=True).stdout)
    nodes = {}
    for o in doc.get("objects", []):
        if "nodes" in o or "subgraphs" in o:
            continue
        if o.get("shape") == "note" or o.get("name", "").startswith("note"):
            continue
        nodes[o["_gvid"]] = o
    return nodes, doc.get("edges", []), doc.get("label", "")


def build_svg(graphs_dir: str, page: str, hl_nodes: set[str] | None = None,
              hl_edges: set[str] | None = None) -> str | None:
    files = page_files(graphs_dir)
    if page not in files:
        return None
    hl_nodes = hl_nodes or set()
    hl_edges = hl_edges or set()
    nodes, edges, label = _parse(files[page])

    out = [
        "digraph G {",
        'rankdir=LR; bgcolor="transparent"; pad=0.2;',
        f'label="{label}"; labelloc="t"; fontname="Helvetica-Bold"; fontsize=13;',
        'node [fontname="Helvetica", fontsize=10, style="rounded,filled",'
        ' shape=box, margin="0.13,0.08", color="#34495e"];',
        'edge [fontname="Helvetica", fontsize=9, color="#95a5a6", arrowsize=0.8];',
    ]
    for gv, o in nodes.items():
        title = _first_line(o.get("label", o.get("name", "")))
        lbl = o.get("label", o.get("name", "")).replace('"', '\\"')
        shape = o.get("shape", "box")
        shape = shape if shape in ("diamond", "box", "ellipse") else "box"
        fill = o.get("fillcolor", "#ECF0F1")
        style = o.get("style", "rounded,filled")
        extra = f', color="{HL}", penwidth=3' if title in hl_nodes else ""
        out.append(f'n{gv} [label="{lbl}", shape={shape}, fillcolor="{fill}", '
                   f'style="{style}"{extra}];')
    for e in edges:
        t, h = e.get("tail"), e.get("head")
        if t not in nodes or h not in nodes:
            continue
        st, tt = _first_line(nodes[t].get("label", "")), _first_line(nodes[h].get("label", ""))
        attrs = []
        lab = (e.get("label") or "").replace('"', "")
        if lab:
            attrs.append(f'label="{lab}"')
        if f"{st}|{tt}" in hl_edges:
            attrs.append(f'color="{HL}"')
            attrs.append("penwidth=3")
        a = (" [" + ", ".join(attrs) + "]") if attrs else ""
        out.append(f"n{t} -> n{h}{a};")
    out.append("}")

    return subprocess.run(["dot", "-Tsvg"], input="\n".join(out),
                          capture_output=True, text=True, check=True).stdout


def build_graph(graphs_dir: str, page: str, hl_nodes: set[str] | None = None,
                hl_edges: set[str] | None = None) -> dict | None:
    """Return the page as Cytoscape.js elements, with `hl` flags on the cited path."""
    files = page_files(graphs_dir)
    if page not in files:
        return None
    hl_nodes = hl_nodes or set()
    hl_edges = hl_edges or set()
    nodes, edges, label = _parse(files[page])

    cy_nodes = []
    for gv, o in nodes.items():
        raw = o.get("label", o.get("name", ""))
        text = raw.replace("\\l", "\n").replace("\\n", "\n").strip()
        title = _first_line(raw)
        shape = "diamond" if o.get("shape") == "diamond" else "round-rectangle"
        cy_nodes.append({"data": {
            "id": f"n{gv}", "label": text, "title": title,
            "type": COLOR_TYPE.get(o.get("fillcolor", ""), "Step"),
            "shape": shape, "hl": title in hl_nodes,
        }})

    cy_edges = []
    for i, e in enumerate(edges):
        t, h = e.get("tail"), e.get("head")
        if t not in nodes or h not in nodes:
            continue
        st, tt = _first_line(nodes[t].get("label", "")), _first_line(nodes[h].get("label", ""))
        cy_edges.append({"data": {
            "id": f"e{i}", "source": f"n{t}", "target": f"n{h}",
            "label": e.get("label") or "", "hl": f"{st}|{tt}" in hl_edges,
        }})

    return {"page": page, "label": label, "nodes": cy_nodes, "edges": cy_edges}
