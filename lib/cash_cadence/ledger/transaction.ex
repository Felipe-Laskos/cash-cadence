defmodule CashCadence.Ledger.Transaction do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  alias CashCadence.Ledger.{BankAccount, Category}
  alias CashCadence.Money

  @kinds [:income, :expense, :transfer]
  @sources [:manual, :spreadsheet, :import]

  schema "transactions" do
    field :date, :date
    field :competence, :date
    field :kind, Ecto.Enum, values: @kinds
    field :amount, :decimal
    field :description, :string
    field :raw_description, :string
    field :normalized_description, :string
    field :posted_on, :date
    field :source, Ecto.Enum, values: @sources, default: :manual
    field :external_id, :string
    field :fingerprint, :string
    field :deleted_at, :utc_datetime
    field :category_name, :string, virtual: true

    belongs_to :category, Category
    belongs_to :bank_account, BankAccount
    belongs_to :reimbursement_of, __MODULE__
    belongs_to :import_batch, CashCadence.Imports.Batch

    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds

  def changeset(transaction, attrs) do
    transaction
    |> cast(Money.normalize_param(attrs, :amount), [
      :date,
      :competence,
      :kind,
      :amount,
      :description,
      :raw_description,
      :normalized_description,
      :posted_on,
      :import_batch_id,
      :source,
      :external_id,
      :fingerprint,
      :category_id,
      :bank_account_id,
      :reimbursement_of_id,
      :category_name
    ])
    |> update_change(:description, &blank_to_nil/1)
    |> validate_required([:date, :kind, :amount])
    |> validate_number(:amount, greater_than: 0)
    |> validate_length(:description, max: 255)
    |> put_competence()
    |> foreign_key_constraint(:category_id)
    |> foreign_key_constraint(:bank_account_id)
    |> check_constraint(:amount,
      name: :amount_must_be_positive,
      message: "deve ser maior que zero"
    )
    |> unique_constraint([:source, :external_id])
  end

  defp put_competence(changeset) do
    cond do
      get_change(changeset, :competence) ->
        changeset

      date = get_change(changeset, :date) ->
        put_change(changeset, :competence, Date.beginning_of_month(date))

      is_nil(get_field(changeset, :competence)) and match?(%Date{}, get_field(changeset, :date)) ->
        put_change(changeset, :competence, Date.beginning_of_month(get_field(changeset, :date)))

      true ->
        changeset
    end
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
