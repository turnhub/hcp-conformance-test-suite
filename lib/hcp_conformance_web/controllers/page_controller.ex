defmodule HcpConformanceWeb.PageController do
  @moduledoc "Reference pages: the check catalogue and the conformance hook protocol."

  use HcpConformanceWeb, :controller

  alias HcpConformance.Catalog

  @hook_path Path.expand("../../../docs/HOOK.md", __DIR__)
  @external_resource @hook_path
  @hook @hook_path |> File.read!() |> HcpConformanceWeb.Markdown.to_html()

  def checks(conn, _params) do
    render(conn, :checks, page_title: "Checks", checks: Catalog.all())
  end

  def hook(conn, _params) do
    render(conn, :hook, page_title: "Conformance hook", hook: @hook)
  end
end
