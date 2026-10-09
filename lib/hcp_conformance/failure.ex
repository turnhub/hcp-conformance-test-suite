defmodule HcpConformance.Failure do
  @moduledoc """
  Raised by a check when the target violates the requirement under test. The
  runner turns it into `:fail` for a MUST and `:warn` for a SHOULD.
  """
  defexception [:message]
end

defmodule HcpConformance.NotApplicable do
  @moduledoc """
  Raised by a check whose requirement does not apply to this target, by the
  target's own declaration: a transport it does not offer, a relevance method
  whose ordering the check cannot state. Unlike a skip, it does not make a run
  incomplete.
  """
  defexception [:message]
end

defmodule HcpConformance.Skip do
  @moduledoc """
  Raised by a check that cannot run against this target: the requirement does not
  apply (a transport it does not offer), or the run lacks what the check needs (a
  second category, the conformance hook).
  """
  defexception [:message]
end
