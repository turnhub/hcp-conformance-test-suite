defmodule HcpConformance.Spec do
  @moduledoc """
  The specification versions the suite checks, and the draft of each it follows.

  A run targets one version. It is named in the run's config, or, left out, read
  from the `hcp_version` the target publishes in its discovery document, falling
  back to v1 when there is none to read.
  """

  @drafts %{"1.0" => "1.0-draft-4", "2.0" => "2.0-draft-3"}
  @default "1.0"

  @type version :: String.t()

  @doc "The protocol versions the suite has checks for, oldest first."
  @spec versions() :: [version()]
  def versions, do: ["1.0", "2.0"]

  @spec default() :: version()
  def default, do: @default

  @doc "The draft of a version the checks follow."
  @spec draft(version()) :: String.t()
  def draft(version), do: Map.fetch!(@drafts, version)

  @doc "A name for a version: \"HCP v2 (2.0-draft-3)\"."
  @spec label(version()) :: String.t()
  def label(version), do: "HCP v#{String.first(version)} (#{draft(version)})"

  @doc """
  Reads a version as a person or a config writes it: `"2.0"`, `"2"`, `"v2"`, or a
  draft name. `nil` and `"auto"` mean detect it from the target.
  """
  @spec parse(term()) :: {:ok, version() | nil} | :error
  def parse(value) when value in [nil, "", "auto"], do: {:ok, nil}

  def parse(value) when is_binary(value) do
    case value |> String.downcase() |> String.trim_leading("v") do
      "1" <> _rest -> {:ok, "1.0"}
      "2" <> _rest -> {:ok, "2.0"}
      _unknown -> :error
    end
  end

  def parse(_value), do: :error

  @doc "The version a discovery document speaks, from its `hcp_version`."
  @spec detect(map() | nil) :: version()
  def detect(%{"hcp_version" => "2" <> _rest}), do: "2.0"
  def detect(_discovery), do: @default
end
