# NCCN Testicular Cancer — Phoenix LiveView UI (single-file, Mix.install)
#
# Frontend for the GraphRAG Klein backend. Run the backend first:
#   (repo root)  uv run --with klein python api/app.py           # :8899
# then this UI:
#   NCCN_API=http://127.0.0.1:8899 elixir nccn_ui/nccn_ui.exs    # :4000
#
# Styling: TailwindCSS via the browser CDN (no asset build step).

Application.put_env(:nccn, NccnUi.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT", "4000"))],
  server: true,
  adapter: Bandit.PhoenixAdapter,
  secret_key_base: String.duplicate("x", 64),
  live_view: [signing_salt: "nccn_salt_01"],
  pubsub_server: NccnUi.PubSub,
  check_origin: false,
  debug_errors: true,
  render_errors: [formats: [html: NccnUi.ErrorHTML]]
)

Mix.install([
  {:phoenix, "~> 1.7.14"},
  {:phoenix_live_view, "~> 1.0"},
  {:bandit, "~> 1.5"},
  {:req, "~> 0.5"},
  {:jason, "~> 1.4"}
])

defmodule NccnUi.ErrorHTML do
  def render(template, _assigns), do: Phoenix.Controller.status_message_from_template(template)
end

defmodule NccnUi.Layouts do
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en" class="h-full">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <title>NCCN Testicular Cancer — GraphRAG</title>
        <script src="https://cdn.tailwindcss.com?plugins=typography"></script>
        <script>
          tailwind.config = { theme: { extend: {
            fontFamily: { sans: ['ui-sans-serif','-apple-system','Segoe UI','Roboto','Helvetica','Arial','sans-serif'] }
          } } }
        </script>
        <style>
          .flowchart svg { max-width: 100%; height: auto; }
          ::-webkit-scrollbar { width: 9px; height: 9px; }
          ::-webkit-scrollbar-thumb { background: #cbd5e1; border-radius: 6px; }
        </style>
        <script src="/js/phoenix/phoenix.min.js"></script>
        <script src="/js/lv/phoenix_live_view.min.js"></script>
        <script>
          window.addEventListener("DOMContentLoaded", () => {
            const csrf = document.querySelector("meta[name=csrf-token]").getAttribute("content")
            const { Socket } = window.Phoenix
            const { LiveSocket } = window.LiveView
            const liveSocket = new LiveSocket("/live", Socket, { params: { _csrf_token: csrf } })
            liveSocket.connect()
            window.liveSocket = liveSocket
          })
        </script>
      </head>
      <body class="h-full bg-slate-100 text-slate-800 antialiased">
        {@inner_content}
      </body>
    </html>
    """
  end
end

defmodule NccnUi.HomeLive do
  use Phoenix.LiveView, layout: false

  @api System.get_env("NCCN_API", "http://127.0.0.1:8899")
  @pages [
    {"Workup", [{"TEST-1", "Workup & diagnosis"}]},
    {"Seminoma",
     [
       {"SEM-1", "Workup & clinical stage"}, {"SEM-2", "Stage IA / IB / IS"},
       {"SEM-3", "Stage IIA / IIB"}, {"SEM-4", "Stage IIC / III"},
       {"SEM-5", "Post first-line chemo"}, {"SEM-6", "Recurrence / 2nd-line"},
       {"SEM-7", "Post 2nd-line"}, {"SEM-8", "Third-line"}
     ]},
    {"Nonseminoma",
     [
       {"NSEM-1", "Workup & clinical stage"}, {"NSEM-2", "Stage I ± risk, IS"},
       {"NSEM-3", "Stage IIA / IIB"}, {"NSEM-4", "Post first-line chemo"},
       {"NSEM-5", "Postsurgical (pN0-3)"}, {"NSEM-6", "Advanced + brain mets"},
       {"NSEM-7", "Response after primary Tx"}, {"NSEM-8", "Recurrence / 2nd-line"},
       {"NSEM-9", "Post 2nd-line"}, {"NSEM-10", "Third-line"}
     ]}
  ]

  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       pages: @pages, method: "local", query: "", loading: false,
       answer: nil, evidence: nil, svg: nil, page: nil, error: nil
     )}
  end

  # ---- events ----
  def handle_event("method", %{"m" => m}, socket), do: {:noreply, assign(socket, method: m)}

  def handle_event("ask", %{"q" => q}, socket) do
    q = String.trim(q)
    if q == "" do
      {:noreply, socket}
    else
      method = socket.assigns.method
      socket = assign(socket, loading: true, query: q, error: nil, answer: nil)
      {:noreply, start_async(socket, :run, fn -> run_query(q, method) end)}
    end
  end

  def handle_event("page", %{"code" => code}, socket) do
    {:noreply, assign(socket, svg: fetch_flowchart(code, [], []), page: code)}
  end

  def handle_event("focus_edge", %{"src" => s, "tgt" => t, "page" => p}, socket) do
    {:noreply, assign(socket, svg: fetch_flowchart(p, [s, t], [[s, t]]), page: p)}
  end

  # ---- async result ----
  def handle_async(:run, {:ok, %{answer: a, svg: svg, page: page}}, socket) do
    {:noreply, assign(socket, loading: false, answer: a, evidence: a["evidence"], svg: svg, page: page)}
  end

  def handle_async(:run, {:exit, reason}, socket) do
    {:noreply, assign(socket, loading: false, error: "query failed: #{inspect(reason)}")}
  end

  # ---- backend calls ----
  defp run_query(q, method) do
    body =
      Req.post!("#{@api}/query",
        json: %{query: q, method: method},
        receive_timeout: 240_000,
        connect_options: [timeout: 10_000]
      ).body

    ev = body["evidence"] || %{}

    {svg, page} =
      case ev["primary_page"] do
        nil ->
          {nil, nil}

        pg ->
          clinical = Enum.filter(ev["edges"] || [], &(&1["kind"] == "clinical"))
          nodes =
            (Enum.flat_map(clinical, &[&1["source"], &1["target"]]) ++
               Enum.map(ev["nodes"] || [], & &1["title"]))
            |> Enum.uniq()
          edges = Enum.map(clinical, &[&1["source"], &1["target"]])
          {fetch_flowchart(pg, nodes, edges), pg}
      end

    %{answer: body, svg: svg, page: page}
  end

  defp fetch_flowchart(page, nodes, edges) do
    Req.post!("#{@api}/flowchart", json: %{page: page, nodes: nodes, edges: edges}).body
  end

  # ---- view helpers ----
  defp fmt(content) do
    content
    |> to_string()
    |> String.replace(~r/\[Data:[^\]]*\]/, "")
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
    |> String.replace(~r/\*\*(.+?)\*\*/, "<strong class=\"font-semibold text-slate-900\">\\1</strong>")
    |> Phoenix.HTML.raw()
  end

  defp clinical_edges(nil), do: []
  defp clinical_edges(ev), do: Enum.filter(ev["edges"] || [], &(&1["kind"] == "clinical"))
  defp nav_edges(nil), do: []
  defp nav_edges(ev), do: Enum.filter(ev["edges"] || [], &(&1["kind"] == "structural"))

  # ---- render ----
  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-screen">
      <div class="shrink-0 bg-amber-50 text-amber-800 text-xs px-4 py-2 border-b border-amber-200 flex items-center gap-2">
        <span class="text-sm">⚠</span>
        <span>Reference aid generated from NCCN Testicular Cancer v2.2026 via a lossy knowledge graph —
          <b class="font-semibold">not a substitute for the guideline or clinical judgment.</b></span>
      </div>

      <div class="grid grid-cols-[240px_minmax(380px,1fr)_minmax(400px,1.15fr)] flex-1 min-h-0">
        <!-- LEFT: nav -->
        <nav class="min-h-0 overflow-auto p-4 bg-white border-r border-slate-200">
          <h1 class="text-[13px] font-bold uppercase tracking-wider text-slate-400 mb-3">Protocols</h1>
          <%= for {group, items} <- @pages do %>
            <div class="text-[11px] font-semibold uppercase tracking-wider text-slate-400 mt-4 mb-1">{group}</div>
            <%= for {code, label} <- items do %>
              <a phx-click="page" phx-value-code={code}
                 class={["block px-2.5 py-1.5 rounded-md text-[13px] cursor-pointer transition-colors",
                         if(@page == code, do: "bg-purple-600 text-white shadow-sm",
                            else: "text-slate-600 hover:bg-purple-50 hover:text-purple-800")]}>
                <span class="font-semibold">{code}</span>
                <span class={if(@page == code, do: "text-purple-50", else: "text-slate-400")}> · {label}</span>
              </a>
            <% end %>
          <% end %>
        </nav>

        <!-- CENTER: ask + answer -->
        <main class="min-h-0 overflow-auto p-6 border-r border-slate-200 bg-slate-50/60">
          <form phx-submit="ask" class="space-y-3 bg-white rounded-xl border border-slate-200 shadow-sm p-4">
            <textarea name="q" rows="3"
              class="w-full rounded-lg border border-slate-300 p-3 text-sm placeholder:text-slate-400 focus:outline-none focus:ring-2 focus:ring-purple-500/40 focus:border-purple-400 resize-y"
              placeholder="e.g. After a brain scan, what should be done? · First-line chemo for advanced disease?"><%= @query %></textarea>
            <div class="flex items-center gap-3 flex-wrap">
              <div class="inline-flex rounded-full border border-slate-200 overflow-hidden text-[13px]">
                <button type="button" phx-click="method" phx-value-m="local"
                  class={["px-4 py-1.5 transition-colors", if(@method == "local", do: "bg-purple-600 text-white", else: "bg-white text-slate-500 hover:bg-slate-50")]}>Specific</button>
                <button type="button" phx-click="method" phx-value-m="global"
                  class={["px-4 py-1.5 transition-colors", if(@method == "global", do: "bg-purple-600 text-white", else: "bg-white text-slate-500 hover:bg-slate-50")]}>Thematic</button>
              </div>
              <span class="text-xs text-slate-500 flex-1 min-w-[180px]">
                <%= if @method == "local" do %>Entity-level — best for “what do I do for X”.<% else %>Map-reduce over community reports — broad questions.<% end %>
              </span>
              <button type="submit" disabled={@loading}
                class="ml-auto inline-flex items-center gap-2 bg-purple-600 hover:bg-purple-700 disabled:opacity-50 disabled:cursor-progress text-white font-semibold rounded-lg px-6 py-2 text-sm shadow-sm transition-colors">
                <%= if @loading do %>
                  <span class="w-3.5 h-3.5 border-2 border-white/70 border-t-transparent rounded-full animate-spin"></span>Asking…
                <% else %>Ask<% end %>
              </button>
            </div>
          </form>

          <div class="mt-5">
            <%= cond do %>
              <% @loading -> %>
                <div class="flex items-center gap-2 text-slate-500 italic p-6">
                  <span class="w-4 h-4 border-2 border-purple-500 border-t-transparent rounded-full animate-spin"></span>
                  Querying GraphRAG (<%= @method %>)… this can take ~30s.
                </div>
              <% @error -> %>
                <div class="p-4 rounded-lg bg-red-50 text-red-700 text-sm border border-red-200">Error: {@error}</div>
              <% @answer -> %>
                <article class="bg-white rounded-xl border border-slate-200 shadow-sm p-5">
                  <%= if @answer["title"] do %>
                    <h2 class="text-lg font-bold text-slate-900 mb-2">{@answer["title"]}</h2>
                  <% end %>
                  <%= for s <- @answer["sections"] do %>
                    <%= if s["content"] != "" or s["heading"] do %>
                      <section class="my-3 pl-3 border-l-2 border-purple-100">
                        <%= if s["heading"] do %>
                          <h3 class="text-[13.5px] font-semibold text-purple-700 mb-1">{s["heading"]}</h3>
                        <% end %>
                        <div class="whitespace-pre-wrap text-sm leading-relaxed text-slate-700">{fmt(s["content"])}</div>
                      </section>
                    <% end %>
                  <% end %>

                  <div class="mt-4 pt-3 border-t border-dashed border-slate-200">
                    <div class="flex items-center gap-2 text-xs text-slate-500 mb-2">
                      <span class="font-semibold text-slate-600">Evidence</span>
                      <span>· source page:</span>
                      <span class="inline-block bg-purple-50 text-purple-700 rounded px-2 py-0.5 font-semibold">{(@evidence && @evidence["primary_page"]) || "—"}</span>
                    </div>
                    <div class="flex flex-wrap gap-1.5">
                      <%= for e <- clinical_edges(@evidence) do %>
                        <button phx-click="focus_edge" phx-value-src={e["source"]} phx-value-tgt={e["target"]} phx-value-page={e["page"]}
                          title={"Relationship #{e["id"]} on #{e["page"]} — click to highlight"}
                          class="inline-flex items-center rounded-full border border-red-300 text-red-600 bg-red-50/40 hover:bg-red-50 text-[11px] px-2.5 py-0.5 cursor-pointer transition-colors">
                          {e["source"]} <span class="mx-1 opacity-60">→</span> {e["target"]}
                        </button>
                      <% end %>
                      <%= for n <- (@evidence && @evidence["nodes"]) || [] do %>
                        <span title={"Entity #{n["id"]}"} class="inline-flex items-center rounded-full border border-red-300 text-red-600 bg-red-50/40 text-[11px] px-2.5 py-0.5">{n["title"]}</span>
                      <% end %>
                    </div>
                    <%= if nav_edges(@evidence) != [] do %>
                      <div class="flex flex-wrap gap-1.5 mt-1.5">
                        <span class="text-[10px] uppercase tracking-wide text-slate-400 self-center">navigation:</span>
                        <%= for e <- nav_edges(@evidence) do %>
                          <span title={"structural edge #{e["id"]}"} class="inline-flex items-center rounded-full border border-slate-200 text-slate-400 text-[11px] px-2.5 py-0.5">{e["source"]} <span class="mx-1 opacity-50">→</span> {e["target"]}</span>
                        <% end %>
                      </div>
                    <% end %>
                    <%= if @answer["context"]["tables"] != %{} do %>
                      <div class="mt-2 text-[11px] text-slate-400">
                        context — <%= for {k, v} <- @answer["context"]["tables"] do %><span class="mr-2">{k}:<span class="text-slate-500 font-medium">{v}</span></span><% end %>
                      </div>
                    <% end %>
                  </div>
                </article>
              <% true -> %>
                <div class="text-slate-400 italic p-6 text-center border border-dashed border-slate-200 rounded-xl bg-white/50">
                  Ask a question, or pick a protocol on the left to view its flowchart.
                </div>
            <% end %>
          </div>
        </main>

        <!-- RIGHT: flowchart -->
        <section class="min-h-0 overflow-auto p-4 bg-white">
          <div class="flex items-center justify-between mb-3">
            <div class="text-sm font-semibold text-slate-700">
              Source flowchart
              <span class="ml-1 inline-block bg-purple-50 text-purple-700 rounded px-2 py-0.5 text-xs font-bold">{@page || "—"}</span>
            </div>
            <div class="text-[11px] text-slate-500"><span class="text-red-600 font-bold">▬ red</span> = cited path</div>
          </div>
          <div class="flowchart bg-slate-50 border border-slate-200 rounded-xl p-3 overflow-auto">
            <%= if @svg do %>
              {Phoenix.HTML.raw(@svg)}
            <% else %>
              <div class="text-slate-400 italic p-6 text-center">The cited pathway will be highlighted here.</div>
            <% end %>
          </div>
        </section>
      </div>
    </div>
    """
  end
end

defmodule NccnUi.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :protect_from_forgery
    plug :put_root_layout, html: {NccnUi.Layouts, :root}
    plug :put_layout, false
  end

  scope "/" do
    pipe_through :browser
    live "/", NccnUi.HomeLive
  end
end

defmodule NccnUi.Endpoint do
  use Phoenix.Endpoint, otp_app: :nccn

  @session_options [
    store: :cookie,
    key: "_nccn_key",
    signing_salt: "nccn_sign_1",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]]

  plug Plug.Static, at: "/js/phoenix", from: {:phoenix, "priv/static"}, only: ~w(phoenix.min.js)
  plug Plug.Static, at: "/js/lv", from: {:phoenix_live_view, "priv/static"}, only: ~w(phoenix_live_view.min.js)

  plug Plug.Session, @session_options
  plug NccnUi.Router
end

{:ok, _} =
  Supervisor.start_link(
    [{Phoenix.PubSub, name: NccnUi.PubSub}, NccnUi.Endpoint],
    strategy: :one_for_one
  )

IO.puts("\nNCCN LiveView UI on http://127.0.0.1:#{System.get_env("PORT", "4000")}  (backend: #{System.get_env("NCCN_API", "http://127.0.0.1:8899")})")
Process.sleep(:infinity)
