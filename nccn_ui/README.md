# NCCN Testicular Cancer — Phoenix LiveView UI

Clinician decision-support frontend for the GraphRAG data. A single-file Phoenix
LiveView app (`Mix.install`, no project scaffold) that calls the Python Klein
backend over HTTP and renders a 3-pane view:

```
┌ Protocols ┬ Question + grounded answer ┬ Source flowchart ┐
│ TEST-1    │  ◉ Specific  ○ Thematic     │  NSEM-6          │
│ SEM-1…8   │  answer sections            │  cited path      │
│ NSEM-1…10 │  citation chips (clinical / │  highlighted in  │
│           │   navigation) → click to    │  red             │
│           │   highlight on flowchart →  │                  │
└───────────┴─────────────────────────────┴──────────────────┘
```

The centerpiece: after a query, the cited **clinical** relationships are
highlighted as a red path on the source protocol flowchart (rendered server-side
by the backend from the original Graphviz `.dot` files). Structural
(anchor/reference) citations are shown separately and not highlighted.

## Architecture

```
Browser ⇄ (LiveView websocket) ⇄ Phoenix :4000  ⇄ (HTTP/Req) ⇄  Klein :8899  ⇄ GraphRAG
                                                                 ├ POST /query     → structured JSON + evidence
                                                                 └ POST /flowchart → highlighted SVG
```

## Run

1. Backend (from repo root, with `GRAPHRAG_API_KEY` exported):
   ```sh
   uv run --with klein python api/app.py            # http://127.0.0.1:8899
   ```
2. This UI:
   ```sh
   NCCN_API=http://127.0.0.1:8899 elixir nccn_ui/nccn_ui.exs   # http://127.0.0.1:4000
   ```
   First run downloads/compiles deps (phoenix, phoenix_live_view, bandit, req) via
   `Mix.install` — ~1–2 min. Open http://127.0.0.1:4000.

Env: `PORT` (default 4000), `NCCN_API` (default `http://127.0.0.1:8899`).

## How it works

- `phx-submit="ask"` → `handle_event` sets a loading state and `start_async`
  runs the query off the LiveView process (UI stays responsive).
- The async task POSTs `/query`, reads `evidence.primary_page` + clinical edges,
  then POSTs `/flowchart` for the highlighted SVG; `handle_async` assigns both.
- Citation chips (`phx-click="focus_edge"`) re-render the flowchart focused on a
  single cited edge. Left-nav entries (`phx-click="page"`) show a plain flowchart.

LiveView client JS is served straight from the `phoenix` / `phoenix_live_view`
hex deps via `Plug.Static` (no node/esbuild build step).

## Styling

TailwindCSS via the browser CDN (`cdn.tailwindcss.com`) — no asset pipeline. It
JIT-compiles utility classes in the page and its MutationObserver picks up the
classes LiveView pushes on updates, so dynamically rendered answers/flowcharts
are styled too. Fine for a prototype; for production, swap the CDN for the
`tailwind` hex package (standalone binary) with a real build step.

## Verified

Headless end-to-end over the LiveView websocket: join → submit → loading state →
answer rendered → highlighted flowchart (red cited path) pushed to the client.

> Reference aid from a lossy graph of NCCN v2.2026 — not a substitute for the
> guideline. Keep local (NCCN content is copyrighted).
