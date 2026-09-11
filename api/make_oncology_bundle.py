#!/usr/bin/env python
"""Build (and optionally upload) a FHIR R4 transaction Bundle of synthetic oncology patients.

The bundle mirrors ``patients.MOCK_PATIENTS`` so a FHIR sandbox loaded with it
shows the same 11 patients as the built-in mock roster, one or more per NCCN
guideline (breast, prostate, colon, NSCLC, testicular). Each patient gets:

    Patient    - official name, MRN identifier (type MR), gender, birthDate
    Condition  - ICD-10-CM + SNOMED codings, clinicalStatus=active,
                 category=encounter-diagnosis, stage.summary, onsetDateTime
    Encounter  - finished ambulatory oncology visit on the last_encounter date

References use ``urn:uuid:`` placeholders with POST requests, so the server
assigns ids and rewrites the references - the most portable transaction shape.

Usage:
    uv run python api/make_oncology_bundle.py                 # writes api/oncology_patients_bundle.json
    uv run python api/make_oncology_bundle.py --upload        # also POSTs it using the FHIR_* env
                                                              #   (same settings as the API; see patients.py)
    uv run python api/make_oncology_bundle.py --upload --url https://trak/csp/healthshare/trakitkit/fhir/r4 \\
        --client-id luna --client-secret ... [--no-verify-tls]
    uv run python api/make_oncology_bundle.py --upload --url https://fhir.<id>.static-test-account.isccloud.io --api-key <key>

All names are obviously synthetic; no real patient data is involved.
"""

from __future__ import annotations

import argparse
import json
import sys
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import patients  # noqa: E402
from patients import GUIDELINE_MAP, MOCK_PATIENTS  # noqa: E402

OUT = Path(__file__).resolve().parent / "oncology_patients_bundle.json"
NS = uuid.UUID("6f1c2a7e-0000-4000-8000-00000000c0de")  # stable namespace -> deterministic uuids

ICD10 = "http://hl7.org/fhir/sid/icd-10-cm"
SNOMED = "http://snomed.info/sct"
SNOMED_DISPLAY = {
    "breast": "Malignant neoplasm of breast (disorder)",
    "prostate": "Malignant tumor of prostate (disorder)",
    "colon": "Malignant tumor of colon (disorder)",
    "nsclc": "Non-small cell lung cancer (disorder)",
    "testicular": "Malignant tumor of testis (disorder)",
}
_SNOMED_CODE = {key: sorted(codes)[0] for key, _icd, codes, _kw in GUIDELINE_MAP}


def _uuid(*parts: str) -> str:
    return f"urn:uuid:{uuid.uuid5(NS, '/'.join(parts))}"


def _split_name(full: str) -> tuple[list[str], str]:
    parts = full.split()
    return parts[:-1], parts[-1]


def _onset(p: dict) -> str:
    # deterministic: a few months before the last encounter, same day-of-month
    y, m, d = (int(x) for x in p["last_encounter"].split("-"))
    m -= 4
    if m <= 0:
        m += 12
        y -= 1
    return f"{y:04d}-{m:02d}-{min(d, 28):02d}"


def patient_resource(p: dict) -> dict:
    given, family = _split_name(p["name"])
    return {
        "resourceType": "Patient",
        "identifier": [{
            "use": "usual",
            "type": {"coding": [{"system": "http://terminology.hl7.org/CodeSystem/v2-0203", "code": "MR", "display": "Medical record number"}]},
            "system": "urn:nccn-demo:mrn",
            "value": p["mrn"],
        }],
        "active": True,
        "name": [{"use": "official", "family": family, "given": given, "text": p["name"]}],
        "gender": p["sex"],
        "birthDate": p["birth_date"],
    }


def condition_resource(p: dict, patient_ref: str, encounter_ref: str) -> dict:
    key = p["guideline"]
    codings = [{"system": ICD10, "code": p["diagnosis_code"], "display": p["diagnosis"]}]
    if key in _SNOMED_CODE:
        codings.append({"system": SNOMED, "code": _SNOMED_CODE[key], "display": SNOMED_DISPLAY[key]})
    stage = p["stage"]
    return {
        "resourceType": "Condition",
        "clinicalStatus": {"coding": [{"system": "http://terminology.hl7.org/CodeSystem/condition-clinical", "code": "active"}]},
        "verificationStatus": {"coding": [{"system": "http://terminology.hl7.org/CodeSystem/condition-ver-status", "code": "confirmed"}]},
        "category": [{"coding": [{"system": "http://terminology.hl7.org/CodeSystem/condition-category", "code": "encounter-diagnosis", "display": "Encounter Diagnosis"}]}],
        "code": {"coding": codings, "text": p["diagnosis"]},
        "subject": {"reference": patient_ref, "display": p["name"]},
        "encounter": {"reference": encounter_ref},
        "onsetDateTime": _onset(p),
        "recordedDate": _onset(p),
        "stage": [{"summary": {"text": f"Stage {stage}" if stage and stage[0] in "0IV" else stage}}],
    }


def encounter_resource(p: dict, patient_ref: str) -> dict:
    day = p["last_encounter"]
    return {
        "resourceType": "Encounter",
        "status": "finished",
        "class": {"system": "http://terminology.hl7.org/CodeSystem/v3-ActCode", "code": "AMB", "display": "ambulatory"},
        "type": [{"coding": [{"system": SNOMED, "code": "185347001", "display": "Encounter for problem (procedure)"}], "text": "Oncology follow-up"}],
        "serviceType": {"coding": [{"system": "http://terminology.hl7.org/CodeSystem/service-type", "code": "165", "display": "Cancer Services"}]},
        "subject": {"reference": patient_ref, "display": p["name"]},
        "period": {"start": f"{day}T09:00:00Z", "end": f"{day}T09:45:00Z"},
    }


def build_bundle() -> dict:
    entries = []
    for p in MOCK_PATIENTS:
        pat_url, enc_url, cond_url = _uuid(p["id"], "Patient"), _uuid(p["id"], "Encounter"), _uuid(p["id"], "Condition")
        entries.append({"fullUrl": pat_url, "resource": patient_resource(p), "request": {"method": "POST", "url": "Patient"}})
        entries.append({"fullUrl": enc_url, "resource": encounter_resource(p, pat_url), "request": {"method": "POST", "url": "Encounter"}})
        entries.append({"fullUrl": cond_url, "resource": condition_resource(p, pat_url, enc_url), "request": {"method": "POST", "url": "Condition"}})
    return {"resourceType": "Bundle", "type": "transaction", "entry": entries}


def upload(bundle: dict, cfg: patients.Config, skip_if_populated: bool = False) -> None:
    """POST the transaction Bundle to the FHIR base using the roster client's auth (OAuth/Basic/API key)."""
    with patients.make_client(cfg) as c:
        c.timeout = 60.0
        if skip_if_populated:
            n = c.get(f"{cfg.base_url}/Patient", params={"_summary": "count"})
            total = n.json().get("total", 0) if n.status_code == 200 else 0
            if total:
                print(f"{cfg.host} already holds {total} Patient resources; skipping upload")
                return
        r = c.post(cfg.base_url, json=bundle, headers={"Content-Type": "application/fhir+json"})
        if r.status_code >= 300:
            print(f"upload failed: HTTP {r.status_code}\n{r.text[:1500]}", file=sys.stderr)
            raise SystemExit(1)
        resp = r.json()
        statuses = [e.get("response", {}).get("status", "?") for e in resp.get("entry", [])]
        ok = sum(1 for s in statuses if s.startswith("2"))
        print(f"uploaded to {cfg.host} ({cfg.source_label}, auth={cfg.auth}): {ok}/{len(statuses)} entries accepted (HTTP {r.status_code})")
        n = c.get(f"{cfg.base_url}/Patient", params={"_summary": "count"}).json().get("total")
        print(f"server now reports {n} Patient resources")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", type=Path, default=OUT)
    ap.add_argument("--upload", action="store_true", help="POST the bundle to the FHIR server")
    ap.add_argument("--url", help="FHIR R4 base URL (default $FHIR_BASE_URL / $INTELLICARE_FHIR_URL)")
    ap.add_argument("--auth", choices=["auto", "oauth", "basic", "apikey", "none"], help="default $FHIR_AUTH or auto")
    ap.add_argument("--client-id", help="OAuth 2.0 client id (default $FHIR_CLIENT_ID)")
    ap.add_argument("--client-secret", help="OAuth 2.0 client secret (default $FHIR_CLIENT_SECRET)")
    ap.add_argument("--token-url", help="OAuth token endpoint (default: discovered)")
    ap.add_argument("--username", help="HTTP Basic user (default $FHIR_USERNAME)")
    ap.add_argument("--password", help="HTTP Basic password (default $FHIR_PASSWORD)")
    ap.add_argument("--api-key", help="x-api-key for FHIRaaS (default $FHIR_API_KEY / $INTELLICARE_API_KEY)")
    ap.add_argument("--no-verify-tls", action="store_true", help="accept self-signed certificates")
    ap.add_argument("--skip-if-populated", action="store_true", help="do nothing if the server already has Patient resources")
    a = ap.parse_args()

    bundle = build_bundle()
    a.out.write_text(json.dumps(bundle, indent=2) + "\n")
    kinds = {}
    for e in bundle["entry"]:
        kinds[e["resource"]["resourceType"]] = kinds.get(e["resource"]["resourceType"], 0) + 1
    print(f"wrote {a.out}  ({len(bundle['entry'])} entries: {kinds})")

    if a.upload:
        cfg = patients.load_config(
            base_url=a.url, auth=a.auth, client_id=a.client_id, client_secret=a.client_secret,
            token_url=a.token_url, username=a.username, password=a.password, api_key=a.api_key,
            verify_tls=False if a.no_verify_tls else None,
        )
        if not cfg.base_url:
            print("--upload needs --url or FHIR_BASE_URL", file=sys.stderr)
            return 2
        upload(bundle, cfg, skip_if_populated=a.skip_if_populated)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
