defmodule CashCadence.Imports.Raw do
  @moduledoc false

  @enforce_keys [:date, :amount, :kind, :raw_description]
  defstruct [
    :date,
    :posted_on,
    :amount,
    :kind,
    :raw_description,
    :external_id,
    :account_ref,
    payload: %{}
  ]
end
