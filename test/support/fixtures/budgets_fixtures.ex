defmodule CashCadence.BudgetsFixtures do
  @moduledoc false

  import CashCadence.LedgerFixtures

  alias CashCadence.Budgets

  def recurring_bill_fixture(attrs \\ %{}) do
    attrs = Map.new(attrs)
    category_id = Map.get_lazy(attrs, :category_id, fn -> category_fixture(%{fixed: true}).id end)

    {:ok, bill} =
      attrs
      |> Map.put(:category_id, category_id)
      |> Enum.into(%{name: unique_name("Fixa"), expected_amount: Decimal.new("100.00")})
      |> Budgets.create_recurring_bill()

    Budgets.get_recurring_bill!(bill.id)
  end
end
