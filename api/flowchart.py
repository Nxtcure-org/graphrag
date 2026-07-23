# Copyright (c) 2024 Microsoft Corporation.
# Licensed under the MIT License

"""Render a protocol flowchart as SVG, optionally highlighting a cited path.

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

GRAPHS = Path(__file__).resolve().parent.parent / "nccn_graphs"
_CODE = re.compile(r"(TEST-1|SEM-\d+|NSEM-\d+[A-Z]?)")
HL = "#c0392b"  # highlight color


def _first_line(label: str) -> str:
    text = label.replace("\\l", "\n").replace("\\n", "\n")
    for ln in text.split("\n"):
        ln = ln.strip()
        if ln:
            return ln
    return ""


@lru_cache(maxsize=1)
def page_files() -> dict[str, str]:
    out: dict[str, str] = {}
    for f in sorted(GRAPHS.glob("*.dot")):
        m = _CODE.match(f.stem)
        if m:
            out.setdefault(m.group(1), str(f))
    return out


def _parse(path: str):
    doc = json.loads(subprocess.run(
        ["dot", "-Tjson", path], capture_output=True, text=True, check=True).stdout)
    nodes = {}
    for o in doc.get("objects", []):
        if "nodes" in o or "subgraphs" in o:
            continue
        if o.get("shape") == "note" or o.get("name", "").startswith("note"):
            continue  # drop footnotes
        nodes[o["_gvid"]] = o
    return nodes, doc.get("edges", []), doc.get("label", "")


def build_svg(page: str, hl_nodes: set[str] | None = None,
              hl_edges: set[str] | None = None) -> str | None:
    """Return SVG for `page`; highlight node titles in hl_nodes and edges
    (as "source|target" first-line titles) in hl_edges."""
    files = page_files()
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
