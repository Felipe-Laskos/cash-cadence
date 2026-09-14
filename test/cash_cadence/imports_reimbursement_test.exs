defmodule CashCadence.ImportsReimbursementTest do
  use CashCadence.DataCase, async: false

  import CashCadence.LedgerFixtures

  alias CashCadence.{Imports, Ledger, Settings}

  @fixtures Path.expand("../support/fixtures/imports", __DIR__)

  defp fixture(name), do: Path.join(@fixtures, name)

  defp income_item do
    Enum.find(Imports.list_inbox(), &(&1.kind == :income))
  end

  defp incoming do
    {:ok, parsed} = CashCadence.Imports.Parsers.OFX.parse(File.read!(fixture("nubank_conta.ofx")))
    Enum.find(parsed.transactions, &(&1.kind == :income))
  end

  defp incoming_amount, do: incoming().amount

  test "flags an incoming amount that mirrors a recent expense and links it on approval" do
    %{amount: amount, date: date} = incoming()

    lunch =
      transaction_fixture(%{date: Date.add(date, -5), amount: amount, description: "Almoço"})

    assert {:ok, _batch} = Imports.ingest_file(fixture("nubank_conta.ofx"))
    item = income_item()
    assert Decimal.equal?(item.amount, amount)
    assert "reimbursement" in item.flags
    assert item.payload["reimbursement_of_id"] == lunch.id
    assert item.payload["reimbursement_description"] == "Almoço"

    assert {:ok, transaction} =
             Imports.approve(item, %{"link_reimbursement" => "true", "category_name" => "Amigo"})

    assert transaction.reimbursement_of_id == lunch.id
    assert Decimal.equal?(Ledger.month_totals(transaction.competence).reimbursed, amount)
  end

  test "leaves the income alone when the checkbox is off" do
    transaction_fixture(%{date: Date.add(incoming().date, -5), amount: incoming_amount()})
    assert {:ok, _batch} = Imports.ingest_file(fixture("nubank_conta.ofx"))
    item = income_item()
    assert {:ok, transaction} = Imports.approve(item, %{})
    assert transaction.reimbursement_of_id == nil
  end

  test "auto-approves confident items on import when the setting is on" do
    :ok = Settings.set_auto_approve(true)
    on_exit(fn -> :ok end)
    taxes = category_fixture(%{name: "Impostos"})

    {:ok, _rule} =
      CashCadence.Classifier.create_rule(%{
        "pattern" => "RECEITA FEDERAL",
        "category_id" => taxes.id
      })

    assert {:ok, batch} = Imports.ingest_file(fixture("nubank_conta.ofx"))
    assert batch.counts["auto_approved"] == 1
    assert Imports.count_pending() == 2
    assert [transaction] = Ledger.list_transactions()
    assert transaction.category_id == taxes.id
    assert transaction.source == :import
  end
end
