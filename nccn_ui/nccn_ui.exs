# Luna — AI Physician Agent · NCCN Testicular Cancer workflow copilot
# Phoenix LiveView (single-file, Mix.install). Backend: api/app.py on :8899.
#   uv run --with klein python api/app.py
#   NCCN_API=http://127.0.0.1:8899 elixir nccn_ui/nccn_ui.exs   → http://127.0.0.1:4000

Application.put_env(:nccn, NccnUi.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT", "4000"))],
  server: true,
  adapter: Bandit.PhoenixAdapter,
  secret_key_base: String.duplicate("x", 64),
  live_view: [signing_salt: "nccn_salt_01"],
  pubsub_server: NccnUi.PubSub,
  check_origin: false,
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
        <title>Luna · AI Physician Agent</title>
        <script src="https://cdn.tailwindcss.com"></script>
        <script src="https://cdn.jsdelivr.net/npm/dagre@0.8.5/dist/dagre.min.js"></script>
        <script src="https://cdn.jsdelivr.net/npm/cytoscape@3.30.2/dist/cytoscape.min.js"></script>
        <script src="https://cdn.jsdelivr.net/npm/cytoscape-dagre@2.5.0/cytoscape-dagre.js"></script>
        <style>
          ::-webkit-scrollbar{width:8px;height:8px}::-webkit-scrollbar-thumb{background:#cbd5e1;border-radius:6px}
          @keyframes lunaPulse{0%,100%{box-shadow:0 0 30px -4px rgba(139,92,246,.6)}50%{box-shadow:0 0 46px 2px rgba(139,92,246,.35)}}
          .luna-glow{animation:lunaPulse 3.4s ease-in-out infinite}
          @keyframes fadeUp{from{opacity:0;transform:translateY(6px)}to{opacity:1;transform:none}}
          .fade-up{animation:fadeUp .35s ease both}
          @keyframes orbit{to{transform:rotate(360deg)}}
          .orbit{transform-origin:center;animation:orbit 14s linear infinite}
          .cy-step{position:absolute;bottom:10px;left:10px;font-size:11px;color:#64748b;background:rgba(255,255,255,.8);border:1px solid #e2e8f0;border-radius:999px;padding:3px 10px;backdrop-filter:blur(4px)}
        </style>
        <script src="/js/phoenix/phoenix.min.js"></script>
        <script src="/js/lv/phoenix_live_view.min.js"></script>
        <script>
          const TYPE_BG={Workup:'#dbeafe',Treatment:'#dcfce7',Decision:'#fef9c3',Management:'#e2e8f0',Recurrence:'#fee2e2',Salvage:'#fecaca',Reference:'#ede9fe','Protocol Page':'#f3e8ff',Step:'#f1f5f9'};
          const TYPE_BD={Workup:'#60a5fa',Treatment:'#4ade80',Decision:'#facc15',Management:'#94a3b8',Recurrence:'#f87171',Salvage:'#ef4444',Reference:'#a78bfa','Protocol Page':'#c084fc',Step:'#cbd5e1'};
          const STYLE=[
            {selector:'node',style:{'label':'data(label)','text-wrap':'wrap','text-max-width':158,'font-size':10,'font-family':'ui-sans-serif,system-ui','text-valign':'center','text-halign':'center','color':'#0f172a','background-color':(e)=>TYPE_BG[e.data('type')]||'#f1f5f9','border-width':1.5,'border-color':(e)=>TYPE_BD[e.data('type')]||'#e2e8f0','shape':'data(shape)','width':'label','height':'label','padding':'11px','transition-property':'border-width,border-color,background-color,opacity','transition-duration':'260ms'}},
            {selector:'node[type="Decision"]',style:{'shape':'diamond','background-color':'#fef9c3','border-color':'#eab308','border-width':2,'padding':'16px'}},
            {selector:'node[?hl]',style:{'border-width':3.5,'border-color':'#8b5cf6','background-color':'#f5f3ff','color':'#3b0764','font-weight':'bold','overlay-color':'#a855f7','overlay-opacity':0.16,'overlay-padding':11,'z-index':30}},
            {selector:'node.sel',style:{'border-width':4,'border-color':'#4f46e5','overlay-color':'#6366f1','overlay-opacity':0.14,'overlay-padding':12,'z-index':40}},
            {selector:'edge',style:{'width':1.5,'line-color':'#cbd5e1','target-arrow-color':'#cbd5e1','target-arrow-shape':'triangle','curve-style':'bezier','arrow-scale':0.9,'label':'data(label)','font-size':8,'color':'#64748b','text-background-color':'#fff','text-background-opacity':0.92,'text-background-padding':2,'text-rotation':'autorotate','transition-property':'line-color,width,opacity','transition-duration':'260ms'}},
            {selector:'edge[?hl]',style:{'width':4,'line-color':'#8b5cf6','target-arrow-color':'#8b5cf6','line-style':'dashed','line-dash-pattern':[9,5],'color':'#7c3aed','font-weight':'bold','z-index':21}},
            {selector:'.faded',style:{'opacity':0.14}},
            {selector:'.stephide',style:{'opacity':0,'events':'no'}},
          ];
          const Hooks={};
          Hooks.Cyto={
            mounted(){
              if(window.cytoscapeDagre){try{cytoscape.use(window.cytoscapeDagre)}catch(_){}}
              const cy=cytoscape({container:this.el,style:STYLE,wheelSensitivity:0.25,minZoom:0.15,maxZoom:2.8,layout:{name:'grid'}});
              this.cy=cy;window.cy=cy;this.step=0;this.max=0;this.auto=false;
              const badge=document.createElement('div');badge.className='cy-step';this.el.appendChild(badge);this.badge=badge;
              const upd=()=>{badge.textContent=this.auto?'full pathway':('step '+Math.min(this.step+1,this.max+1)+' / '+(this.max+1))};
              this.reveal=()=>{cy.batch(()=>{cy.nodes().forEach(n=>{const o=n.data('ord')||0;(this.auto||o<=this.step)?n.removeClass('stephide'):n.addClass('stephide')});cy.edges().forEach(ed=>{(!ed.source().hasClass('stephide')&&!ed.target().hasClass('stephide'))?ed.removeClass('stephide'):ed.addClass('stephide')})});upd()};
              window.cyStep=(d)=>{this.auto=false;this.step=Math.max(0,Math.min(this.max,this.step+d));this.reveal();cy.animate({fit:{eles:cy.elements(':visible'),padding:45}},{duration:300})};
              window.cyAll=()=>{this.auto=true;this.reveal();cy.animate({fit:{padding:45}},{duration:300})};
              window.cyFit=()=>cy.animate({fit:{eles:cy.elements(':visible'),padding:45}},{duration:300});
              window.cyZoom=(f)=>cy.zoom({level:Math.min(2.8,Math.max(0.15,cy.zoom()*f)),renderedPosition:{x:cy.width()/2,y:cy.height()/2}});
              cy.on('tap','node',(e)=>{const n=e.target;cy.nodes().removeClass('sel');n.addClass('sel');const nb=n.closedNeighborhood();cy.elements().addClass('faded');nb.removeClass('faded');this.pushEvent('node_click',{id:n.id(),title:n.data('title'),type:n.data('type')})});
              cy.on('tap',(e)=>{if(e.target===cy){cy.elements().removeClass('faded');cy.nodes().removeClass('sel')}});
              this.handleEvent('graph',(g)=>this.render(g));
              this.dash=0;const flow=()=>{this.dash-=0.9;if(this.cy)this.cy.edges('[?hl]').style('line-dash-offset',this.dash);this.raf=requestAnimationFrame(flow)};flow();
              this.pushEvent('cy_ready',{});
            },
            render(g){
              const cy=this.cy;
              cy.batch(()=>{cy.elements().remove();cy.add((g.nodes||[]).concat(g.edges||[]))});
              this.max=cy.nodes().length?Math.max(...cy.nodes().map(n=>n.data('ord')||0)):0;
              this.auto=!!g.autoReveal;this.step=this.auto?this.max:0;
              cy.layout({name:'dagre',rankDir:'TB',nodeSep:28,rankSep:60,edgeSep:8,animate:true,animationDuration:460,fit:true,padding:45}).run();
              setTimeout(()=>this.reveal(),40);
            },
            destroyed(){if(this.raf)cancelAnimationFrame(this.raf)}
          };
          window.addEventListener("DOMContentLoaded",()=>{
            const csrf=document.querySelector("meta[name=csrf-token]").getAttribute("content");
            const {Socket}=window.Phoenix;const {LiveSocket}=window.LiveView;
            const liveSocket=new LiveSocket("/live",Socket,{params:{_csrf_token:csrf},hooks:Hooks});
            liveSocket.connect();window.liveSocket=liveSocket;
          });
        </script>
      </head>
      <body class="h-full bg-gradient-to-br from-slate-50 via-white to-violet-50/50 text-slate-800 antialiased">
        {@inner_content}
      </body>
    </html>
    """
  end
end

defmodule NccnUi.HomeLive do
  use Phoenix.LiveView, layout: false

  @api System.get_env("NCCN_API", "http://127.0.0.1:8899")
  @legend [{"Workup", "#dbeafe"}, {"Decision", "#fef9c3"}, {"Treatment", "#dcfce7"}, {"Recurrence", "#fee2e2"}, {"Salvage", "#fecaca"}]
  @suggestions ["Initial staging workup", "Advanced disease chemotherapy", "What to do after a brain scan", "Recurrence & second-line options"]
  @pages_flat ~w(TEST-1 SEM-1 SEM-2 SEM-3 SEM-4 SEM-5 SEM-6 SEM-7 SEM-8 NSEM-1 NSEM-2 NSEM-3 NSEM-4 NSEM-5 NSEM-6 NSEM-7 NSEM-8 NSEM-9 NSEM-10)
  # Grounded workup checklist template (from NCCN TEST-1 / SEM-1 / NSEM-1 + staging + MDT)
  @todo_template [
    {"Patient & clinical", [{"History and physical (H&P)", "Clinician"}, {"Chemistry profile (baseline gonadal fn)", "Lab"}]},
    {"Serum tumor markers", [{"Alpha-fetoprotein (AFP)", "Lab"}, {"Beta-hCG (quantitative)", "Lab"}, {"Lactate dehydrogenase (LDH)", "Lab"}]},
    {"Imaging", [{"Scrotal ultrasound", "Radiology"}, {"Abdomen/pelvis CT or MRI", "Radiology"}, {"Chest x-ray / chest CT if indicated", "Radiology"}, {"Brain MRI if clinically indicated", "Radiology"}]},
    {"Pathology", [{"Radical inguinal orchiectomy specimen", "Pathology"}, {"Histology: seminoma vs NSGCT", "Pathology"}]},
    {"Staging & review", [{"Post-orchiectomy marker nadir", "Clinician"}, {"AJCC TNM + risk (TEST-D)", "Clinician"}, {"Multidisciplinary review", "Tumor board"}]},
    {"Fertility", [{"Discuss sperm banking", "Clinician"}]}
  ]

  def mount(_params, _session, socket) do
    hello = %{role: "luna", text: "I'm Luna — your clinical copilot.", sub: "Ask about staging, workup, treatment or recurrence. I'll walk the pathway step by step on the right."}

    todos =
      for {grp, items} <- @todo_template, {label, party} <- items do
        %{group: grp, label: label, party: party, status: "pending"}
      end

    {:ok,
     assign(socket,
       legend: @legend, suggestions: @suggestions, pages: @pages_flat,
       method: "local", loading: false, error: nil, messages: [hello],
       page: nil, page_label: nil, track: "—", status: "Reference",
       evidence: nil, sections: [], graph: nil, selected: nil,
       tab: "todo", todos: todos, history: []
     )}
  end

  # ---------------- events ----------------
  def handle_event("cy_ready", _p, socket) do
    code = socket.assigns.page || "TEST-1"
    g = graph_for(code, [], [], false)
    {:noreply, socket |> assign(graph: g) |> put_stage(code, g) |> push_event("graph", g)}
  end

  def handle_event("method", %{"m" => m}, socket), do: {:noreply, assign(socket, method: m)}
  def handle_event("tab", %{"t" => t}, socket), do: {:noreply, assign(socket, tab: t)}

  def handle_event("page", %{"code" => code}, socket) do
    g = graph_for(code, [], [], false)
    {:noreply,
     socket
     |> assign(graph: g)
     |> put_stage(code, g)
     |> log(%{page: code, hln: [], hle: [], label: g["label"], kind: "browse"})
     |> luna("Opened #{code}.", g["label"])
     |> push_event("graph", g)}
  end

  def handle_event("suggest", %{"q" => q}, socket), do: do_ask(q, socket)
  def handle_event("ask", %{"q" => q}, socket), do: do_ask(String.trim(q), socket)

  def handle_event("todo_toggle", %{"i" => i}, socket) do
    i = String.to_integer(i)
    todos = List.update_at(socket.assigns.todos, i, fn t ->
      %{t | status: if(t.status == "complete", do: "pending", else: "complete")}
    end)
    {:noreply, assign(socket, todos: todos)}
  end

  def handle_event("node_click", %{"id" => id, "title" => title, "type" => type}, socket) do
    {:noreply, assign(socket, selected: node_detail(socket.assigns.graph, id, title, type), tab: "detail")}
  end

  def handle_event("restore", %{"i" => i}, socket) do
    entry = Enum.at(Enum.reverse(socket.assigns.history), String.to_integer(i))
    if entry do
      g = graph_for(entry.page, entry.hln, entry.hle, entry.hln != [])
      {:noreply, socket |> assign(graph: g) |> put_stage(entry.page, g) |> luna("↩ Restored: #{entry.label}", nil) |> push_event("graph", g)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("focus_edge", %{"src" => s, "tgt" => t, "page" => p}, socket) do
    g = graph_for(p, [s, t], [[s, t]], true)
    {:noreply, socket |> assign(graph: g) |> put_stage(p, g) |> push_event("graph", g)}
  end

  defp do_ask("", socket), do: {:noreply, socket}

  defp do_ask(q, socket) do
    method = socket.assigns.method
    msgs = socket.assigns.messages ++ [%{role: "user", text: q, sub: nil}]
    {:noreply,
     socket
     |> assign(loading: true, error: nil, messages: msgs, status: "Analyzing")
     |> start_async(:run, fn -> run_query(q, method) end)}
  end

  # ---------------- async ----------------
  def handle_async(:run, {:ok, res}, socket) do
    socket = assign(socket, loading: false, messages: socket.assigns.messages ++ [res.msg], sections: res.sections, evidence: res.evidence)

    socket =
      if res.graph do
        socket
        |> assign(graph: res.graph, status: "Active guidance")
        |> put_stage(res.page, res.graph)
        |> log(%{page: res.page, hln: res.hln, hle: res.hle, label: res.label, kind: "query"})
        |> push_event("graph", res.graph)
      else
        assign(socket, status: "Reference")
      end

    {:noreply, socket}
  end

  def handle_async(:run, {:exit, reason}, socket) do
    {:noreply, socket |> assign(loading: false, status: "Error") |> luna("Something went wrong.", inspect(reason))}
  end

  # ---------------- backend ----------------
  defp run_query(q, method) do
    body = Req.post!("#{@api}/query", json: %{query: q, method: method}, receive_timeout: 240_000, connect_options: [timeout: 10_000]).body
    ev = body["evidence"] || %{}
    page = ev["primary_page"]
    clinical = Enum.filter(ev["edges"] || [], &(&1["kind"] == "clinical"))
    hln = Enum.uniq(Enum.flat_map(clinical, &[&1["source"], &1["target"]]) ++ Enum.map(ev["nodes"] || [], & &1["title"]))
    hle = Enum.map(clinical, &[&1["source"], &1["target"]])
    graph = if page, do: graph_for(page, hln, hle, true), else: nil
    title = body["title"] || (List.first(body["sections"] || []) || %{})["heading"] || "Here's the pathway"
    sub = if page, do: "Highlighted the cited path on #{page}.", else: "Broad question — key points shown."
    %{msg: %{role: "luna", text: title, sub: sub}, sections: body["sections"] || [], evidence: ev,
      graph: graph, page: page, label: graph && graph["label"], hln: hln, hle: hle}
  end

  defp graph_for(page, hln, hle, auto) do
    g = Req.post!("#{@api}/graph", json: %{page: page, nodes: hln, edges: hle}).body
    g |> add_order() |> Map.put("autoReveal", auto)
  end

  # ---------------- helpers ----------------
  defp put_stage(socket, code, g) do
    {track, dstat} = track_of(code)
    cur = socket.assigns[:status]
    assign(socket, page: code, page_label: g["label"], track: track,
      status: if(cur in [nil, "Reference", "Analyzing"], do: dstat, else: cur))
  end

  defp track_of("TEST-1"), do: {"Initial workup", "Reference"}
  defp track_of("TEST-D"), do: {"Risk classification", "Reference"}
  defp track_of("SEM" <> _), do: {"Pure seminoma", "Reference"}
  defp track_of("NSEM" <> _), do: {"Nonseminoma", "Reference"}
  defp track_of(_), do: {"—", "Reference"}

  defp luna(socket, text, sub), do: assign(socket, messages: socket.assigns.messages ++ [%{role: "luna", text: text, sub: sub}])
  defp log(socket, entry), do: assign(socket, history: [entry | socket.assigns.history] |> Enum.take(30))

  defp add_order(%{"nodes" => nodes, "edges" => edges} = g) do
    adj = Enum.reduce(edges, %{}, fn e, a -> Map.update(a, e["data"]["source"], [e["data"]["target"]], &[e["data"]["target"] | &1]) end)
    indeg = Enum.reduce(edges, %{}, fn e, a -> Map.update(a, e["data"]["target"], 1, &(&1 + 1)) end)
    ids = Enum.map(nodes, & &1["data"]["id"])
    sources = Enum.filter(ids, &(Map.get(indeg, &1, 0) == 0))
    sources = if sources == [], do: Enum.take(ids, 1), else: sources
    ranks = bfs(sources, adj, %{}, 0)
    nodes2 = Enum.map(nodes, fn n -> put_in(n, ["data", "ord"], Map.get(ranks, n["data"]["id"], 0)) end)
    %{g | "nodes" => nodes2}
  end

  defp bfs([], _adj, ranks, _r), do: ranks
  defp bfs(frontier, adj, ranks, r) do
    {ranks2, nxt} =
      Enum.reduce(frontier, {ranks, []}, fn id, {rk, n} ->
        if Map.has_key?(rk, id), do: {rk, n}, else: {Map.put(rk, id, r), n ++ Map.get(adj, id, [])}
      end)
    nxt = nxt |> Enum.uniq() |> Enum.reject(&Map.has_key?(ranks2, &1))
    bfs(nxt, adj, ranks2, r + 1)
  end

  defp node_detail(nil, _id, title, type), do: %{title: title, type: type, text: title, options: [], parents: []}
  defp node_detail(graph, id, title, type) do
    idx = Map.new(graph["nodes"], fn n -> {n["data"]["id"], n["data"]} end)
    node = idx[id] || %{"label" => title}
    options =
      graph["edges"] |> Enum.filter(&(&1["data"]["source"] == id))
      |> Enum.map(fn e -> %{to: (idx[e["data"]["target"]] || %{})["title"] || "", via: e["data"]["label"]} end)
    parents =
      graph["edges"] |> Enum.filter(&(&1["data"]["target"] == id))
      |> Enum.map(fn e -> (idx[e["data"]["source"]] || %{})["title"] || "" end)
    %{title: title, type: type, text: node["label"] || title, options: options, parents: parents}
  end

  defp snippet(content) do
    content |> to_string() |> String.replace(~r/\[Data:[^\]]*\]/, "") |> String.replace(~r/\s+/, " ")
    |> String.trim() |> String.split(~r/(?<=\.)\s/) |> List.first() |> Kernel.||("") |> String.slice(0, 150)
  end

  defp bullets(sections) do
    sections
    |> Enum.map(fn s -> %{head: s["heading"], text: snippet(s["content"])} end)
    |> Enum.filter(fn b -> b.head not in [nil, ""] or b.text != "" end)
    |> Enum.take(6)
  end

  defp clinical(nil), do: []
  defp clinical(ev), do: Enum.filter(ev["edges"] || [], &(&1["kind"] == "clinical"))

  defp status_color("Active guidance"), do: "bg-violet-100 text-violet-700 border-violet-200"
  defp status_color("Analyzing"), do: "bg-amber-100 text-amber-700 border-amber-200"
  defp status_color("Error"), do: "bg-red-100 text-red-700 border-red-200"
  defp status_color(_), do: "bg-slate-100 text-slate-600 border-slate-200"

  defp done(todos), do: Enum.count(todos, &(&1.status == "complete"))

  defp node_type_color("Decision"), do: "#ca8a04"
  defp node_type_color("Treatment"), do: "#16a34a"
  defp node_type_color("Workup"), do: "#2563eb"
  defp node_type_color("Recurrence"), do: "#dc2626"
  defp node_type_color("Salvage"), do: "#b91c1c"
  defp node_type_color("Management"), do: "#475569"
  defp node_type_color("Reference"), do: "#7c3aed"
  defp node_type_color("Protocol Page"), do: "#9333ea"
  defp node_type_color(_), do: "#64748b"

  # ---------------- render ----------------
  def render(assigns) do
    ~H"""
    <div class="flex h-screen overflow-hidden">
      <!-- ═══ LEFT: Luna ═══ -->
      <aside class="w-[368px] shrink-0 flex flex-col bg-white/70 backdrop-blur-xl border-r border-white/60 shadow-xl shadow-slate-200/40">
        <div class="p-5 border-b border-slate-100/80">
          <div class="flex items-center gap-4">
            <div class="luna-glow relative w-16 h-16 rounded-2xl bg-gradient-to-br from-violet-600 via-fuchsia-500 to-indigo-600 grid place-items-center shadow-lg">
              <svg width="40" height="40" viewBox="0 0 48 48" fill="none">
                <path d="M31 10a15 15 0 1 0 0 28 12 12 0 0 1 0-28Z" fill="#fff" fill-opacity="0.95"/>
                <path d="M22 20h4v-4h4v4h4v4h-4v4h-4v-4h-4z" fill="#7c3aed"/>
                <g class="orbit"><circle cx="24" cy="24" r="21" stroke="#fff" stroke-opacity="0.7" stroke-width="1.3" stroke-dasharray="3 5" fill="none"/></g>
                <circle cx="45" cy="24" r="2.3" fill="#fff"/>
              </svg>
            </div>
            <div>
              <div class="font-bold text-slate-900 text-lg leading-none">Luna</div>
              <div class="text-xs text-slate-500 mt-1">AI Physician Agent</div>
              <div class="mt-1.5 inline-flex items-center gap-1.5 text-[11px] text-slate-600">
                <span class={["w-1.5 h-1.5 rounded-full", if(@loading, do: "bg-amber-400 animate-pulse", else: "bg-emerald-400")]}></span>
                <%= if @loading, do: "Reasoning over the guideline…", else: "Ready · " <> @track %>
              </div>
            </div>
          </div>
        </div>

        <div class="flex-1 min-h-0 overflow-auto p-4 space-y-3" id="chat">
          <%= for m <- @messages do %>
            <%= if m.role == "luna" do %>
              <div class="fade-up flex gap-2.5">
                <div class="shrink-0 w-7 h-7 rounded-lg bg-gradient-to-br from-violet-500 to-indigo-500 mt-0.5"></div>
                <div class="bg-white rounded-2xl rounded-tl-sm border border-slate-100 shadow-sm px-3.5 py-2.5 max-w-[85%]">
                  <div class="text-sm text-slate-800">{m.text}</div>
                  <%= if m.sub do %><div class="text-xs text-slate-500 mt-1 leading-snug">{m.sub}</div><% end %>
                </div>
              </div>
            <% else %>
              <div class="fade-up flex justify-end"><div class="bg-gradient-to-br from-violet-600 to-indigo-600 text-white rounded-2xl rounded-tr-sm shadow-sm px-3.5 py-2.5 max-w-[85%] text-sm">{m.text}</div></div>
            <% end %>
          <% end %>
          <%= if @loading do %>
            <div class="fade-up flex gap-2.5 items-center">
              <div class="shrink-0 w-7 h-7 rounded-lg bg-gradient-to-br from-violet-500 to-indigo-500"></div>
              <div class="flex gap-1 items-center bg-white border border-slate-100 rounded-2xl rounded-tl-sm px-3.5 py-3 shadow-sm">
                <span class="w-1.5 h-1.5 bg-violet-400 rounded-full animate-bounce [animation-delay:-0.3s]"></span>
                <span class="w-1.5 h-1.5 bg-violet-400 rounded-full animate-bounce [animation-delay:-0.15s]"></span>
                <span class="w-1.5 h-1.5 bg-violet-400 rounded-full animate-bounce"></span>
              </div>
            </div>
          <% end %>
        </div>

        <div class="p-3 border-t border-slate-100/80 space-y-2">
          <div class="flex flex-wrap gap-1.5">
            <%= for s <- @suggestions do %>
              <button phx-click="suggest" phx-value-q={s} class="text-[11px] px-2.5 py-1 rounded-full bg-violet-50 text-violet-700 border border-violet-100 hover:bg-violet-100 transition">{s}</button>
            <% end %>
          </div>
          <div class="flex gap-1.5">
            <button phx-click="method" phx-value-m="local" class={["text-[11px] px-2.5 py-1 rounded-full border transition", if(@method == "local", do: "bg-violet-600 text-white border-violet-600", else: "bg-white text-slate-500 border-slate-200")]}>🎯 Specific</button>
            <button phx-click="method" phx-value-m="global" class={["text-[11px] px-2.5 py-1 rounded-full border transition", if(@method == "global", do: "bg-violet-600 text-white border-violet-600", else: "bg-white text-slate-500 border-slate-200")]}>🌐 Thematic</button>
          </div>
          <form phx-submit="ask" class="flex items-center gap-2 bg-white rounded-2xl border border-slate-200 focus-within:border-violet-400 focus-within:ring-2 focus-within:ring-violet-500/20 p-1.5 pl-3 shadow-sm">
            <input name="q" autocomplete="off" placeholder="Ask Luna…" class="flex-1 bg-transparent text-sm py-1.5 focus:outline-none placeholder:text-slate-400" />
            <button type="submit" disabled={@loading} class="shrink-0 w-9 h-9 rounded-xl bg-gradient-to-br from-violet-600 to-indigo-600 disabled:opacity-50 text-white grid place-items-center shadow transition">
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m22 2-7 20-4-9-9-4Z"/><path d="M22 2 11 13"/></svg>
            </button>
          </form>
        </div>
      </aside>

      <!-- ═══ MAIN workspace ═══ -->
      <main class="flex-1 min-w-0 flex flex-col">
        <header class="shrink-0 flex items-center gap-4 px-6 py-3 bg-white/60 backdrop-blur-md border-b border-white/60">
          <div>
            <div class="text-[10px] font-bold uppercase tracking-widest text-violet-500">Current focus</div>
            <div class="flex items-center gap-2 mt-0.5">
              <span class="w-8 h-8 rounded-lg bg-gradient-to-br from-violet-600 to-indigo-600 text-white text-[11px] grid place-items-center font-bold">{@page || "—"}</span>
              <span class="text-lg font-semibold text-slate-900 max-w-[420px] truncate">{@page_label || "Select a pathway"}</span>
              <span class="text-xs text-slate-500 bg-slate-100 rounded-full px-2.5 py-0.5">{@track}</span>
            </div>
          </div>
          <span class={["ml-1 inline-flex items-center gap-1.5 text-xs font-semibold rounded-full border px-3 py-1", status_color(@status)]}>
            <span class="w-1.5 h-1.5 rounded-full bg-current opacity-70"></span>{@status}
          </span>
          <div class="ml-auto flex items-center gap-3">
            <form phx-change="page">
              <select name="code" class="text-xs bg-white border border-slate-200 rounded-lg px-2 py-1.5 text-slate-600 shadow-sm">
                <%= for c <- @pages do %><option value={c} selected={c == @page}>{c}</option><% end %>
              </select>
            </form>
            <div class="hidden xl:flex items-center gap-2.5">
              <%= for {name, color} <- @legend do %>
                <span class="flex items-center gap-1 text-[11px] text-slate-500"><span class="w-2.5 h-2.5 rounded-sm" style={"background:#{color}"}></span>{name}</span>
              <% end %>
            </div>
            <div class="flex items-center gap-1 bg-white rounded-xl border border-slate-200 p-0.5 shadow-sm">
              <button onclick="cyStep(-1)" title="Previous step" class="w-8 h-8 grid place-items-center rounded-lg hover:bg-violet-50 text-slate-600">◂</button>
              <button onclick="cyStep(1)" title="Next step" class="w-8 h-8 grid place-items-center rounded-lg hover:bg-violet-50 text-slate-600">▸</button>
              <button onclick="cyAll()" title="Reveal all" class="px-2 h-8 grid place-items-center rounded-lg hover:bg-violet-50 text-slate-600 text-xs">All</button>
              <span class="w-px h-5 bg-slate-200 mx-0.5"></span>
              <button onclick="cyZoom(1.25)" class="w-8 h-8 grid place-items-center rounded-lg hover:bg-violet-50 text-slate-600">＋</button>
              <button onclick="cyZoom(0.8)" class="w-8 h-8 grid place-items-center rounded-lg hover:bg-violet-50 text-slate-600">－</button>
              <button onclick="cyFit()" class="w-8 h-8 grid place-items-center rounded-lg hover:bg-violet-50 text-slate-600">
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M8 3H5a2 2 0 0 0-2 2v3m18 0V5a2 2 0 0 0-2-2h-3M3 16v3a2 2 0 0 0 2 2h3m13-5v3a2 2 0 0 1-2 2h-3"/></svg>
              </button>
            </div>
          </div>
        </header>

        <div class="flex flex-1 min-h-0">
          <div class="relative flex-1 min-h-0 bg-[radial-gradient(#e2e8f0_1px,transparent_1px)] [background-size:20px_20px]">
            <div id="cy" phx-hook="Cyto" phx-update="ignore" class="absolute inset-0"></div>
            <div class="pointer-events-none absolute bottom-3 right-3 text-[10px] text-slate-400 bg-white/70 rounded-full px-2.5 py-1 border border-slate-200">drag · scroll-zoom · click a node</div>
          </div>

          <section class="w-[320px] shrink-0 flex flex-col bg-white/70 backdrop-blur-md border-l border-white/60">
            <div class="flex text-xs font-medium border-b border-slate-100">
              <%= for {t, label} <- [{"todo", "✓ To-Do"}, {"timeline", "🕑 Timeline"}, {"detail", "◇ Detail"}] do %>
                <button phx-click="tab" phx-value-t={t} class={["flex-1 py-2.5 transition", if(@tab == t, do: "text-violet-700 border-b-2 border-violet-600 bg-violet-50/40", else: "text-slate-500 hover:text-slate-700")]}>{label}</button>
              <% end %>
            </div>

            <div class="flex-1 min-h-0 overflow-auto p-4">
              <%= cond do %>
                <% @tab == "todo" -> %>
                  <div class="flex items-center justify-between mb-3">
                    <div class="text-[11px] uppercase tracking-wider text-slate-400 font-semibold">Clinical workup</div>
                    <div class="text-[11px] text-violet-700 font-semibold">{done(@todos)}/{length(@todos)}</div>
                  </div>
                  <div class="w-full h-1.5 bg-slate-100 rounded-full mb-4 overflow-hidden">
                    <div class="h-full bg-gradient-to-r from-violet-500 to-indigo-500 rounded-full transition-all" style={"width:#{trunc(done(@todos) / max(length(@todos), 1) * 100)}%"}></div>
                  </div>
                  <%= for grp <- Enum.uniq(Enum.map(@todos, & &1.group)) do %>
                    <div class="text-[10px] font-bold uppercase tracking-wider text-slate-400 mt-3 mb-1.5">{grp}</div>
                    <%= for {t, i} <- Enum.with_index(@todos), t.group == grp do %>
                      <button phx-click="todo_toggle" phx-value-i={i} class="flex items-start gap-2 w-full text-left py-1 group">
                        <span class={["mt-0.5 w-4 h-4 rounded-[5px] border grid place-items-center shrink-0 transition", if(t.status == "complete", do: "bg-violet-600 border-violet-600 text-white", else: "border-slate-300 group-hover:border-violet-400")]}>
                          <%= if t.status == "complete" do %><svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3.5" stroke-linecap="round"><path d="M20 6 9 17l-5-5"/></svg><% end %>
                        </span>
                        <span class={["text-[12.5px] leading-snug", if(t.status == "complete", do: "text-slate-400 line-through", else: "text-slate-700")]}>{t.label}<span class="text-slate-400"> · {t.party}</span></span>
                      </button>
                    <% end %>
                  <% end %>
                  <div class="mt-4 text-[10px] text-slate-400 italic">Template from NCCN workup — tick items completed for this case.</div>

                <% @tab == "timeline" -> %>
                  <div class="text-[11px] uppercase tracking-wider text-slate-400 font-semibold mb-3">Case history · look-back</div>
                  <%= if @history == [] do %>
                    <div class="text-sm text-slate-400 italic">Steps you take appear here. Click any to jump back.</div>
                  <% else %>
                    <ol class="relative border-l-2 border-slate-100 ml-1.5 space-y-3">
                      <%= for {e, i} <- Enum.with_index(@history) do %>
                        <li class="ml-4 relative">
                          <span class={["absolute -left-[23px] top-1 w-3 h-3 rounded-full border-2 border-white", if(i == 0, do: "bg-violet-600", else: "bg-slate-300")]}></span>
                          <button phx-click="restore" phx-value-i={length(@history) - 1 - i} class="text-left group">
                            <div class="text-[12.5px] text-slate-700 group-hover:text-violet-700 leading-snug">{e.label}</div>
                            <div class="text-[10px] text-slate-400">{e.page} · {e.kind}<%= if e.kind == "query", do: " · path highlighted", else: "" %></div>
                          </button>
                        </li>
                      <% end %>
                    </ol>
                  <% end %>

                <% true -> %>
                  <%= if @selected do %>
                    <span class="text-[10px] font-bold uppercase tracking-wider text-white rounded px-2 py-0.5" style={"background:#{node_type_color(@selected.type)}"}>{@selected.type}</span>
                    <div class="text-sm font-semibold text-slate-900 mt-2 mb-1">{@selected.title}</div>
                    <div class="text-[12px] text-slate-500 whitespace-pre-wrap mb-3">{@selected.text}</div>
                    <%= if @selected.parents != [] do %>
                      <div class="text-[10px] font-bold uppercase tracking-wider text-slate-400 mt-2 mb-1">Comes from</div>
                      <div class="flex flex-wrap gap-1"><%= for p <- @selected.parents do %><span class="text-[11px] bg-slate-100 text-slate-600 rounded-full px-2 py-0.5">{p}</span><% end %></div>
                    <% end %>
                    <%= if @selected.options != [] do %>
                      <div class="text-[10px] font-bold uppercase tracking-wider text-slate-400 mt-3 mb-1">◇ Options / next</div>
                      <div class="space-y-1.5">
                        <%= for o <- @selected.options do %>
                          <div class="rounded-lg border border-slate-200 bg-white px-2.5 py-1.5">
                            <div class="text-[12.5px] text-slate-800">{o.to}</div>
                            <%= if o.via && o.via != "" do %><div class="text-[10.5px] text-violet-600 mt-0.5">criterion: {o.via}</div><% end %>
                          </div>
                        <% end %>
                      </div>
                    <% end %>
                    <button phx-click="suggest" phx-value-q={"Explain '" <> @selected.title <> "' in the " <> (@page || "") <> " pathway and what comes next."} class="mt-4 w-full text-[12px] bg-violet-600 hover:bg-violet-500 text-white rounded-lg py-2 transition">Ask Luna about this node</button>
                  <% else %>
                    <div class="text-sm text-slate-400 italic">Click any node in the flowchart to inspect its type, where it comes from, and its options.</div>
                  <% end %>
              <% end %>
            </div>

            <%= if @sections != [] do %>
              <div class="shrink-0 max-h-[40%] overflow-auto border-t border-slate-100 p-4">
                <div class="text-[10px] font-bold uppercase tracking-wider text-slate-400 mb-2">✦ Key points</div>
                <ul class="space-y-1.5">
                  <%= for b <- bullets(@sections) do %>
                    <li class="flex gap-2 text-[12.5px] leading-snug">
                      <span class="mt-1.5 w-1.5 h-1.5 rounded-full bg-gradient-to-br from-violet-500 to-indigo-500 shrink-0"></span>
                      <span><%= if b.head do %><b class="text-slate-800">{b.head}.</b> <% end %><span class="text-slate-600">{b.text}</span></span>
                    </li>
                  <% end %>
                </ul>
                <%= if clinical(@evidence) != [] do %>
                  <div class="flex flex-wrap gap-1 mt-3">
                    <%= for e <- clinical(@evidence) do %>
                      <button phx-click="focus_edge" phx-value-src={e["source"]} phx-value-tgt={e["target"]} phx-value-page={e["page"]} class="text-[10.5px] bg-violet-50 hover:bg-violet-100 border border-violet-200 text-violet-700 rounded-full px-2 py-0.5 transition">{e["source"]} → {e["target"]}</button>
                    <% end %>
                  </div>
                <% end %>
              </div>
            <% end %>
          </section>
        </div>
      </main>
    </div>
    <script>(()=>{const c=document.getElementById('chat');if(c)c.scrollTop=c.scrollHeight})();</script>
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
  @session_options [store: :cookie, key: "_nccn_key", signing_salt: "nccn_sign_1", same_site: "Lax"]
  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]]
  plug Plug.Static, at: "/js/phoenix", from: {:phoenix, "priv/static"}, only: ~w(phoenix.min.js)
  plug Plug.Static, at: "/js/lv", from: {:phoenix_live_view, "priv/static"}, only: ~w(phoenix_live_view.min.js)
  plug Plug.Session, @session_options
  plug NccnUi.Router
end

{:ok, _} = Supervisor.start_link([{Phoenix.PubSub, name: NccnUi.PubSub}, NccnUi.Endpoint], strategy: :one_for_one)
IO.puts("\nLuna copilot on http://127.0.0.1:#{System.get_env("PORT", "4000")}  (backend: #{System.get_env("NCCN_API", "http://127.0.0.1:8899")})")
Process.sleep(:infinity)
