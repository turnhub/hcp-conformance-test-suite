defmodule HcpConformance.Web.Html do
  @moduledoc "Server-rendered pages for the hosted runner: no JavaScript, no assets, readable on a phone."

  alias HcpConformance.{Catalog, Report}

  defp esc(nil), do: ""
  defp esc(value) when is_binary(value), do: Plug.HTML.html_escape(value)
  defp esc(value), do: value |> to_string() |> Plug.HTML.html_escape()

  @css """
  :root{--bg:#fbfbfa;--fg:#1d1d1b;--muted:#6b6b66;--line:#e2e1dc;--card:#fff;--pass:#1f7a3d;--fail:#b3261e;--warn:#9a6700;--skip:#6b6b66;--accent:#2f5bd3}
  @media (prefers-color-scheme:dark){:root{--bg:#161615;--fg:#ecebe6;--muted:#a3a29b;--line:#33322f;--card:#1e1e1c;--pass:#5cc27f;--fail:#f2867d;--warn:#e0b252;--skip:#a3a29b;--accent:#8aa8ff}}
  *{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.5 system-ui,-apple-system,Segoe UI,sans-serif}
  main{max-width:1040px;margin:0 auto;padding:24px 16px 64px}a{color:var(--accent)}h1{font-size:24px;margin:0 0 4px}h2{font-size:18px;margin:28px 0 8px}
  .muted{color:var(--muted)}.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:16px;margin:12px 0}
  label{display:block;font-weight:600;margin:12px 0 4px}input[type=text],input[type=url],input[type=password]{width:100%;padding:9px 10px;border:1px solid var(--line);border-radius:8px;background:var(--bg);color:var(--fg);font:inherit}
  .hint{font-size:13px;color:var(--muted);margin-top:3px}button{margin-top:16px;padding:10px 16px;border:0;border-radius:8px;background:var(--accent);color:#fff;font:inherit;font-weight:600;cursor:pointer}
  button.secondary{background:transparent;color:var(--accent);border:1px solid var(--accent)}
  .grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:12px}
  table{width:100%;border-collapse:collapse;font-size:14px}th,td{text-align:left;padding:7px 6px;border-bottom:1px solid var(--line);vertical-align:top}
  th{font-size:12px;text-transform:uppercase;letter-spacing:.04em;color:var(--muted)}.scroll{overflow-x:auto}
  .badge{display:inline-block;padding:2px 8px;border-radius:999px;font-size:12px;font-weight:700;border:1px solid currentColor}
  .pass{color:var(--pass)}.fail,.error{color:var(--fail)}.warn{color:var(--warn)}.skip,.na,.queued,.running{color:var(--skip)}
  .verdict{font-size:20px;padding:4px 14px}code,pre{font:12.5px/1.45 ui-monospace,SFMono-Regular,Menlo,monospace}
  pre{white-space:pre-wrap;word-break:break-word;background:var(--bg);border:1px solid var(--line);border-radius:6px;padding:8px;margin:6px 0}
  details summary{cursor:pointer;color:var(--accent)}.msg{margin-top:4px}.counts span{margin-right:14px}
  fieldset{border:1px solid var(--line);border-radius:10px;padding:4px 14px 14px;margin:14px 0}legend{font-weight:700;padding:0 6px}
  .checks label{display:inline-flex;gap:6px;font-weight:400;margin:4px 14px 4px 0}
  """

  defp layout(title, body, opts \\ []) do
    refresh = if opts[:refresh], do: ~s(<meta http-equiv="refresh" content="#{opts[:refresh]}">), else: ""

    """
    <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    #{refresh}<title>#{esc(title)}</title><style>#{@css}</style></head>
    <body><main><p class="muted"><a href="/">HCP conformance suite</a> · <a href="/checks">Checks</a> · <a href="/docs/hook">Conformance hook</a></p>
    #{body}</main></body></html>
    """
  end

  @doc "The home page: the run form."
  @spec home(map()) :: String.t()
  def home(%{reference: reference, error: error}) do
    groups =
      Enum.map_join(Catalog.groups(), "", fn group ->
        ~s(<label><input type="checkbox" name="groups[]" value="#{group}" checked> #{group}</label>)
      end)

    reference_card =
      if reference do
        """
        <div class="card"><strong>Try it first.</strong> This instance hosts a reference HCP implementation with the conformance hook.
        <form method="post" action="/runs" style="display:inline">
        <input type="hidden" name="target" value="#{esc(reference.target)}"><input type="hidden" name="hook_url" value="#{esc(reference.hook_url)}">
        <input type="hidden" name="hook_secret" value="#{esc(reference.hook_secret)}"><input type="hidden" name="label" value="reference implementation">
        <button class="secondary" type="submit">Run against the reference implementation</button></form></div>
        """
      else
        ""
      end

    error_html = if error, do: ~s(<div class="card fail"><strong>#{esc(error)}</strong></div>), else: ""

    layout("HCP conformance suite", """
    <h1>HCP conformance suite</h1>
    <p class="muted">Checks an implementation of the Human Context Protocol v1 (#{Report.spec_version()}) against the specification, over the network.
    Suite #{Report.suite_version()}. Credentials are used for the run and never stored.</p>
    #{reference_card}#{error_html}
    <form method="post" action="/runs" class="card">
      <label for="target">HCP base URL</label>
      <input id="target" name="target" type="url" required placeholder="https://vault.example.com">
      <div class="hint">The discovery document is read from <code>{base}/.well-known/hcp-configuration</code>.</div>
      <label for="discovery_url">Discovery URL (optional)</label>
      <input id="discovery_url" name="discovery_url" type="url" placeholder="Only if it is not under the base URL">
      <fieldset><legend>Conformance hook (full run)</legend>
        <div class="hint">Lets the suite create a fresh test subject and the grants each check needs. See <a href="/docs/hook">the hook</a>.</div>
        <div class="grid"><div><label for="hook_url">Hook URL</label><input id="hook_url" name="hook_url" type="url" placeholder="https://vault.example.com/conformance-hook"></div>
        <div><label for="hook_secret">Hook secret</label><input id="hook_secret" name="hook_secret" type="password" autocomplete="off"></div></div>
      </fieldset>
      <fieldset><legend>Or: existing credentials (partial run)</legend>
        <div class="hint">Without the hook, checks that need grants created on demand are skipped. Entries the suite creates are hard-deleted at the end.</div>
        <div class="grid"><div><label for="person_token">Person token</label><input id="person_token" name="person_token" type="password" autocomplete="off"></div>
        <div><label for="agent_token">Agent token (optional)</label><input id="agent_token" name="agent_token" type="password" autocomplete="off">
        <div class="hint">A client holding read and write on the category below.</div></div></div>
        <label for="subject_did">Subject DID (optional)</label><input id="subject_did" name="subject_did" type="text" placeholder="did:hcp:user:…">
      </fieldset>
      <label for="category">Category (optional)</label>
      <input id="category" name="category" type="text" placeholder="Defaults to the first supported category">
      <label>Groups</label><div class="checks">#{groups}</div>
      <button type="submit">Run the suite</button>
    </form>
    <p class="muted">Also available as an API (<code>POST /api/runs</code>) and a CLI. See the README.</p>
    """)
  end

  @doc "A run's live progress or final report."
  @spec run(map()) :: String.t()
  def run(run) do
    report = run.report
    results = if report, do: report.results, else: run.results
    running = run.status in [:queued, :running]
    exchanges = if report, do: Map.new(report.transcript, &{&1.id, &1}), else: %{}

    verdict =
      cond do
        report ->
          partial =
            if report.partial,
              do:
                ~s( <span class="muted" style="font-size:14px">selected checks only, not a conformance claim</span>),
              else: ""

          ~s(<span class="badge verdict #{report.verdict}">#{String.upcase(report.verdict)}</span>#{partial})

        run.status == :failed ->
          ~s(<span class="badge verdict fail">SUITE ERROR</span>)

        true ->
          ~s(<span class="badge verdict running">RUNNING #{length(results)}/#{run.total || "?"}</span>)
      end

    summary =
      if report do
        """
        <div class="card counts"><strong>MUST</strong> #{counts(report.summary.must)}<br><strong>SHOULD</strong> #{counts(report.summary.should)}
        <p class="muted">Capabilities: #{esc(Enum.join(report.capabilities, ", "))}. Categories: #{esc(report.categories.primary)} (primary), #{esc(report.categories.second || "none")} (second).
        <a href="/api/runs/#{run.id}/report.json">Download the JSON report</a></p></div>
        """
      else
        ""
      end

    notes =
      Enum.map_join(run.setup_notes ++ List.wrap(run.error), "", &~s(<div class="card warn">#{esc(&1)}</div>))

    rows =
      Enum.map_join(results, "", fn result ->
        detail =
          if result.status in [:fail, :warn, :error] and exchanges != %{} do
            trace = Enum.map_join(result.exchanges, "", &exchange_html(exchanges[&1]))
            if trace == "", do: "", else: "<details><summary>HTTP exchanges</summary>#{trace}</details>"
          else
            ""
          end

        message = if result.message, do: ~s(<div class="msg muted">#{esc(result.message)}</div>), else: ""

        """
        <tr><td><span class="badge #{result.status}">#{result.status |> to_string() |> String.upcase()}</span></td>
        <td><code>#{esc(result.id)}</code><div>#{esc(result.title)}</div>#{message}#{detail}</td>
        <td>§#{esc(result.section)}</td><td>#{result.level |> to_string() |> String.upcase()}</td></tr>
        """
      end)

    layout(
      "HCP conformance run",
      """
      <h1>Conformance run #{verdict}</h1>
      <p class="muted">#{esc(run.config.target)} · #{esc(run.config.mode)} mode#{if run.config.label, do: " · " <> esc(run.config.label), else: ""} · started #{esc(run.created_at)}</p>
      #{summary}#{notes}
      <div class="card scroll"><table><thead><tr><th>Result</th><th>Check</th><th>Section</th><th>Level</th></tr></thead><tbody>#{rows}</tbody></table></div>
      """,
      refresh: if(running, do: 2)
    )
  end

  defp counts(counts) do
    Enum.map_join([:pass, :fail, :warn, :skip, :error, :na], "", fn key ->
      ~s(<span class="#{key}">#{Map.fetch!(counts, key)} #{if key == :na, do: "n/a", else: key}</span>)
    end)
  end

  defp exchange_html(nil), do: ""

  defp exchange_html(exchange) do
    request = if exchange.request_body, do: "<pre>#{esc(exchange.request_body)}</pre>", else: ""
    response = esc(exchange.response_body || exchange.error || "")

    """
    <div><code>#{esc(exchange.method)} #{esc(exchange.url)} → #{esc(exchange.status || "no response")}</code>#{request}<pre>#{response}</pre></div>
    """
  end

  @doc "The check catalogue."
  @spec checks() :: String.t()
  def checks do
    rows =
      Enum.map_join(Catalog.all(), "", fn check ->
        needs = if check.requires == [], do: "—", else: Enum.map_join(check.requires, ", ", &to_string/1)

        "<tr><td><code>#{esc(check.id)}</code></td><td>§#{esc(check.section)}</td><td>#{check.level |> to_string() |> String.upcase()}</td><td>#{esc(check.title)}</td><td class=\"muted\">#{esc(needs)}</td></tr>"
      end)

    layout("HCP conformance checks", """
    <h1>Checks</h1><p class="muted">#{length(Catalog.all())} checks against HCP v1 #{Report.spec_version()}.</p>
    <div class="card scroll"><table><thead><tr><th>Check</th><th>Section</th><th>Level</th><th>Requirement</th><th>Needs</th></tr></thead><tbody>#{rows}</tbody></table></div>
    """)
  end

  @doc "A Markdown document shown as preformatted text."
  @spec document(String.t(), String.t()) :: String.t()
  def document(title, markdown), do: layout(title, "<div class=\"card\"><pre>#{esc(markdown)}</pre></div>")

  @doc "A plain error page."
  @spec error(String.t()) :: String.t()
  def error(message), do: layout("Error", ~s(<div class="card fail"><strong>#{esc(message)}</strong></div>))
end
