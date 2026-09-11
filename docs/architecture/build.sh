#!/usr/bin/env bash
# Rebuild the architecture deck: render every Graphviz diagram to SVG,
# then compile the Touying slides. Run from anywhere.
set -euo pipefail
cd "$(dirname "$0")"

for f in diagrams/*.dot; do
  dot -Tsvg "$f" -o "${f%.dot}.svg"
  echo "rendered ${f%.dot}.svg"
done

typst compile slides.typ nccn_graphrag_slides.pdf
echo "compiled nccn_graphrag_slides.pdf"
