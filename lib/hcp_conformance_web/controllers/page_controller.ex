defmodule HcpConformanceWeb.PageController do
  @moduledoc "Reference pages: the check catalogue and the conformance hook protocol."

  use HcpConformanceWeb, :controller

  alias HcpConformance.{Catalog, Spec}

  @hook_path Path.expand("../../../docs/HOOK.md", __DIR__)
  @external_resource @hook_path
  @hook @hook_path |> File.read!() |> HcpConformanceWeb.Markdown.to_html()

  def checks(conn, params) do
    version = version(params)

    render(conn, :checks,
      page_title: "Checks",
      checks: Catalog.all(version),
      version: version,
      versions: Enum.map(Spec.versions(), &{&1, Spec.label(&1)})
    )
  end

  # ?spec_version=2.0 shows another version's catalogue; anything unreadable shows v1's.
  defp version(params) do
    case Spec.parse(params["spec_version"]) do
      {:ok, version} when is_binary(version) -> version
      _default -> Spec.default()
    end
  end

  def hook(conn, _params) do
    render(conn, :hook, page_title: "Conformance hook", hook: @hook)
  end
end
