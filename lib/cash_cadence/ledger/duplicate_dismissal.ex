defmodule CashCadence.Ledger.DuplicateDismissal do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  alias CashCadence.Ledger.Transaction

  schema "duplicate_dismissals" do
    belongs_to :transaction, Transaction
    belongs_to :other_transaction, Transaction

    timestamps(type: :utc_datetime)
  end

  def changeset(dismissal, attrs) do
    dismissal
    |> cast(attrs, [:transaction_id, :other_transaction_id])
    |> validate_required([:transaction_id, :other_transaction_id])
    |> foreign_key_constraint(:transaction_id)
    |> foreign_key_constraint(:other_transaction_id)
    |> unique_constraint([:transaction_id, :other_transaction_id])
  end
end
