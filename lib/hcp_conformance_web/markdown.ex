defmodule HcpConformanceWeb.Markdown do
  @moduledoc """
  Renders Markdown: the repository's docs as pages, so a doc stays the single
  source of what its page says, and the assistants' replies on the chat page.

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

  @options [extension: [table: true, strikethrough: true], syntax_highlight: nil]

  @doc "The doc as HTML, its title dropped: the page header already says it."
  @spec to_html(String.t()) :: String.t()
  def to_html(markdown) do
    markdown
    |> MDEx.to_html!(@options)
    |> String.replace(~r{\A<h1>.*?</h1>\n}, "")
    |> style()
  end

  @doc """
  An assistant's reply as HTML. A reply is text from a vendor that saw the
  person's memories, so it is rendered more warily than a doc: raw HTML shows
  as text, links to scripts are dropped, and an image becomes its description.
  A browser fetches an image without asking, so a reply that a memory talked
  into one could send recalled memories to any host in the image's URL.
  """
  @spec reply_to_html(String.t()) :: String.t()
  def reply_to_html(markdown) do
    markdown
    |> MDEx.parse_document!(@options)
    |> MDEx.traverse_and_update(&describe_image/1)
    |> MDEx.to_html!(Keyword.put(@options, :render, escape: true))
    |> style()
  end

  @spec describe_image(MDEx.Document.md_node()) :: MDEx.Document.md_node()
  defp describe_image(%MDEx.Image{nodes: nodes}),
    do: %MDEx.Text{literal: Enum.map_join(nodes, &plain_text/1)}

  defp describe_image(node), do: node

  @spec plain_text(MDEx.Document.md_node()) :: String.t()
  defp plain_text(%{literal: literal}) when is_binary(literal), do: literal
  defp plain_text(%{nodes: nodes}), do: Enum.map_join(nodes, &plain_text/1)
  defp plain_text(_node), do: ""

  @spec style(String.t()) :: String.t()
  defp style(html) do
    html
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
