#!/usr/bin/env python
# Copyright (c) 2024 Microsoft Corporation.
# Licensed under the MIT License

"""Klein REST API wrapping GraphRAG query over the injected NCCN graphs.

Serves MULTIPLE guidelines (testicular, breast, prostate, colon, nsclc). Every
endpoint takes a `guideline` key and dispatches to that project's config +
tables + Graphviz directory. The /query endpoint returns structured JSON
(sections + typed citations + resolved evidence for flowchart highlighting).

Run (from repo root, with GRAPHRAG_API_KEY exported):

    uv run --with klein python api/app.py
"""

from __future__ import annotations

import asyncio
import json
import os
import re
from pathlib import Path
from typing import Any

import pandas as pd
from klein import Klein
from pydantic import BaseModel, Field
from twisted.internet.threads import deferToThread

from graphrag import api as grag
from graphrag.config.load_config import load_config

import flowchart  # local module (api/flowchart.py)

REPO = Path(__file__).resolve().parent.parent
HOST = os.environ.get("API_HOST", "127.0.0.1")
PORT = int(os.environ.get("API_PORT", "8899"))
DEFAULT_RESPONSE_TYPE = "Multiple Paragraphs"

# guideline registry: key -> (label, project root, graphviz dir)
GUIDELINE_DEFS = [
    ("testicular", "Testicular", "nccn_graphrag", "nccn_graphs"),
    ("breast", "Breast", "nccn_graphrag_breast", "nccn_graphs_breast"),
    ("prostate", "Prostate", "nccn_graphrag_prostate", "nccn_graphs_prostate"),
    ("colon", "Colon", "nccn_graphrag_colon", "nccn_graphs_colon"),
    ("nsclc", "NSCLC", "nccn_graphrag_nsclc", "nccn_graphs_nsclc"),
]


# ============================ Pydantic models ==============================
class Citation(BaseModel):
    dataset: str = Field(description="Source table: Reports, Entities, Relationships, Sources, ...")
    ids: list[str] = Field(default_factory=list)


class AnswerSection(BaseModel):
    heading: str | None = None
    level: int = 0
    content: str
    citations: list[Citation] = Field(default_factory=list)


class ContextSummary(BaseModel):
    tables: dict[str, int] = Field(default_factory=dict)


class EvidenceEdge(BaseModel):
    id: str
    source: str
    target: str
    page: str | None = None
    kind: str = Field(description="'clinical' or 'structural'")


class EvidenceNode(BaseModel):
    id: str
    title: str
    pages: list[str] = Field(default_factory=list)


class Evidence(BaseModel):
    primary_page: str | None = None
    edges: list[EvidenceEdge] = Field(default_factory=list)
    nodes: list[EvidenceNode] = Field(default_factory=list)


class QueryResponse(BaseModel):
    guideline: str
    method: str
    query: str
    community_level: int | None = None
    title: str | None = None
    sections: list[AnswerSection] = Field(default_factory=list)
    citations: list[Citation] = Field(default_factory=list)
    evidence: Evidence = Field(default_factory=Evidence)
    context: ContextSummary = Field(default_factory=ContextSummary)
    raw_markdown: str | None = None


# ======================= guideline (loaded project) ========================
class Guideline:
    def __init__(self, key: str, label: str, root: str, graphs: str):
        self.key = key
        self.label = label
        self.root = REPO / root
        self.graphs_dir = str(REPO / graphs)
        self.config = load_config(self.root)
        out = self.root / "output"

        def t(name):
            return pd.read_parquet(out / f"{name}.parquet")

        self.entities = t("entities")
        self.communities = t("communities")
        self.reports = t("community_reports")
        self.relationships = t("relationships")
        self.text_units = t("text_units")
        self.max_level = int(self.communities["level"].max())
        self.anchors = set(self.entities.loc[self.entities["type"] == "Protocol Page", "title"])
        self.rel_by_hid = self.relationships.set_index("human_readable_id")
        self.ent_by_hid = self.entities.set_index("human_readable_id")
        self.pages = list(flowchart.page_index(self.graphs_dir))

    def ready(self) -> bool:
        return len(self.reports) > 0


def _load_guidelines() -> dict[str, Guideline]:
    loaded: dict[str, Guideline] = {}
    for key, label, root, graphs in GUIDELINE_DEFS:
        if (REPO / root / "output" / "entities.parquet").exists() and (REPO / graphs).is_dir():
            try:
                loaded[key] = Guideline(key, label, root, graphs)
                print(f"  loaded {key:<11} {len(loaded[key].entities):>4} entities · "
                      f"{len(loaded[key].reports):>3} reports · {len(loaded[key].pages):>2} pages")
            except Exception as e:  # noqa: BLE001
                print(f"  SKIP {key}: {e}")
    return loaded


print("Loading guidelines…")
GUIDELINES = _load_guidelines()
DEFAULT_KEY = "testicular" if "testicular" in GUIDELINES else next(iter(GUIDELINES))


def _g(key: str | None) -> Guideline:
    return GUIDELINES.get(key or DEFAULT_KEY) or GUIDELINES[DEFAULT_KEY]


# ============================ parsing helpers ==============================
_HEADING = re.compile(r"^(#{1,6})\s+(.+?)\s*$")
_RULE = re.compile(r"^\s*([-*_])\1{2,}\s*$")
_DATA_BLOCK = re.compile(r"\[Data:\s*(.*?)\]", re.DOTALL)
_CITE_PART = re.compile(r"([A-Za-z][A-Za-z /]*?)\s*\(([^)]*)\)")


def parse_citations(text: str) -> list[Citation]:
    merged: dict[str, list[str]] = {}
    for block in _DATA_BLOCK.findall(text):
        for dataset, raw_ids in _CITE_PART.findall(block):
            ds = dataset.strip()
            ids = [i.strip() for i in raw_ids.split(",") if i.strip() and "more" not in i.lower()]
            bucket = merged.setdefault(ds, [])
            for i in ids:
                if i not in bucket:
                    bucket.append(i)
    return [Citation(dataset=k, ids=v) for k, v in merged.items()]


def parse_sections(md: str) -> tuple[str | None, list[AnswerSection]]:
    title: str | None = None
    sections: list[AnswerSection] = []
    cur_heading: str | None = None
    cur_level = 0
    buf: list[str] = []

    def flush() -> None:
        content = "\n".join(buf).strip()
        if cur_heading is None and not content:
            return
        sections.append(AnswerSection(heading=cur_heading, level=cur_level,
                                      content=content, citations=parse_citations(content)))

    for line in md.splitlines():
        if _RULE.match(line):
            continue
        m = _HEADING.match(line)
        if m:
            flush()
            buf = []
            cur_level = len(m.group(1))
            cur_heading = m.group(2).strip()
            if title is None and cur_level == 1:
                title = cur_heading
        else:
            buf.append(line)
    flush()
    return title, sections


def summarize_context(ctx: Any) -> ContextSummary:
    tables: dict[str, int] = {}
    if isinstance(ctx, dict):
        for k, v in ctx.items():
            if isinstance(v, pd.DataFrame):
                tables[str(k)] = int(len(v))
    elif isinstance(ctx, list):
        for i, v in enumerate(ctx):
            if isinstance(v, pd.DataFrame):
                tables[f"table_{i}"] = int(len(v))
    return ContextSummary(tables=tables)


def _pages(val) -> list[str]:
    return [str(p) for p in (val if val is not None else [])]


def resolve_evidence(g: Guideline, citations: list[Citation]) -> Evidence:
    edges: list[EvidenceEdge] = []
    nodes: list[EvidenceNode] = []
    page_votes: dict[str, int] = {}
    for c in citations:
        ds = c.dataset.lower()
        for raw in c.ids:
            try:
                hid = int(raw)
            except ValueError:
                continue
            if ds.startswith("relationship") and hid in g.rel_by_hid.index:
                r = g.rel_by_hid.loc[hid]
                src, tgt = str(r["source"]), str(r["target"])
                kind = "structural" if (src in g.anchors or tgt in g.anchors) else "clinical"
                pages = _pages(r["text_unit_ids"])
                page = pages[0] if pages else None
                edges.append(EvidenceEdge(id=str(hid), source=src, target=tgt, page=page, kind=kind))
                if kind == "clinical" and page:
                    page_votes[page] = page_votes.get(page, 0) + 1
            elif ds.startswith("entit") and hid in g.ent_by_hid.index:
                e = g.ent_by_hid.loc[hid]
                nodes.append(EvidenceNode(id=str(hid), title=str(e["title"]), pages=_pages(e["text_unit_ids"])))
    primary = max(page_votes, key=page_votes.get) if page_votes else None
    if primary is None:
        pf = flowchart.page_files(g.graphs_dir)
        for n in nodes:
            real = [p for p in n.pages if p in pf]
            if real:
                primary = real[0]
                break
    return Evidence(primary_page=primary, edges=edges, nodes=nodes)


def build_response(g: Guideline, method: str, query: str, level: int | None,
                   resp: Any, ctx: Any, include_raw: bool) -> QueryResponse:
    md = resp if isinstance(resp, str) else json.dumps(resp)
    title, sections = parse_sections(md)
    merged: dict[str, list[str]] = {}
    for s in sections:
        for c in s.citations:
            bucket = merged.setdefault(c.dataset, [])
            for i in c.ids:
                if i not in bucket:
                    bucket.append(i)
    citations = [Citation(dataset=k, ids=v) for k, v in merged.items()]
    return QueryResponse(
        guideline=g.key, method=method, query=query, community_level=level, title=title,
        sections=sections, citations=citations, evidence=resolve_evidence(g, citations),
        context=summarize_context(ctx), raw_markdown=md if include_raw else None,
    )


# ==================== query bridges (worker thread) ========================
def _global(g: Guideline, query: str, level: int | None, response_type: str):
    return asyncio.run(grag.global_search(
        config=g.config, entities=g.entities, communities=g.communities,
        community_reports=g.reports, community_level=level,
        dynamic_community_selection=False, response_type=response_type, query=query))


def _local(g: Guideline, query: str, level: int, response_type: str):
    return asyncio.run(grag.local_search(
        config=g.config, entities=g.entities, communities=g.communities,
        community_reports=g.reports, text_units=g.text_units,
        relationships=g.relationships, covariates=None,
        community_level=level, response_type=response_type, query=query))


# ============================== helpers ====================================
def _json(request, payload: dict, code: int = 200) -> bytes:
    request.setResponseCode(code)
    request.setHeader("Content-Type", "application/json")
    return json.dumps(payload).encode("utf-8")


app = Klein()
_UI_HTML = Path(__file__).resolve().parent / "ui.html"


# =============================== routes ====================================
@app.route("/", methods=["GET"])
def index(request):
    request.setHeader("Content-Type", "text/html; charset=utf-8")
    return _UI_HTML.read_bytes()


@app.route("/guidelines", methods=["GET"])
def guidelines(request):
    return _json(request, {"default": DEFAULT_KEY, "guidelines": [
        {"key": g.key, "label": g.label, "max_level": g.max_level,
         "pages": g.pages, "reports": len(g.reports)}
        for g in GUIDELINES.values()
    ]})


@app.route("/pages", methods=["GET"])
def pages(request):
    vals = request.args.get(b"guideline", [])
    g = _g(vals[0].decode() if vals else None)
    return _json(request, {"guideline": g.key, "pages": g.pages})


@app.route("/flowchart", methods=["POST"])
def flowchart_post(request):
    try:
        body = json.loads(request.content.read() or b"{}")
    except json.JSONDecodeError as e:
        return _json(request, {"error": f"invalid JSON: {e}"}, code=400)
    g = _g(body.get("guideline"))
    page = body.get("page")
    hl_nodes = set(body.get("nodes") or [])
    hl_edges = {f"{s}|{t}" for s, t in (body.get("edges") or [])}
    svg = flowchart.build_svg(g.graphs_dir, page, hl_nodes, hl_edges) if page else None
    if svg is None:
        return _json(request, {"error": f"unknown page '{page}' in {g.key}"}, code=404)
    request.setHeader("Content-Type", "image/svg+xml; charset=utf-8")
    return svg.encode("utf-8")


@app.route("/graph", methods=["POST"])
def graph_post(request):
    try:
        body = json.loads(request.content.read() or b"{}")
    except json.JSONDecodeError as e:
        return _json(request, {"error": f"invalid JSON: {e}"}, code=400)
    g = _g(body.get("guideline"))
    page = body.get("page")
    hl_nodes = set(body.get("nodes") or [])
    hl_edges = {f"{s}|{t}" for s, t in (body.get("edges") or [])}
    graph = flowchart.build_graph(g.graphs_dir, page, hl_nodes, hl_edges) if page else None
    if graph is None:
        return _json(request, {"error": f"unknown page '{page}' in {g.key}"}, code=404)
    graph["guideline"] = g.key
    return _json(request, graph)


@app.route("/health", methods=["GET"])
def health(request):
    return _json(request, {"status": "ok", "default": DEFAULT_KEY, "guidelines": {
        g.key: {"entities": len(g.entities), "reports": len(g.reports),
                "pages": len(g.pages), "max_level": g.max_level}
        for g in GUIDELINES.values()
    }})


def _dispatch(request, g, query, method, level, response_type, include_raw):
    if not query:
        return _json(request, {"error": "missing 'query'"}, code=400)
    if method not in ("global", "local"):
        return _json(request, {"error": f"unknown method '{method}'"}, code=400)

    if method == "global":
        level = None if level is None else int(level)
        d = deferToThread(_global, g, query, level, response_type)
    else:
        level = g.max_level if level is None else int(level)
        d = deferToThread(_local, g, query, level, response_type)

    d.addCallback(lambda result: _json(
        request, build_response(g, method, query, level, result[0], result[1], include_raw).model_dump()))
    d.addErrback(lambda f: _json(request, {"error": str(f.value)}, code=500))
    return d


def _truthy(v) -> bool:
    return str(v).lower() in ("1", "true", "yes", "on")


@app.route("/query", methods=["POST"])
def query_post(request):
    try:
        body = json.loads(request.content.read() or b"{}")
    except json.JSONDecodeError as e:
        return _json(request, {"error": f"invalid JSON: {e}"}, code=400)
    return _dispatch(
        request, _g(body.get("guideline")),
        query=body.get("query"), method=body.get("method", "global"),
        level=body.get("community_level"),
        response_type=body.get("response_type", DEFAULT_RESPONSE_TYPE),
        include_raw=bool(body.get("include_raw", False)))


@app.route("/query", methods=["GET"])
def query_get(request):
    def arg(name, default=None):
        vals = request.args.get(name.encode(), [])
        return vals[0].decode() if vals else default

    return _dispatch(
        request, _g(arg("guideline")),
        query=arg("query"), method=arg("method", "global"),
        level=arg("community_level"),
        response_type=arg("response_type", DEFAULT_RESPONSE_TYPE),
        include_raw=_truthy(arg("include_raw", "false")))


if __name__ == "__main__":
    print(f"NCCN GraphRAG API on http://{HOST}:{PORT}  ({len(GUIDELINES)} guidelines, default={DEFAULT_KEY})")
    app.run(HOST, PORT)
