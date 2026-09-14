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
    has_many :reimbursements, __MODULE__, foreign_key: :reimbursement_of_id
    field :competence_month, :string, virtual: true
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
      :category_name,
      :competence_month
    ])
    |> update_change(:description, &blank_to_nil/1)
    |> put_competence_month()
    |> validate_required([:date, :kind, :amount])
    |> validate_reimbursement()
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

  defp put_competence_month(changeset) do
    case get_change(changeset, :competence_month) do
      nil -> changeset
      "" -> changeset
      value -> put_parsed_month(changeset, Date.from_iso8601(value <> "-01"))
    end
  end

  defp put_parsed_month(changeset, {:ok, date}),
    do: put_change(changeset, :competence, Date.beginning_of_month(date))

  defp put_parsed_month(changeset, _error),
    do: add_error(changeset, :competence_month, "mês inválido")

  defp validate_reimbursement(changeset) do
    if get_field(changeset, :reimbursement_of_id) && get_field(changeset, :kind) != :income,
      do: add_error(changeset, :reimbursement_of_id, "só uma receita pode ser reembolso"),
      else: changeset
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
