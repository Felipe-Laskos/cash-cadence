defmodule CashCadence.ReimbursementsTest do
  use CashCadence.DataCase, async: true

  import CashCadence.LedgerFixtures

  alias CashCadence.Ledger

  defp assert_money(actual, expected),
    do:
      assert(Decimal.equal?(actual, Decimal.new(expected)), "expected #{expected}, got #{actual}")

  setup do
    food = category_fixture(%{name: "Comida"})
    friend = category_fixture(%{name: "Amigo", kind: :person})

    dinner =
      transaction_fixture(%{
        date: ~D[2026-05-10],
        amount: "120.00",
        category_id: food.id,
        description: "Jantar"
      })

    transaction_fixture(%{date: ~D[2026-05-11], amount: "30.00", category_id: food.id})
    salary = transaction_fixture(%{date: ~D[2026-05-05], kind: :income, amount: "6500.00"})

    refund =
      transaction_fixture(%{
        date: ~D[2026-05-12],
        kind: :income,
        amount: "60.00",
        category_id: friend.id,
        description: "Pix do amigo"
      })

    %{food: food, dinner: dinner, salary: salary, refund: refund}
  end

  test "links only an income to an expense and nets it out of every aggregate", ctx do
    before = Ledger.month_totals(~D[2026-05-01])
    assert_money(before.income, "6560.00")
    assert_money(before.expense, "150.00")

    assert {:error, :invalid_pair} = Ledger.link_reimbursement(ctx.dinner, ctx.refund)
    assert {:ok, refund} = Ledger.link_reimbursement(ctx.refund, ctx.dinner)
    assert refund.reimbursement_of_id == ctx.dinner.id

    totals = Ledger.month_totals(~D[2026-05-01])
    assert_money(totals.income, "6500.00")
    assert_money(totals.expense, "90.00")
    assert_money(totals.gross_expense, "150.00")
    assert_money(totals.reimbursed, "60.00")
    assert_money(totals.net, "6410.00")
    assert totals.income_count == 1

    [food_row] = Ledger.expenses_by_category(~D[2026-05-01])
    assert food_row.category_id == ctx.food.id
    assert_money(food_row.total, "90.00")

    [may] = Ledger.monthly_series(~D[2026-05-01], ~D[2026-05-01])
    assert_money(may.income, "6500.00")
    assert_money(may.expense, "90.00")

    matrix = Ledger.category_month_matrix(~D[2026-05-01], ~D[2026-05-01])
    [row] = matrix.rows
    assert_money(row.totals[~D[2026-05-01]], "90.00")

    incomes = Ledger.income_by_category(~D[2026-05-01], ~D[2026-05-01])
    assert Enum.map(incomes, & &1.name) == [nil]

    dinner = Ledger.get_transaction!(ctx.dinner.id)
    assert [%{id: refund_id}] = dinner.reimbursements
    assert refund_id == ctx.refund.id

    assert {:ok, _} = Ledger.unlink_reimbursement(refund)
    assert_money(Ledger.month_totals(~D[2026-05-01]).expense, "150.00")
  end

  test "lists candidates closest in amount first and finds exact open matches", ctx do
    candidates = Ledger.reimbursement_candidates(ctx.refund)
    assert Enum.map(candidates, &Decimal.to_string(&1.amount, :normal)) == ["30.00", "120.00"]

    assert Ledger.find_reimbursement_candidate(Decimal.new("120.00"), ~D[2026-05-20], 45).id ==
             ctx.dinner.id

    assert Ledger.find_reimbursement_candidate(Decimal.new("120.00"), ~D[2026-08-20], 45) == nil
    assert Ledger.find_reimbursement_candidate(Decimal.new("99.00"), ~D[2026-05-20], 45) == nil

    {:ok, _} = Ledger.link_reimbursement(ctx.refund, ctx.dinner)
    assert Ledger.find_reimbursement_candidate(Decimal.new("120.00"), ~D[2026-05-20], 45) == nil
  end

  test "a reimbursement without category is not counted as uncategorized", ctx do
    {:ok, _} = Ledger.update_transaction(ctx.refund, %{category_id: nil, category_name: nil})
    assert Ledger.count_uncategorized(~D[2026-05-01]) == 2

    {:ok, _} = Ledger.link_reimbursement(Ledger.get_transaction!(ctx.refund.id), ctx.dinner)
    assert Ledger.count_uncategorized(~D[2026-05-01]) == 1
  end

  test "refuses to turn a reimbursement into an expense" do
    dinner = transaction_fixture(%{date: ~D[2026-06-01], amount: "10.00"})

    assert {:error, changeset} =
             Ledger.create_transaction(%{
               date: ~D[2026-06-02],
               kind: :expense,
               amount: "10.00",
               reimbursement_of_id: dinner.id
             })

    assert %{reimbursement_of_id: ["só uma receita pode ser reembolso"]} = errors_on(changeset)
  end

  test "accepts an explicit competence month on the transaction" do
    assert {:ok, transaction} =
             Ledger.create_transaction(%{
               date: ~D[2026-05-30],
               kind: :expense,
               amount: "10.00",
               competence_month: "2026-06"
             })

    assert transaction.competence == ~D[2026-06-01]

    assert {:error, changeset} =
             Ledger.create_transaction(%{
               date: ~D[2026-05-30],
               kind: :expense,
               amount: "10.00",
               competence_month: "junho"
             })

    assert %{competence_month: ["mês inválido"]} = errors_on(changeset)
  end
end
