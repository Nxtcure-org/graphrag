#!/usr/bin/env python
"""Human-in-the-loop Playwright walkthrough: TrakCare FHIR access -> OAuth client / IRIS user -> .env.

InterSystems TrakCare has **no self-service developer portal or public sandbox**
(InterSystems confirmed a sandbox exists but is granted case by case). Its FHIR
layer is the IRIS for Health FHIR repository that the TrakCare Innovation Toolkit
installs, reached at

    https://<trakcare-host>/csp/healthshare/<namespace>/fhir/r4

and secured by the IRIS OAuth 2.0 server (bearer tokens) or HTTP Basic (an IRIS
user). So the human-in-the-loop work is: get a host from the TrakCare team,
sign in to the IRIS **Management Portal** on that host, register an OAuth client
(or pick a Basic-auth user), and copy the credentials.

This script opens a VISIBLE Chromium, navigates to the right Management Portal
pages, and stops with a boxed instruction in this terminal whenever you must act
(log in, click Create, copy a secret). It never types credentials or submits
forms. Then it writes FHIR_* to ./.env, verifies with the same client the API
uses (token -> /metadata -> Patient count), and offers to seed the oncology
bundle and restart the api container.

Run from the repo root in a normal terminal (needs interactive stdin):

    uv run --with playwright --with httpx python scripts/trakcare_fhir_setup.py
    uv run --with playwright --with httpx python scripts/trakcare_fhir_setup.py --host https://trak-test.example.org
    uv run --with playwright --with httpx python scripts/trakcare_fhir_setup.py --from verify   # creds already in .env

First time only:  uv run --with playwright playwright install chromium

The browser profile persists in ./.playwright/trakcare-profile (git-ignored) so
the Management Portal session survives between runs. Secrets are read with
getpass and never echoed.
"""

from __future__ import annotations

import argparse
import getpass
import os
import re
import subprocess
import sys
import textwrap
import time
from pathlib import Path
from urllib.parse import quote, urlsplit

REPO = Path(__file__).resolve().parent.parent
ENV_FILE = REPO / ".env"
PROFILE_DIR = REPO / ".playwright" / "trakcare-profile"
sys.path.insert(0, str(REPO / "api"))

# Public pages for the "I don't have a host yet" path
TRAKCARE_PRODUCT = "https://www.intersystems.com/products/trakcare/"
TRAKCARE_SANDBOX_THREAD = "https://community.intersystems.com/post/fhir-sandbox-available-trakcare"
INTERSYSTEMS_CONTACT = "https://www.intersystems.com/contact-us/"
CLIENT_PORTAL = "https://client.intersystems.com/home"

# IRIS Management Portal paths (stable across IRIS for Health releases)
MP_HOME = "/csp/sys/UtilHome.csp"
MP_OAUTH_SERVER = "/csp/sys/sec/" + quote("%CSP.UI.Portal.OAuth2.Server.Configuration.zen")
MP_OAUTH_CLIENTS = "/csp/sys/sec/" + quote("%CSP.UI.Portal.OAuth2.Server.ClientList.zen")
MP_USERS = "/csp/sys/sec/" + quote("%CSP.UI.Portal.Users.zen")
MP_WEBAPPS = "/csp/sys/sec/" + quote("%CSP.UI.Portal.Applications.WebList.zen")

FHIR_PATH_RE = re.compile(r"/csp/healthshare/[A-Za-z0-9_-]+/fhir/(?:r4|r5|stu3)\b", re.I)
DEFAULT_SCOPE = "system/Patient.read system/Condition.read system/Encounter.read"

STEPS = ["host", "login", "endpoint", "auth", "env", "verify", "seed"]


# ------------------------------------------------------------------ console --
def box(title: str, body: str) -> None:
    width = 78
    print("\n┌" + "─" * width + "┐")
    print("│ " + f"▶ {title}".ljust(width - 1) + "│")
    print("├" + "─" * width + "┤")
    for para in textwrap.dedent(body).strip().split("\n"):
        for line in textwrap.wrap(para, width - 2, replace_whitespace=False) or [""]:
            print("│ " + line.ljust(width - 1) + "│")
    print("└" + "─" * width + "┘")


def human(title: str, body: str) -> None:
    """Print instructions and block until Enter (q = quit)."""
    box("YOUR TURN — " + title, body + "\n\nPress Enter here when done  (q + Enter to quit).")
    if input("› ").strip().lower() == "q":
        print("Stopping. Re-run with --from <step> to resume.")
        sys.exit(0)


def note(msg: str) -> None:
    print(f"  · {msg}")


def ask(prompt: str, default: str = "") -> str:
    val = input(f"{prompt}{f' [{default}]' if default else ''}: ").strip()
    return val or default


def secret(prompt: str) -> str:
    return getpass.getpass(f"{prompt} (hidden): ").strip()


def yes(prompt: str, default: bool = True) -> bool:
    val = input(f"{prompt} ({'Y/n' if default else 'y/N'}): ").strip().lower()
    return default if not val else val.startswith("y")


def choose(prompt: str, options: list[tuple[str, str]], default: str) -> str:
    print(prompt)
    for key, desc in options:
        print(f"    {key:<7} {desc}")
    while True:
        v = ask("Choice", default).lower()
        if v in dict(options):
            return v
        print("  pick one of: " + ", ".join(k for k, _ in options))


# --------------------------------------------------------------- playwright --
def launch(pw):
    PROFILE_DIR.mkdir(parents=True, exist_ok=True)
    ctx = pw.chromium.launch_persistent_context(
        str(PROFILE_DIR), headless=False, slow_mo=250, viewport=None,
        args=["--start-maximized"], ignore_https_errors=True,  # TrakCare test hosts are often self-signed
    )
    return ctx, (ctx.pages[0] if ctx.pages else ctx.new_page())


def goto(page, url: str) -> bool:
    try:
        page.goto(url, wait_until="domcontentloaded", timeout=30000)
        time.sleep(1.2)
        return True
    except Exception as e:  # noqa: BLE001
        note(f"could not open {url}: {type(e).__name__}")
        return False


def try_click(page, labels: list[str], timeout_ms: int = 3000) -> bool:
    for label in labels:
        pat = re.compile(label, re.I)
        for loc in (page.get_by_role("button", name=pat), page.get_by_role("link", name=pat), page.get_by_text(pat)):
            try:
                if loc.first.count() and loc.first.is_visible():
                    loc.first.click(timeout=timeout_ms)
                    note(f"clicked “{label}”")
                    return True
            except Exception:  # noqa: BLE001
                continue
    return False


def page_text(page) -> str:
    try:
        return page.content()
    except Exception:  # noqa: BLE001
        return ""


def scrape_fhir_paths(page) -> list[str]:
    return sorted(set(m.group(0) for m in FHIR_PATH_RE.finditer(page_text(page))))


# --------------------------------------------------------------------- steps --
def step_host(page, host: str) -> str:
    box("Step 1/7 — TrakCare host", "TrakCare has no public sandbox; you need a host from the TrakCare team.")
    if not host:
        host = ask("TrakCare / IRIS for Health host URL (blank if you don't have one yet)").rstrip("/")
    if host:
        if not host.startswith("http"):
            host = "https://" + host
        note(f"using {host}")
        return host
    goto(page, TRAKCARE_SANDBOX_THREAD)
    page.context.new_page().goto(INTERSYSTEMS_CONTACT, wait_until="domcontentloaded")
    page.context.new_page().goto(CLIENT_PORTAL, wait_until="domcontentloaded")
    human(
        "Request TrakCare FHIR access",
        """
        Three tabs are open:
          1. Community thread where InterSystems' TrakCare interoperability PM confirms a
             non-public TrakCare FHIR sandbox exists and asks to be emailed with requirements.
          2. InterSystems contact form — ask for "TrakCare FHIR (Innovation Toolkit) test
             access for a SMART/FHIR oncology decision-support app"; mention you need an
             R4 endpoint plus an OAuth 2.0 client (client_credentials) or a Basic-auth user.
          3. Client portal (WRC) — if your organisation is already a TrakCare customer, open a
             request there; the site admin can also install the Innovation Toolkit on a test
             instance and give you the host.
        Until you have a host there is nothing to automate; the roster keeps serving the
        synthetic patients. Re-run this script with --host https://<trakcare-test-host>
        when you have one.
        """,
    )
    sys.exit(0)


def step_login(page, host: str) -> None:
    box("Step 2/7 — Management Portal login", f"Opening {host}{MP_HOME}")
    if not goto(page, host + MP_HOME):
        human("Open the Management Portal", f"Open {host}{MP_HOME} in the browser (the port may differ, e.g. :52773 or :443), then press Enter.")
    human(
        "Sign in to the IRIS Management Portal",
        """
        Sign in with the IRIS credentials your TrakCare administrator gave you (a user with
        %Admin_Secure or similar, so you can create OAuth clients / users). If you see a
        certificate warning page, proceed — this profile ignores TLS errors on purpose.
        Stop when the Management Portal home page (System Overview) is showing.
        """,
    )


def step_endpoint(page, host: str) -> str:
    box("Step 3/7 — FHIR endpoint", "Finding the R4 endpoint under /csp/healthshare/<namespace>/fhir/r4")
    goto(page, host + MP_WEBAPPS)  # every FHIR endpoint is a web application; this list shows them all
    paths = scrape_fhir_paths(page)
    if paths:
        print("  FHIR web applications found on this host:")
        for i, p in enumerate(paths, 1):
            print(f"    {i}. {p}")
        pick = ask("Use which one? (number, or paste a full URL)", "1")
        if pick.isdigit() and 1 <= int(pick) <= len(paths):
            return host + paths[int(pick) - 1]
        if pick.startswith("http"):
            return pick.rstrip("/")
    human(
        "Locate the FHIR endpoint",
        f"""
        The Web Applications page is open (System Administration > Security > Applications >
        Web Applications). Look for an entry like /csp/healthshare/<namespace>/fhir/r4 — the
        Innovation Toolkit uses namespace "trakitkit" by default. Alternatively open
        Health > <namespace> > FHIR Configuration > Server Configuration and copy the endpoint.
        Paste the full URL below, e.g.  {host}/csp/healthshare/trakitkit/fhir/r4
        """,
    )
    while True:
        url = ask("FHIR R4 base URL").rstrip("/")
        if url.startswith("http") and "/fhir/" in url:
            return url
        print("  expected something like https://host/csp/healthshare/<ns>/fhir/r4")


def step_auth(page, host: str, fhir_url: str) -> dict:
    box("Step 4/7 — Credentials", "TrakCare FHIR endpoints accept OAuth 2.0 bearer tokens or HTTP Basic.")
    mode = choose("How should Luna authenticate?", [
        ("oauth", "OAuth 2.0 client_credentials — register a client on the IRIS OAuth server (recommended)"),
        ("basic", "HTTP Basic — an IRIS user with read access to the FHIR web application"),
        ("apikey", "x-api-key — only for the InterSystems cloud FHIR Server, not TrakCare"),
    ], "oauth")
    creds: dict = {"auth": mode}

    if mode == "oauth":
        goto(page, host + MP_OAUTH_SERVER)
        issuer = ""
        m = re.search(r"https?://[^\s\"'<>]+/oauth2", page_text(page))
        if m:
            issuer = m.group(0)
            note(f"OAuth server issuer looks like {issuer}")
        goto(page, host + MP_OAUTH_CLIENTS)
        try_click(page, [r"create client description", r"create new client", r"^create$"], timeout_ms=2500)
        human(
            "Register an OAuth 2.0 client for Luna",
            """
            The OAuth 2.0 server's Client Descriptions page is open (System Administration >
            Security > OAuth 2.0 > Server > Client Descriptions). If the server itself is not
            configured yet, ask the TrakCare admin — the Innovation Toolkit installer sets it up.
              1. Create Client Description:  Name  luna-nccn   ·  Client Type  Confidential
                 Description  "Luna NCCN copilot roster (backend service)".
              2. Grant types: tick  Client credentials  (also tick Password if you'll use an IRIS user).
              3. Client authentication: leave  client_secret_basic  (the default).
              4. Supported scopes: add  system/Patient.read  system/Condition.read  system/Encounter.read
                 (or user/*.read if the server only defines SMART user scopes).
              5. Save. Open the  Client Credentials  tab and copy the  Client ID  and  Client Secret.
            Press Enter, then paste them here.
            """,
        )
        creds["client_id"] = ask("Client ID")
        creds["client_secret"] = secret("Client secret")
        creds["token_url"] = ask("Token endpoint (blank = discover / <origin>/oauth2/token)", f"{issuer}/token" if issuer else "")
        creds["scope"] = ask("Scopes", DEFAULT_SCOPE)
    elif mode == "basic":
        goto(page, host + MP_USERS)
        human(
            "Pick or create an IRIS user",
            f"""
            The Users page is open (System Administration > Security > Users). Either use an
            existing service user or create one (e.g.  luna_fhir ) with a password that does not
            expire. It needs a role that grants access to the FHIR web application
            ({urlsplit(fhir_url).path}) — typically the %HS_* / FHIR resource roles the Toolkit
            created, or whatever the admin recommends. Make sure the web application allows
            password authentication (Web Applications > that path > Allowed Authentication Methods).
            """,
        )
        creds["username"] = ask("Username")
        creds["password"] = secret("Password")
    else:
        creds["api_key"] = secret("API key")

    creds["verify_tls"] = yes("Does this host have a valid (not self-signed) TLS certificate?", default=False)
    return creds


def step_env(fhir_url: str, creds: dict) -> None:
    box("Step 5/7 — .env", f"Writing FHIR_* settings to {ENV_FILE}")
    new = {"FHIR_BASE_URL": fhir_url, "FHIR_AUTH": creds["auth"],
           "FHIR_VERIFY_TLS": "true" if creds.get("verify_tls", True) else "false"}
    for k_env, k in (("FHIR_CLIENT_ID", "client_id"), ("FHIR_CLIENT_SECRET", "client_secret"), ("FHIR_TOKEN_URL", "token_url"),
                     ("FHIR_SCOPE", "scope"), ("FHIR_USERNAME", "username"), ("FHIR_PASSWORD", "password"), ("FHIR_API_KEY", "api_key")):
        if creds.get(k):
            new[k_env] = creds[k]
    lines = ENV_FILE.read_text().splitlines() if ENV_FILE.exists() else []
    managed = tuple(f"{k}=" for k in list(new) + ["FHIR_CLIENT_ID", "FHIR_CLIENT_SECRET", "FHIR_TOKEN_URL", "FHIR_SCOPE",
                                                  "FHIR_USERNAME", "FHIR_PASSWORD", "FHIR_API_KEY", "INTELLICARE_FHIR_URL", "INTELLICARE_API_KEY"])
    if any(l.startswith(managed) for l in lines):
        note("existing FHIR_*/INTELLICARE_* lines found")
        if not yes("Replace them?"):
            note("left .env untouched")
            return
    kept = [l for l in lines if not l.startswith(managed)]
    kept += [f"{k}={v}" for k, v in new.items()]
    ENV_FILE.write_text("\n".join(kept).rstrip("\n") + "\n")
    note("written: " + ", ".join(k for k in new if not k.endswith(("SECRET", "PASSWORD", "KEY"))) + " (+ secrets)")


def step_verify(fhir_url: str, creds: dict):
    """Use the API's own client: token -> /metadata -> Patient count. Returns the Config."""
    box("Step 6/7 — Verify", "Authenticating exactly as the api container will.")
    import patients

    cfg = patients.load_config(
        base_url=fhir_url, auth=creds["auth"], client_id=creds.get("client_id"), client_secret=creds.get("client_secret"),
        token_url=creds.get("token_url") or None, scope=creds.get("scope") or None, username=creds.get("username"),
        password=creds.get("password"), api_key=creds.get("api_key"), verify_tls=creds.get("verify_tls", True),
    )
    try:
        with patients.make_client(cfg) as c:
            if cfg.auth == "oauth":
                tok = patients.fetch_token(cfg, c)
                note(f"token OK from {patients.discover_token_url(cfg, c)} (expires in {int(tok.get('expires_in', 0))}s, scope={tok.get('scope', cfg.scope)})")
            r = c.get(f"{cfg.base_url}/metadata")
            if r.status_code != 200:
                raise RuntimeError(f"/metadata -> HTTP {r.status_code}: {r.text[:300]}")
            note(f"/metadata OK — FHIR {r.json().get('fhirVersion', '?')} ({cfg.source_label} profile, host {cfg.host})")
            n = c.get(f"{cfg.base_url}/Patient", params={"_summary": "count"})
            note(f"Patient search -> HTTP {n.status_code}; server holds {n.json().get('total', '?') if n.status_code == 200 else '?'} patients")
            if n.status_code == 403:
                note("403 on Patient search = token accepted but scope/role too narrow; widen the client's scopes or the user's roles")
    except Exception as e:  # noqa: BLE001
        print(f"\n  Verification failed: {type(e).__name__}: {e}")
        print("  Typical causes: OAuth client lacks the client_credentials grant or the scopes; web application")
        print("  doesn't allow the auth method; wrong namespace in the URL; self-signed cert with FHIR_VERIFY_TLS=true.")
        print("  Fix in the Management Portal and re-run with:  --from verify")
        sys.exit(1)
    return cfg


def step_seed(cfg) -> None:
    box("Step 7/7 — Seed & restart", "Optionally load the 11 synthetic oncology patients, then restart the api container.")
    if yes("Upload api/oncology_patients_bundle.json to this TrakCare FHIR endpoint? (POST transaction; duplicates if run twice)", default=False):
        env = {**os.environ, "FHIR_BASE_URL": cfg.base_url, "FHIR_AUTH": cfg.auth, "FHIR_CLIENT_ID": cfg.client_id,
               "FHIR_CLIENT_SECRET": cfg.client_secret, "FHIR_TOKEN_URL": cfg.token_url, "FHIR_SCOPE": cfg.scope,
               "FHIR_USERNAME": cfg.username, "FHIR_PASSWORD": cfg.password, "FHIR_API_KEY": cfg.api_key,
               "FHIR_VERIFY_TLS": "true" if cfg.verify_tls else "false"}
        note("note: writing needs system/*.write (or user/*.write) scope on the OAuth client")
        subprocess.run([sys.executable, str(REPO / "api" / "make_oncology_bundle.py"), "--upload"], cwd=REPO, env=env, check=False)
    if yes("Restart the api container so it picks up the new .env?", default=True):
        subprocess.run(["docker", "compose", "up", "-d", "api"], cwd=REPO, check=False)
        note('check:  curl -s 127.0.0.1:8899/health | jq ".patients_source, .patients_auth"   (expect "trakcare")')
        note("then open http://127.0.0.1:5901 and click the person icon next to Luna")


# ------------------------------------------------------- dev IRIS autopilot --
DEV_HOST = "http://127.0.0.1:52773"
DEV_MP_USER, DEV_MP_PASS = "_SYSTEM", "SYS"          # fhir-dev/iris.script un-expires these
DEV_FHIR_USER, DEV_FHIR_PASS = "luna_fhir", "lunapw"  # created by fhir-dev/iris.script
SHOT_DIR = REPO / ".playwright" / "shots"


def watch(page, title: str, body: str, seconds: float = 2.5) -> None:
    """Dev-mode stand-in for human(): show the same instruction, pause so the browser is visible, move on."""
    box("AUTOPILOT — " + title, body)
    time.sleep(seconds)


def shot(page, name: str) -> Path:
    SHOT_DIR.mkdir(parents=True, exist_ok=True)
    p = SHOT_DIR / f"{name}.png"
    try:
        page.screenshot(path=str(p), full_page=False)
    except Exception:  # noqa: BLE001
        pass
    return p


def auto_dev_iris(page, host: str) -> tuple[str, dict]:
    """Drive the compose `iris` container end to end with the known dev credentials.

    Same pages the human walkthrough visits (Management Portal login -> Web Applications ->
    Users), just with the typing done for you because the dev creds live in the repo.
    """
    box("Dev IRIS autopilot", f"Driving {host} with the credentials from fhir-dev/iris.script. Watch the browser.")
    # 1. Management Portal login
    goto(page, host + MP_HOME)
    user = page.locator('input[name="IRISUsername"], #IRISUsername').first
    if user.count():
        user.fill(DEV_MP_USER)
        page.locator('input[name="IRISPassword"], #IRISPassword').first.fill(DEV_MP_PASS)
        watch(page, "Sign in", f"Typing {DEV_MP_USER} / {DEV_MP_PASS} into the IRIS Management Portal login.", 1.5)
        page.keyboard.press("Enter")
        page.wait_for_load_state("domcontentloaded")
        time.sleep(1.5)
    if "login" in page.url.lower() or page.locator('input[name="IRISPassword"]').count():
        raise SystemExit(f"Management Portal login failed at {host} — is the iris container healthy?")
    note(f"signed in — {page.url}")
    shot(page, "01-portal-home")

    # 2. FHIR endpoint from the Web Applications list
    goto(page, host + MP_WEBAPPS)
    paths = scrape_fhir_paths(page)
    watch(page, "Find the FHIR web application",
          "System Administration > Security > Applications > Web Applications. FHIR endpoints found:\n  " + ("\n  ".join(paths) or "(none)"))
    shot(page, "02-web-applications")
    fhir_path = next((p for p in paths if "fhirserver" in p.lower()), paths[0] if paths else "/csp/healthshare/fhirserver/fhir/r4")
    fhir_url = host + fhir_path
    note(f"endpoint: {fhir_url}")

    # 3. Show the Basic-auth user the api container uses
    goto(page, host + MP_USERS)
    try:
        page.get_by_text(DEV_FHIR_USER, exact=True).first.scroll_into_view_if_needed(timeout=3000)
    except Exception:  # noqa: BLE001
        pass
    watch(page, "Credentials", f"System Administration > Security > Users — the roster authenticates as {DEV_FHIR_USER} (HTTP Basic). "
          "On a real TrakCare host you would instead register an OAuth 2.0 client under OAuth 2.0 > Server > Client Descriptions.")
    shot(page, "03-users")

    # 4. Show the OAuth server page too, so the TrakCare path is visible
    goto(page, host + MP_OAUTH_CLIENTS)
    watch(page, "OAuth 2.0 (TrakCare path)", "OAuth 2.0 > Server > Client Descriptions — empty on the dev server; this is where a TrakCare admin creates the client for Luna.")
    shot(page, "04-oauth-clients")

    creds = {"auth": "basic", "username": DEV_FHIR_USER, "password": DEV_FHIR_PASS, "verify_tls": True}
    return fhir_url, creds


# --------------------------------------------------------------------- main --
def _creds_from_env() -> tuple[str, dict]:
    import patients

    cfg = patients.load_config()
    return cfg.base_url, {"auth": cfg.auth, "client_id": cfg.client_id, "client_secret": cfg.client_secret,
                          "token_url": cfg.token_url, "scope": cfg.scope, "username": cfg.username,
                          "password": cfg.password, "api_key": cfg.api_key, "verify_tls": cfg.verify_tls}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default="", help="TrakCare / IRIS for Health base, e.g. https://trak-test.example.org")
    ap.add_argument("--from", dest="start", choices=STEPS, default="host", help="resume from this step")
    ap.add_argument("--dev-iris", action="store_true",
                    help=f"autopilot against the compose `iris` dev container (default host {DEV_HOST}); "
                         "no prompts, no .env change, screenshots in .playwright/shots/")
    a = ap.parse_args()
    start = STEPS.index(a.start)

    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        print("playwright missing. Run:  uv run --with playwright --with httpx python scripts/trakcare_fhir_setup.py")
        return 2

    if a.dev_iris:
        host = (a.host or DEV_HOST).rstrip("/")
        with sync_playwright() as pw:
            ctx, page = launch(pw)
            try:
                fhir_url, creds = auto_dev_iris(page, host)
            finally:
                note("leaving the browser open for 4 s…")
                time.sleep(4)
                ctx.close()
        box(".env (skipped)", f"Inside compose the api already points at http://iris:52773{urlsplit(fhir_url).path} "
                              f"with {DEV_FHIR_USER}/{DEV_FHIR_PASS} (compose.yml defaults), so .env is left untouched.\n"
                              f"For a host process instead:  FHIR_BASE_URL={fhir_url}  FHIR_AUTH=basic  "
                              f"FHIR_USERNAME={DEV_FHIR_USER}  FHIR_PASSWORD={DEV_FHIR_PASS}  FHIR_PROFILE=generic")
        cfg = step_verify(fhir_url, creds)
        box("Done", f"Dev IRIS verified: {cfg.base_url} (auth={cfg.auth}). Screenshots: {SHOT_DIR}\n"
                    "Roster in the UI at http://127.0.0.1:5901 shows source 'fhir · iris:52773'.")
        return 0

    box(
        "TrakCare FHIR access for the Luna roster",
        """
        A Chromium window will open on your TrakCare host's IRIS Management Portal. When this
        terminal shows a "YOUR TURN" box, do what it says in the browser, then press Enter here.
        I never type credentials or submit forms; secrets you paste are read without echo.
        """,
    )

    fhir_url, creds = "", {}
    if start >= STEPS.index("env"):
        # resuming after the browser part: take everything from .env (loaded by the shell / docker) or ask
        fhir_url, creds = _creds_from_env()
        if not fhir_url:
            fhir_url = ask("FHIR R4 base URL").rstrip("/")
            creds = {"auth": choose("Auth mode", [("oauth", ""), ("basic", ""), ("apikey", "")], "oauth")}
            if creds["auth"] == "oauth":
                creds.update(client_id=ask("Client ID"), client_secret=secret("Client secret"),
                             token_url=ask("Token endpoint (blank = discover)"), scope=ask("Scopes", DEFAULT_SCOPE))
            elif creds["auth"] == "basic":
                creds.update(username=ask("Username"), password=secret("Password"))
            else:
                creds.update(api_key=secret("API key"))
            creds["verify_tls"] = yes("Valid TLS certificate?", default=False)
    else:
        with sync_playwright() as pw:
            ctx, page = launch(pw)
            try:
                host = a.host.rstrip("/")
                if start <= STEPS.index("host"):
                    host = step_host(page, host)
                if not host:
                    host = ask("TrakCare / IRIS host URL").rstrip("/")
                if start <= STEPS.index("login"):
                    step_login(page, host)
                if start <= STEPS.index("endpoint"):
                    fhir_url = step_endpoint(page, host)
                else:
                    fhir_url = ask("FHIR R4 base URL", os.environ.get("FHIR_BASE_URL", "")).rstrip("/")
                creds = step_auth(page, host, fhir_url)
            finally:
                note("leaving the browser open for 5 s so you can see the final state…")
                time.sleep(5)
                ctx.close()

    if start <= STEPS.index("env"):
        step_env(fhir_url, creds)
    cfg = step_verify(fhir_url, creds)
    if start <= STEPS.index("seed"):
        step_seed(cfg)

    box("Done", f"FHIR_BASE_URL={cfg.base_url}\nFHIR_AUTH={cfg.auth}  (profile: {cfg.profile})\n"
                "Roster source will read 'trakcare' once the api container restarts.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
