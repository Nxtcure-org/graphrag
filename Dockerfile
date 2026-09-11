# syntax=docker/dockerfile:1
# Multi-stage build for the NCCN GraphRAG demo.
#   target `api` — Python/Klein backend (GraphRAG query + graphviz flowchart rendering)
#   target `ui`  — Elixir/Phoenix LiveView frontend (Luna)
# Build/run both via compose.yml.

# ============================ API (Python) ============================
FROM ghcr.io/astral-sh/uv:python3.11-bookworm-slim AS api

# graphviz `dot` is required to render/parse the flowcharts
RUN apt-get update \
 && apt-get install -y --no-install-recommends graphviz \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
ENV UV_LINK_MODE=copy \
    UV_COMPILE_BYTECODE=1 \
    API_HOST=0.0.0.0 \
    API_PORT=8899 \
    FHIR_BASE_URL="" \
    FHIR_AUTH=auto \
    FHIR_VERIFY_TLS=true

# install the graphrag workspace + klein (cached unless deps change)
COPY pyproject.toml uv.lock ./
COPY packages ./packages
RUN uv sync --all-packages --no-dev \
 && uv pip install klein httpx

# application code
COPY api ./api

# graphviz sources (one dir per guideline)
COPY nccn_graphs        ./nccn_graphs
COPY nccn_graphs_breast   ./nccn_graphs_breast
COPY nccn_graphs_prostate ./nccn_graphs_prostate
COPY nccn_graphs_colon    ./nccn_graphs_colon
COPY nccn_graphs_nsclc    ./nccn_graphs_nsclc

# indexed GraphRAG projects (settings + prompts + output parquet + lancedb)
COPY nccn_graphrag          ./nccn_graphrag
COPY nccn_graphrag_breast   ./nccn_graphrag_breast
COPY nccn_graphrag_prostate ./nccn_graphrag_prostate
COPY nccn_graphrag_colon    ./nccn_graphrag_colon
COPY nccn_graphrag_nsclc    ./nccn_graphrag_nsclc

EXPOSE 8899
CMD [".venv/bin/python", "api/app.py"]

# ============================ UI (Elixir) ============================
FROM elixir:1.18 AS ui

WORKDIR /app
ENV HTTP_IP=0.0.0.0 \
    PORT=5901 \
    NCCN_API=http://api:8899 \
    MIX_INSTALL_DIR=/opt/mix-install

RUN mix local.hex --force && mix local.rebar --force

COPY nccn_ui ./nccn_ui

# pre-warm Mix.install so deps are fetched+compiled into the image (fast, offline startup)
RUN elixir -e 'Mix.install([{:phoenix, "~> 1.7.14"}, {:phoenix_live_view, "~> 1.0"}, {:bandit, "~> 1.5"}, {:req, "~> 0.5"}, {:jason, "~> 1.4"}])'

EXPOSE 5901
CMD ["elixir", "nccn_ui/nccn_ui.exs"]

# ================= IRIS for Health Community (dev FHIR server) =================
# Stand-in for a TrakCare host: same IRIS for Health FHIR repository, Management Portal
# and OAuth server that TrakCare's FHIR layer runs on. fhir-dev/iris.script provisions a
# FHIR R4 endpoint at /csp/healthshare/fhirserver/fhir/r4 and a Basic-auth dev user at
# image build time, so the container starts ready. DEV ONLY (fixed passwords, %All role).
FROM intersystemsdc/irishealth-community:latest AS iris

USER root
COPY fhir-dev/iris.script /tmp/iris.script
RUN chown ${ISC_PACKAGE_MGRUSER}:${ISC_PACKAGE_IRISGROUP} /tmp/iris.script
USER ${ISC_PACKAGE_MGRUSER}

RUN iris start IRIS \
 && iris session IRIS < /tmp/iris.script \
 && iris stop IRIS quietly

# The community image's entrypoint runs a one-time "iris-after-start" init (create namespace via
# embedded-Python dbapi) unless this marker exists. Provisioning is already done above, and that
# init hook crashes the container on this image, so mark the instance as initialized.
RUN date > ${ISC_PACKAGE_INSTALLDIR}/iris.init

EXPOSE 52773 1972
