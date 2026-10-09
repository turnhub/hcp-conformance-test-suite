defmodule HcpConformanceWeb.PageHTML do
  @moduledoc "The catalogue and hook pages."

  use HcpConformanceWeb, :html

  embed_templates "page_html/*"

  @doc "A check's requirements, for the catalogue."
  @spec needs([atom()]) :: String.t()
  def needs([]), do: "—"
  def needs(requires), do: Enum.map_join(requires, ", ", &to_string/1)
end
