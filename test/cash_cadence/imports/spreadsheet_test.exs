defmodule CashCadence.Imports.SpreadsheetTest do
  use CashCadence.DataCase, async: true

  alias CashCadence.{Budgets, Ledger}
  alias CashCadence.Imports.Spreadsheet

  @fixtures Path.expand("../../support/fixtures/imports", __DIR__)

  defp fixture(name), do: Path.join(@fixtures, name)

  defp run_all do
    Spreadsheet.run(
      transactions: fixture("transactions.csv"),
      bills: fixture("bills.csv"),
      accounts: fixture("accounts.csv")
    )
  end

  test "imports transactions, bills and accounts, merging categories case-insensitively" do
    assert {:ok, result} = run_all()

    assert result.transactions == %{
             created: 6,
             skipped: 0,
             ignored: 1,
             uncategorized: 1,
             categories_created: 4
           }

    assert result.bills == %{created: 2, skipped: 0}
    assert result.accounts == %{created: 2, skipped: 0}

    assert %{fixed: true, kind: :expense} = Ledger.get_category_by_name("TELEFONE")
    assert %{kind: :person} = Ledger.get_category_by_name("Amigo")
    assert %{kind: :income} = Ledger.get_category_by_name("Salario")
    assert %{fixed: true} = Ledger.get_category_by_name("Academia")
    assert length(Ledger.list_categories()) == 5
    assert Ledger.get_category_by_name("Lucros") == nil

    totals = Ledger.month_totals(~D[2026-05-01])
    assert Decimal.equal?(totals.income, Decimal.new("3020.00"))
    assert Decimal.equal?(totals.expense, Decimal.new("263.35"))
    assert Ledger.count_uncategorized(~D[2026-05-01]) == 1

    assert [%{name: "Academia"}, %{name: "Telefone"}] = Budgets.list_recurring_bills()
    assert length(Ledger.list_bank_accounts()) == 2
  end

  test "is idempotent" do
    assert {:ok, _} = run_all()
    assert {:ok, result} = run_all()

    assert result.transactions == %{
             created: 0,
             skipped: 6,
             ignored: 1,
             uncategorized: 0,
             categories_created: 0
           }

    assert result.bills == %{created: 0, skipped: 2}
    assert result.accounts == %{created: 0, skipped: 2}
  end

  test "rolls back everything on an invalid row" do
    path = Path.join(System.tmp_dir!(), "cash-cadence-#{System.unique_integer([:positive])}.csv")

    File.write!(path, """
    row,date,type,category,category_kind,description,amount
    8,2026-05-02,expense,Mercado,expense,,10.00
    9,2026-05-03,foo,Mercado,expense,,10.00
    """)

    assert {:error, {:unknown_type, "foo"}} = Spreadsheet.run(transactions: path)
    assert Ledger.list_transactions() == []
    assert Ledger.list_categories() == []
  after
    File.rm(Path.join(System.tmp_dir!(), "unused"))
  end
end
