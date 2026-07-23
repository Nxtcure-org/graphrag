# NCCN GraphRAG — Klein REST API

A small [Klein](https://github.com/twisted/klein) REST API that wraps GraphRAG
query over the injected NCCN Testicular Cancer graph (`../nccn_graphrag`).

GraphRAG's query API is asyncio and Klein is Twisted, so each request runs in a
worker thread (`deferToThread` + `asyncio.run`). Config and the parquet tables
(entities / communities / community_reports / relationships / text_units) are
loaded once at startup.

## Run

From the repo root, with `GRAPHRAG_API_KEY` exported (queries call OpenAI):

```sh
uv run --with klein python api/app.py
```

Env overrides: `GRAPHRAG_ROOT` (default `../nccn_graphrag`), `API_HOST`
(default `127.0.0.1`), `API_PORT` (default `8899`).

## Endpoints

| Method | Path      | Description |
|--------|-----------|-------------|
| GET    | `/`       | service info |
| GET    | `/health` | status + table sizes + max community level |
| POST   | `/query`  | JSON body (see below) |
| GET    | `/query`  | same via query params: `?query=...&method=global` |

`POST /query` body:

```json
{
  "query": "After a brain scan, what should be done?",
  "method": "global",              // "global" | "local"  (default global)
  "community_level": 1,             // optional; global accepts null (all), local defaults to max
  "response_type": "Multiple Paragraphs"  // optional
}
```

Response:

```json
{ "method": "local", "query": "...", "community_level": 1, "response": "..." }
```

- **global** — map-reduce over community reports; best for thematic / sensemaking
  questions. `community_level` may be omitted (searches all levels).
- **local** — entity-centric, uses the LanceDB embeddings; best for specific
  "what do I do for X" questions.

## Examples

```sh
curl -s localhost:8899/health | jq

curl -s -X POST localhost:8899/query \
  -H 'content-type: application/json' \
  -d '{"query":"How does risk classification change first-line chemo?","method":"global"}' | jq -r .response

curl -s -X POST localhost:8899/query \
  -H 'content-type: application/json' \
  -d '{"query":"What to do after a brain scan, and how are brain metastases managed?","method":"local"}' | jq -r .response
```

> Answers are generated from a lossy graph derived from the NCCN guideline and
> are a navigational aid only — not a substitute for the source. Keep local
> (NCCN content is copyrighted).
