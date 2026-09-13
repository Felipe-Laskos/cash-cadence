defmodule CashCadence.ImportsClassifierTest do
  use CashCadence.DataCase, async: false

  import CashCadence.LedgerFixtures

  alias CashCadence.{Classifier, Imports}

  @fixtures Path.expand("../support/fixtures/imports", __DIR__)

  defp fixture(name), do: Path.join(@fixtures, name)

  defp tax_item,
    do: Enum.find(Imports.list_inbox(), &Decimal.equal?(&1.amount, Decimal.new("390.00")))

  test "applies rules while ingesting, counts hits and records the source" do
    taxes = category_fixture(%{name: "Impostos"})

    {:ok, rule} =
      Classifier.create_rule(%{"pattern" => "RECEITA FEDERAL", "category_id" => taxes.id})

    assert {:ok, batch} = Imports.ingest_file(fixture("nubank_conta.ofx"))
    assert batch.counts["suggested"] == 1

    tax = tax_item()
    assert tax.suggested_category_id == taxes.id
    assert tax.confidence == :high
    assert tax.payload["suggestion_source"] == "rule"
    assert tax.payload["rule_id"] == rule.id
    refute "uncategorized" in tax.flags
    assert Classifier.get_rule!(rule.id).hits == 1
  end

  test "a rule can force the kind, and approving teaches the memory" do
    {:ok, _} =
      Classifier.create_rule(%{"pattern" => "RECEITA FEDERAL", "kind_override" => "transfer"})

    assert {:ok, batch} = Imports.ingest_file(fixture("nubank_conta.ofx"))
    assert batch.counts["transfers"] == 1

    tax = tax_item()
    assert tax.kind == :transfer
    refute "transfer" in tax.flags
    refute "uncategorized" in tax.flags

    bakery =
      Enum.find(Imports.list_inbox(), &(&1.description == "Compra no débito: PADARIA EXEMPLO"))

    assert {:ok, transaction} = Imports.approve(bakery, %{"category_name" => "Comida"})
    [memory] = Classifier.list_memory("padaria")
    assert memory.category_id == transaction.category_id
    assert memory.normalized_description == bakery.normalized_description
    assert memory.uses == 1
  end

  test "reclassifies pending items when rules change" do
    assert {:ok, _} = Imports.ingest_file(fixture("nubank_conta.ofx"))
    tax = tax_item()
    assert tax.suggested_category_id == nil
    assert "uncategorized" in tax.flags

    taxes = category_fixture(%{name: "Impostos"})

    {:ok, _} =
      Classifier.create_rule(%{"pattern" => "RECEITA FEDERAL", "category_id" => taxes.id})

    assert Imports.reclassify_pending() == 1
    assert Imports.reclassify_pending() == 0

    tax = Imports.get_item!(tax.id)
    assert tax.suggested_category_id == taxes.id
    assert tax.confidence == :high
    assert tax.payload["suggestion_source"] == "rule"
    refute "uncategorized" in tax.flags
  end
end
