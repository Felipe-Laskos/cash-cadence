defmodule CashCadence.ImportsTest do
  use CashCadence.DataCase, async: true

  import CashCadence.LedgerFixtures

  alias CashCadence.{Imports, Ledger}

  @fixtures Path.expand("../support/fixtures/imports", __DIR__)

  defp fixture(name), do: Path.join(@fixtures, name)

  describe "ingest_file/2" do
    test "creates a batch with inbox items and counts" do
      assert {:ok, batch} = Imports.ingest_file(fixture("nubank_conta.ofx"), source: :cli)
      assert batch.bank == :nubank
      assert batch.format == :ofx
      assert batch.period_start == ~D[2026-05-01]
      assert Decimal.equal?(batch.statement_balance, Decimal.new("561.18"))

      assert batch.counts == %{
               "total" => 3,
               "new" => 3,
               "duplicates" => 0,
               "matched" => 0,
               "transfers" => 0,
               "suggested" => 0
             }

      items = Imports.list_inbox()
      assert length(items) == 3
      assert Imports.count_pending() == 3
      [bakery | _] = items
      assert bakery.date == ~D[2026-05-22]
      assert bakery.kind == :expense
      assert bakery.normalized_description == "COMPRA NO DEBITO PADARIA EXEMPLO"
      assert bakery.description == "Compra no débito: PADARIA EXEMPLO"
      assert "uncategorized" in bakery.flags
    end

    test "refuses the same file twice and skips transactions already known by id" do
      assert {:ok, batch} = Imports.ingest_file(fixture("nubank_conta.ofx"))

      assert {:error, {:already_imported, %{id: id}}} =
               Imports.ingest_file(fixture("nubank_conta.ofx"))

      assert id == batch.id

      assert {:ok, csv_batch} = Imports.ingest_file(fixture("nubank_conta.csv"))
      assert csv_batch.counts["duplicates"] == 3
      assert csv_batch.counts["new"] == 0
      assert Imports.count_pending() == 3
    end

    test "links the account by external reference and remembers it" do
      account = bank_account_fixture(%{name: "Conta corrente"})

      assert {:ok, batch} =
               Imports.ingest_file(fixture("nubank_conta.ofx"), bank_account_id: account.id)

      assert batch.bank_account_id == account.id
      assert Ledger.get_bank_account_by_name("Conta corrente").external_ref == "1234567-8"

      assert {:ok, csv_batch} =
               Imports.ingest_binary(
                 File.read!(fixture("nubank_conta.ofx")) <> "\n",
                 "outro.ofx",
                 []
               )

      assert csv_batch.bank_account_id == account.id
    end

    test "matches manual transactions, suggests categories and flags likely duplicates" do
      food = category_fixture(%{name: "Comida"})

      manual =
        transaction_fixture(%{
          date: ~D[2026-05-23],
          amount: "48.82",
          category_id: food.id,
          description: "Padaria"
        })

      transaction_fixture(%{
        date: ~D[2026-04-22],
        amount: "10.00",
        category_id: food.id,
        normalized_description: "COMPRA NO DEBITO PADARIA EXEMPLO"
      })

      transaction_fixture(%{
        date: ~D[2026-03-22],
        amount: "12.00",
        category_id: food.id,
        normalized_description: "COMPRA NO DEBITO PADARIA EXEMPLO"
      })

      assert {:ok, batch} = Imports.ingest_file(fixture("nubank_conta.ofx"))
      assert batch.counts["matched"] == 1
      assert batch.counts["suggested"] == 1

      [bakery | _] = Imports.list_inbox()
      assert bakery.match_transaction_id == manual.id
      assert bakery.suggested_category_id == food.id
      assert bakery.confidence == :high
      assert "match" in bakery.flags
      refute "uncategorized" in bakery.flags
    end

    test "detects a likely transfer when a counterpart exists in another account" do
      nubank = bank_account_fixture(%{name: "Nubank"})
      itau = bank_account_fixture(%{name: "Itaú"})

      transaction_fixture(%{
        date: ~D[2026-05-11],
        kind: :income,
        amount: "390.00",
        bank_account_id: itau.id
      })

      assert {:ok, batch} =
               Imports.ingest_file(fixture("nubank_conta.ofx"), bank_account_id: nubank.id)

      assert batch.counts["transfers"] == 1

      tax =
        Enum.find(
          Imports.list_inbox(),
          &(&1.external_id == "22222222-2222-2222-2222-222222222222")
        )

      assert tax.kind == :transfer
      assert tax.counterpart_transaction_id
      assert "transfer" in tax.flags
    end
  end

  describe "inbox actions" do
    setup do
      {:ok, batch} = Imports.ingest_file(fixture("nubank_conta.ofx"))
      %{batch: batch, items: Imports.list_inbox()}
    end

    test "approve creates a transaction with the bank identifiers and a chosen category", %{
      items: [bakery | _]
    } do
      assert {:ok, transaction} =
               Imports.approve(bakery, %{"category_name" => "Comida", "description" => "Padaria"})

      assert transaction.source == :import
      assert transaction.external_id == bakery.external_id
      assert transaction.bank_account_id == nil
      assert transaction.description == "Padaria"
      assert transaction.normalized_description == "COMPRA NO DEBITO PADARIA EXEMPLO"
      assert Ledger.get_category!(transaction.category_id).name == "Comida"
      assert Imports.get_item!(bakery.id).status == :approved
      assert Imports.count_pending() == 2
    end

    test "approve accepts a kind override and marks the batch reviewed when nothing is pending",
         %{batch: batch, items: items} do
      Enum.each(items, fn item ->
        assert {:ok, _} = Imports.approve(item, %{"kind" => "transfer"})
      end)

      assert Imports.count_pending() == 0
      assert Imports.get_batch!(batch.id).status == :reviewed
      assert Ledger.list_transactions() |> Enum.all?(&(&1.kind == :transfer))
    end

    test "merge attaches the bank data to a manual transaction and takes the bank amount", %{
      items: [bakery | _]
    } do
      manual =
        transaction_fixture(%{date: ~D[2026-05-22], amount: "48.00", description: "Padaria"})

      assert {:ok, merged} = Imports.merge(bakery, manual)
      assert merged.id == manual.id
      assert merged.external_id == bakery.external_id
      assert Decimal.equal?(merged.amount, Decimal.new("48.82"))
      assert merged.raw_description == "Compra no débito - PADARIA EXEMPLO"
      assert Imports.get_item!(bakery.id).status == :merged

      assert {:ok, again} = Imports.ingest_file(fixture("nubank_conta.csv"))
      assert again.counts["duplicates"] == 3
    end

    test "ignore hides the item", %{items: [bakery | _]} do
      assert {:ok, %{status: :ignored}} = Imports.ignore(bakery)
      assert Imports.count_pending() == 2
      assert Imports.approve_high_confidence() == 0
    end
  end

  test "approve_high_confidence approves only confident items without flags" do
    food = category_fixture(%{name: "Comida"})

    transaction_fixture(%{
      date: ~D[2026-04-22],
      amount: "10.00",
      category_id: food.id,
      normalized_description: "COMPRA NO DEBITO PADARIA EXEMPLO"
    })

    transaction_fixture(%{
      date: ~D[2026-03-22],
      amount: "12.00",
      category_id: food.id,
      normalized_description: "COMPRA NO DEBITO PADARIA EXEMPLO"
    })

    assert {:ok, _batch} = Imports.ingest_file(fixture("nubank_conta.ofx"))
    assert Imports.approve_high_confidence() == 1
    assert Imports.count_pending() == 2

    assert [%{category_id: category_id, source: :import}] =
             Ledger.list_transactions(%{
               competence: ~D[2026-05-01],
               kind: :expense,
               search: "padaria"
             })

    assert category_id == food.id
  end
end
