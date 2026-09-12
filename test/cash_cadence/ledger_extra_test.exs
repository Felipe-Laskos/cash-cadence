defmodule CashCadence.LedgerExtraTest do
  use CashCadence.DataCase, async: true

  import CashCadence.BudgetsFixtures
  import CashCadence.LedgerFixtures

  alias CashCadence.{Budgets, Ledger}

  test "merge_categories moves transactions and bills, then archives the source" do
    tim = category_fixture(%{name: "Tim"})
    telefonia = category_fixture(%{name: "Telefonia"})
    bill = recurring_bill_fixture(%{name: "TIM", category_id: tim.id})
    transaction_fixture(%{category_id: tim.id})

    assert {:ok, target} = Ledger.merge_categories(tim, telefonia)
    assert target.id == telefonia.id
    assert [%{category_id: id}] = Ledger.list_transactions()
    assert id == telefonia.id
    assert Budgets.get_recurring_bill!(bill.id).category_id == telefonia.id
    assert Ledger.get_category!(tim.id).archived_at != nil
    assert Ledger.list_categories() |> Enum.map(& &1.name) == ["Telefonia"]
    assert Ledger.list_categories(archived: :only) |> Enum.map(& &1.name) == ["Tim"]
  end

  test "category_stats aggregates usage and monthly average" do
    food = category_fixture(%{name: "Comida"})
    transaction_fixture(%{date: ~D[2026-03-10], amount: "100.00", category_id: food.id})
    transaction_fixture(%{date: ~D[2026-05-10], amount: "50.00", category_id: food.id})
    recurring_bill_fixture(%{name: "Comida", category_id: food.id})

    [row] = Ledger.category_stats(kind: :expense)
    assert row.count == 2
    assert Decimal.equal?(row.total, Decimal.new("150.00"))
    assert Decimal.equal?(row.monthly_average, Decimal.new("50.00"))
    assert row.last_date == ~D[2026-05-10]
    assert row.has_bill?
  end

  test "category_month_matrix and income_by_category cover the range" do
    food = category_fixture(%{name: "Comida"})
    fuel = category_fixture(%{name: "Combustível"})
    salary = category_fixture(%{name: "Salário", kind: :income})
    transaction_fixture(%{date: ~D[2026-04-10], amount: "70.00", category_id: food.id})
    transaction_fixture(%{date: ~D[2026-05-10], amount: "30.00", category_id: food.id})
    transaction_fixture(%{date: ~D[2026-05-11], amount: "200.00", category_id: fuel.id})

    transaction_fixture(%{
      date: ~D[2026-05-07],
      kind: :income,
      amount: "1000.00",
      category_id: salary.id
    })

    transaction_fixture(%{date: ~D[2026-05-08], kind: :income, amount: "1000.00"})

    %{months: months, rows: [fuel_row, food_row]} =
      Ledger.category_month_matrix(~D[2026-04-01], ~D[2026-05-01])

    assert months == [~D[2026-04-01], ~D[2026-05-01]]
    assert fuel_row.name == "Combustível"
    assert Decimal.equal?(food_row.total, Decimal.new("100.00"))
    assert Decimal.equal?(food_row.totals[~D[2026-04-01]], Decimal.new("70.00"))
    assert Decimal.equal?(food_row.average, Decimal.new("50.00"))

    [first, second] = Ledger.income_by_category(~D[2026-04-01], ~D[2026-05-01])
    assert Decimal.equal?(first.share, Decimal.new("0.5"))
    assert second.name in ["Salário", nil]
    assert Ledger.count_uncategorized() == 1
  end
end
