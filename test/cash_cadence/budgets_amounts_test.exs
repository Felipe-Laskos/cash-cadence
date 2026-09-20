defmodule CashCadence.BudgetsAmountsTest do
  use CashCadence.DataCase, async: true

  import CashCadence.BudgetsFixtures
  import CashCadence.LedgerFixtures

  alias CashCadence.Budgets

  defp assert_money(actual, expected) do
    assert Decimal.equal?(actual, Decimal.new(expected)), "expected #{expected}, got #{actual}"
  end

  defp item(bill, month) do
    month |> Budgets.month_panel() |> Map.fetch!(:items) |> Enum.find(&(&1.bill.id == bill.id))
  end

  describe "change_amount_from/3" do
    test "leaves the earlier months on the previous value" do
      fuel = recurring_bill_fixture(%{name: "Combustível", expected_amount: "500.00"})

      assert {:ok, _bill} = Budgets.change_amount_from(fuel, ~D[2026-09-01], "250,00")

      assert_money(item(fuel, ~D[2026-03-01]).expected, "500.00")
      assert_money(item(fuel, ~D[2026-08-01]).expected, "500.00")
      assert_money(item(fuel, ~D[2026-09-01]).expected, "250.00")
      assert_money(item(fuel, ~D[2026-12-01]).expected, "250.00")
    end

    test "keeps the status an earlier month already had" do
      fuel = recurring_bill_fixture(%{name: "Combustível", expected_amount: "500.00"})

      transaction_fixture(%{
        date: ~D[2026-08-12],
        amount: "300.00",
        category_id: fuel.category_id
      })

      assert {:ok, _bill} = Budgets.change_amount_from(fuel, ~D[2026-09-01], "250.00")

      august = item(fuel, ~D[2026-08-01])
      assert august.status == :partial
      assert_money(august.remaining, "200.00")
      assert_money(august.over, "0")

      assert item(fuel, ~D[2026-09-01]).status == :unpaid
    end

    test "stacks a second change without touching the first window" do
      bill = recurring_bill_fixture(%{name: "Aluguel", expected_amount: "1000.00"})

      {:ok, bill} = Budgets.change_amount_from(bill, ~D[2026-05-01], "1200.00")
      {:ok, bill} = Budgets.change_amount_from(bill, ~D[2026-09-01], "1500.00")

      assert_money(item(bill, ~D[2026-04-01]).expected, "1000.00")
      assert_money(item(bill, ~D[2026-05-01]).expected, "1200.00")
      assert_money(item(bill, ~D[2026-08-01]).expected, "1200.00")
      assert_money(item(bill, ~D[2026-09-01]).expected, "1500.00")
      assert length(Budgets.list_bill_amounts(bill)) == 3
    end

    test "a future change does not move the current amount" do
      bill = recurring_bill_fixture(%{name: "Plano", expected_amount: "80.00"})
      next_year = Date.shift(Date.utc_today(), year: 1)

      {:ok, bill} = Budgets.change_amount_from(bill, next_year, "95.00")

      assert_money(Budgets.get_recurring_bill!(bill.id).expected_amount, "80.00")
      assert_money(Budgets.expected_amount_at(bill, next_year), "95.00")
    end
  end

  describe "update_recurring_bill/3" do
    test "corrects the value in force on the given month, not the later ones" do
      bill = recurring_bill_fixture(%{name: "Internet", expected_amount: "100.00"})
      {:ok, bill} = Budgets.change_amount_from(bill, ~D[2026-09-01], "120.00")

      assert {:ok, _bill} =
               Budgets.update_recurring_bill(bill, %{expected_amount: "110.00"},
                 on: ~D[2026-08-01]
               )

      assert_money(item(bill, ~D[2026-02-01]).expected, "110.00")
      assert_money(item(bill, ~D[2026-08-01]).expected, "110.00")
      assert_money(item(bill, ~D[2026-09-01]).expected, "120.00")
    end

    test "without history it just moves the bill's own amount" do
      bill = recurring_bill_fixture(%{name: "Streaming", expected_amount: "100.00"})

      assert {:ok, updated} = Budgets.update_recurring_bill(bill, %{expected_amount: "150.00"})
      assert_money(updated.expected_amount, "150.00")
      assert Budgets.list_bill_amounts(bill) == []
      assert_money(item(bill, ~D[2026-01-01]).expected, "150.00")
    end
  end

  describe "expected_amount_at/2" do
    test "falls back to the bill's amount when there is no history" do
      bill = recurring_bill_fixture(%{name: "Seguro", expected_amount: "500.00"})
      assert_money(Budgets.expected_amount_at(bill, ~D[2020-01-01]), "500.00")
    end

    test "uses the oldest entry for months before it" do
      bill = recurring_bill_fixture(%{name: "Imposto", expected_amount: "390.00"})
      {:ok, bill} = Budgets.put_bill_amount(bill, ~D[2026-06-01], Decimal.new("410.00"))

      assert_money(Budgets.expected_amount_at(bill, ~D[2026-01-01]), "410.00")
      assert_money(Budgets.expected_amount_at(bill, ~D[2026-07-01]), "410.00")
    end
  end

  describe "put_bill_amount/3 and delete_bill_amount/2" do
    test "removing an entry gives the month back to the previous value" do
      bill = recurring_bill_fixture(%{name: "Academia", expected_amount: "120.00"})
      {:ok, bill} = Budgets.change_amount_from(bill, ~D[2026-09-01], "160.00")

      [_base, latest] = Budgets.list_bill_amounts(bill)
      assert {:ok, bill} = Budgets.delete_bill_amount(bill, latest.id)

      assert_money(item(bill, ~D[2026-09-01]).expected, "120.00")
      assert_money(Budgets.get_recurring_bill!(bill.id).expected_amount, "120.00")
    end
  end

  describe "history in the rest of the app" do
    test "the import matches against the amount of the competence" do
      bill = recurring_bill_fixture(%{name: "Combustível", expected_amount: "500.00"})
      {:ok, _bill} = Budgets.change_amount_from(bill, ~D[2026-09-01], "250.00")

      assert %{bill: %{id: id}} =
               Budgets.find_bill_match(:expense, Decimal.new("500.00"), ~D[2026-08-01], "POSTO")

      assert id == bill.id

      assert Budgets.find_bill_match(:expense, Decimal.new("500.00"), ~D[2026-09-01], "POSTO") ==
               nil

      assert %{bill: %{id: ^id}} =
               Budgets.find_bill_match(:expense, Decimal.new("250.00"), ~D[2026-09-01], "POSTO")
    end

    test "the adherence table reads each month with its own amount" do
      bill = recurring_bill_fixture(%{name: "Combustível", expected_amount: "500.00"})

      transaction_fixture(%{
        date: ~D[2026-08-12],
        amount: "300.00",
        category_id: bill.category_id
      })

      transaction_fixture(%{
        date: ~D[2026-09-12],
        amount: "300.00",
        category_id: bill.category_id
      })

      {:ok, _bill} = Budgets.change_amount_from(bill, ~D[2026-09-01], "250.00")

      %{rows: [row]} = Budgets.adherence(~D[2026-09-01], 3)
      assert Enum.map(row.statuses, & &1.status) == [:unpaid, :partial, :paid]
    end

    test "expected incomes follow the raise from the month it happened" do
      salary = category_fixture(%{name: "Salário", kind: :income})

      bill =
        recurring_bill_fixture(%{
          name: "Salário",
          kind: :income,
          expected_amount: "6500.00",
          category_id: salary.id
        })

      {:ok, _bill} = Budgets.change_amount_from(bill, ~D[2026-09-01], "7000.00")

      [july] = Budgets.expected_incomes(~D[2026-07-01])
      [september] = Budgets.expected_incomes(~D[2026-09-01])

      assert_money(july.expected, "6500.00")
      assert_money(september.expected, "7000.00")
    end
  end
end
