defmodule HcpConformanceWeb.MarkdownTest do
  use ExUnit.Case, async: true

  alias HcpConformanceWeb.Markdown

  test "drops the title, which the page header already shows" do
    assert Markdown.to_html("# Title\n\nBody\n") == "<p>Body</p>"
  end

  test "styles the tags Tailwind's preflight strips with daisyUI components" do
    html = Markdown.to_html("## Section\n\n- item\n\n[spec](https://example.com)\n")

    assert html =~ ~s(<h2 class="text-lg font-semibold leading-8 mt-8">Section</h2>)
    assert html =~ ~s(<ul class="list-disc pl-6 space-y-1">)
    assert html =~ ~s(<a class="link link-primary" href="https://example.com">spec</a>)
  end

  test "wraps tables so they scroll on narrow screens" do
    html = Markdown.to_html("| a | b |\n| --- | --- |\n| 1 | 2 |\n")

    assert html =~
             ~r{\A<div class="overflow-x-auto"><table class="table table-sm">.*</table></div>}s
  end

  test "renders code blocks unhighlighted, without inline theme styles" do
    assert Markdown.to_html("```json\n{\"a\": 1}\n```\n") ==
             ~s(<pre class="bg-base-300 rounded-box p-4 overflow-x-auto text-sm"><code class="language-json">{&quot;a&quot;: 1}\n</code></pre>)
  end

  test "escapes raw HTML, so every tag on the page is one MDEx made" do
    refute Markdown.to_html("<script>alert(1)</script>\n") =~ "<script>"
  end
end
