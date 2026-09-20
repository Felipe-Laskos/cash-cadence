defmodule CashCadence.Budgets.BillAmount do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  alias CashCadence.Budgets.RecurringBill
  alias CashCadence.Money

  schema "recurring_bill_amounts" do
    field :starts_on, :date
    field :expected_amount, :decimal

    belongs_to :recurring_bill, RecurringBill

    timestamps(type: :utc_datetime)
  end

  def changeset(amount, attrs) do
    amount
    |> cast(Money.normalize_param(attrs, :expected_amount), [
      :starts_on,
      :expected_amount,
      :recurring_bill_id
    ])
    |> update_change(:starts_on, &Date.beginning_of_month/1)
    |> validate_required([:starts_on, :expected_amount, :recurring_bill_id])
    |> validate_number(:expected_amount, greater_than: 0)
    |> foreign_key_constraint(:recurring_bill_id)
    |> unique_constraint(:starts_on,
      name: :recurring_bill_amounts_recurring_bill_id_starts_on_index,
      message: "já existe um valor a partir desse mês"
    )
  end
end
