defmodule CashCadence.Imports.Batch do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  alias CashCadence.Imports.InboxItem
  alias CashCadence.Ledger.BankAccount

  schema "import_batches" do
    field :source, Ecto.Enum, values: [:upload, :cli]
    field :format, Ecto.Enum, values: [:ofx, :csv]
    field :bank, Ecto.Enum, values: [:nubank, :itau, :unknown], default: :unknown
    field :account_kind, Ecto.Enum, values: [:checking, :credit_card]
    field :file_name, :string
    field :file_sha256, :string
    field :period_start, :date
    field :period_end, :date
    field :statement_balance, :decimal
    field :counts, :map, default: %{}
    field :status, Ecto.Enum, values: [:pending, :reviewed], default: :pending

    belongs_to :bank_account, BankAccount
    has_many :items, InboxItem, foreign_key: :batch_id

    timestamps(type: :utc_datetime)
  end

  def changeset(batch, attrs) do
    batch
    |> cast(attrs, [
      :source,
      :format,
      :bank,
      :account_kind,
      :file_name,
      :file_sha256,
      :period_start,
      :period_end,
      :statement_balance,
      :counts,
      :status,
      :bank_account_id
    ])
    |> validate_required([:source, :format, :file_name, :file_sha256])
    |> unique_constraint(:file_sha256, message: "este arquivo já foi importado")
  end
end
