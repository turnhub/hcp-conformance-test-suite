defmodule HcpConformance.Reference do
  @moduledoc """
  The reference HCP implementations, one per specification version
  (`HcpConformance.Reference.Server` for v1, `HcpConformance.Reference.ServerV2`
  for v2), and their state (`HcpConformance.Reference.Store`).

  It is a boundary of its own, apart from the suite: the suite's tests prove each
  check against it, which only means something if the reference shares no code
  with the checks. Boundary fails the build if it ever calls into the suite.
  """

  use Boundary, top_level?: true, deps: [], exports: [Server, ServerV2, Store]
end
