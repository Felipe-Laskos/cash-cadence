defmodule CashCadence.Budgets.RecurringBill do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  alias CashCadence.Ledger.Category
  alias CashCadence.Money

  schema "recurring_bills" do
    field :name, :string
    field :expected_amount, :decimal
    field :due_day, :integer
    field :active, :boolean, default: true

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
      :category_id
    ])
    |> validate_required([:name, :expected_amount, :category_id])
    |> validate_length(:name, max: 60)
    |> validate_number(:expected_amount, greater_than: 0)
    |> validate_number(:due_day, greater_than_or_equal_to: 1, less_than_or_equal_to: 31)
    |> foreign_key_constraint(:category_id)
    |> unique_constraint(:name)
  end
end
