defmodule CashCadence.BackupTest do
  use CashCadence.DataCase, async: false

  import CashCadence.BudgetsFixtures
  import CashCadence.LedgerFixtures

  alias CashCadence.{Backup, Budgets, Classifier, Imports, Ledger, Repo}

  @fixtures Path.expand("../support/fixtures/imports", __DIR__)

  test "dumps every table and restores it faithfully, resetting the sequences" do
    food = category_fixture(%{name: "Comida"})
    account = bank_account_fixture(%{name: "Conta backup", bank: :itau, kind: :checking})

    transaction =
      transaction_fixture(%{
        date: ~D[2026-05-10],
        amount: "48.82",
        category_id: food.id,
        description: "Padaria",
        bank_account_id: account.id
      })

    bill = recurring_bill_fixture(%{name: "Internet", expected_amount: "99.90", due_day: 10})
    {:ok, bill} = Budgets.change_amount_from(bill, ~D[2026-05-01], "120.00")
    {:ok, rule} = Classifier.create_rule(%{"pattern" => "PADARIA", "category_id" => food.id})
    :ok = Classifier.learn("PIX QRS PADARIA", food.id)
    {:ok, batch} = Imports.ingest_file(Path.join(@fixtures, "nubank_conta.ofx"))

    dump = Backup.dump()
    assert dump["app"] == "CashCadence"
    assert dump["version"] == 1
    assert Map.keys(dump["tables"]) |> Enum.sort() == Enum.sort(Backup.tables())
    assert length(dump["tables"]["transactions"]) == 1
    assert length(dump["tables"]["inbox_items"]) == 3
    assert length(dump["tables"]["recurring_bill_amounts"]) == 2

    decoded = dump |> Backup.encode() |> Jason.decode!()

    Repo.query!("TRUNCATE #{Enum.join(Backup.tables(), ", ")} RESTART IDENTITY CASCADE")
    assert Ledger.list_transactions() == []

    assert {:ok, counts} = Backup.restore(decoded)
    assert counts["transactions"] == 1
    assert counts["inbox_items"] == 3
    assert counts["rules"] == 1
    assert counts["category_memory"] == 1

    restored = Ledger.get_transaction!(transaction.id)
    assert restored.description == "Padaria"
    assert Decimal.equal?(restored.amount, Decimal.new("48.82"))
    assert restored.category_id == food.id
    assert restored.bank_account_id == account.id
    assert restored.competence == ~D[2026-05-01]

    assert Budgets.get_recurring_bill!(bill.id).due_day == 10
    assert Decimal.equal?(Budgets.expected_amount_at(bill, ~D[2026-04-01]), Decimal.new("99.90"))
    assert Decimal.equal?(Budgets.expected_amount_at(bill, ~D[2026-05-01]), Decimal.new("120.00"))
    assert Classifier.get_rule!(rule.id).pattern == "PADARIA"
    assert Imports.get_batch!(batch.id).file_name == "nubank_conta.ofx"
    assert Imports.count_pending() == 3

    new_category = category_fixture(%{name: "Nova depois do restore"})
    assert new_category.id > food.id
  end

  test "rejects files that are not a CashCadence backup" do
    assert Backup.restore(%{"foo" => "bar"}) == {:error, :unrecognized_backup}

    assert Backup.restore(%{"app" => "Outro", "version" => 1, "tables" => %{}}) ==
             {:error, :unrecognized_backup}
  end
end
