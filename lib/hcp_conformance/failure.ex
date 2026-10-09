defmodule HcpConformance.Failure do
  @moduledoc """
  Raised by a check when the target violates the requirement under test. The
  runner turns it into `:fail` for a MUST and `:warn` for a SHOULD.
  """
  defexception [:message]
end
