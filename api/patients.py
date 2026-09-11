"""Patient roster for the Luna UI: FHIR R4 client (TrakCare / IRIS for Health / FHIRaaS) + mock fallback.

Reads ``Patient`` / ``Condition`` / ``Encounter`` from any FHIR R4 server and
normalizes them into a flat oncology roster the LiveView renders directly:

    {"source": "trakcare"|"fhir"|"mock"|"error", "server": host, "auth": mode,
     "error": ..., "fetched_at": iso, "cached": bool,
     "total": n, "by_guideline": {key: n, ..., "other": n},
     "patients": [{"id","mrn","name","sex","birth_date","age","diagnosis",
                   "diagnosis_code","stage","guideline","last_encounter"}]}

Primary target is **InterSystems TrakCare**, whose FHIR layer is the IRIS for
Health FHIR repository (what the TrakCare Innovation Toolkit exposes):

    https://<trakcare-host>/csp/healthshare/<namespace>/fhir/r4

and which authenticates with OAuth 2.0 bearer tokens (IRIS OAuth server,
``/oauth2/token``, SMART scopes) or HTTP Basic (an IRIS user). The InterSystems
cloud FHIR Server (FHIRaaS) with its ``x-api-key`` header is also supported.

Configuration (env; ``FHIR_*`` preferred, ``INTELLICARE_*`` kept as aliases):

    FHIR_BASE_URL       R4 base, no trailing slash            (alias INTELLICARE_FHIR_URL)
    FHIR_AUTH           auto | oauth | basic | apikey | none  (auto picks from what is set)
    FHIR_CLIENT_ID / FHIR_CLIENT_SECRET   OAuth 2.0 client_credentials (SMART backend service)
    FHIR_TOKEN_URL      token endpoint; default = discovered from
                        <base>/.well-known/smart-configuration, else <origin>/oauth2/token
    FHIR_SCOPE          default "system/Patient.read system/Condition.read system/Encounter.read"
    FHIR_USERNAME / FHIR_PASSWORD         HTTP Basic (or OAuth password grant if client id is set too)
    FHIR_API_KEY        x-api-key header                       (alias INTELLICARE_API_KEY)
    FHIR_PROFILE        auto | trakcare | fhiraas | generic   (auto: trakcare if the path
                        contains /csp/healthshare/, fhiraas for *.isccloud.io)
    FHIR_VERIFY_TLS     "false" to accept self-signed certs (common on TrakCare test hosts)

If no base URL is set a deterministic synthetic roster is served (``source:
"mock"``). Upstream failures never raise out of ``load_roster``; they come back
as ``source: "error"`` so the modal can show a friendly state.

Mock ages are computed from fixed birth dates at call time, so they drift by one
each calendar year. Acceptable for a demo.
"""

from __future__ import annotations

import os
import re
import time
from dataclasses import dataclass, field
from datetime import date, datetime, timezone
from urllib.parse import urlsplit

TIMEOUT_S = 10.0
CACHE_TTL_S = 60.0
MAX_PAGES = 5  # safety valve when following Bundle.link[rel=next]
DEFAULT_SCOPE = "system/Patient.read system/Condition.read system/Encounter.read"


# ============================== configuration ==============================
def _env(*names: str, default: str = "") -> str:
    for n in names:
        v = os.environ.get(n)
        if v:
            return v.strip()
    return default


@dataclass
class Config:
    """Connection settings. Build via ``load_config()``; override fields for tests/CLIs."""

    base_url: str = ""
    auth: str = "auto"          # auto | oauth | basic | apikey | none
    api_key: str = ""
    client_id: str = ""
    client_secret: str = ""
    token_url: str = ""
    scope: str = DEFAULT_SCOPE
    username: str = ""
    password: str = ""
    profile: str = "auto"       # auto | trakcare | fhiraas | generic
    verify_tls: bool = True
    public_url: str = ""        # browser-reachable base for "open FHIR resource" links (default: base_url)
    _token: dict = field(default_factory=dict, repr=False)

    def __post_init__(self) -> None:
        self.base_url = self.base_url.rstrip("/")
        self.public_url = (self.public_url or self.base_url).rstrip("/")
        if self.auth == "auto":
            if self.client_id and (self.client_secret or self.password):
                self.auth = "oauth"
            elif self.username:
                self.auth = "basic"
            elif self.api_key:
                self.auth = "apikey"
            else:
                self.auth = "none"
        if self.profile == "auto":
            low = self.base_url.lower()
            if "/csp/healthshare/" in low or "trak" in low:
                self.profile = "trakcare"
            elif "isccloud.io" in low:
                self.profile = "fhiraas"
            else:
                self.profile = "generic"

    @property
    def origin(self) -> str:
        u = urlsplit(self.base_url)
        return f"{u.scheme}://{u.netloc}"

    @property
    def host(self) -> str:
        return urlsplit(self.base_url).netloc

    @property
    def source_label(self) -> str:
        return "trakcare" if self.profile == "trakcare" else "fhir"


def load_config(**overrides) -> Config:
    """Config from env (FHIR_* first, INTELLICARE_* aliases), with keyword overrides."""
    cfg = dict(
        base_url=_env("FHIR_BASE_URL", "INTELLICARE_FHIR_URL"),
        auth=_env("FHIR_AUTH", default="auto").lower(),
        api_key=_env("FHIR_API_KEY", "INTELLICARE_API_KEY"),
        client_id=_env("FHIR_CLIENT_ID"),
        client_secret=_env("FHIR_CLIENT_SECRET"),
        token_url=_env("FHIR_TOKEN_URL"),
        scope=_env("FHIR_SCOPE", default=DEFAULT_SCOPE),
        username=_env("FHIR_USERNAME"),
        password=_env("FHIR_PASSWORD"),
        profile=_env("FHIR_PROFILE", default="auto").lower(),
        verify_tls=_env("FHIR_VERIFY_TLS", default="true").lower() not in ("0", "false", "no"),
        public_url=_env("FHIR_PUBLIC_URL"),
    )
    cfg.update({k: v for k, v in overrides.items() if v is not None})
    return Config(**cfg)


CFG = load_config()

GUIDELINE_KEYS = ["testicular", "breast", "prostate", "colon", "nsclc"]

# (guideline key, ICD-10 prefixes, SNOMED codes, keywords) - first match wins.
GUIDELINE_MAP = [
    ("breast", ("C50",), {"254837009", "254838004"}, ("breast",)),
    ("prostate", ("C61",), {"399068003", "254900004"}, ("prostate",)),
    ("colon", ("C18", "C19", "C20"), {"363406005", "363351006", "93761005"},
     ("colon", "colorectal", "rectal", "rectum", "sigmoid")),
    ("nsclc", ("C34",), {"254637007", "363358000", "254632001"},
     ("lung", "nsclc", "non-small cell", "bronch")),
    ("testicular", ("C62",), {"363449006", "92621004"},
     ("testic", "testis", "seminoma", "germ cell")),
]
# "small cell" / "SCLC" excludes nsclc, but "non-small cell" must not.
_SMALL_CELL = re.compile(r"(?<!non-)(?<!non )small[- ]cell|(?<![a-z])sclc(?![a-z])", re.I)
_ONCOLOGIC = re.compile(r"carcinoma|cancer|neoplasm|malignan|tumou?r|lymphoma|sarcoma", re.I)
_ICD_C = re.compile(r"^C\d\d", re.I)
_STAGE_RE = re.compile(r"\bstage\s+(0|IV|I{1,3})([A-C])?\b", re.I)
_ACTIVE = {"active", "recurrence", "relapse"}

_cache: dict = {"ts": 0.0, "payload": None}


# ============================== mock roster ================================
MOCK_PATIENTS = [
    {"id": "mock-01", "mrn": "MRN-90001", "name": "Ada Testpatient", "sex": "female", "birth_date": "1968-04-12",
     "diagnosis": "Invasive ductal carcinoma of breast", "diagnosis_code": "C50.911", "stage": "IIA",
     "guideline": "breast", "last_encounter": "2026-09-02"},
    {"id": "mock-02", "mrn": "MRN-90002", "name": "Sam Demo-Rivera", "sex": "male", "birth_date": "1959-11-03",
     "diagnosis": "Adenocarcinoma of prostate", "diagnosis_code": "C61", "stage": "T2c, Gleason 7",
     "guideline": "prostate", "last_encounter": "2026-08-28"},
    {"id": "mock-03", "mrn": "MRN-90003", "name": "Priya Sandbox", "sex": "female", "birth_date": "1975-07-21",
     "diagnosis": "Adenocarcinoma of sigmoid colon", "diagnosis_code": "C18.7", "stage": "IIIB",
     "guideline": "colon", "last_encounter": "2026-08-30"},
    {"id": "mock-04", "mrn": "MRN-90004", "name": "Lars Placeholder", "sex": "male", "birth_date": "1954-02-09",
     "diagnosis": "Non-small cell lung carcinoma, right upper lobe", "diagnosis_code": "C34.11", "stage": "IIIA",
     "guideline": "nsclc", "last_encounter": "2026-09-04"},
    {"id": "mock-05", "mrn": "MRN-90005", "name": "Theo Specimen", "sex": "male", "birth_date": "1996-05-30",
     "diagnosis": "Seminoma of testis", "diagnosis_code": "C62.91", "stage": "IS",
     "guideline": "testicular", "last_encounter": "2026-08-19"},
    {"id": "mock-06", "mrn": "MRN-90006", "name": "Mira Fixture", "sex": "female", "birth_date": "1981-12-14",
     "diagnosis": "Ductal carcinoma in situ of breast", "diagnosis_code": "D05.11", "stage": "0",
     "guideline": "breast", "last_encounter": "2026-07-25"},
    {"id": "mock-07", "mrn": "MRN-90007", "name": "Omar Dummydata", "sex": "male", "birth_date": "1948-08-02",
     "diagnosis": "Adenocarcinoma of prostate, metastatic", "diagnosis_code": "C61", "stage": "IV",
     "guideline": "prostate", "last_encounter": "2026-09-06"},
    {"id": "mock-08", "mrn": "MRN-90008", "name": "Greta Synthetic", "sex": "female", "birth_date": "1962-03-17",
     "diagnosis": "Adenocarcinoma of ascending colon, dMMR", "diagnosis_code": "C18.2", "stage": "IV",
     "guideline": "colon", "last_encounter": "2026-09-01"},
    {"id": "mock-09", "mrn": "MRN-90009", "name": "Hana Exampleton", "sex": "female", "birth_date": "1970-10-05",
     "diagnosis": "Non-small cell lung carcinoma, EGFR+", "diagnosis_code": "C34.90", "stage": "IB",
     "guideline": "nsclc", "last_encounter": "2026-08-12"},
    {"id": "mock-10", "mrn": "MRN-90010", "name": "Ivo Stubfield", "sex": "male", "birth_date": "1991-01-26",
     "diagnosis": "Nonseminomatous germ cell tumor of testis", "diagnosis_code": "C62.11", "stage": "IIB",
     "guideline": "testicular", "last_encounter": "2026-08-22"},
    {"id": "mock-11", "mrn": "MRN-90011", "name": "Nadia Mockwell", "sex": "female", "birth_date": "1957-06-08",
     "diagnosis": "Invasive lobular carcinoma of breast, HR+/HER2-", "diagnosis_code": "C50.412", "stage": "IIIB",
     "guideline": "breast", "last_encounter": "2026-08-15"},
]


# ================================ helpers ==================================
def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _age(birth_date: str | None) -> int | None:
    if not birth_date:
        return None
    try:
        b = date.fromisoformat(birth_date[:10])
    except ValueError:
        return None
    t = date.today()
    return t.year - b.year - ((t.month, t.day) < (b.month, b.day))


def _empty_counts() -> dict[str, int]:
    return {k: 0 for k in GUIDELINE_KEYS} | {"other": 0}


def _summarize(patients: list[dict], source: str, **extra) -> dict:
    """Shared final shaping for both mock and FHIR paths (guarantees identical shape)."""
    counts = _empty_counts()
    for p in patients:
        p["age"] = _age(p.get("birth_date"))
        counts[p["guideline"] if p.get("guideline") in counts else "other"] += 1
    patients.sort(key=lambda p: (p.get("last_encounter") or "", p.get("name") or ""))
    patients.sort(key=lambda p: p.get("last_encounter") or "", reverse=True)
    return {"source": source, "error": None, "fetched_at": _now_iso(), "cached": False,
            "total": len(patients), "by_guideline": counts, "patients": patients, **extra}


def _error_payload(err: str) -> dict:
    return {"source": "error", "error": err, "fetched_at": _now_iso(), "cached": False,
            "total": 0, "by_guideline": _empty_counts(), "patients": []}


def configured_source(cfg: Config | None = None) -> str:
    """'trakcare' / 'fhir' if a base URL is configured, else 'mock'. Never touches the network."""
    cfg = cfg or CFG
    return cfg.source_label if cfg.base_url else "mock"


def configured_auth(cfg: Config | None = None) -> str:
    return (cfg or CFG).auth


# ============================ FHIR normalization ===========================
def _codings(cond: dict) -> list[dict]:
    return (cond.get("code") or {}).get("coding") or []


def _texts(cond: dict) -> str:
    parts = [(cond.get("code") or {}).get("text") or ""]
    parts += [c.get("display") or "" for c in _codings(cond)]
    return " ".join(parts).lower()


def map_guideline(cond: dict) -> str | None:
    """Map a FHIR Condition to an NCCN guideline key (ICD-10 prefix > SNOMED > keyword)."""
    codes = [(c.get("code") or "").upper() for c in _codings(cond)]
    text = _texts(cond)
    small_cell = bool(_SMALL_CELL.search(text))
    for key, icd, snomed, kws in GUIDELINE_MAP:
        if key == "nsclc" and small_cell:
            continue
        if any(code.startswith(p) for code in codes for p in icd):
            return key
        if any(code in snomed for code in codes):
            return key
        if any(kw in text for kw in kws):
            return key
    return None


def _is_oncologic(cond: dict) -> bool:
    return any(_ICD_C.match(c.get("code") or "") for c in _codings(cond)) or bool(_ONCOLOGIC.search(_texts(cond)))


def _stage(cond: dict) -> str | None:
    for st in cond.get("stage") or []:
        summ = st.get("summary") or {}
        disp = ((summ.get("coding") or [{}])[0].get("display")) or summ.get("text")
        if disp:
            return re.sub(r"^\s*stage\s+", "", disp, flags=re.I).strip()
    m = _STAGE_RE.search(_texts(cond))
    return (m.group(1).upper() + (m.group(2) or "").upper()) if m else None


def _display(cond: dict) -> str | None:
    code = cond.get("code") or {}
    for c in code.get("coding") or []:
        if c.get("display"):
            return c["display"]
    return code.get("text")


def _code(cond: dict) -> str | None:
    for c in _codings(cond):
        if c.get("code"):
            return c["code"]
    return None


def _is_active(cond: dict) -> bool:
    cs = cond.get("clinicalStatus") or {}
    codes = {c.get("code") for c in cs.get("coding") or []}
    return not codes or bool(codes & _ACTIVE)


def _cond_date(cond: dict) -> str:
    return cond.get("onsetDateTime") or cond.get("recordedDate") or ""


def _patient_ref(res: dict) -> str | None:
    ref = (res.get("subject") or res.get("patient") or {}).get("reference") or ""
    parts = ref.rstrip("/").split("/")
    return parts[-1] if len(parts) >= 2 and parts[-2] == "Patient" else None


def _name(p: dict) -> str:
    names = p.get("name") or []
    n = next((x for x in names if x.get("use") == "official"), names[0] if names else {})
    given = " ".join(n.get("given") or [])
    full = " ".join(x for x in (given, n.get("family") or "") if x).strip()
    return full or n.get("text") or f"Patient {p.get('id', '?')}"


def _mrn(p: dict) -> str | None:
    ids = p.get("identifier") or []
    for i in ids:
        codes = {c.get("code") for c in ((i.get("type") or {}).get("coding") or [])}
        if "MR" in codes and i.get("value"):
            return i["value"]
    return next((i.get("value") for i in ids if i.get("value")), None)


def _encounter_date(enc: dict) -> str | None:
    per = enc.get("period") or {}
    d = max((per.get("end") or "", per.get("start") or ""))
    return d[:10] or None


def normalize(patients: list[dict], conditions: list[dict], encounters: list[dict]) -> list[dict]:
    """Join raw FHIR resources into the flat roster shape (pure; unit-testable)."""
    conds: dict[str, list[dict]] = {}
    for c in conditions:
        pid = _patient_ref(c)
        if pid:
            conds.setdefault(pid, []).append(c)
    last: dict[str, str] = {}
    for e in encounters:
        pid, d = _patient_ref(e), _encounter_date(e)
        if pid and d and d > last.get(pid, ""):
            last[pid] = d

    out = []
    for p in patients:
        pid = p.get("id") or ""
        cs = conds.get(pid, [])
        active = [c for c in cs if _is_active(c)] or cs
        active.sort(key=_cond_date, reverse=True)
        primary = next((c for c in active if map_guideline(c)), None) \
            or next((c for c in active if _is_oncologic(c)), None)
        out.append({
            "id": pid, "mrn": _mrn(p), "name": _name(p), "sex": p.get("gender"),
            "birth_date": p.get("birthDate"),
            "diagnosis": _display(primary) if primary else None,
            "diagnosis_code": _code(primary) if primary else None,
            "stage": _stage(primary) if primary else None,
            "guideline": map_guideline(primary) if primary else None,
            "last_encounter": last.get(pid),
        })
    return out


# ============================ authentication ===============================
def discover_token_url(cfg: Config, client) -> str:
    """Token endpoint: explicit > SMART discovery > IRIS default <origin>/oauth2/token."""
    if cfg.token_url:
        return cfg.token_url
    for url in (f"{cfg.base_url}/.well-known/smart-configuration",
                f"{cfg.origin}/oauth2/.well-known/openid-configuration"):
        try:
            r = client.get(url, headers={"Accept": "application/json"}, auth=None)
            if r.status_code == 200:
                te = r.json().get("token_endpoint")
                if te:
                    return te
        except Exception:  # noqa: BLE001 - discovery is best-effort
            continue
    return f"{cfg.origin}/oauth2/token"


def fetch_token(cfg: Config, client) -> dict:
    """OAuth 2.0 token via client_credentials (or password grant when a username is set).

    The client secret goes in the HTTP Basic header (IRIS default ``client_secret_basic``).
    """
    import httpx

    token_url = discover_token_url(cfg, client)
    if cfg.username and cfg.password:
        data = {"grant_type": "password", "username": cfg.username, "password": cfg.password, "scope": cfg.scope}
    else:
        data = {"grant_type": "client_credentials", "scope": cfg.scope}
    r = client.post(token_url, data=data, headers={"Accept": "application/json"},
                    auth=httpx.BasicAuth(cfg.client_id, cfg.client_secret))
    if r.status_code != 200:
        raise PermissionError(f"token request to {token_url} failed: HTTP {r.status_code} {r.text[:200]}")
    tok = r.json()
    if "access_token" not in tok:
        raise PermissionError(f"token response from {token_url} has no access_token")
    tok["_expires_at"] = time.time() + float(tok.get("expires_in", 300)) - 30
    cfg._token = tok
    return tok


def _oauth_auth(cfg: Config, client):
    """httpx.Auth that attaches a bearer token and refreshes it once on 401."""
    import httpx

    class _OAuthAuth(httpx.Auth):
        def _token(self) -> str:
            t = cfg._token
            if not t or time.time() >= t.get("_expires_at", 0):
                t = fetch_token(cfg, client)
            return t["access_token"]

        def auth_flow(self, request):
            request.headers["Authorization"] = f"Bearer {self._token()}"
            response = yield request
            if response.status_code == 401:
                cfg._token = {}
                request.headers["Authorization"] = f"Bearer {self._token()}"
                yield request

    return _OAuthAuth()


def make_client(cfg: Config | None = None, transport=None):
    """An httpx.Client pre-configured for the server's auth mode (lazy import; mock path needs none)."""
    import httpx

    cfg = cfg or CFG
    headers = {"Accept": "application/fhir+json"}
    auth = None
    if cfg.auth == "apikey":
        headers["x-api-key"] = cfg.api_key
    elif cfg.auth == "basic":
        auth = httpx.BasicAuth(cfg.username, cfg.password)
    client = httpx.Client(timeout=TIMEOUT_S, headers=headers, follow_redirects=True,
                          verify=cfg.verify_tls, auth=auth, transport=transport)
    if cfg.auth == "oauth":
        # token requests reuse the same client (same TLS settings) but bypass this hook via auth=None
        client.auth = _oauth_auth(cfg, client)
    return client


# ============================== FHIR client ================================
def _search(client, base_url: str, resource: str, params: dict) -> list[dict]:
    """GET a search Bundle and follow `next` links (bounded). Returns resources."""
    url, out, pages = f"{base_url}/{resource}", [], 0
    while url and pages < MAX_PAGES:
        r = client.get(url, params=params if pages == 0 else None)
        r.raise_for_status()
        bundle = r.json()
        if bundle.get("resourceType") != "Bundle":
            raise ValueError(f"{resource}: expected Bundle, got {bundle.get('resourceType')!r}")
        out += [e["resource"] for e in bundle.get("entry") or [] if e.get("resource")]
        url = next((l.get("url") for l in bundle.get("link") or [] if l.get("relation") == "next"), None)
        pages += 1
    return out


def _fetch_fhir(cfg: Config, transport=None) -> list[dict]:
    with make_client(cfg, transport=transport) as client:
        patients = _search(client, cfg.base_url, "Patient", {"_count": 50})
        conditions = _search(client, cfg.base_url, "Condition", {"_count": 200})
        try:
            encounters = _search(client, cfg.base_url, "Encounter", {"_count": 200, "_sort": "-date"})
        except Exception as e:  # noqa: BLE001 - degrade to last_encounter=None
            print(f"  patients: Encounter fetch failed ({type(e).__name__}); continuing without dates")
            encounters = []
    print(f"  patients: {cfg.source_label} {cfg.host}: {len(patients)} Patient · "
          f"{len(conditions)} Condition · {len(encounters)} Encounter")
    return normalize(patients, conditions, encounters)


def load_roster(refresh: bool = False, cfg: Config | None = None, transport=None) -> dict:
    """Return the roster payload. Never raises; upstream failures -> source='error'."""
    cfg = cfg or CFG
    if not cfg.base_url:
        return _summarize([dict(p) for p in MOCK_PATIENTS], "mock", server=None, auth="none")
    now = time.time()
    if not refresh and _cache["payload"] and now - _cache["ts"] < CACHE_TTL_S:
        return {**_cache["payload"], "cached": True}
    try:
        payload = _summarize(_fetch_fhir(cfg, transport), cfg.source_label, server=cfg.host, auth=cfg.auth)
    except Exception as e:  # noqa: BLE001 - surfaced to the UI as a friendly state
        return {**_error_payload(f"{type(e).__name__}: {e}"), "server": cfg.host, "auth": cfg.auth}
    _cache.update(ts=now, payload=payload)
    return payload


# ============================ single-patient detail =========================
def _condition_row(c: dict) -> dict:
    cs = c.get("clinicalStatus") or {}
    status = next((x.get("code") for x in cs.get("coding") or [] if x.get("code")), None)
    coding = next((x for x in _codings(c) if x.get("code")), {})
    system = (coding.get("system") or "").rsplit("/", 1)[-1] or None
    return {"id": c.get("id"), "display": _display(c), "code": coding.get("code"), "system": system,
            "stage": _stage(c), "status": status, "onset": (_cond_date(c) or "")[:10] or None,
            "guideline": map_guideline(c), "oncologic": _is_oncologic(c)}


def _encounter_row(e: dict) -> dict:
    per = e.get("period") or {}
    typ = next((t.get("text") or ((t.get("coding") or [{}])[0].get("display")) for t in e.get("type") or [] if t), None)
    return {"id": e.get("id"), "date": (per.get("start") or per.get("end") or "")[:10] or None,
            "end": (per.get("end") or "")[:10] or None, "type": typ,
            "class": (e.get("class") or {}).get("display") or (e.get("class") or {}).get("code"),
            "status": e.get("status")}


def context_text(row: dict) -> str:
    """One-paragraph patient context Luna prepends to questions (no free-text PHI beyond the roster row)."""
    bits = []
    if row.get("age") is not None or row.get("sex"):
        bits.append(" ".join(str(x) for x in (row.get("age") and f"{row['age']}-year-old", row.get("sex")) if x))
    dx = row.get("diagnosis")
    if dx:
        bits.append(f"with {dx}" + (f" ({row['diagnosis_code']})" if row.get("diagnosis_code") else ""))
    if row.get("stage"):
        bits.append(f"stage {row['stage']}")
    who = ", ".join(bits) if bits else "patient"
    last = f" Last encounter {row['last_encounter']}." if row.get("last_encounter") else ""
    return f"Patient context: {who}.{last} Answer for this patient specifically."


def load_patient(pid: str, cfg: Config | None = None, transport=None) -> dict:
    """Full record for one patient: roster row + all conditions + recent encounters + FHIR link.

    Never raises; shape: {"source", "server", "patient": row|None, "conditions": [...],
    "encounters": [...], "resource_url", "context", "error"}.
    """
    cfg = cfg or CFG
    if not cfg.base_url:
        row = next((dict(p) for p in MOCK_PATIENTS if p["id"] == pid), None)
        if not row:
            return {"source": "mock", "server": None, "patient": None, "conditions": [], "encounters": [],
                    "resource_url": None, "context": None, "error": f"no mock patient {pid!r}"}
        row["age"] = _age(row["birth_date"])
        cond = {"display": row["diagnosis"], "code": row["diagnosis_code"], "system": "icd-10-cm", "stage": row["stage"],
                "status": "active", "onset": None, "guideline": row["guideline"], "oncologic": True, "id": None}
        enc = {"id": None, "date": row["last_encounter"], "end": None, "type": "Oncology follow-up", "class": "ambulatory", "status": "finished"}
        return {"source": "mock", "server": None, "patient": row, "conditions": [cond], "encounters": [enc],
                "resource_url": None, "context": context_text(row), "error": None}
    try:
        with make_client(cfg, transport=transport) as client:
            r = client.get(f"{cfg.base_url}/Patient/{pid}")
            r.raise_for_status()
            patient = r.json()
            conditions = _search(client, cfg.base_url, "Condition", {"patient": pid, "_count": 100})
            try:
                encounters = _search(client, cfg.base_url, "Encounter", {"patient": pid, "_count": 50, "_sort": "-date"})
            except Exception:  # noqa: BLE001
                encounters = []
        row = normalize([patient], conditions, encounters)[0]
        row["age"] = _age(row.get("birth_date"))
        conds = sorted((_condition_row(c) for c in conditions), key=lambda c: (not c["oncologic"], c["onset"] or ""), reverse=False)
        conds.sort(key=lambda c: (c["oncologic"], c["onset"] or ""), reverse=True)
        encs = sorted((_encounter_row(e) for e in encounters), key=lambda e: e["date"] or "", reverse=True)
        return {"source": cfg.source_label, "server": cfg.host, "patient": row, "conditions": conds, "encounters": encs,
                "resource_url": f"{cfg.public_url}/Patient/{pid}", "context": context_text(row), "error": None}
    except Exception as e:  # noqa: BLE001
        return {"source": "error", "server": cfg.host, "patient": None, "conditions": [], "encounters": [],
                "resource_url": None, "context": None, "error": f"{type(e).__name__}: {e}"}
