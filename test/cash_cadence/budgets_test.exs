defmodule CashCadence.BudgetsTest do
  use CashCadence.DataCase, async: true

  import CashCadence.BudgetsFixtures
  import CashCadence.LedgerFixtures

  alias CashCadence.Budgets

  defp assert_money(actual, expected) do
    assert Decimal.equal?(actual, Decimal.new(expected)), "expected #{expected}, got #{actual}"
  end

  describe "month_panel/1" do
    setup do
      fuel = recurring_bill_fixture(%{name: "Combustível", expected_amount: "450.00"})
      phone = recurring_bill_fixture(%{name: "Telefone", expected_amount: "40.00"})
      gym = recurring_bill_fixture(%{name: "Academia", expected_amount: "120.00"})
      recurring_bill_fixture(%{name: "Antiga", expected_amount: "10.00", active: false})

      transaction_fixture(%{
        date: ~D[2026-05-13],
        amount: "100.00",
        category_id: fuel.category_id
      })

      transaction_fixture(%{
        date: ~D[2026-05-04],
        amount: "41.99",
        category_id: phone.category_id
      })

      transaction_fixture(%{
        date: ~D[2026-04-22],
        amount: "300.00",
        category_id: fuel.category_id
      })

      transaction_fixture(%{
        date: ~D[2026-05-05],
        kind: :income,
        amount: "500.00",
        category_id: gym.category_id
      })

      %{fuel: fuel, phone: phone, gym: gym}
    end

    test "classifies each active bill for the month" do
      panel = Budgets.month_panel(~D[2026-05-01])
      assert Enum.map(panel.items, & &1.bill.name) == ["Academia", "Combustível", "Telefone"]

      [gym, fuel, phone] = panel.items
      assert gym.status == :unpaid
      assert_money(gym.remaining, "120.00")
      assert gym.progress == 0

      assert fuel.status == :partial
      assert_money(fuel.paid, "100.00")
      assert_money(fuel.remaining, "350.00")
      assert fuel.progress == 22

      assert phone.status == :paid
      assert_money(phone.over, "1.99")
      assert_money(phone.remaining, "0")
      assert phone.progress == 100
    end

    test "totals the panel" do
      panel = Budgets.month_panel(~D[2026-05-01])
      assert_money(panel.expected_total, "610.00")
      assert_money(panel.paid_total, "141.99")
      assert_money(panel.open_total, "470.00")
      assert panel.paid_count == 1
      assert panel.count == 3
    end

    test "coverage compares income with the expected total" do
      covered = Budgets.coverage(~D[2026-05-01], Decimal.new("6000.00"))
      assert covered.covered?
      assert_money(covered.expected_total, "610.00")

      short = Budgets.coverage(~D[2026-05-01], Decimal.new("100.00"))
      refute short.covered?
      assert Budgets.coverage(~D[2026-05-01], Decimal.new("0")).share == nil
    end
  end

  describe "recurring bills" do
    test "validates amount, due day and category" do
      category = category_fixture()

      assert {:error, changeset} =
               Budgets.create_recurring_bill(%{
                 name: "X",
                 expected_amount: "0",
                 due_day: 32,
                 category_id: category.id
               })

      assert %{expected_amount: [_], due_day: [_]} = errors_on(changeset)

      assert {:error, changeset} =
               Budgets.create_recurring_bill(%{name: "X", expected_amount: "10"})

      assert %{category_id: [_]} = errors_on(changeset)
    end

    test "creates, updates and deletes" do
      bill = recurring_bill_fixture(%{name: "Internet", expected_amount: "99,90"})
      assert_money(bill.expected_amount, "99.90")
      assert {:ok, updated} = Budgets.update_recurring_bill(bill, %{due_day: 10})
      assert updated.due_day == 10
      assert {:ok, _} = Budgets.delete_recurring_bill(updated)
      assert Budgets.list_recurring_bills() == []
    end
  end
end
