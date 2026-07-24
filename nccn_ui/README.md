# Luna — NCCN multi-cancer clinical copilot (Phoenix LiveView)

Covers **5 guidelines** — testicular, breast, prostate, colon, NSCLC —
switchable from pills in the sidebar. A visual-first clinical decision UI: an
**interactive Cytoscape.js flowchart** dominates the screen, and **Luna** (an AI
physician-agent persona) + chat in the left sidebar drive it.

The backend (`api/app.py`) loads all five indexed GraphRAG projects at startup
and every endpoint (`/query`, `/graph`, `/flowchart`, `/pages`) takes a
`guideline` key; `/guidelines` lists them with their page indexes. Switching the
guideline in the UI re-seeds the flowchart and routes all queries to that
project. Ask a question → Luna answers concisely in chat, the
relevant protocol flowchart loads, and the **cited decision path animates/glows**
in purple. Key points render as bullets under the diagram.

Single-file Phoenix LiveView app (`Mix.install`, no project scaffold) that calls
the Python GraphRAG backend over HTTP.

## Architecture

```
Browser ⇄ LiveView ws ⇄ Phoenix :4000 ⇄ HTTP/Req ⇄ Klein :8899 ⇄ GraphRAG
  │  Cytoscape.js + dagre (JS hook)      ├ POST /query  → structured answer + evidence
  │  push_event("graph", elements) ──────┤ POST /graph  → Cytoscape elements (hl flags)
  └  chat drives the diagram             └ POST /flowchart → static SVG (legacy)
```

- **Stage header** — current focus page + label + track + status badge
  (Reference / Analyzing / Active guidance), page jump `<select>`, legend,
  and toolbar: step ◂ ▸ / Reveal-all, zoom ± , fit.
- **Main pane** — Cytoscape/dagre flowchart: pan, scroll-zoom, **progressive
  step reveal** (rank-by-rank via BFS `ord`), decision nodes as amber diamonds,
  animated dashed "flow" on the cited (purple) path, node colors by type,
  click a node to focus + open its Detail.
- **Left sidebar** — large **Luna** identity (crescent-moon + medical cross +
  orbiting neural ring, glow) + live status, chat bubbles + typing indicator,
  suggested-action chips, Specific/Thematic toggle, input.
- **Right panel (tabs)** — **To-Do** (grounded NCCN workup checklist, toggleable,
  progress bar) · **Timeline** (case history / look-back, click to restore a
  prior state) · **Detail** (selected node: type, "comes from", options/next
  with criteria, "Ask Luna about this node"). Key-point bullets + cited-pathway
  chips pinned below.

The LiveView orchestrates: it fetches `/graph` (with highlight from the query's
`evidence`) and `push_event`s the elements to the `Cyto` hook, which renders and
runs the dagre layout with a smooth transition.

## Run

```sh
# 1. backend (repo root, GRAPHRAG_API_KEY exported)
uv run --with klein python api/app.py                         # :8899
# 2. this UI
NCCN_API=http://127.0.0.1:8899 elixir nccn_ui/nccn_ui.exs     # :4000
```

Open http://127.0.0.1:4000. First run compiles deps via `Mix.install` (~1–2 min).
Env: `PORT` (default 4000), `NCCN_API` (default `http://127.0.0.1:8899`).

## Styling

TailwindCSS + Cytoscape.js / dagre, all via browser CDNs (no asset build). Light
"AI-native" aesthetic: gradient background, glassmorphic panels, purple accent
with soft glow for AI/active elements. For production, vendor the CDNs.

## Verified

Headless over the LiveView websocket: join → `cy_ready` → **initial graph pushed**
→ `ask` → **Luna answer in chat** + **highlighted graph (cited path) pushed**.
The Cytoscape *rendering* itself needs a browser to view (no headless browser was
available to screenshot it here).

> Reference aid from a lossy graph of NCCN v2.2026 — not a substitute for the
> guideline. Keep local (NCCN content is copyrighted).
