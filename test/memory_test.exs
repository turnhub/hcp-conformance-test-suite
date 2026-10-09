defmodule HcpConformance.MemoryTest do
  # The chat page's side of HCP, against a reference implementation: memories go
  # in through one agent grant and come back out for the questions they answer.
  use ExUnit.Case, async: true

  alias HcpConformance.{Config, Memory, ReferenceTarget}

  @shoes "I need high arch support in my running shoes."
  @diet "I am vegetarian and avoid mushrooms."

  setup do
    target = ReferenceTarget.start!()
    {:ok, config} = Config.new(ReferenceTarget.hook_config(target))
    {:ok, memory} = Memory.connect(config)
    %{memory: memory, target: target}
  end

  test "connects as an agent with a grant on one category", %{memory: memory} do
    assert Memory.categories(memory) == ["general_preferences"]
  end

  test "a memory saved by one assistant is recalled for a question it answers", %{memory: memory} do
    assert {:ok, %{"id" => "urn:uuid:" <> _}} = Memory.remember(memory, @shoes)

    assert {:ok, [entry]} = Memory.recall(memory, "Which running shoes should I buy?")
    assert Memory.preference(entry) == @shoes
  end

  test "recall hands over only the memories the question touches", %{memory: memory} do
    {:ok, _shoes} = Memory.remember(memory, @shoes)
    {:ok, _diet} = Memory.remember(memory, @diet)

    assert {:ok, [entry]} = Memory.recall(memory, "Plan a vegetarian dinner for me")
    assert Memory.preference(entry) == @diet
    assert {:ok, []} = Memory.recall(memory, "What is the capital of France?")
  end

  test "instructions give ChatGPT the recalled memories, and say when there are none", %{
    memory: memory
  } do
    {:ok, _entry} = Memory.remember(memory, @shoes)
    {:ok, entries} = Memory.recall(memory, "running shoes")

    assert Memory.instructions(entries) =~ "- #{@shoes} (general_preferences, user-declared)"
    assert Memory.instructions([]) =~ "No memories from the user's HCP vault apply"
  end

  test "closing deletes the hook subject and stops the connection's processes", %{
    memory: memory,
    target: target
  } do
    {:ok, _entry} = Memory.remember(memory, @shoes)
    assert Agent.get(target.store, &map_size(&1.subjects)) == 1

    assert Memory.close(memory) == :ok

    assert Agent.get(target.store, &map_size(&1.subjects)) == 0
    refute Process.alive?(memory.context.transcript)
  end

  test "an unreachable vault is an error to show, not a crash" do
    {:ok, config} =
      Config.new(%{
        target: "http://127.0.0.1:1",
        hook_url: "http://127.0.0.1:1/conformance-hook",
        hook_secret: "s",
        allow_private: true
      })

    assert {:error, "cannot act as an agent on this target: " <> _notes} = Memory.connect(config)
  end
end
