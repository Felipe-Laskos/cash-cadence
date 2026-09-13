defmodule CashCadence.ImportsBudgetTest do
  use CashCadence.DataCase, async: false

  import CashCadence.BudgetsFixtures
  import CashCadence.LedgerFixtures

  alias CashCadence.{Budgets, Imports, Repo}
  alias CashCadence.Imports.{Batch, InboxItem}

  @fixtures Path.expand("../support/fixtures/imports", __DIR__)

  defp fixture(name), do: Path.join(@fixtures, name)

  test "suggests the recurring bill when amount and text match a still open bill" do
    taxes = category_fixture(%{name: "Impostos"})

    recurring_bill_fixture(%{
      name: "DAS",
      expected_amount: "390.00",
      category_id: taxes.id,
      match_text: "receita federal"
    })

    assert {:ok, batch} = Imports.ingest_file(fixture("nubank_conta.ofx"))
    assert batch.counts["suggested"] == 1

    tax = Enum.find(Imports.list_inbox(), &Decimal.equal?(&1.amount, Decimal.new("390.00")))
    assert tax.suggested_category_id == taxes.id
    assert tax.confidence == :high
    assert tax.payload["suggestion_source"] == "bill"
    assert tax.payload["bill_name"] == "DAS"
    refute "uncategorized" in tax.flags
  end

  test "uses the statement month as competence for cards configured that way" do
    card =
      bank_account_fixture(%{
        name: "Cartão teste",
        bank: :nubank,
        kind: :credit_card,
        competence_mode: :statement_month
      })

    assert {:ok, batch} =
             Imports.ingest_file(fixture("nubank_cartao.csv"), bank_account_id: card.id)

    items = Imports.list_inbox()
    assert items != []
    statement_month = Date.beginning_of_month(batch.period_end)
    assert Enum.all?(items, &(&1.competence == statement_month))

    other =
      bank_account_fixture(%{name: "Cartão normal", bank: :nubank, kind: :credit_card})

    csv = File.read!(fixture("nubank_cartao.csv")) |> String.replace("\n", "\r\n")
    assert {:ok, _} = Imports.ingest_binary(csv, "outro.csv", bank_account_id: other.id)

    Imports.list_inbox()
    |> Enum.filter(&(&1.bank_account_id == other.id))
    |> Enum.each(fn item -> assert item.competence == Date.beginning_of_month(item.date) end)
  end

  test "approving an installment plans the remaining ones as a temporary bill" do
    batch =
      Repo.insert!(%Batch{
        source: :cli,
        format: :pdf,
        bank: :itau,
        account_kind: :credit_card,
        file_name: "fatura.pdf",
        file_sha256: "sha-teste"
      })

    item =
      %InboxItem{}
      |> InboxItem.changeset(%{
        batch_id: batch.id,
        fingerprint: "fp-teste",
        date: ~D[2026-06-16],
        competence: ~D[2026-06-01],
        amount: "208.00",
        kind: :expense,
        raw_description: "OficinaExemplo 01/03",
        normalized_description: "OFICINAEXEMPLO",
        description: "OficinaExemplo (1/3)",
        payload: %{"installment" => %{"number" => 1, "of" => 3}}
      })
      |> Repo.insert!()

    assert {:ok, transaction} = Imports.approve(item, %{"category_name" => "Mecânico"})

    assert Imports.installment_forecast(item, transaction) == %{
             remaining: 2,
             ends_on: ~D[2026-08-01]
           }

    [bill] = Budgets.list_recurring_bills()
    assert bill.name == "OficinaExemplo"
    assert bill.starts_on == ~D[2026-06-01]
    assert bill.ends_on == ~D[2026-08-01]
    assert bill.installments_total == 3
    assert bill.match_text == "OFICINAEXEMPLO"
    assert bill.category_id == transaction.category_id

    [june] = Budgets.month_panel(~D[2026-06-01]).items
    assert june.status == :paid
    assert june.installment == %{number: 1, of: 3}

    [july] = Budgets.month_panel(~D[2026-07-01]).items
    assert july.status == :unpaid
    assert july.installment == %{number: 2, of: 3}
  end
end
