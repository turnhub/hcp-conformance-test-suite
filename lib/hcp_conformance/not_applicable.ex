defmodule HcpConformance.NotApplicable do
  @moduledoc """
  Raised by a check whose requirement does not apply to this target, by the
  target's own declaration: a transport it does not offer, a relevance method
  whose ordering the check cannot state. Unlike a skip, it does not make a run
  incomplete.
  """
  defexception [:message]
end
