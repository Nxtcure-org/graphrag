# NCCN GraphRAG — Klein REST API

A small [Klein](https://github.com/twisted/klein) REST API that wraps GraphRAG
query over the injected NCCN graphs. All five guideline projects (testicular,
breast, prostate, colon, NSCLC — see `GUIDELINE_DEFS` in `app.py`) are loaded
at startup and every endpoint takes a `guideline` key (default `testicular`).

GraphRAG's query API is asyncio and Klein is Twisted, so each request runs in a
worker thread (`deferToThread` + `asyncio.run`). Config and the parquet tables
(entities / communities / community_reports / relationships / text_units) are
loaded once at startup.

## Run

From the repo root, with `GRAPHRAG_API_KEY` exported (queries call OpenAI):

```sh
uv run --with klein python api/app.py
```

Env: `API_HOST` (default `127.0.0.1`), `API_PORT` (default `8899`), and for the
patient roster:

| Var | Purpose |
|-----|---------|
| `FHIR_BASE_URL` | FHIR R4 base, no trailing slash. **TrakCare**: `https://<host>/csp/healthshare/<namespace>/fhir/r4` (the IRIS for Health endpoint the TrakCare Innovation Toolkit installs; default namespace `trakitkit`). Cloud FHIR Server: `https://fhir.<id>.static-test-account.isccloud.io[/fhir/r4]`. **Unset → synthetic roster.** |
| `FHIR_AUTH` | `auto` (default) picks from what is set, or force `oauth` / `basic` / `apikey` / `none`. |
| `FHIR_CLIENT_ID`, `FHIR_CLIENT_SECRET` | OAuth 2.0 `client_credentials` against the IRIS OAuth server (secret sent as `client_secret_basic`). Token refreshed automatically, retried once on 401. |
| `FHIR_TOKEN_URL` | Optional. Default: `token_endpoint` from `<base>/.well-known/smart-configuration`, else `<origin>/oauth2/token`. |
| `FHIR_SCOPE` | Default `system/Patient.read system/Condition.read system/Encounter.read`. |
| `FHIR_USERNAME`, `FHIR_PASSWORD` | HTTP Basic with an IRIS user (with a client id set too → OAuth password grant). |
| `FHIR_API_KEY` | `x-api-key` header — InterSystems cloud FHIR Server only. |
| `FHIR_PROFILE` | `auto` → `trakcare` when the path contains `/csp/healthshare/`, `fhiraas` for `*.isccloud.io`, else `generic`. Sets the roster's `source` label. |
| `FHIR_VERIFY_TLS` | `false` to accept self-signed certificates (common on TrakCare test hosts). |
| `FHIR_PUBLIC_URL` | Browser-reachable FHIR base used for the "Open FHIR Patient" links (defaults to `FHIR_BASE_URL`; compose sets it to `127.0.0.1:52773` because the api reaches the dev server as `iris`). |

`INTELLICARE_FHIR_URL` / `INTELLICARE_API_KEY` are still read as aliases.

### Dev FHIR server (TrakCare stand-in) in compose

`docker compose up` also starts **`iris`**, an InterSystems IRIS for Health
Community Edition container provisioned at image build by `fhir-dev/iris.script`
with a FHIR R4 endpoint, a Basic-auth dev user, and unauthenticated access
enabled — the same IRIS FHIR repository / Management Portal / OAuth server that
TrakCare's FHIR layer runs on. A one-shot **`fhir-seed`** service loads the 11
synthetic oncology patients once it is healthy (idempotent). The api defaults to
it, so the roster badge reads `fhir` with `iris:52773` out of the box.

| | |
|---|---|
| FHIR R4 base | `http://127.0.0.1:52773/csp/healthshare/fhirserver/fhir/r4` (inside compose: `http://iris:52773/…`) |
| Management Portal | `http://127.0.0.1:52773/csp/sys/UtilHome.csp` — user `_SYSTEM`, password `SYS` |
| Roster user (Basic) | `luna_fhir` / `lunapw` |
| Playwright walkthrough | `scripts/trakcare_fhir_setup.py --dev-iris` — autopilot (known dev creds, no prompts, screenshots in `.playwright/shots/`); or `--host http://127.0.0.1:52773` for the manual human-in-the-loop flow |

Dev only: fixed passwords and `%All`. Switch the api to a real TrakCare host by
setting `FHIR_BASE_URL` (+ credentials, `FHIR_PROFILE=auto`) in `.env`; set
`FHIR_BASE_URL=` (empty) for the synthetic mock roster. IRIS takes ~30–60 s to
start; until then the modal shows a retryable error.

TrakCare has no public sandbox — InterSystems grants test access case by case.
`scripts/trakcare_fhir_setup.py` opens a visible Playwright browser on your
TrakCare host's IRIS Management Portal, pauses with terminal instructions at
every human step (sign in, find the FHIR web application, register an OAuth
client or pick a Basic-auth user, copy the secret), writes the `FHIR_*` vars to
`.env`, verifies them with the same client the API uses (token → `/metadata` →
Patient count), and offers to seed the oncology bundle and restart the api
container. Without a host it opens the pages to request access and exits.

```sh
uv run --with playwright playwright install chromium      # once
uv run --with playwright --with httpx python scripts/trakcare_fhir_setup.py --host https://trak-test.example.org
```

## Endpoints

| Method | Path      | Description |
|--------|-----------|-------------|
| GET    | `/`       | service info |
| GET    | `/health` | status, `patients_source` (`fhir`/`mock`), per-guideline table sizes |
| GET    | `/guidelines` | the loaded guidelines with their page indexes |
| GET    | `/pages?guideline=` | page index for one guideline |
| POST   | `/query`  | JSON body (see below); add `"guideline": "<key>"`. `"route": true` lets a question that names another cancer (breast, prostate, colon/rectal, lung/NSCLC, testicular terms — see `ROUTE_TERMS`) be answered from that guideline instead; the response then carries `routed_from`. Ties resolve to the requested guideline. The Luna UI always sends `route: true`. |
| GET    | `/query`  | same via query params: `?guideline=colon&query=...&method=global` |
| POST   | `/graph`  | `{guideline, page, nodes, edges}` → Cytoscape elements with `hl` flags |
| POST   | `/flowchart` | same input → server-rendered SVG (legacy) |
| GET    | `/patients` | oncology patient roster (see below); `?refresh=1` bypasses the 60 s cache |
| GET    | `/patients/<id>` | one patient's FHIR record: `patient` (roster row), all `conditions` (code, system, stage, status, onset, mapped guideline), recent `encounters`, `resource_url` (browser-reachable `FHIR_PUBLIC_URL/Patient/<id>`), and `context` — the one-line patient summary the UI prepends to Luna's questions |

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

## `GET /patients` — patient roster (TrakCare / FHIR R4)

Implemented in `patients.py`. With `FHIR_BASE_URL` set it reads
`Patient`, `Condition` and `Encounter` (three bulk searches, `next` links
followed) from the FHIR server, maps each patient's primary cancer diagnosis to
an NCCN guideline key (ICD-10 prefix → SNOMED code → keyword; small-cell lung
is deliberately excluded from `nsclc`), and caches the result in-process for
60 s. Without it, a deterministic 11-patient synthetic roster is served. The
route always answers **200**; upstream failures come back as `source: "error"`.
`/health` reports `patients_source`, `patients_auth` and `patients_server`.

```json
{
  "source": "trakcare" | "fhir" | "mock" | "error", "server": "trak-test.example.org", "auth": "oauth",
  "error": null, "fetched_at": "…Z", "cached": false,
  "total": 11, "by_guideline": {"testicular": 2, "breast": 3, "prostate": 2, "colon": 2, "nsclc": 2, "other": 0},
  "patients": [{"id": "…", "mrn": "…", "name": "…", "sex": "female", "birth_date": "1968-04-12", "age": 58,
                "diagnosis": "…", "diagnosis_code": "C50.911", "stage": "IIA", "guideline": "breast",
                "last_encounter": "2026-09-02"}]
}
```

### Loading synthetic oncology patients into a sandbox

A fresh FHIR Server deployment is empty, and Synthea datasets have few cancer
patients. `make_oncology_bundle.py` builds a FHIR R4 **transaction Bundle** of
the same 11 synthetic patients as the mock roster (Patient + Condition with
ICD-10-CM/SNOMED codings and stage + Encounter), so the live and mock paths show
identical data:

```sh
uv run python api/make_oncology_bundle.py            # writes api/oncology_patients_bundle.json
uv run python api/make_oncology_bundle.py --upload   # POSTs it with the same FHIR_* auth the API uses
uv run python api/make_oncology_bundle.py --upload --url https://trak/csp/healthshare/trakitkit/fhir/r4 \
    --client-id luna-nccn --client-secret … --no-verify-tls      # or --username/--password, or --api-key
```

Writing to TrakCare needs a client scope such as `system/*.write` (read scopes
alone return 403). Uploading into a real TrakCare instance creates synthetic
patients in an EHR — only do this on a test/sandbox host.

Re-running `--upload` creates duplicates (entries are POSTs); wipe the
deployment or delete the resources first if you need a clean reload.

## Examples

```sh
curl -s localhost:8899/health | jq
curl -s localhost:8899/patients | jq '.source, .by_guideline'

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
