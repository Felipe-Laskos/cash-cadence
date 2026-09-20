defmodule CashCadence.DuplicatesTest do
  use CashCadence.DataCase, async: true

  import CashCadence.LedgerFixtures

  alias CashCadence.{Duplicates, Ledger, Repo}
  alias CashCadence.Imports.Batch

  test "pairs entries with the same amount within the window and ranks by evidence" do
    food = category_fixture(%{name: "Comida"})

    sheet =
      transaction_fixture(%{date: ~D[2026-05-10], amount: "48.82", category_id: food.id})

    bank =
      transaction_fixture(%{
        date: ~D[2026-05-11],
        amount: "48.82",
        category_id: food.id,
        source: :import,
        normalized_description: "COMPRA NO DEBITO PADARIA EXEMPLO"
      })

    transaction_fixture(%{date: ~D[2026-05-30], amount: "10.00"})

    assert [pair] = Duplicates.list()
    assert pair.left.id == sheet.id
    assert pair.right.id == bank.id
    assert pair.reason == :category
    refute pair.same_day?
  end

  test "leaves the two sides of a transfer alone" do
    one = bank_account_fixture(%{name: "Conta A"})
    other = bank_account_fixture(%{name: "Conta B"})

    transaction_fixture(%{
      date: ~D[2026-05-10],
      kind: :transfer,
      amount: "500.00",
      bank_account_id: one.id
    })

    transaction_fixture(%{
      date: ~D[2026-05-10],
      kind: :transfer,
      amount: "500.00",
      bank_account_id: other.id
    })

    assert Duplicates.list() == []
  end

  test "dismissing a pair keeps it out of the list for good" do
    gym = category_fixture(%{name: "Academia"})
    left = transaction_fixture(%{date: ~D[2026-05-10], amount: "70.00", category_id: gym.id})
    right = transaction_fixture(%{date: ~D[2026-05-10], amount: "70.00", category_id: gym.id})

    assert [pair] = Duplicates.list()
    assert {:ok, _} = Duplicates.dismiss(pair.left, pair.right)
    assert Duplicates.list() == []

    assert {:ok, _} = Duplicates.dismiss(right, left)
    assert Duplicates.list() == []
  end

  test "resolving keeps one side, deletes the other and carries the reimbursement over" do
    gym = category_fixture(%{name: "Academia"})

    kept =
      transaction_fixture(%{
        date: ~D[2026-05-10],
        amount: "90.00",
        source: :import,
        category_id: gym.id
      })

    removed = transaction_fixture(%{date: ~D[2026-05-10], amount: "90.00", category_id: gym.id})

    refund =
      transaction_fixture(%{
        date: ~D[2026-05-20],
        kind: :income,
        amount: "90.00",
        reimbursement_of_id: removed.id
      })

    assert {:ok, _} = Duplicates.resolve(kept, removed)

    assert Ledger.get_transaction!(refund.id).reimbursement_of_id == kept.id
    assert Duplicates.list() == []
    assert_raise Ecto.NoResultsError, fn -> Ledger.get_transaction!(removed.id) end
  end

  test "two identical lines of the same file are two real entries" do
    batch =
      Repo.insert!(%Batch{
        source: :cli,
        format: :ofx,
        bank: :itau,
        file_name: "extrato.ofx",
        file_sha256: "sha-do-arquivo"
      })

    food = category_fixture(%{name: "Comida"})

    attrs = %{
      date: ~D[2026-04-12],
      amount: "14.00",
      category_id: food.id,
      source: :import,
      import_batch_id: batch.id,
      normalized_description: "PIX QRS ESPETINHOS"
    }

    transaction_fixture(attrs)
    transaction_fixture(attrs)

    assert Duplicates.list() == []
  end

  test "installments of the same purchase are never a pair" do
    workshop = category_fixture(%{name: "Mecânico"})

    attrs = %{date: ~D[2026-06-16], amount: "208.00", category_id: workshop.id, source: :import}

    transaction_fixture(Map.put(attrs, :description, "AutoMecanicaLi (1/3)"))
    transaction_fixture(Map.put(attrs, :description, "AutoMecanicaLi (2/3)"))

    assert Duplicates.list() == []
  end

  test "a pair held together only by the amount waits behind the weak toggle" do
    transaction_fixture(%{date: ~D[2026-05-10], amount: "100.00", description: "Posto"})
    transaction_fixture(%{date: ~D[2026-05-11], amount: "100.00", description: "Dízimo"})

    assert Duplicates.list() == []
    assert Duplicates.weak_count() == 1
    assert [pair] = Duplicates.list(weak: true)
    assert pair.strength == :weak
  end
end
