defmodule CashCadence.Budgets.RecurringBill do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  alias CashCadence.Imports.Normalizer
  alias CashCadence.Ledger.Category
  alias CashCadence.Money

  schema "recurring_bills" do
    field :name, :string
    field :expected_amount, :decimal
    field :due_day, :integer
    field :active, :boolean, default: true
    field :kind, Ecto.Enum, values: [:expense, :income], default: :expense
    field :starts_on, :date
    field :ends_on, :date
    field :installments_total, :integer
    field :match_text, :string
    field :category_name, :string, virtual: true
    field :starts_month, :string, virtual: true
    field :ends_month, :string, virtual: true

    belongs_to :category, Category

    timestamps(type: :utc_datetime)
  end

  def changeset(bill, attrs) do
    bill
    |> cast(Money.normalize_param(attrs, :expected_amount), [
      :name,
      :expected_amount,
      :due_day,
      :active,
      :kind,
      :starts_on,
      :ends_on,
      :installments_total,
      :match_text,
      :category_id,
      :category_name,
      :starts_month,
      :ends_month
    ])
    |> update_change(:name, &trim/1)
    |> update_change(:match_text, &normalize_text/1)
    |> put_month(:starts_month, :starts_on)
    |> put_month(:ends_month, :ends_on)
    |> update_change(:starts_on, &Date.beginning_of_month/1)
    |> update_change(:ends_on, &Date.beginning_of_month/1)
    |> validate_required([:name, :expected_amount, :kind, :category_id])
    |> validate_length(:name, max: 60)
    |> validate_number(:expected_amount, greater_than: 0)
    |> validate_number(:due_day, greater_than_or_equal_to: 1, less_than_or_equal_to: 31)
    |> validate_number(:installments_total, greater_than_or_equal_to: 2)
    |> validate_range()
    |> foreign_key_constraint(:category_id)
    |> unique_constraint(:name, message: "já existe uma despesa fixa com esse nome")
  end

  defp trim(nil), do: nil
  defp trim(name), do: String.trim(name)

  defp normalize_text(nil), do: nil

  defp normalize_text(text) do
    case Normalizer.normalize(text) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp put_month(changeset, virtual, field) do
    case get_change(changeset, virtual) do
      nil -> changeset
      "" -> put_change(changeset, field, nil)
      value -> put_parsed_month(changeset, virtual, field, Date.from_iso8601(value <> "-01"))
    end
  end

  defp put_parsed_month(changeset, _virtual, field, {:ok, date}),
    do: put_change(changeset, field, date)

  defp put_parsed_month(changeset, virtual, _field, _error),
    do: add_error(changeset, virtual, "mês inválido")

  defp validate_range(changeset) do
    starts_on = get_field(changeset, :starts_on)
    ends_on = get_field(changeset, :ends_on)

    if starts_on && ends_on && Date.compare(ends_on, starts_on) == :lt,
      do: add_error(changeset, :ends_month, "termina antes de começar"),
      else: changeset
  end
end
