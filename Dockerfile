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
    API_PORT=8899

# install the graphrag workspace + klein (cached unless deps change)
COPY pyproject.toml uv.lock ./
COPY packages ./packages
RUN uv sync --all-packages --no-dev \
 && uv pip install klein

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
    PORT=4000 \
    NCCN_API=http://api:8899 \
    MIX_INSTALL_DIR=/opt/mix-install

RUN mix local.hex --force && mix local.rebar --force

COPY nccn_ui ./nccn_ui

# pre-warm Mix.install so deps are fetched+compiled into the image (fast, offline startup)
RUN elixir -e 'Mix.install([{:phoenix, "~> 1.7.14"}, {:phoenix_live_view, "~> 1.0"}, {:bandit, "~> 1.5"}, {:req, "~> 0.5"}, {:jason, "~> 1.4"}])'

EXPOSE 4000
CMD ["elixir", "nccn_ui/nccn_ui.exs"]
