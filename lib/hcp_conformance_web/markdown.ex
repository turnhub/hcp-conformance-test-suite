defmodule HcpConformanceWeb.Markdown do
  @moduledoc """
  Renders the repository's Markdown docs as pages, so a doc stays the single
  source of what its page says.

  Tailwind's preflight strips headings, lists, tables and code blocks of their
  default look. Each tag MDEx emits gets the daisyUI component, or the core
  components' heading style, it would have if the page were written in HEEx.
  Raw HTML in the Markdown is escaped, so every tag here is one MDEx made.
  """

  @classes [
    {"h2", "text-lg font-semibold leading-8 mt-8"},
    {"h3", "font-semibold mt-6"},
    {"ul", "list-disc pl-6 space-y-1"},
    {"ol", "list-decimal pl-6 space-y-1"},
    {"table", "table table-sm"},
    {"pre", "bg-base-300 rounded-box p-4 overflow-x-auto text-sm"}
  ]

  @doc "The doc as HTML, its title dropped: the page header already says it."
  @spec to_html(String.t()) :: String.t()
  def to_html(markdown) do
    markdown
    |> MDEx.to_html!(extension: [table: true], syntax_highlight: nil)
    |> String.replace(~r{\A<h1>.*?</h1>\n}, "")
    |> String.replace(
      ~r{<table>(.*?)</table>}s,
      ~s(<div class="overflow-x-auto"><table>\\1</table></div>)
    )
    |> String.replace("<a href=", ~s(<a class="link link-primary" href=))
    |> add_classes()
  end

  @spec add_classes(String.t()) :: String.t()
  defp add_classes(html) do
    Enum.reduce(@classes, html, fn {tag, class}, html ->
      String.replace(html, "<#{tag}>", ~s(<#{tag} class="#{class}">))
    end)
  end
end
