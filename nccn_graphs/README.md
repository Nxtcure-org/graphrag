# NCCN Testicular Cancer v2.2026 — Graphviz protocol diagrams

Flowchart renderings of the treatment algorithms from the NCCN Clinical Practice
Guidelines in Oncology, *Testicular Cancer, Version 2.2026 (June 16, 2026)*,
built from the algorithm pages (TEST-1, SEM-1…8, NSEM-1…10) plus the risk table (TEST-D).

> Derived for personal/clinical comprehension of the decision logic. These are a
> lossy simplification — footnotes and category-of-evidence nuances are abbreviated.
> **Always consult the source guideline for clinical decisions.** The NCCN content
> is copyrighted; do not redistribute.

## Files

| File | Protocol |
|------|----------|
| `00_overview.dot` | Master map: how all pages connect + legend |
| `TEST-1_workup.dot` | Suspicious mass → workup → orchiectomy → histology split |
| `SEM-1_stage.dot` | Pure seminoma: postdiagnostic workup & clinical stage |
| `SEM-2_stageIA-IB-IS.dot` | Seminoma stage IA/IB and IS |
| `SEM-3_stageIIA-IIB.dot` | Seminoma stage IIA/IIB (incl. RPLND pN0–pN3) |
| `SEM-4_stageIIC-III.dot` | Seminoma stage IIC/III (good/intermediate risk) |
| `SEM-5_post-first-line.dot` | Seminoma post first-line chemo management |
| `SEM-6_recurrence-second-line.dot` | Seminoma recurrence / second-line |
| `SEM-7_post-second-line.dot` | Seminoma post second-line management |
| `SEM-8_third-line.dot` | Seminoma third-line therapy |
| `NSEM-1_stage.dot` | Nonseminoma: workup & clinical stage |
| `NSEM-2_stageI-IS.dot` | Nonseminoma stage I ± risk factors, IS |
| `NSEM-3_stageIIA-IIB.dot` | Nonseminoma stage IIA/IIB |
| `NSEM-4_post-first-line.dot` | Nonseminoma post first-line chemo (stage II) |
| `NSEM-5_postsurgical.dot` | Nonseminoma postsurgical mgmt (pN0–pN3) |
| `NSEM-6_advanced.dot` | Nonseminoma advanced disease (by risk) + brain mets |
| `NSEM-7_response-partial.dot` | Nonseminoma response after primary treatment |
| `NSEM-8_recurrence-second-line.dot` | Nonseminoma recurrence / second-line |
| `NSEM-9_post-second-line.dot` | Nonseminoma post second-line management |
| `NSEM-10_third-line.dot` | Nonseminoma third-line therapy |
| `TEST-D_risk-classification.dot` | IGCCCG risk classification table |

## Rendering

```sh
# one file
dot -Tsvg SEM-3_stageIIA-IIB.dot -o SEM-3_stageIIA-IIB.svg

# all files to SVG
for f in *.dot; do dot -Tsvg "$f" -o "${f%.dot}.svg"; done

# high-res PNG
dot -Tpng -Gdpi=150 00_overview.dot -o 00_overview.png
```

## Color legend

- **Blue** — workup / entry point
- **Green** — diagnosis, clinical stage, treatment
- **Yellow (diamond)** — decision / branch point (stage, marker status, histology)
- **Gray** — management / follow-up
- **Red (light)** — recurrence / second-line
- **Red (dark)** — third-line / salvage
- **Tan, dashed** — reference to another page (TEST-A/B/D/E/F/G) or follow-up table

## Regimen abbreviations

- **BEP** = Bleomycin / Etoposide / Cisplatin
- **EP** = Etoposide / Cisplatin
- **VIP** = Etoposide / Ifosfamide / Cisplatin
- **TIP** = Paclitaxel / Ifosfamide / Cisplatin
- **VeIP** = Vinblastine / Ifosfamide / Cisplatin
