defmodule HcpConformance.Skip do
  @moduledoc """
  Raised by a check that cannot run against this target: the requirement does not
  apply (a transport it does not offer), or the run lacks what the check needs (a
  second category, the conformance hook).
  """
  defexception [:message]
end
