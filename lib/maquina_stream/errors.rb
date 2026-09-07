# frozen_string_literal: true

module MaquinaStream
  Error = Class.new(StandardError)

  # Raised when a host model does not satisfy the Streamable contract.
  ContractError = Class.new(Error)

  # Raised when a required host seam has not been configured.
  ConfigurationError = Class.new(Error)
end
