defmodule CashCadence.BudgetsExtraTest do
  use CashCadence.DataCase, async: true

  import CashCadence.BudgetsFixtures
  import CashCadence.LedgerFixtures

  alias CashCadence.Budgets

  test "expected_incomes reports received incomes for the month" do
    salary = category_fixture(%{name: "Salário", kind: :income})

    recurring_bill_fixture(%{
      name: "Salário",
      kind: :income,
      expected_amount: "6500.00",
      category_id: salary.id
    })

    recurring_bill_fixture(%{
      name: "Lucros",
      kind: :income,
      expected_amount: "1000.00",
      category_id: category_fixture(%{name: "Lucros", kind: :income}).id
    })

    transaction_fixture(%{
      date: ~D[2026-05-07],
      kind: :income,
      amount: "6500.00",
      category_id: salary.id
    })

    [lucros, salario] = Budgets.expected_incomes(~D[2026-05-01])
    assert lucros.status == :pending
    assert salario.status == :received
    assert salario.received_on == ~D[2026-05-07]
    assert Budgets.month_panel(~D[2026-05-01]).count == 0
  end

  test "adherence covers the last months" do
    fuel = recurring_bill_fixture(%{name: "Combustível", expected_amount: "100.00"})
    transaction_fixture(%{date: ~D[2026-03-10], amount: "100.00", category_id: fuel.category_id})
    transaction_fixture(%{date: ~D[2026-05-10], amount: "40.00", category_id: fuel.category_id})

    %{months: months, rows: [row]} = Budgets.adherence(~D[2026-05-01], 3)
    assert months == [~D[2026-03-01], ~D[2026-04-01], ~D[2026-05-01]]
    assert Enum.map(row.statuses, & &1.status) == [:paid, :unpaid, :partial]
  end
end
