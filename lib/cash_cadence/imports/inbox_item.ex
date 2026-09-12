defmodule CashCadence.Imports.InboxItem do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  alias CashCadence.Imports.Batch
  alias CashCadence.Ledger.{BankAccount, Category, Transaction}

  schema "inbox_items" do
    field :external_id, :string
    field :fingerprint, :string
    field :posted_on, :date
    field :date, :date
    field :competence, :date
    field :amount, :decimal
    field :kind, Ecto.Enum, values: [:income, :expense, :transfer]
    field :raw_description, :string
    field :normalized_description, :string
    field :description, :string
    field :confidence, Ecto.Enum, values: [:high, :medium, :low, :none], default: :none
    field :status, Ecto.Enum, values: [:pending, :approved, :ignored, :merged], default: :pending
    field :flags, {:array, :string}, default: []
    field :payload, :map, default: %{}
    field :category_name, :string, virtual: true

    belongs_to :batch, Batch
    belongs_to :bank_account, BankAccount
    belongs_to :suggested_category, Category
    belongs_to :match_transaction, Transaction
    belongs_to :counterpart_transaction, Transaction
    belongs_to :transaction, Transaction

    timestamps(type: :utc_datetime)
  end

  def changeset(item, attrs) do
    item
    |> cast(attrs, [
      :external_id,
      :fingerprint,
      :posted_on,
      :date,
      :competence,
      :amount,
      :kind,
      :raw_description,
      :normalized_description,
      :description,
      :confidence,
      :status,
      :flags,
      :payload,
      :batch_id,
      :bank_account_id,
      :suggested_category_id,
      :match_transaction_id,
      :counterpart_transaction_id,
      :transaction_id
    ])
    |> validate_required([
      :fingerprint,
      :date,
      :competence,
      :amount,
      :kind,
      :raw_description,
      :normalized_description,
      :batch_id
    ])
    |> validate_number(:amount, greater_than: 0)
  end
end
