defmodule HcpConformance.Check do
  @moduledoc """
  One conformance check: a single requirement of the specification, the section
  it comes from, and the function that tests it.

  `level` is the requirement's strength. A failed `:must` makes the target
  non-conformant; a failed `:should` is reported as a warning.

  `requires` lists what the run must have for the check to mean anything:

  - `:person` a credential for the person (the subject of the instance)
  - `:agent` a client credential holding read and write on the primary category
  - `:hook` the conformance hook, to create grants on demand
  - `:rest` the RESTful HTTP transport
  - `:mcp` the MCP transport
  - `:second_category` a second supported category

  `phase: :post` checks run after every other check and inspect the transcript of
  the whole run instead of making requests of their own.

  `evidence` says which HTTP exchanges a result cites, so a reader can see what
  was judged: `:own`, the requests the check made; `:discovery`, the discovery
  document fetched during setup; `:run`, every response in the run, too many to
  cite.
  """

  @enforce_keys [:id, :section, :level, :title, :run]
  defstruct [
    :id,
    :section,
    :level,
    :title,
    :run,
    :group,
    requires: [],
    phase: :main,
    evidence: :own
  ]

  @type level :: :must | :should
  @type t :: %__MODULE__{
          id: String.t(),
          section: String.t(),
          level: level(),
          title: String.t(),
          run: (HcpConformance.Context.t() -> term()),
          group: String.t() | nil,
          requires: [atom()],
          phase: :main | :post,
          evidence: evidence()
        }

  @type evidence :: :own | :discovery | :run

  @doc "Builds a check. `opts` take `requires`, `phase` and `evidence`."
  @spec new(
          String.t(),
          String.t(),
          level(),
          String.t(),
          (HcpConformance.Context.t() -> term()),
          keyword()
        ) ::
          t()
  def new(id, section, level, title, run, opts \\ []) do
    %__MODULE__{
      id: id,
      section: section,
      level: level,
      title: title,
      run: run,
      requires: Keyword.get(opts, :requires, []),
      phase: Keyword.get(opts, :phase, :main),
      evidence: Keyword.get(opts, :evidence, :own)
    }
  end
end
