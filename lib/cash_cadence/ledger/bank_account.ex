defmodule CashCadence.Ledger.BankAccount do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  schema "bank_accounts" do
    field :name, :string
    field :bank, Ecto.Enum, values: [:itau, :nubank, :other]
    field :kind, Ecto.Enum, values: [:checking, :credit_card, :other]
    field :own, :boolean, default: true
    field :external_ref, :string

    field :competence_mode, Ecto.Enum,
      values: [:purchase_date, :statement_month],
      default: :purchase_date

    timestamps(type: :utc_datetime)
  end

  def changeset(bank_account, attrs) do
    bank_account
    |> cast(attrs, [:name, :bank, :kind, :own, :external_ref, :competence_mode])
    |> validate_required([:name, :bank, :kind])
    |> validate_length(:name, max: 60)
    |> unique_constraint(:name)
  end
end
