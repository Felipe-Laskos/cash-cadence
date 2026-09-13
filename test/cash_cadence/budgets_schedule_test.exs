defmodule CashCadence.BudgetsScheduleTest do
  use CashCadence.DataCase, async: true

  import CashCadence.BudgetsFixtures
  import CashCadence.LedgerFixtures

  alias CashCadence.Budgets

  describe "validity window and installments" do
    test "lists only bills valid for the month and numbers the installments" do
      bill =
        recurring_bill_fixture(%{
          name: "Oficina",
          expected_amount: "208.00",
          starts_on: ~D[2026-03-01],
          ends_on: ~D[2026-05-01],
          installments_total: 3
        })

      recurring_bill_fixture(%{name: "Sempre", expected_amount: "10.00"})

      assert Enum.map(Budgets.month_panel(~D[2026-02-01]).items, & &1.bill.name) == ["Sempre"]

      [workshop, _always] = Budgets.month_panel(~D[2026-04-15]).items
      assert workshop.bill.id == bill.id
      assert workshop.installment == %{number: 2, of: 3}
      assert Enum.map(Budgets.month_panel(~D[2026-06-01]).items, & &1.bill.name) == ["Sempre"]

      row = Budgets.adherence(~D[2026-06-01], 3).rows |> Enum.find(&(&1.bill.id == bill.id))
      assert Enum.map(row.statuses, & &1.status) == [:unpaid, :unpaid, :none]
    end

    test "accepts months from the form and validates the range" do
      category = category_fixture()

      assert {:ok, bill} =
               Budgets.create_recurring_bill(%{
                 name: "Curso",
                 expected_amount: "99.90",
                 category_id: category.id,
                 starts_month: "2026-05",
                 ends_month: "2026-08",
                 installments_total: 4,
                 match_text: "curso exemplo"
               })

      assert bill.starts_on == ~D[2026-05-01]
      assert bill.ends_on == ~D[2026-08-01]
      assert bill.match_text == "CURSO EXEMPLO"

      assert {:error, changeset} =
               Budgets.create_recurring_bill(%{
                 name: "Errada",
                 expected_amount: "1.00",
                 category_id: category.id,
                 starts_month: "2026-05",
                 ends_month: "2026-04"
               })

      assert %{ends_month: ["termina antes de começar"]} = errors_on(changeset)

      assert {:error, changeset} =
               Budgets.create_recurring_bill(%{
                 name: "Errada",
                 expected_amount: "1.00",
                 category_id: category.id,
                 starts_month: "abc"
               })

      assert %{starts_month: ["mês inválido"]} = errors_on(changeset)
    end
  end

  describe "due dates" do
    test "computes the due date inside the month and flags overdue bills" do
      bill = recurring_bill_fixture(%{name: "Aluguel", expected_amount: "1000.00", due_day: 31})
      past = Date.shift(Date.utc_today(), month: -1)

      [item] = Budgets.month_panel(past).items
      assert item.due_on == Date.new!(past.year, past.month, Date.days_in_month(past))
      assert item.overdue?
      assert Budgets.month_panel(past).overdue_count == 1

      transaction_fixture(%{
        date: Date.new!(past.year, past.month, 10),
        amount: "1000.00",
        category_id: bill.category_id
      })

      [item] = Budgets.month_panel(past).items
      refute item.overdue?

      [item] = Budgets.month_panel(Date.shift(Date.utc_today(), month: 2)).items
      refute item.overdue?
    end
  end

  describe "match text" do
    setup do
      taxes = category_fixture(%{name: "Impostos"})

      das =
        recurring_bill_fixture(%{
          name: "DAS",
          expected_amount: "390.00",
          category_id: taxes.id,
          match_text: "receita federal"
        })

      darf =
        recurring_bill_fixture(%{
          name: "DARF",
          expected_amount: "175.00",
          category_id: taxes.id,
          match_text: "receita federal"
        })

      internet = recurring_bill_fixture(%{name: "Internet", expected_amount: "100.00"})
      %{taxes: taxes, das: das, darf: darf, internet: internet}
    end

    test "counts payments by description and amount instead of category", ctx do
      transaction_fixture(%{
        date: ~D[2026-05-10],
        amount: "390.00",
        category_id: ctx.taxes.id,
        raw_description: "Pix RECEITA FEDERAL",
        normalized_description: "PIX RECEITA FEDERAL"
      })

      items = Budgets.month_panel(~D[2026-05-01]).items
      assert Enum.find(items, &(&1.bill.id == ctx.das.id)).status == :paid
      assert Enum.find(items, &(&1.bill.id == ctx.darf.id)).status == :unpaid

      transaction_fixture(%{
        date: ~D[2026-05-12],
        amount: "178.31",
        category_id: ctx.taxes.id,
        normalized_description: "PIX RECEITA FEDERAL"
      })

      items = Budgets.month_panel(~D[2026-05-01]).items
      assert Enum.find(items, &(&1.bill.id == ctx.darf.id)).status == :paid
    end

    test "matches imported amounts to open bills, preferring text plus amount", ctx do
      may = ~D[2026-05-01]

      assert %{bill: %{id: das_id}, strong?: true} =
               Budgets.find_bill_match(
                 :expense,
                 Decimal.new("390.00"),
                 may,
                 "PIX RECEITA FEDERAL"
               )

      assert das_id == ctx.das.id

      assert %{bill: %{id: darf_id}, strong?: true} =
               Budgets.find_bill_match(
                 :expense,
                 Decimal.new("178.31"),
                 may,
                 "PIX RECEITA FEDERAL"
               )

      assert darf_id == ctx.darf.id

      assert %{bill: %{id: internet_id}, strong?: false} =
               Budgets.find_bill_match(:expense, Decimal.new("100.00"), may, "NET SERVICOS")

      assert internet_id == ctx.internet.id

      assert Budgets.find_bill_match(:expense, Decimal.new("390.00"), may, "OUTRA COISA") == nil

      assert Budgets.find_bill_match(:transfer, Decimal.new("390.00"), may, "PIX RECEITA FEDERAL") ==
               nil

      transaction_fixture(%{
        date: ~D[2026-05-10],
        amount: "390.00",
        category_id: ctx.taxes.id,
        normalized_description: "PIX RECEITA FEDERAL"
      })

      assert Budgets.find_bill_match(:expense, Decimal.new("390.00"), may, "PIX RECEITA FEDERAL") ==
               nil
    end
  end

  describe "plan_installments/1" do
    test "creates a temporary bill for the remaining installments and updates it later" do
      category = category_fixture(%{name: "Mecânico"})

      plan = %{
        name: "Oficina Exemplo",
        amount: Decimal.new("208.00"),
        category_id: category.id,
        competence: ~D[2026-06-01],
        number: 1,
        of: 3,
        match_text: "OFICINA EXEMPLO"
      }

      assert {:ok, bill} = Budgets.plan_installments(plan)
      assert bill.starts_on == ~D[2026-06-01]
      assert bill.ends_on == ~D[2026-08-01]
      assert bill.installments_total == 3
      assert bill.match_text == "OFICINA EXEMPLO"
      assert Decimal.equal?(bill.expected_amount, Decimal.new("208.00"))

      assert {:ok, same} =
               Budgets.plan_installments(%{plan | number: 2, competence: ~D[2026-07-01]})

      assert same.id == bill.id
      assert same.starts_on == ~D[2026-06-01]

      assert {:ok, nil} =
               Budgets.plan_installments(%{plan | number: 3, competence: ~D[2026-08-01]})

      assert length(Budgets.list_recurring_bills()) == 1

      recurring_bill_fixture(%{name: "Academia Exemplo", expected_amount: "120.00"})

      assert {:ok, other} =
               Budgets.plan_installments(%{plan | name: "Academia Exemplo", number: 1, of: 2})

      assert other.name == "Academia Exemplo (parcelas)"
    end
  end
end
