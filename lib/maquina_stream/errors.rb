# frozen_string_literal: true

module MaquinaStream
  # Base class for everything this engine raises. Rescue it to catch all of
  # them at once.
  Error = Class.new(StandardError)

  # Raised when a host model does not satisfy the MaquinaStream::Streamable
  # contract. The message names the method, the column and the class, so the
  # fix is in the error rather than in a document.
  ContractError = Class.new(Error)

  # Raised when a required host seam has not been configured — `find_stream`,
  # in practice. `authorize` denies instead of raising, because denial is the
  # safe answer.
  ConfigurationError = Class.new(Error)
end
