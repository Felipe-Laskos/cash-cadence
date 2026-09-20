defmodule CashCadence.LedgerTest do
  use CashCadence.DataCase, async: true

  import CashCadence.LedgerFixtures

  alias CashCadence.Ledger

  defp assert_money(actual, expected) do
    assert Decimal.equal?(actual, Decimal.new(expected)), "expected #{expected}, got #{actual}"
  end

  describe "categories" do
    test "create_category trims the name and enforces case-insensitive uniqueness" do
      assert {:ok, category} = Ledger.create_category(%{name: "  Comida ", kind: :expense})
      assert category.name == "Comida"
      assert {:error, changeset} = Ledger.create_category(%{name: "comida", kind: :expense})
      assert %{name: [_message]} = errors_on(changeset)
    end

    test "find_or_create_category reuses an existing name regardless of case" do
      category = category_fixture(%{name: "TIM"})
      assert {:ok, found} = Ledger.find_or_create_category("tim", :expense)
      assert found.id == category.id
      assert {:ok, created} = Ledger.find_or_create_category("Freelance", :income)
      assert created.kind == :income
    end

    test "category_suggestions orders by usage" do
      rare = category_fixture(%{name: "Raro"})
      common = category_fixture(%{name: "Comum"})
      transaction_fixture(%{category_id: common.id})
      transaction_fixture(%{category_id: common.id})
      transaction_fixture(%{category_id: rare.id})

      assert [%{name: "Comum", uses: 2}, %{name: "Raro", uses: 1}] = Ledger.category_suggestions()
    end

    test "list_categories hides archived ones and filters by kind" do
      category_fixture(%{name: "Ativa"})
      category_fixture(%{name: "Pessoa", kind: :person})
      category_fixture(%{name: "Velha", archived_at: DateTime.utc_now(:second)})

      assert ["Ativa", "Pessoa"] = Ledger.list_categories() |> Enum.map(& &1.name)
      assert ["Pessoa"] = Ledger.list_categories(kind: :person) |> Enum.map(& &1.name)
    end
  end

  describe "transactions" do
    test "derives competence from the date" do
      transaction = transaction_fixture(%{date: ~D[2026-05-22]})
      assert transaction.competence == ~D[2026-05-01]
    end

    test "accepts amounts typed with a comma" do
      assert {:ok, transaction} =
               Ledger.create_transaction(%{
                 "date" => "2026-05-22",
                 "kind" => "expense",
                 "amount" => "1.048,82"
               })

      assert_money(transaction.amount, "1048.82")
    end

    test "rejects non-positive amounts and missing fields" do
      assert {:error, changeset} =
               Ledger.create_transaction(%{date: ~D[2026-05-22], kind: :expense, amount: "0"})

      assert %{amount: [_message]} = errors_on(changeset)
      assert {:error, changeset} = Ledger.create_transaction(%{})
      assert %{date: [_], kind: [_], amount: [_]} = errors_on(changeset)
    end

    test "resolves category_name, creating the category with the transaction kind" do
      assert {:ok, income} =
               Ledger.create_transaction(%{
                 "date" => "2026-05-21",
                 "kind" => "income",
                 "amount" => "75",
                 "category_name" => "Freelance"
               })

      assert Ledger.get_category!(income.category_id).kind == :income

      assert {:ok, again} =
               Ledger.create_transaction(%{
                 "date" => "2026-05-22",
                 "kind" => "income",
                 "amount" => "10",
                 "category_name" => " freelance "
               })

      assert again.category_id == income.category_id
    end

    test "blank category_name leaves the transaction uncategorized" do
      assert {:ok, transaction} =
               Ledger.create_transaction(%{
                 "date" => "2026-05-22",
                 "kind" => "expense",
                 "amount" => "5",
                 "category_name" => "  "
               })

      assert transaction.category_id == nil
    end

    test "update_transaction recomputes competence when the date changes" do
      transaction = transaction_fixture(%{date: ~D[2026-05-22]})
      assert {:ok, updated} = Ledger.update_transaction(transaction, %{date: ~D[2026-06-02]})
      assert updated.competence == ~D[2026-06-01]
    end

    test "delete_transaction soft deletes" do
      transaction = transaction_fixture(%{date: ~D[2026-05-22], amount: "10.00"})
      assert {:ok, _} = Ledger.delete_transaction(transaction)
      assert_raise Ecto.NoResultsError, fn -> Ledger.get_transaction!(transaction.id) end
      assert Ledger.list_transactions(%{competence: ~D[2026-05-01]}) == []
      assert_money(Ledger.month_totals(~D[2026-05-01]).expense, "0")
    end
  end

  describe "aggregates" do
    setup do
      food = category_fixture(%{name: "Comida"})
      fuel = category_fixture(%{name: "Combustível"})
      salary = category_fixture(%{name: "Salário", kind: :income})

      transaction_fixture(%{
        date: ~D[2026-05-02],
        kind: :income,
        amount: "1000.00",
        category_id: salary.id
      })

      transaction_fixture(%{
        date: ~D[2026-05-10],
        kind: :income,
        amount: "500.00",
        category_id: salary.id
      })

      transaction_fixture(%{
        date: ~D[2026-05-11],
        kind: :expense,
        amount: "200.00",
        category_id: food.id
      })

      transaction_fixture(%{
        date: ~D[2026-05-12],
        kind: :expense,
        amount: "50.50",
        category_id: fuel.id,
        description: "Posto"
      })

      transaction_fixture(%{date: ~D[2026-05-13], kind: :transfer, amount: "300.00"})
      transaction_fixture(%{date: ~D[2026-05-14], kind: :expense, amount: "9.50"})

      transaction_fixture(%{
        date: ~D[2026-04-20],
        kind: :expense,
        amount: "70.00",
        category_id: food.id
      })

      %{food: food, fuel: fuel}
    end

    test "month_totals ignores transfers and other months" do
      totals = Ledger.month_totals(~D[2026-05-15])
      assert_money(totals.income, "1500.00")
      assert_money(totals.expense, "260.00")
      assert_money(totals.net, "1240.00")
      assert totals.count == 5
      assert totals.income_count == 2
      assert totals.expense_count == 3
    end

    test "all_time_totals sums every month" do
      assert_money(Ledger.all_time_totals().expense, "330.00")
      assert_money(Ledger.all_time_totals().income, "1500.00")
    end

    test "monthly_series fills months without data" do
      [march, april, may] = Ledger.monthly_series(~D[2026-03-01], ~D[2026-05-31])
      assert march.competence == ~D[2026-03-01]
      assert_money(march.expense, "0")
      assert_money(april.expense, "70.00")
      assert_money(may.income, "1500.00")
      assert_money(may.net, "1240.00")
    end

    test "expenses_by_category groups and orders by total", %{food: food} do
      [first, second, third] = Ledger.expenses_by_category(~D[2026-05-01])
      assert first.category_id == food.id
      assert_money(first.total, "200.00")
      assert second.name == "Combustível"
      assert third.category_id == nil
      assert_money(third.total, "9.50")
    end

    test "count_uncategorized and months_with_data" do
      assert Ledger.count_uncategorized(~D[2026-05-01]) == 1
      assert Ledger.months_with_data() == [~D[2026-05-01], ~D[2026-04-01]]
    end

    test "list_transactions applies filters", %{fuel: fuel} do
      assert length(Ledger.list_transactions(%{competence: ~D[2026-05-01]})) == 6
      assert length(Ledger.list_transactions(%{competence: ~D[2026-05-01], kind: :income})) == 2

      assert [%{description: "Posto"}] =
               Ledger.list_transactions(%{competence: ~D[2026-05-01], search: "posto"})

      assert [%{category_id: id}] =
               Ledger.list_transactions(%{competence: ~D[2026-05-01], search: "combust"})

      assert id == fuel.id

      assert [%{category_id: nil}] =
               Ledger.list_transactions(%{competence: ~D[2026-05-01], category_id: :none})

      assert [%{competence: ~D[2026-04-01]}] =
               Ledger.list_transactions(%{competence: ~D[2026-04-01]})
    end

    test "recent_transactions returns the latest first" do
      assert [%{date: ~D[2026-05-14]}, %{date: ~D[2026-05-13]}] = Ledger.recent_transactions(2)
    end
  end

  test "a transaction accepts a date typed the Brazilian way" do
    assert {:ok, transaction} =
             Ledger.create_transaction(%{
               "date" => "10/05/2026",
               "kind" => "expense",
               "amount" => "12,50"
             })

    assert transaction.date == ~D[2026-05-10]
    assert transaction.competence == ~D[2026-05-01]
  end
end
