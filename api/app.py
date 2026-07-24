#!/usr/bin/env python
# Copyright (c) 2024 Microsoft Corporation.
# Licensed under the MIT License

"""Klein REST API wrapping GraphRAG query over the injected NCCN graph.

The /query endpoint returns STRUCTURED JSON built from Pydantic models: the
GraphRAG markdown answer is parsed into titled sections, inline
``[Data: Reports (2); Entities (57, 68)]`` citations are extracted into typed
objects, and the context tables GraphRAG actually used are summarized.

GraphRAG's query API is asyncio and Klein is Twisted, so each request runs in a
worker thread (deferToThread + asyncio.run). Config and parquet tables are
loaded once at startup.

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

ROOT = Path(os.environ.get("GRAPHRAG_ROOT", Path(__file__).resolve().parent.parent / "nccn_graphrag"))
HOST = os.environ.get("API_HOST", "127.0.0.1")
PORT = int(os.environ.get("API_PORT", "8899"))
DEFAULT_RESPONSE_TYPE = "Multiple Paragraphs"


# ============================ Pydantic models ==============================
class Citation(BaseModel):
    """A parsed inline citation, e.g. `Reports (2, 8)`."""

    dataset: str = Field(description="Source table: Reports, Entities, Relationships, Sources, ...")
    ids: list[str] = Field(default_factory=list, description="Referenced record ids")


class AnswerSection(BaseModel):
    """One markdown section of the answer."""

    heading: str | None = Field(default=None, description="Section heading text (None for preamble)")
    level: int = Field(default=0, description="Markdown heading level; 0 = preamble")
    content: str = Field(description="Section body with markdown stripped of heading line")
    citations: list[Citation] = Field(default_factory=list)


class ContextSummary(BaseModel):
    """Counts of the context records GraphRAG used to answer."""

    tables: dict[str, int] = Field(default_factory=dict)


class EvidenceEdge(BaseModel):
    """A cited relationship resolved to a concrete graph edge."""

    id: str
    source: str
    target: str
    page: str | None = None
    kind: str = Field(description="'clinical' (real transition) or 'structural' (anchor/reference)")


class EvidenceNode(BaseModel):
    """A cited entity resolved to a concrete node."""

    id: str
    title: str
    pages: list[str] = Field(default_factory=list)


class Evidence(BaseModel):
    """Resolved provenance the UI uses to highlight the source flowchart."""

    primary_page: str | None = Field(default=None, description="Best page to show (most-cited clinical page)")
    edges: list[EvidenceEdge] = Field(default_factory=list)
    nodes: list[EvidenceNode] = Field(default_factory=list)


class QueryResponse(BaseModel):
    """Structured query result returned by /query."""

    method: str
    query: str
    community_level: int | None = None
    title: str | None = Field(default=None, description="First H1 of the answer, if any")
    sections: list[AnswerSection] = Field(default_factory=list)
    citations: list[Citation] = Field(default_factory=list, description="Deduped across the answer")
    evidence: Evidence = Field(default_factory=Evidence)
    context: ContextSummary = Field(default_factory=ContextSummary)
    raw_markdown: str | None = Field(default=None, description="Original answer; included only if requested")


# ============================ parsing helpers ==============================
_HEADING = re.compile(r"^(#{1,6})\s+(.+?)\s*$")
_RULE = re.compile(r"^\s*([-*_])\1{2,}\s*$")
_DATA_BLOCK = re.compile(r"\[Data:\s*(.*?)\]", re.DOTALL)
_CITE_PART = re.compile(r"([A-Za-z][A-Za-z /]*?)\s*\(([^)]*)\)")


def parse_citations(text: str) -> list[Citation]:
    """Extract `[Data: Reports (2); Entities (57, 68)]` style citations."""
    merged: dict[str, list[str]] = {}
    for block in _DATA_BLOCK.findall(text):
        for dataset, raw_ids in _CITE_PART.findall(block):
            ds = dataset.strip()
            ids = [i.strip() for i in raw_ids.split(",")]
            ids = [i for i in ids if i and "more" not in i.lower()]
            bucket = merged.setdefault(ds, [])
            for i in ids:
                if i not in bucket:
                    bucket.append(i)
    return [Citation(dataset=k, ids=v) for k, v in merged.items()]


def parse_sections(md: str) -> tuple[str | None, list[AnswerSection]]:
    """Split markdown into (title, sections). Title = first H1 if present."""
    title: str | None = None
    sections: list[AnswerSection] = []
    cur_heading: str | None = None
    cur_level = 0
    buf: list[str] = []

    def flush() -> None:
        content = "\n".join(buf).strip()
        if cur_heading is None and not content:
            return
        sections.append(AnswerSection(
            heading=cur_heading, level=cur_level,
            content=content, citations=parse_citations(content),
        ))

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
    """Count records per context table GraphRAG returned."""
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


def build_response(method: str, query: str, level: int | None,
                   resp: Any, ctx: Any, include_raw: bool) -> QueryResponse:
    md = resp if isinstance(resp, str) else json.dumps(resp)
    title, sections = parse_sections(md)
    # dedupe citations across all sections
    merged: dict[str, list[str]] = {}
    for s in sections:
        for c in s.citations:
            bucket = merged.setdefault(c.dataset, [])
            for i in c.ids:
                if i not in bucket:
                    bucket.append(i)
    citations = [Citation(dataset=k, ids=v) for k, v in merged.items()]
    return QueryResponse(
        method=method, query=query, community_level=level, title=title,
        sections=sections, citations=citations,
        evidence=resolve_evidence(citations),
        context=summarize_context(ctx),
        raw_markdown=md if include_raw else None,
    )


# ======================== preload once at startup ==========================
_config = load_config(ROOT)
_out = ROOT / "output"


def _table(name: str) -> pd.DataFrame:
    return pd.read_parquet(_out / f"{name}.parquet")


ENTITIES = _table("entities")
COMMUNITIES = _table("communities")
COMMUNITY_REPORTS = _table("community_reports")
RELATIONSHIPS = _table("relationships")
TEXT_UNITS = _table("text_units")
MAX_LEVEL = int(COMMUNITIES["level"].max())

_ANCHORS = set(ENTITIES.loc[ENTITIES["type"] == "Protocol Page", "title"])
_REL_BY_HID = RELATIONSHIPS.set_index("human_readable_id")
_ENT_BY_HID = ENTITIES.set_index("human_readable_id")


def _pages(val) -> list[str]:
    return [str(p) for p in (val if val is not None else [])]


def resolve_evidence(citations: list[Citation]) -> Evidence:
    """Resolve cited human_readable_ids to concrete edges/nodes and pick the
    primary page to display (the page carrying the most cited *clinical* edges)."""
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
            if ds.startswith("relationship") and hid in _REL_BY_HID.index:
                r = _REL_BY_HID.loc[hid]
                src, tgt = str(r["source"]), str(r["target"])
                kind = "structural" if (src in _ANCHORS or tgt in _ANCHORS) else "clinical"
                pages = _pages(r["text_unit_ids"])
                page = pages[0] if pages else None
                edges.append(EvidenceEdge(id=str(hid), source=src, target=tgt, page=page, kind=kind))
                if kind == "clinical" and page:
                    page_votes[page] = page_votes.get(page, 0) + 1
            elif ds.startswith("entit") and hid in _ENT_BY_HID.index:
                e = _ENT_BY_HID.loc[hid]
                nodes.append(EvidenceNode(id=str(hid), title=str(e["title"]), pages=_pages(e["text_unit_ids"])))
    # fallback: if no clinical edge voted a page, use a cited node's page
    primary = max(page_votes, key=page_votes.get) if page_votes else None
    if primary is None:
        for n in nodes:
            real = [p for p in n.pages if p in flowchart.page_files()]
            if real:
                primary = real[0]
                break
    return Evidence(primary_page=primary, edges=edges, nodes=nodes)


app = Klein()


# ==================== query bridges (worker thread) ========================
def _global(query: str, level: int | None, response_type: str):
    return asyncio.run(grag.global_search(
        config=_config, entities=ENTITIES, communities=COMMUNITIES,
        community_reports=COMMUNITY_REPORTS, community_level=level,
        dynamic_community_selection=False, response_type=response_type, query=query,
    ))


def _local(query: str, level: int, response_type: str):
    return asyncio.run(grag.local_search(
        config=_config, entities=ENTITIES, communities=COMMUNITIES,
        community_reports=COMMUNITY_REPORTS, text_units=TEXT_UNITS,
        relationships=RELATIONSHIPS, covariates=None,
        community_level=level, response_type=response_type, query=query,
    ))


# ============================== helpers ====================================
def _json(request, payload: dict, code: int = 200) -> bytes:
    request.setResponseCode(code)
    request.setHeader("Content-Type", "application/json")
    return json.dumps(payload).encode("utf-8")


# =============================== routes ====================================
_UI_HTML = (Path(__file__).resolve().parent / "ui.html")


@app.route("/", methods=["GET"])
def index(request):
    request.setHeader("Content-Type", "text/html; charset=utf-8")
    return _UI_HTML.read_bytes()


@app.route("/schema", methods=["GET"])
def schema(request):
    return _json(request, QueryResponse.model_json_schema())


@app.route("/flowchart", methods=["POST"])
def flowchart_post(request):
    try:
        body = json.loads(request.content.read() or b"{}")
    except json.JSONDecodeError as e:
        return _json(request, {"error": f"invalid JSON: {e}"}, code=400)
    page = body.get("page")
    hl_nodes = set(body.get("nodes") or [])
    hl_edges = {f"{s}|{t}" for s, t in (body.get("edges") or [])}
    svg = flowchart.build_svg(page, hl_nodes, hl_edges) if page else None
    if svg is None:
        return _json(request, {"error": f"unknown page '{page}'"}, code=404)
    request.setHeader("Content-Type", "image/svg+xml; charset=utf-8")
    return svg.encode("utf-8")


@app.route("/graph", methods=["POST"])
def graph_post(request):
    try:
        body = json.loads(request.content.read() or b"{}")
    except json.JSONDecodeError as e:
        return _json(request, {"error": f"invalid JSON: {e}"}, code=400)
    page = body.get("page")
    hl_nodes = set(body.get("nodes") or [])
    hl_edges = {f"{s}|{t}" for s, t in (body.get("edges") or [])}
    g = flowchart.build_graph(page, hl_nodes, hl_edges) if page else None
    if g is None:
        return _json(request, {"error": f"unknown page '{page}'"}, code=404)
    return _json(request, g)


@app.route("/pages", methods=["GET"])
def pages(request):
    return _json(request, {"pages": sorted(flowchart.page_files())})


@app.route("/health", methods=["GET"])
def health(request):
    return _json(request, {
        "status": "ok", "root": str(ROOT),
        "entities": len(ENTITIES), "relationships": len(RELATIONSHIPS),
        "communities": len(COMMUNITIES), "community_reports": len(COMMUNITY_REPORTS),
        "max_community_level": MAX_LEVEL,
    })


def _dispatch(request, query, method, level, response_type, include_raw):
    if not query:
        return _json(request, {"error": "missing 'query'"}, code=400)
    if method not in ("global", "local"):
        return _json(request, {"error": f"unknown method '{method}' (use global|local)"}, code=400)

    if method == "global":
        level = None if level is None else int(level)
        d = deferToThread(_global, query, level, response_type)
    else:
        level = MAX_LEVEL if level is None else int(level)
        d = deferToThread(_local, query, level, response_type)

    d.addCallback(lambda result: _json(
        request,
        build_response(method, query, level, result[0], result[1], include_raw).model_dump(),
    ))
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
        request,
        query=body.get("query"),
        method=body.get("method", "global"),
        level=body.get("community_level"),
        response_type=body.get("response_type", DEFAULT_RESPONSE_TYPE),
        include_raw=bool(body.get("include_raw", False)),
    )


@app.route("/query", methods=["GET"])
def query_get(request):
    def arg(name, default=None):
        vals = request.args.get(name.encode(), [])
        return vals[0].decode() if vals else default

    return _dispatch(
        request,
        query=arg("query"),
        method=arg("method", "global"),
        level=arg("community_level"),
        response_type=arg("response_type", DEFAULT_RESPONSE_TYPE),
        include_raw=_truthy(arg("include_raw", "false")),
    )


if __name__ == "__main__":
    print(f"NCCN GraphRAG API on http://{HOST}:{PORT}  (root={ROOT})")
    print(f"  {len(ENTITIES)} entities · {len(COMMUNITIES)} communities · "
          f"{len(COMMUNITY_REPORTS)} reports · max level {MAX_LEVEL}")
    app.run(HOST, PORT)
