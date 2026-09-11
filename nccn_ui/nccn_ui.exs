# Luna — AI Physician Agent · NCCN multi-cancer workflow copilot
# (testicular, breast, prostate, colon, NSCLC — switchable in the sidebar)
# Phoenix LiveView (single-file, Mix.install). Backend: api/app.py on :8899.
#   uv run --with klein python api/app.py
#   NCCN_API=http://127.0.0.1:8899 elixir nccn_ui/nccn_ui.exs   → http://127.0.0.1:5901

_bind_ip = if System.get_env("HTTP_IP", "127.0.0.1") == "0.0.0.0", do: {0, 0, 0, 0}, else: {127, 0, 0, 1}

Application.put_env(:nccn, NccnUi.Endpoint,
  http: [ip: _bind_ip, port: String.to_integer(System.get_env("PORT", "5901"))],
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
          @keyframes caret{50%{opacity:0}}
          .speech-text.typing::after{content:"▍";margin-left:1px;color:#8b5cf6;animation:caret .9s steps(1) infinite}
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
          // Half-duplex voice (ported from nxt-teach's VoiceRecorder): tap to record, tap again to
          // stop. The clip POSTs to /voice/transcribe (session cookie + CSRF header); the transcript
          // lands in the LiveView as a normal question. Luna's spoken reply arrives via "play_audio".
          Hooks.VoiceRecorder={
            mounted(){
              this.recorder=null;this.chunks=[];this.audio=null;this.typer=null;this.typeTarget=null;this.typeText="";
              this.el.addEventListener("click",()=>(this.recorder?this.stop():this.start()));
              // play_audio carries the spoken text and the id of the "Luna speaking" bubble's span
              // (rendered in the same LiveView patch, which is applied before events dispatch).
              this.handleEvent("play_audio",({audio,mime,text,el,timings})=>{
                this.stopAudio();
                const a=new Audio(`data:${mime};base64,${audio}`);this.audio=a;
                window.lunaSpeech={audio:a,timings:timings||[],text:text||""};   // debug/inspection handle (like window.cy)
                const target=el?document.getElementById(el):null;
                this.typeTarget=target;this.typeText=text||(target&&target.dataset.text)||"";
                if(target){target.textContent="";target.classList.add("typing")}
                const begin=()=>this.typewrite(a,target,this.typeText,timings||[]);
                a.addEventListener("playing",begin,{once:true});   // follow the real playback clock, not a timer
                a.addEventListener("ended",()=>this.finishText());
                a.play().catch(()=>{this.finishText()});   // autoplay refused: show the words anyway
              });
              this.handleEvent("stop_audio",()=>this.stopAudio());
            },
            // Reveal the narration word by word against audio.currentTime. `timings` are nova-3 word
            // [start,end] pairs for the clip; the i-th text word is mapped onto the proportional
            // transcript word so small tokenisation differences don't matter. Without timings, fall
            // back to spreading the words evenly over the clip's duration.
            typewrite(a,target,text,timings){
              if(!target){return}
              const words=text.split(/(\s+)/);            // keep separators so slicing preserves layout
              const tokens=[];let off=0;for(const w of words){if(w.trim()){tokens.push({end:off+w.length})}off+=w.length}
              const n=tokens.length,m=timings.length;
              const at=(i)=>{ if(m>0){const j=Math.min(m-1,Math.floor(i*m/n));return timings[j][0]}
                              const d=isFinite(a.duration)&&a.duration>0?a.duration:n/2.6;return (i/n)*d*0.96 };
              const revealAt=tokens.map((t,i)=>({end:t.end,t:at(i)}));
              const chat=document.getElementById("chat");let shown=0;
              const frame=()=>{
                if(this.audio!==a){return}
                const now=a.currentTime+0.12;              // small lookahead: the eye reads slightly ahead of the ear
                let k=shown;while(k<n&&revealAt[k].t<=now){k++}
                if(k!==shown){shown=k;target.textContent=text.slice(0,k?revealAt[k-1].end:0);if(chat){chat.scrollTop=chat.scrollHeight}}
                if(shown<n&&!a.ended){this.typer=requestAnimationFrame(frame)}else{target.textContent=text;target.classList.remove("typing");this.typer=null}
              };
              frame();
            },
            finishText(){
              if(this.typer){cancelAnimationFrame(this.typer);this.typer=null}
              if(this.typeTarget){this.typeTarget.textContent=this.typeText;this.typeTarget.classList.remove("typing");this.typeTarget=null}
            },
            stopAudio(){this.finishText();if(this.audio){try{this.audio.pause()}catch(_){}this.audio=null}},
            async start(){
              this.stopAudio();
              if(!navigator.mediaDevices||!navigator.mediaDevices.getUserMedia){this.pushEvent("voice_failed",{reason:"the microphone needs a secure context — open Luna over https or on localhost/127.0.0.1"});return}
              if(!window.MediaRecorder){this.pushEvent("voice_failed",{reason:"this browser has no MediaRecorder"});return}
              try{
                const stream=await navigator.mediaDevices.getUserMedia({audio:true});
                this.chunks=[];this.recorder=new MediaRecorder(stream);
                this.recorder.ondataavailable=(e)=>e.data.size&&this.chunks.push(e.data);
                this.recorder.onstop=()=>this.upload(stream);
                this.recorder.start();
                this.pushEvent("voice_recording",{});
              }catch(error){
                this.pushEvent("voice_failed",{reason:(error&&error.name==="NotAllowedError")?"microphone permission denied":("microphone unavailable: "+error)});
              }
            },
            stop(){this.recorder.stop()},
            async upload(stream){
              stream.getTracks().forEach((t)=>t.stop());
              this.pushEvent("voice_uploading",{});
              const blob=new Blob(this.chunks,{type:this.recorder.mimeType||"audio/webm"});
              this.recorder=null;
              try{
                const csrf=document.querySelector("meta[name=csrf-token]").getAttribute("content");
                const response=await fetch("/voice/transcribe",{method:"POST",headers:{"content-type":blob.type,"x-csrf-token":csrf},body:blob});
                const result=await response.json();
                if(!response.ok){this.pushEvent("voice_failed",{reason:result.error||String(response.status)});return}
                this.pushEvent("voice_transcribed",{transcript:result.transcript||""});
              }catch(error){this.pushEvent("voice_failed",{reason:String(error)})}
            },
            destroyed(){this.stopAudio()}
          };
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
  @suggestions ["Initial staging workup", "Primary treatment options", "Systemic therapy for advanced disease", "Recurrence & later-line options"]
  # Fallback checklist for a guideline we don't have a curated list for.
  @todo_general [
    {"Patient & clinical", [{"History and physical (H&P)", "Clinician"}, {"Performance status & comorbidities", "Clinician"}]},
    {"Laboratory", [{"CBC + comprehensive chemistry", "Lab"}, {"Disease-specific tumor markers", "Lab"}]},
    {"Imaging", [{"Cross-sectional imaging (CT/MRI)", "Radiology"}, {"PET/CT or bone scan if indicated", "Radiology"}]},
    {"Pathology", [{"Biopsy / surgical specimen", "Pathology"}, {"Histology & grade confirmed", "Pathology"}]},
    {"Staging & review", [{"AJCC TNM stage assigned", "Clinician"}, {"Multidisciplinary review", "Tumor board"}]}
  ]

  # Per-guideline workup checklists, transcribed from each guideline's own
  # workup pages (the same .dot flowcharts the graph on the right renders) —
  # the group headers cite the page the tasks come from, so the To-Do list
  # always reflects the clinical flow under review.
  @todos_by_guideline %{
    "testicular" => [
      {"Diagnosis · TEST-1", [
        {"History & physical (H&P)", "Clinician"},
        {"Testicular ultrasound", "Radiology"},
        {"AFP, beta-hCG (quantitative), LDH + chemistry", "Lab"}]},
      {"Primary treatment · TEST-1", [
        {"Radical inguinal orchiectomy", "Surgery"},
        {"Sperm banking discussed, if indicated", "Clinician"}]},
      {"Postdiagnostic staging · SEM-1 / NSEM-1", [
        {"C/A/P CT or MRI", "Radiology"},
        {"Repeat post-orchiectomy AFP, beta-hCG, LDH", "Lab"},
        {"Brain MRI, if clinically indicated", "Radiology"},
        {"Clinical stage + risk classification (TEST-D)", "Clinician"}]}
    ],
    "breast" => [
      {"Workup · BINV-1", [
        {"History & physical exam", "Clinician"},
        {"Diagnostic bilateral mammogram ± ultrasound", "Radiology"},
        {"Breast MRI (optional)", "Radiology"},
        {"Pathology review", "Pathology"},
        {"ER/PR and HER2 status", "Pathology"}]},
      {"Risk & counseling · BINV-1", [
        {"Genetic counseling/testing (at risk, TNBC, olaparib candidate)", "Molecular"},
        {"Fertility & sexual health addressed", "Clinician"},
        {"Pregnancy test if childbearing potential", "Lab"},
        {"Distress assessment", "Clinician"}]},
      {"Stage & pathway · BINV-1", [
        {"Clinical stage assigned (cT, cN, M0)", "Clinician"},
        {"Preoperative systemic therapy candidacy (BINV-L)", "Tumor board"}]}
    ],
    "prostate" => [
      {"Workup · PROS-1", [
        {"Physical exam + DRE to confirm clinical stage", "Clinician"},
        {"PSA (PSADT if regional/metastatic)", "Lab"},
        {"Diagnostic prostate biopsies reviewed", "Pathology"}]},
      {"Risk context · PROS-1", [
        {"Life expectancy estimate (PROS-A)", "Clinician"},
        {"Germline/somatic testing & family history", "Molecular"},
        {"Quality-of-life measures", "Clinician"}]},
      {"Stratification · PROS-2", [
        {"Bone & soft-tissue imaging for staging, if indicated", "Radiology"},
        {"Initial risk group assigned", "Clinician"}]}
    ],
    "colon" => [
      {"Workup · COL-1", [
        {"Pathology review", "Pathology"},
        {"Colonoscopy + marking of cancerous polyp site (≤2 wks)", "Endoscopy"},
        {"MMR/MSI testing", "Molecular"}]},
      {"Additional workup · COL-1", [
        {"CBC, chemistry profile, CEA", "Lab"},
        {"Chest/abdomen/pelvis CT (consider pelvis MRI)", "Radiology"}]},
      {"Surgical decision · COL-1", [
        {"Histologic features & margins assessed", "Pathology"},
        {"Observe vs colectomy with en-bloc regional nodes", "Tumor board"}]}
    ],
    "nsclc" => [
      {"Presentation · DIAG-1", [
        {"Multidisciplinary evaluation", "Tumor board"},
        {"Smoking cessation counseling", "Clinician"}]},
      {"Risk assessment · DIAG-1", [
        {"Patient factors: age, smoking, exposures, prior cancer", "Clinician"},
        {"Radiologic factors: size, shape, density, FDG avidity", "Radiology"},
        {"Compare against prior imaging (stability is decisive)", "Radiology"}]},
      {"Nodule pathway · DIAG-1", [
        {"Classify nodule: solid → DIAG-2, subsolid → DIAG-3", "Radiology"}]}
    ]
  }

  defp build_todos(key) do
    for {grp, items} <- Map.get(@todos_by_guideline, key, @todo_general),
        {label, party} <- items do
      %{group: grp, label: label, party: party, status: "pending"}
    end
  end

  def mount(_params, _session, socket) do
    hello = %{role: "luna", text: "I'm Luna — your clinical copilot.", sub: "Ask about staging, workup, treatment or recurrence. I'll walk the pathway step by step on the right."}

    # The real guideline isn't known until cy_ready resolves it; start general.
    todos = build_todos(nil)

    {:ok,
     assign(socket,
       legend: @legend, suggestions: @suggestions,
       guidelines: [], guideline: nil, guideline_label: "",
       pages: [], method: "local", loading: false, error: nil, messages: [hello],
       page: nil, page_label: nil, track: "—", status: "Reference",
       evidence: nil, sections: [], graph: nil, selected: nil,
       tab: "todo", todos: todos, history: [],
       patients_open: false, patients: nil, patients_loading: false, patients_error: nil, patients_filter: nil,
       patient: nil, patient_detail: nil, patient_loading: false,
       voice_enabled: NccnUi.Voice.enabled?(), voice_state: "idle", voice_speak: true, voice_last: false
     )}
  end

  # ---------------- events ----------------
  def handle_event("cy_ready", _p, socket) do
    %{"guidelines" => gs, "default" => default} =
      Req.get!("#{@api}/guidelines").body
    key = socket.assigns.guideline || default
    gd = Enum.find(gs, &(&1["key"] == key)) || List.first(gs)
    key = gd["key"]
    pages = gd["pages"]
    code = socket.assigns.page || (List.first(pages) || %{})["code"]
    g = graph_for(key, code, [], [], false)
    {:noreply,
     socket
     |> assign(guidelines: gs, guideline: key, guideline_label: gd["label"], pages: pages, graph: g,
               todos: build_todos(key))
     |> put_stage(code, g)
     |> push_event("graph", g)}
  end

  def handle_event("guideline", %{"key" => key}, socket), do: {:noreply, switch_guideline(socket, key)}

  # ---- voice (Deepgram via NccnUi.Voice; browser side is the VoiceRecorder hook) ----
  def handle_event("voice_recording", _p, socket),
    do: {:noreply, socket |> assign(voice_state: "recording") |> push_event("stop_audio", %{})}

  def handle_event("voice_uploading", _p, socket), do: {:noreply, assign(socket, voice_state: "uploading")}

  def handle_event("voice_transcribed", %{"transcript" => t}, socket) do
    socket = assign(socket, voice_state: "idle")
    case String.trim(t) do
      "" -> {:noreply, luna(socket, "I couldn't hear anything in that clip — try again a little closer?", nil)}
      q -> do_ask(q, assign(socket, voice_last: true))
    end
  end

  def handle_event("voice_failed", %{"reason" => reason}, socket),
    do: {:noreply, socket |> assign(voice_state: "idle") |> luna("Voice unavailable.", to_string(reason))}

  def handle_event("voice_speak", _p, socket) do
    on = !socket.assigns.voice_speak
    {:noreply, socket |> assign(voice_speak: on) |> then(&if(on, do: &1, else: push_event(&1, "stop_audio", %{})))}
  end

  def handle_event("method", %{"m" => m}, socket), do: {:noreply, assign(socket, method: m)}
  def handle_event("tab", %{"t" => t}, socket), do: {:noreply, assign(socket, tab: t)}

  # ---- patient roster modal (TrakCare / FHIR server, proxied by the API's /patients) ----
  def handle_event("patients_open", _p, socket) do
    loaded = socket.assigns.patients
    if loaded && loaded["source"] != "error",
      do: {:noreply, assign(socket, patients_open: true)},
      else: {:noreply, fetch_patients(socket, false)}
  end

  def handle_event("patients_refresh", _p, socket), do: {:noreply, fetch_patients(socket, true)}
  def handle_event("patients_close", _p, socket), do: {:noreply, assign(socket, patients_open: false)}

  def handle_event("patients_filter", %{"key" => k}, socket),
    do: {:noreply, assign(socket, patients_filter: if(k == "all", do: nil, else: k))}

  # Selecting a patient makes them the active clinical context: switch to their guideline, open the
  # Patient tab, fetch the full FHIR record, and ask Luna the pathway question for them (the answer's
  # cited path lights up the flowchart). Every later question carries the patient context too.
  def handle_event("patient_select", %{"id" => id}, socket) do
    p = Enum.find((socket.assigns.patients || %{})["patients"] || [], &(&1["id"] == id))
    if p do
      key = p["guideline"]
      socket = assign(socket, patients_open: false, patient: p, patient_detail: nil, patient_loading: true, tab: "patient")
      socket = if key && key != socket.assigns.guideline, do: switch_guideline(socket, key), else: socket
      dx = Enum.join(Enum.reject([p["stage"] && "stage #{p["stage"]}", p["diagnosis"]], &is_nil/1), " ")
      sub = Enum.join(Enum.reject([p["sex"], p["age"] && "#{p["age"]} y", p["mrn"] && "MRN #{p["mrn"]}"], &is_nil/1), " · ")
      url = "#{@api}/patients/#{URI.encode(id)}"
      socket =
        socket
        |> luna("Now reviewing #{p["name"]}#{if dx != "", do: " — " <> dx, else: ""}.", sub)
        |> log(%{page: socket.assigns.page, hln: [], hle: [], kind: "patient",
                 label: "Patient: #{p["name"]} (#{guideline_label(socket.assigns.guidelines, key)})"})
        |> start_async(:patient_detail, fn -> Req.get!(url, receive_timeout: 20_000, connect_options: [timeout: 5_000]).body end)
      if key, do: do_ask(patient_question(p), socket), else: {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("patient_clear", _p, socket) do
    {:noreply,
     socket
     |> assign(patient: nil, patient_detail: nil, patient_loading: false, tab: if(socket.assigns.tab == "patient", do: "todo", else: socket.assigns.tab))
     |> luna("Cleared the patient context — answers are general again.", nil)}
  end

  def handle_event("page", %{"code" => code}, socket) do
    g = graph_for(socket.assigns.guideline, code, [], [], false)
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
      g = graph_for(socket.assigns.guideline, entry.page, entry.hln, entry.hle, entry.hln != [])
      {:noreply, socket |> assign(graph: g) |> put_stage(entry.page, g) |> luna("↩ Restored: #{entry.label}", nil) |> push_event("graph", g)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("focus_edge", %{"src" => s, "tgt" => t, "page" => p}, socket) do
    g = graph_for(socket.assigns.guideline, p, [s, t], [[s, t]], true)
    {:noreply, socket |> assign(graph: g) |> put_stage(p, g) |> push_event("graph", g)}
  end

  defp do_ask("", socket), do: {:noreply, socket}

  defp do_ask(q, socket) do
    method = socket.assigns.method
    key = socket.assigns.guideline
    p = socket.assigns.patient
    # The chat shows what was typed; the API gets the patient context prepended when one is active.
    full_q = if p, do: patient_context(p) <> "\n\nQuestion: " <> q, else: q
    tags = Enum.reject([socket.assigns[:voice_last] && "🎤 spoken", p && "for #{p["name"]}"], &(!&1))
    msgs = socket.assigns.messages ++ [%{role: "user", text: q, sub: if(tags == [], do: nil, else: Enum.join(tags, " · "))}]
    {:noreply,
     socket
     |> assign(loading: true, error: nil, messages: msgs, status: "Analyzing", voice_last: false)
     |> start_async(:run, fn -> run_query(key, full_q, method) end)}
  end

  # Luna speaks her answer (Aura TTS) when the speaker toggle is on; never blocks the answer itself.
  # The async returns the spoken text too, so the "Luna speaking" bubble can typewriter it in sync.
  defp maybe_speak(socket, res) do
    text = speak_text(res)
    if socket.assigns.voice_enabled and socket.assigns.voice_speak and text != "" do
      start_async(socket, :speak, fn ->
        case NccnUi.Voice.speak(text) do
          {:ok, audio, mime} = ok -> {text, ok, NccnUi.Voice.word_timings(audio, mime)}
          err -> {text, err, []}
        end
      end)
    else
      socket
    end
  end

  # Title + the first two sections, stripped of citations/markdown, cut at a sentence boundary
  # around 900 chars (~1 min of Aura speech; the hard API limit is 2000). The full answer stays on screen.
  defp speak_text(res) do
    text =
      [res.msg.text | Enum.map(Enum.take(res.sections || [], 2), &(&1["content"] || ""))]
      |> Enum.join(". ")
      |> String.replace(~r/\[Data:[^\]]*\]/, "")
      |> String.replace(~r/[*#_`>|]+/, "")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    if String.length(text) <= 900 do
      text
    else
      head = String.slice(text, 0, 900)
      case :binary.matches(head, [". ", "; "]) do
        [] -> head
        ms -> {pos, len} = List.last(ms); String.slice(head, 0, pos + len - 1)
      end
    end
  end

  defp patient_context(p) do
    who =
      [p["age"] && "#{p["age"]}-year-old", p["sex"], p["diagnosis"] && "with #{p["diagnosis"]}#{if p["diagnosis_code"], do: " (#{p["diagnosis_code"]})", else: ""}",
       p["stage"] && "stage #{p["stage"]}"]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")
    last = if p["last_encounter"], do: " Last encounter #{p["last_encounter"]}.", else: ""
    "Patient context: #{if who == "", do: "patient", else: who}.#{last} Answer for this patient specifically."
  end

  defp patient_question(p) do
    stage = if p["stage"], do: " at stage #{p["stage"]}", else: ""
    dx = p["diagnosis"] || "this diagnosis"
    "What are the NCCN-recommended next steps in workup and treatment for #{dx}#{stage}?"
  end

  # ---------------- async ----------------
  def handle_async(:run, {:ok, res}, socket) do
    # The question named another cancer: follow it — pills, page list, checklist and chart move
    # to that guideline (switch_guideline posts "Switched to …"), then the answer lands on top.
    socket =
      if res[:routed_from] && res.guideline != socket.assigns.guideline,
        do: switch_guideline(socket, res.guideline),
        else: socket

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

    {:noreply, maybe_speak(socket, res)}
  end

  def handle_async(:speak, {:ok, {text, {:ok, audio, mime}, timings}}, socket) do
    id = System.unique_integer([:positive])
    {:noreply,
     socket
     |> assign(messages: socket.assigns.messages ++ [%{role: "speech", text: text, sub: nil, id: id}])
     |> push_event("play_audio", %{audio: Base.encode64(audio), mime: mime, text: text, el: "speech-#{id}", timings: timings})}
  end

  def handle_async(:speak, {:ok, {_text, {:error, _reason}, _}}, socket), do: {:noreply, socket}
  def handle_async(:speak, {:exit, _reason}, socket), do: {:noreply, socket}

  def handle_async(:run, {:exit, reason}, socket) do
    {:noreply, socket |> assign(loading: false, status: "Error") |> luna("Something went wrong.", inspect(reason))}
  end

  def handle_async(:patients, {:ok, body}, socket),
    do: {:noreply, assign(socket, patients: body, patients_loading: false, patients_error: body["error"])}

  def handle_async(:patients, {:exit, reason}, socket),
    do: {:noreply, assign(socket, patients_loading: false, patients_error: "API unreachable: #{inspect(reason)}")}

  def handle_async(:patient_detail, {:ok, body}, socket),
    do: {:noreply, assign(socket, patient_detail: body, patient_loading: false)}

  def handle_async(:patient_detail, {:exit, reason}, socket),
    do: {:noreply, assign(socket, patient_detail: %{"error" => "API unreachable: #{inspect(reason)}", "conditions" => [], "encounters" => []}, patient_loading: false)}

  # ---------------- backend ----------------
  # route: true lets the API answer from whichever guideline the question names (e.g. asking about
  # breast cancer while Testicular is selected). The response's `guideline` is then authoritative:
  # the graph is fetched from it and handle_async switches the UI to it before showing the answer.
  defp run_query(key, q, method) do
    body = Req.post!("#{@api}/query", json: %{guideline: key, query: q, method: method, route: true}, receive_timeout: 240_000, connect_options: [timeout: 10_000]).body
    gkey = body["guideline"] || key
    ev = body["evidence"] || %{}
    page = ev["primary_page"]
    clinical = Enum.filter(ev["edges"] || [], &(&1["kind"] == "clinical"))
    hln = Enum.uniq(Enum.flat_map(clinical, &[&1["source"], &1["target"]]) ++ Enum.map(ev["nodes"] || [], & &1["title"]))
    hle = Enum.map(clinical, &[&1["source"], &1["target"]])
    graph = if page, do: graph_for(gkey, page, hln, hle, true), else: nil
    title = body["title"] || (List.first(body["sections"] || []) || %{})["heading"] || "Here's the pathway"
    sub = if page, do: "Highlighted the cited path on #{page}.", else: "Broad question — key points shown."
    %{msg: %{role: "luna", text: title, sub: sub}, sections: body["sections"] || [], evidence: ev,
      graph: graph, page: page, label: graph && graph["label"], hln: hln, hle: hle,
      guideline: gkey, routed_from: body["routed_from"]}
  end

  defp graph_for(key, page, hln, hle, auto) do
    g = Req.post!("#{@api}/graph", json: %{guideline: key, page: page, nodes: hln, edges: hle}).body
    g |> add_order() |> Map.put("autoReveal", auto)
  end

  # ---------------- helpers ----------------
  defp put_stage(socket, code, g) do
    cur = socket.assigns[:status]
    assign(socket, page: code, page_label: g["label"], track: socket.assigns.guideline_label,
      status: if(cur in [nil, "Reference", "Analyzing"], do: "Reference", else: cur))
  end

  defp luna(socket, text, sub), do: assign(socket, messages: socket.assigns.messages ++ [%{role: "luna", text: text, sub: sub}])
  defp log(socket, entry), do: assign(socket, history: [entry | socket.assigns.history] |> Enum.take(30))

  # Switch the active guideline. Shared by the sidebar pills and patient selection;
  # returns the socket unchanged for an unknown key.
  defp switch_guideline(socket, key) do
    gd = Enum.find(socket.assigns.guidelines, &(&1["key"] == key))
    if gd do
      pages = gd["pages"]
      code = (List.first(pages) || %{})["code"]
      g = graph_for(key, code, [], [], false)
      socket
      |> assign(guideline: key, guideline_label: gd["label"], pages: pages, graph: g,
                selected: nil, sections: [], evidence: nil, status: "Reference",
                # A new guideline is a new clinical flow — fresh checklist,
                # sourced from that guideline's own workup pages.
                todos: build_todos(key))
      |> put_stage(code, g)
      |> luna("Switched to #{gd["label"]} — showing #{code}.", g["label"])
      |> push_event("graph", g)
    else
      socket
    end
  end

  # Kick off the async roster fetch; the API answers 200 with source=error on upstream failure.
  defp fetch_patients(socket, refresh) do
    url = "#{@api}/patients" <> if(refresh, do: "?refresh=1", else: "")
    socket
    |> assign(patients_open: true, patients_loading: true, patients_error: nil)
    |> start_async(:patients, fn -> Req.get!(url, receive_timeout: 20_000, connect_options: [timeout: 5_000]).body end)
  end

  defp visible_patients(%{"patients" => ps}, nil) when is_list(ps), do: ps
  defp visible_patients(%{"patients" => ps}, filter) when is_list(ps), do: Enum.filter(ps, &(&1["guideline"] == filter))
  defp visible_patients(_, _), do: []

  defp guideline_label(guidelines, key) do
    case Enum.find(guidelines || [], &(&1["key"] == key)) do
      nil -> "Unmapped"
      gd -> gd["label"]
    end
  end

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

  defp guideline_tint("breast"), do: "bg-pink-100 text-pink-700 border-pink-200"
  defp guideline_tint("prostate"), do: "bg-sky-100 text-sky-700 border-sky-200"
  defp guideline_tint("colon"), do: "bg-amber-100 text-amber-700 border-amber-200"
  defp guideline_tint("nsclc"), do: "bg-emerald-100 text-emerald-700 border-emerald-200"
  defp guideline_tint("testicular"), do: "bg-violet-100 text-violet-700 border-violet-200"
  defp guideline_tint(_), do: "bg-slate-100 text-slate-500 border-slate-200"

  defp source_tint("trakcare"), do: "bg-sky-100 text-sky-700 border-sky-200"
  defp source_tint("fhir"), do: "bg-emerald-100 text-emerald-700 border-emerald-200"
  defp source_tint("mock"), do: "bg-amber-100 text-amber-700 border-amber-200"
  defp source_tint(_), do: "bg-red-100 text-red-700 border-red-200"

  defp source_label(%{"source" => "trakcare", "server" => h}), do: "InterSystems TrakCare · #{h}"
  defp source_label(%{"source" => "fhir", "server" => h}), do: "FHIR R4 · #{h}"
  defp source_label(%{"source" => "mock"}), do: "Synthetic roster (no FHIR server configured)"
  defp source_label(%{"source" => "error", "server" => h}) when is_binary(h), do: "FHIR R4 · #{h}"
  defp source_label(_), do: "Patient roster"

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
            <button phx-click="patients_open" title="Patient roster (TrakCare / FHIR)"
              class="ml-auto self-start w-9 h-9 rounded-xl border border-slate-200 bg-white text-slate-500 grid place-items-center transition hover:border-violet-300 hover:text-violet-700 hover:bg-violet-50">
              <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2"/><circle cx="12" cy="7" r="4"/></svg>
            </button>
          </div>
          <div class="mt-4">
            <div class="text-[10px] font-bold uppercase tracking-wider text-slate-400 mb-1.5">Guideline</div>
            <div class="flex flex-wrap gap-1.5">
              <%= for gd <- @guidelines do %>
                <button phx-click="guideline" phx-value-key={gd["key"]}
                  class={["text-[11px] px-2.5 py-1 rounded-lg border transition", if(@guideline == gd["key"], do: "bg-gradient-to-br from-violet-600 to-indigo-600 text-white border-transparent shadow-sm", else: "bg-white text-slate-600 border-slate-200 hover:border-violet-300")]}>
                  {gd["label"]}
                </button>
              <% end %>
            </div>
          </div>
        </div>

        <div class="flex-1 min-h-0 overflow-auto p-4 space-y-3" id="chat">
          <%= for m <- @messages do %>
            <%= cond do %>
              <% m.role == "speech" -> %>
                <%!-- Luna's spoken narration. The span is phx-update="ignore": the VoiceRecorder hook types
                      the text into it in step with the audio; server-rendered full text is the no-JS fallback. --%>
                <div class="fade-up flex gap-2.5">
                  <div class="shrink-0 w-7 h-7 rounded-lg bg-gradient-to-br from-violet-500 to-fuchsia-500 mt-0.5 grid place-items-center text-white">
                    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5" fill="currentColor" stroke="none"/><path d="M15.54 8.46a5 5 0 0 1 0 7.07"/><path d="M19.07 4.93a10 10 0 0 1 0 14.14"/></svg>
                  </div>
                  <div class="bg-violet-50/80 rounded-2xl rounded-tl-sm border border-violet-200 shadow-sm shadow-violet-100 px-3.5 py-2.5 max-w-[85%]">
                    <div class="text-[10px] font-bold uppercase tracking-wider text-violet-600 mb-1">Luna speaking</div>
                    <div class="text-sm text-slate-800 leading-relaxed"><span id={"speech-#{m.id}"} phx-update="ignore" data-text={m.text} class="speech-text">{m.text}</span></div>
                  </div>
                </div>
              <% m.role == "luna" -> %>
                <div class="fade-up flex gap-2.5">
                  <div class="shrink-0 w-7 h-7 rounded-lg bg-gradient-to-br from-violet-500 to-indigo-500 mt-0.5"></div>
                  <div class="bg-white rounded-2xl rounded-tl-sm border border-slate-100 shadow-sm px-3.5 py-2.5 max-w-[85%]">
                    <div class="text-sm text-slate-800">{m.text}</div>
                    <%= if m.sub do %><div class="text-xs text-slate-500 mt-1 leading-snug">{m.sub}</div><% end %>
                  </div>
                </div>
              <% true -> %>
              <div class="fade-up flex justify-end">
                <div class="bg-gradient-to-br from-violet-600 to-indigo-600 text-white rounded-2xl rounded-tr-sm shadow-sm px-3.5 py-2.5 max-w-[85%] text-sm">
                  {m.text}
                  <%= if m.sub do %><div class="text-[10.5px] text-violet-100/90 mt-1 flex items-center gap-1"><svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2"/><circle cx="12" cy="7" r="4"/></svg>{m.sub}</div><% end %>
                </div>
              </div>
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
            <%= if @voice_enabled do %>
              <button phx-click="voice_speak" title="Luna reads her answers aloud (Deepgram Aura)"
                class={["ml-auto text-[11px] px-2.5 py-1 rounded-full border transition", if(@voice_speak, do: "bg-gradient-to-br from-violet-600 to-fuchsia-600 text-white border-transparent shadow-sm", else: "bg-white text-slate-500 border-slate-200")]}>
                <%= if @voice_speak, do: "🔊 Speaks", else: "🔇 Muted" %>
              </button>
            <% end %>
          </div>
          <form phx-submit="ask" class="flex items-center gap-2 bg-white rounded-2xl border border-slate-200 focus-within:border-violet-400 focus-within:ring-2 focus-within:ring-violet-500/20 p-1.5 pl-3 shadow-sm">
            <input name="q" autocomplete="off" placeholder={if @voice_state == "recording", do: "Listening… tap the mic to stop", else: "Ask Luna…"} class="flex-1 bg-transparent text-sm py-1.5 focus:outline-none placeholder:text-slate-400" />
            <%= if @voice_enabled do %>
              <button type="button" id="voice-rec" phx-hook="VoiceRecorder" disabled={@voice_state == "uploading"}
                title={case @voice_state do "recording" -> "Stop and send"; "uploading" -> "Transcribing…"; _ -> "Ask by voice (Deepgram nova-3)" end}
                class={["shrink-0 w-9 h-9 rounded-xl grid place-items-center border transition",
                        case @voice_state do
                          "recording" -> "bg-red-500 text-white border-red-500 animate-pulse shadow"
                          "uploading" -> "bg-slate-100 text-slate-400 border-slate-200"
                          _ -> "bg-white text-slate-500 border-slate-200 hover:border-violet-300 hover:text-violet-700"
                        end]}>
                <%= if @voice_state == "recording" do %>
                  <svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor"><rect x="5" y="5" width="14" height="14" rx="2"/></svg>
                <% else %>
                  <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 2a3 3 0 0 0-3 3v7a3 3 0 0 0 6 0V5a3 3 0 0 0-3-3Z"/><path d="M19 10v2a7 7 0 0 1-14 0v-2"/><line x1="12" x2="12" y1="19" y2="22"/></svg>
                <% end %>
              </button>
            <% else %>
              <button type="button" disabled title="Voice is off — set DEEPGRAM_API_KEY on the UI service to enable"
                class="shrink-0 w-9 h-9 rounded-xl grid place-items-center border border-slate-200 bg-slate-50 text-slate-300">
                <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="2" x2="22" y1="2" y2="22"/><path d="M18.89 13.23A7.12 7.12 0 0 0 19 12v-2"/><path d="M5 10v2a7 7 0 0 0 12 5"/><path d="M15 9.34V5a3 3 0 0 0-5.68-1.33"/><path d="M9 9v3a3 3 0 0 0 5.12 2.12"/><line x1="12" x2="12" y1="19" y2="22"/></svg>
              </button>
            <% end %>
            <button type="submit" disabled={@loading} class="shrink-0 w-9 h-9 rounded-xl bg-gradient-to-br from-violet-600 to-indigo-600 disabled:opacity-50 text-white grid place-items-center shadow transition">
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m22 2-7 20-4-9-9-4Z"/><path d="M22 2 11 13"/></svg>
            </button>
          </form>
        </div>
      </aside>

      <!-- ═══ MAIN workspace ═══ -->
      <main class="flex-1 min-w-0 flex flex-col">
        <header class="shrink-0 flex flex-col gap-2.5 px-6 py-3 bg-white/60 backdrop-blur-md border-b border-white/60">
          <div class="self-center flex items-center gap-4 px-5 py-3 rounded-2xl bg-violet-100/70 border border-violet-300 shadow-sm">
            <div class="pr-1">
              <div class="text-[10px] font-bold uppercase tracking-widest text-violet-600">Current focus</div>
              <div class="text-base font-semibold text-slate-900 max-w-[360px] truncate leading-tight mt-0.5">{@page_label || "Select a pathway"}</div>
              <div class="text-[11px] font-medium text-violet-700/80">{@track}</div>
            </div>
            <span class={["inline-flex items-center gap-1.5 text-xs font-semibold rounded-full border px-3 py-1", status_color(@status)]}>
              <span class="w-1.5 h-1.5 rounded-full bg-current opacity-70"></span>{@status}
            </span>
            <%= if @patient do %>
              <button phx-click="tab" phx-value-t="patient" title="Active patient — Luna answers for this patient. Open the Patient tab."
                class="inline-flex items-center gap-2 text-xs rounded-full border border-sky-200 bg-sky-50 text-sky-800 pl-2.5 pr-1 py-0.5 transition hover:border-sky-400">
                <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2"/><circle cx="12" cy="7" r="4"/></svg>
                <span class="font-semibold">{@patient["name"]}</span>
                <span class="text-sky-600">{Enum.join(Enum.reject([@patient["age"] && "#{@patient["age"]} #{String.slice(@patient["sex"] || "", 0, 1) |> String.upcase()}", @patient["stage"] && "stage #{@patient["stage"]}"], &is_nil/1), " · ")}</span>
                <span phx-click="patient_clear" onclick="event.stopPropagation()" title="Clear patient context"
                  class="w-5 h-5 grid place-items-center rounded-full text-sky-500 hover:bg-sky-200 hover:text-sky-900 transition">×</span>
              </button>
            <% end %>
          </div>
          <div class="self-center flex items-center gap-3 flex-wrap justify-center">
            <label class="flex items-center gap-1.5 text-[11px] font-medium text-slate-500">Cancer
              <form phx-change="guideline">
                <select name="key" class="text-xs bg-white border border-slate-200 rounded-lg px-2 py-1.5 text-slate-700 font-semibold shadow-sm focus:border-violet-400 focus:outline-none">
                  <%= for gd <- @guidelines do %><option value={gd["key"]} selected={gd["key"] == @guideline}>{gd["label"]}</option><% end %>
                </select>
              </form>
            </label>
            <label class="flex items-center gap-1.5 text-[11px] font-medium text-slate-500">Diagram
              <form phx-change="page">
                <select name="code" class="text-xs bg-white border border-slate-200 rounded-lg px-2 py-1.5 text-slate-700 shadow-sm max-w-[230px] focus:border-violet-400 focus:outline-none">
                  <%= for p <- @pages do %><option value={p["code"]} selected={p["code"] == @page}>{p["code"]} · {p["label"]}</option><% end %>
                </select>
              </form>
            </label>
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
          <div class="self-center flex items-center gap-4 flex-wrap justify-center">
            <span class="text-[10px] font-bold uppercase tracking-wider text-slate-400">Legend</span>
            <%= for {name, color} <- @legend do %>
              <span class="flex items-center gap-1 text-[11px] text-slate-500"><span class="w-2.5 h-2.5 rounded-sm" style={"background:#{color}"}></span>{name}</span>
            <% end %>
          </div>
        </header>

        <div class="relative flex-1 min-h-0 bg-[radial-gradient(#e2e8f0_1px,transparent_1px)] [background-size:20px_20px]">
            <div id="cy" phx-hook="Cyto" phx-update="ignore" class="absolute inset-0"></div>
            <div class="pointer-events-none absolute bottom-3 right-3 text-[10px] text-slate-400 bg-white/70 rounded-full px-2.5 py-1 border border-slate-200">drag · scroll-zoom · click a node</div>
        </div>
      </main>

      <section class="w-[320px] shrink-0 flex flex-col bg-white/70 backdrop-blur-md border-l border-white/60">
            <div class="flex text-xs font-medium border-b border-slate-100">
              <%= for {t, label} <- (if @patient, do: [{"patient", "⚕ Patient"}], else: []) ++ [{"todo", "✓ To-Do"}, {"timeline", "🕑 Timeline"}, {"detail", "◇ Detail"}] do %>
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
                  <div class="mt-4 text-[10px] text-slate-400 italic">From the {@guideline_label} workup pages — tick items completed for this case.</div>

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

                <% @tab == "patient" and not is_nil(@patient) -> %>
                  <% d = @patient_detail || %{} %>
                  <div class="flex items-start justify-between gap-2 mb-3">
                    <div>
                      <div class="text-[11px] uppercase tracking-wider text-slate-400 font-semibold">Active patient</div>
                      <div class="text-sm font-semibold text-slate-900 mt-0.5">{@patient["name"]}</div>
                      <div class="text-[11px] text-slate-500">
                        {Enum.join(Enum.reject([@patient["sex"], @patient["age"] && "#{@patient["age"]} y", @patient["mrn"] && "MRN #{@patient["mrn"]}", @patient["birth_date"] && "DOB #{@patient["birth_date"]}"], &is_nil/1), " · ")}
                      </div>
                    </div>
                    <button phx-click="patient_clear" class="text-[11px] px-2 py-1 rounded-full border border-slate-200 bg-white text-slate-500 hover:border-red-300 hover:text-red-600 transition">Clear</button>
                  </div>
                  <div class="rounded-xl border border-sky-200 bg-sky-50/70 px-3 py-2 mb-3">
                    <div class="text-[10px] font-bold uppercase tracking-wider text-sky-700">Guideline</div>
                    <div class="flex items-center gap-2 mt-1">
                      <span class={["text-[10.5px] font-semibold px-2 py-0.5 rounded-full border", guideline_tint(@patient["guideline"])]}>{guideline_label(@guidelines, @patient["guideline"])}</span>
                      <span class="text-[11px] text-slate-600">{@patient["diagnosis"] || "no oncologic diagnosis on record"}<%= if @patient["stage"], do: " · stage #{@patient["stage"]}", else: "" %></span>
                    </div>
                    <div class="text-[10.5px] text-sky-800/80 mt-1.5">Luna prepends this patient's context to every question while they are active.</div>
                  </div>
                  <%= cond do %>
                    <% @patient_loading -> %>
                      <div class="text-[12px] text-slate-500 flex items-center gap-2 py-3"><span class="w-2 h-2 rounded-full bg-sky-500 animate-pulse"></span> Loading FHIR record…</div>
                    <% d["error"] -> %>
                      <div class="rounded-lg border border-red-200 bg-red-50 p-2.5 text-[12px] text-red-700 break-all">Couldn't load the FHIR record: {d["error"]}</div>
                    <% true -> %>
                      <div class="text-[10px] font-bold uppercase tracking-wider text-slate-400 mt-2 mb-1">Conditions · {length(d["conditions"] || [])}</div>
                      <%= if (d["conditions"] || []) == [] do %><div class="text-[12px] text-slate-400 italic">None on record.</div><% end %>
                      <div class="space-y-1.5">
                        <%= for c <- d["conditions"] || [] do %>
                          <div class={["rounded-lg border px-2.5 py-1.5", if(c["oncologic"], do: "border-violet-200 bg-violet-50/50", else: "border-slate-200 bg-white")]}>
                            <div class="text-[12px] font-medium text-slate-800">{c["display"] || "—"}</div>
                            <div class="text-[10.5px] text-slate-500">
                              {Enum.join(Enum.reject([c["code"] && "#{c["code"]}#{if c["system"], do: " (#{c["system"]})", else: ""}", c["stage"] && "stage #{c["stage"]}", c["status"], c["onset"] && "onset #{c["onset"]}"], &is_nil/1), " · ")}
                            </div>
                          </div>
                        <% end %>
                      </div>
                      <div class="text-[10px] font-bold uppercase tracking-wider text-slate-400 mt-3 mb-1">Encounters · {length(d["encounters"] || [])}</div>
                      <%= if (d["encounters"] || []) == [] do %><div class="text-[12px] text-slate-400 italic">None on record.</div><% end %>
                      <div class="space-y-1">
                        <%= for e <- Enum.take(d["encounters"] || [], 8) do %>
                          <div class="flex items-baseline gap-2 text-[11.5px]">
                            <span class="text-slate-500 shrink-0 w-[78px]">{e["date"] || "—"}</span>
                            <span class="text-slate-800">{e["type"] || e["class"] || "encounter"}</span>
                            <span class="text-slate-400 ml-auto">{e["status"]}</span>
                          </div>
                        <% end %>
                      </div>
                      <div class="flex flex-wrap gap-1.5 mt-4">
                        <button phx-click="suggest" phx-value-q={patient_question(@patient)} class="text-[11px] px-2.5 py-1 rounded-full border border-violet-300 bg-violet-50 text-violet-700 hover:bg-violet-100 transition">Ask Luna: next steps</button>
                        <button phx-click="suggest" phx-value-q="Which surveillance schedule applies after treatment for this patient?" class="text-[11px] px-2.5 py-1 rounded-full border border-slate-200 bg-white text-slate-600 hover:border-violet-300 transition">Surveillance</button>
                        <%= if d["resource_url"] do %>
                          <a href={d["resource_url"]} target="_blank" rel="noopener" class="text-[11px] px-2.5 py-1 rounded-full border border-sky-200 bg-sky-50 text-sky-700 hover:bg-sky-100 transition">Open FHIR Patient ↗</a>
                        <% end %>
                      </div>
                      <%= if d["source"] do %>
                        <div class="text-[10px] text-slate-400 mt-3">Source: {d["source"]}<%= if d["server"], do: " · #{d["server"]}", else: "" %></div>
                      <% end %>
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

              <%= if @sections != [] do %>
              <div class="mt-5 border-t border-slate-100 pt-4">
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
            </div>
          </section>

      <%!-- ═══ Patient roster modal (TrakCare / FHIR R4 via API /patients) ═══ --%>
      <%= if @patients_open do %>
        <div class="fixed inset-0 z-50 bg-slate-900/40 backdrop-blur-sm grid place-items-center fade-up">
          <div phx-click-away="patients_close" phx-window-keydown="patients_close" phx-key="Escape"
               class="w-[880px] max-w-[95vw] max-h-[85vh] flex flex-col rounded-2xl bg-white/90 backdrop-blur-xl shadow-2xl border border-white/60 overflow-hidden">
            <div class="flex items-center gap-3 px-5 py-4 border-b border-slate-100/80">
              <div class="w-9 h-9 rounded-xl bg-gradient-to-br from-violet-600 to-indigo-600 text-white grid place-items-center shadow-sm">
                <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M22 21v-2a4 4 0 0 0-3-3.87"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/></svg>
              </div>
              <div class="min-w-0">
                <div class="font-bold text-slate-900 leading-none">Patient Roster</div>
                <div class="text-[11px] text-slate-500 mt-1 truncate">
                  {source_label(@patients)}<%= if @patients && @patients["fetched_at"], do: " · fetched #{@patients["fetched_at"]}#{if @patients["cached"], do: " (cached)", else: ""}", else: "" %>
                </div>
              </div>
              <%= if @patients do %>
                <span class={["text-[10px] font-bold uppercase tracking-wider px-2 py-0.5 rounded-full border", source_tint(@patients["source"])]}>{@patients["source"]}</span>
              <% end %>
              <div class="ml-auto flex items-center gap-1.5">
                <button phx-click="patients_refresh" title="Refresh from source" disabled={@patients_loading}
                  class="w-8 h-8 rounded-lg border border-slate-200 bg-white text-slate-500 grid place-items-center transition hover:border-violet-300 hover:text-violet-700 disabled:opacity-50">
                  <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class={if(@patients_loading, do: "animate-spin", else: "")}><path d="M21 12a9 9 0 1 1-3-6.7"/><path d="M21 3v6h-6"/></svg>
                </button>
                <button phx-click="patients_close" title="Close (Esc)"
                  class="w-8 h-8 rounded-lg border border-slate-200 bg-white text-slate-500 grid place-items-center transition hover:border-red-300 hover:text-red-600">
                  <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M18 6 6 18"/><path d="m6 6 12 12"/></svg>
                </button>
              </div>
            </div>

            <div class="grid grid-cols-6 gap-2 px-5 pt-4">
              <div class="rounded-xl border border-slate-200 bg-white/80 px-3 py-2">
                <div class="text-[10px] font-bold uppercase tracking-wider text-slate-400">Patients</div>
                <div class="text-xl font-bold text-slate-900 leading-tight">{(@patients || %{})["total"] || 0}</div>
              </div>
              <%= for gd <- @guidelines do %>
                <div class={["rounded-xl border px-3 py-2", guideline_tint(gd["key"])]}>
                  <div class="text-[10px] font-bold uppercase tracking-wider opacity-70">{gd["label"]}</div>
                  <div class="text-xl font-bold leading-tight">{((@patients || %{})["by_guideline"] || %{})[gd["key"]] || 0}</div>
                </div>
              <% end %>
            </div>

            <div class="flex flex-wrap items-center gap-1.5 px-5 pt-3 pb-2">
              <button phx-click="patients_filter" phx-value-key="all"
                class={["text-[11px] px-2.5 py-1 rounded-full border transition", if(is_nil(@patients_filter), do: "bg-gradient-to-br from-violet-600 to-indigo-600 text-white border-transparent shadow-sm", else: "bg-white text-slate-600 border-slate-200 hover:border-violet-300")]}>
                All · {(@patients || %{})["total"] || 0}
              </button>
              <%= for gd <- @guidelines do %>
                <button phx-click="patients_filter" phx-value-key={gd["key"]}
                  class={["text-[11px] px-2.5 py-1 rounded-full border transition", if(@patients_filter == gd["key"], do: "bg-gradient-to-br from-violet-600 to-indigo-600 text-white border-transparent shadow-sm", else: "bg-white text-slate-600 border-slate-200 hover:border-violet-300")]}>
                  {gd["label"]} · {((@patients || %{})["by_guideline"] || %{})[gd["key"]] || 0}
                </button>
              <% end %>
            </div>

            <div class="flex-1 min-h-0 overflow-auto px-5 pb-3">
              <%= cond do %>
                <% @patients_loading -> %>
                  <div class="py-12 grid place-items-center text-slate-500 text-sm">
                    <div class="flex items-center gap-2"><span class="w-2 h-2 rounded-full bg-violet-500 animate-pulse"></span> Loading roster…</div>
                  </div>
                <% @patients_error -> %>
                  <div class="my-4 rounded-xl border border-red-200 bg-red-50 p-4">
                    <div class="text-sm font-semibold text-red-700">Couldn't load the roster</div>
                    <div class="text-[12px] text-red-600 mt-1 break-all">{@patients_error}</div>
                    <button phx-click="patients_refresh" class="mt-3 text-[11px] px-2.5 py-1 rounded-full border border-red-300 bg-white text-red-700 hover:bg-red-100 transition">Retry</button>
                  </div>
                <% true -> %>
                  <table class="w-full text-left text-[12.5px]">
                    <thead class="sticky top-0 bg-white/95 backdrop-blur text-[10px] font-bold uppercase tracking-wider text-slate-400">
                      <tr>
                        <th class="py-2 pr-3">Patient</th>
                        <th class="py-2 pr-3">Sex / Age</th>
                        <th class="py-2 pr-3">Diagnosis</th>
                        <th class="py-2 pr-3">Guideline</th>
                        <th class="py-2">Last encounter</th>
                      </tr>
                    </thead>
                    <tbody class="divide-y divide-slate-100">
                      <%= for p <- visible_patients(@patients, @patients_filter) do %>
                        <tr phx-click="patient_select" phx-value-id={p["id"]} class={["cursor-pointer transition hover:bg-violet-50/60", if(@patient && @patient["id"] == p["id"], do: "bg-sky-50/80 ring-1 ring-inset ring-sky-200", else: "")]}>
                          <td class="py-2.5 pr-3">
                            <div class="font-semibold text-slate-800">{p["name"]}</div>
                            <div class="text-[10.5px] text-slate-400">{p["mrn"] || "—"}</div>
                          </td>
                          <td class="py-2.5 pr-3 text-slate-600 capitalize">{p["sex"] || "—"}<%= if p["age"], do: " · #{p["age"]}", else: "" %></td>
                          <td class="py-2.5 pr-3">
                            <div class="text-slate-800">{p["diagnosis"] || "—"}</div>
                            <div class="text-[10.5px] text-slate-400">{p["diagnosis_code"] || ""}<%= if p["stage"], do: " · stage #{p["stage"]}", else: "" %></div>
                          </td>
                          <td class="py-2.5 pr-3">
                            <span class={["text-[10.5px] font-semibold px-2 py-0.5 rounded-full border", guideline_tint(p["guideline"])]}>{guideline_label(@guidelines, p["guideline"])}</span>
                          </td>
                          <td class="py-2.5 text-slate-600">{p["last_encounter"] || "—"}</td>
                        </tr>
                      <% end %>
                      <%= if visible_patients(@patients, @patients_filter) == [] do %>
                        <tr><td colspan="5" class="py-8 text-center text-slate-400 italic">No patients in this view.</td></tr>
                      <% end %>
                    </tbody>
                  </table>
              <% end %>
            </div>

            <div class="flex items-center justify-between px-5 py-3 border-t border-slate-100/80 text-[11px] text-slate-500">
              <span>{length(visible_patients(@patients, @patients_filter))} of {(@patients || %{})["total"] || 0} shown</span>
              <span>Click a patient to switch Luna to their guideline</span>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    <script>(()=>{const c=document.getElementById('chat');if(c)c.scrollTop=c.scrollHeight})();</script>
    """
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Voice — Deepgram REST, ported from nxt-teach (NxtTeach.Voice.Deepgram + its
# VoiceController). Half-duplex: the browser records a clip, POSTs it to
# /voice/transcribe, the transcript becomes a normal Luna question, and Luna's
# answer is synthesized with Aura and pushed back as base64 for playback.
# The Deepgram key stays server-side, is read at call time, and is never logged.
# ─────────────────────────────────────────────────────────────────────────────
defmodule NccnUi.Voice do
  @moduledoc "Deepgram REST: `nova-3` STT and `aura-2-athena-en` TTS (env-overridable)."
  require Logger

  @listen_url "https://api.deepgram.com/v1/listen"
  @speak_url "https://api.deepgram.com/v1/speak"

  def listen_model, do: System.get_env("DEEPGRAM_LISTEN_MODEL", "nova-3")
  def speak_model, do: System.get_env("DEEPGRAM_SPEAK_MODEL", "aura-2-athena-en")

  def enabled?, do: api_key() != nil

  def transcribe(audio, content_type) do
    with {:ok, key} <- require_key() do
      request =
        Req.new(
          url: @listen_url,
          params: [model: listen_model(), smart_format: true],
          headers: [{"authorization", "Token " <> key}, {"content-type", content_type}],
          body: audio,
          retry: false,
          receive_timeout: 60_000
        )

      case Req.post(request) do
        {:ok, %Req.Response{status: 200, body: body}} ->
          transcript =
            get_in(body, ["results", "channels", Access.at(0), "alternatives", Access.at(0), "transcript"]) || ""

          {:ok, String.trim(transcript)}

        {:ok, %Req.Response{status: status}} ->
          Logger.warning("voice: deepgram listen returned #{status}")
          {:error, {:http, status}}

        {:error, reason} ->
          Logger.warning("voice: transport error #{inspect(reason)}")
          {:error, :transport}
      end
    end
  end

  @doc """
  Word-level timestamps for a clip, by running it back through nova-3. Used to sync the
  "Luna speaking" typewriter to the actual audio (Aura's speak endpoint returns no timings).
  Returns [[start_s, end_s], ...] in spoken order; [] on any failure so playback never waits on it.
  """
  def word_timings(audio, content_type) do
    with {:ok, key} <- require_key(),
         {:ok, %Req.Response{status: 200, body: body}} <-
           Req.post(
             Req.new(
               url: @listen_url,
               params: [model: listen_model(), smart_format: true],
               headers: [{"authorization", "Token " <> key}, {"content-type", content_type}],
               body: audio,
               retry: false,
               receive_timeout: 60_000
             )
           ) do
      words = get_in(body, ["results", "channels", Access.at(0), "alternatives", Access.at(0), "words"]) || []
      Enum.map(words, &[&1["start"], &1["end"]])
    else
      _ -> []
    end
  end

  def speak(text) do
    with {:ok, key} <- require_key() do
      request =
        Req.new(
          url: @speak_url,
          params: [model: speak_model()],
          headers: [{"authorization", "Token " <> key}],
          json: %{text: text},
          retry: false,
          receive_timeout: 60_000
        )

      case Req.post(request) do
        {:ok, %Req.Response{status: 200, body: audio} = resp} when is_binary(audio) ->
          # trust the real content type; "audio/mpeg" is what Aura returns by default
          mime = resp.headers |> Map.get("content-type", ["audio/mpeg"]) |> List.first() |> String.split(";") |> List.first()
          {:ok, audio, mime}

        {:ok, %Req.Response{status: status}} ->
          Logger.warning("voice: deepgram speak returned #{status}")
          {:error, {:http, status}}

        {:error, reason} ->
          Logger.warning("voice: transport error #{inspect(reason)}")
          {:error, :transport}
      end
    end
  end

  defp require_key do
    case api_key() do
      nil -> {:error, :not_configured}
      key -> {:ok, key}
    end
  end

  defp api_key do
    case System.get_env("DEEPGRAM_API_KEY") do
      key when is_binary(key) and key != "" -> key
      _ -> nil
    end
  end
end

defmodule NccnUi.VoiceController do
  use Phoenix.Controller, formats: [:json]
  import Plug.Conn

  # audio/* is passed through Plug.Parsers unread (see the Endpoint), so the raw
  # clip is still on the conn; read it ourselves with a hard cap (nxt-teach pattern).
  @max_bytes 10_000_000

  def status(conn, _params) do
    json(conn, %{enabled: NccnUi.Voice.enabled?(), listen_model: NccnUi.Voice.listen_model(), speak_model: NccnUi.Voice.speak_model()})
  end

  @doc "STT only — the fast half, so the spoken words land in the chat before the answer exists."
  def transcribe(conn, _params) do
    content_type = List.first(get_req_header(conn, "content-type")) || "audio/webm"

    cond do
      not NccnUi.Voice.enabled?() ->
        conn |> put_status(:service_unavailable) |> json(%{error: "voice is not configured on this server (DEEPGRAM_API_KEY)"})

      not String.starts_with?(content_type, "audio/") ->
        conn |> put_status(:unsupported_media_type) |> json(%{error: "send the recorded clip with an audio/* content type"})

      true ->
        case read_body(conn, length: @max_bytes) do
          {:ok, audio, conn} when byte_size(audio) > 0 ->
            case NccnUi.Voice.transcribe(audio, content_type) do
              {:ok, ""} ->
                conn |> put_status(:unprocessable_entity) |> json(%{error: "I couldn't hear anything in that clip — try again a little closer?"})

              {:ok, transcript} ->
                json(conn, %{transcript: transcript})

              {:error, _} ->
                conn |> put_status(:bad_gateway) |> json(%{error: "the voice service is unavailable right now"})
            end

          {:ok, _empty, conn} ->
            conn |> put_status(:unprocessable_entity) |> json(%{error: "the clip was empty"})

          {:more, _partial, conn} ->
            conn |> put_status(:request_entity_too_large) |> json(%{error: "clips are limited to 10 MB"})

          {:error, _reason} ->
            conn |> put_status(:bad_request) |> json(%{error: "could not read the clip"})
        end
    end
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

  # Same session + CSRF as the LiveView: the hook sends the page's csrf meta as x-csrf-token.
  scope "/voice" do
    pipe_through :browser
    get "/status", NccnUi.VoiceController, :status
    post "/transcribe", NccnUi.VoiceController, :transcribe
  end
end

defmodule NccnUi.Endpoint do
  use Phoenix.Endpoint, otp_app: :nccn
  @session_options [store: :cookie, key: "_nccn_key", signing_salt: "nccn_sign_1", same_site: "Lax"]
  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]]
  plug Plug.Static, at: "/js/phoenix", from: {:phoenix, "priv/static"}, only: ~w(phoenix.min.js)
  plug Plug.Static, at: "/js/lv", from: {:phoenix_live_view, "priv/static"}, only: ~w(phoenix_live_view.min.js)
  # audio/* is deliberately not parsed so /voice/transcribe can read the raw clip body
  plug Plug.Parsers, parsers: [:urlencoded, :multipart, :json], pass: ["audio/*"], json_decoder: Jason
  plug Plug.Session, @session_options
  plug NccnUi.Router
end

{:ok, _} = Supervisor.start_link([{Phoenix.PubSub, name: NccnUi.PubSub}, NccnUi.Endpoint], strategy: :one_for_one)
IO.puts("\nLuna copilot on http://127.0.0.1:#{System.get_env("PORT", "5901")}  (backend: #{System.get_env("NCCN_API", "http://127.0.0.1:8899")})")
Process.sleep(:infinity)
