defmodule CashCadence.ImportsPDFTest do
  use CashCadence.DataCase, async: false

  import CashCadence.LedgerFixtures

  alias CashCadence.{Imports, Ledger}

  @fixtures Path.expand("../support/fixtures/imports", __DIR__)

  defp fixture(name), do: Path.join(@fixtures, name)

  describe "ingest_file/2 with Itaú PDFs" do
    @describetag :pdftotext

    test "creates a PDF batch, keeps the extracted text and links the only matching Itaú account" do
      account = bank_account_fixture(%{name: "Itaú conta", bank: :itau, kind: :checking})
      bank_account_fixture(%{name: "Itaú cartão", bank: :itau, kind: :credit_card})

      assert {:ok, batch} = Imports.ingest_file(fixture("itau_extrato.pdf"), source: :cli)
      assert batch.format == :pdf
      assert batch.bank == :itau
      assert batch.account_kind == :checking
      assert batch.bank_account_id == account.id
      assert batch.raw_text =~ "SALDO DO DIA"
      assert batch.warnings == []
      assert batch.counts["total"] == 7
      assert batch.counts["transfers"] == 1
      assert Ledger.get_bank_account_by_name("Itaú conta").external_ref == "0001/12345-6"
      assert Ledger.get_bank_account_by_name("Itaú cartão").external_ref == nil

      items = Imports.list_inbox()
      card_payment = Enum.find(items, &(&1.description == "Fatura do cartão: Banco Exemplo"))
      assert card_payment.kind == :transfer
      refute "uncategorized" in card_payment.flags

      bakery = Enum.find(items, &(&1.description == "Pix QR: PADARIA EXEMPLO"))
      assert bakery.date == ~D[2026-05-18]
      assert bakery.posted_on == ~D[2026-05-20]
      assert bakery.competence == ~D[2026-05-01]
      assert bakery.bank_account_id == account.id
    end

    test "persists reconciliation warnings and leaves the account open when none matches" do
      assert {:ok, batch} = Imports.ingest_file(fixture("itau_extrato_divergente.pdf"))
      assert [warning] = batch.warnings
      assert warning =~ "Saldo de 20/05/2026 não bate"
      assert batch.bank_account_id == nil
      assert Imports.count_pending() == 7
    end

    test "reads the card statement and approves an installment with the statement month" do
      assert {:ok, batch} = Imports.ingest_file(fixture("itau_fatura.pdf"))
      assert batch.account_kind == :credit_card
      assert Decimal.equal?(batch.statement_balance, Decimal.new("358.00"))
      assert batch.period_end == ~D[2026-05-30]

      workshop = Enum.find(Imports.list_inbox(), &(&1.description == "OficinaExemplo (3/3)"))
      assert workshop.date == ~D[2026-03-16]
      assert workshop.competence == ~D[2026-05-01]
      assert workshop.payload["itau_category"] == "serviços"

      assert {:ok, transaction} = Imports.approve(workshop, %{"category_name" => "Carro"})
      assert transaction.competence == ~D[2026-05-01]
      assert transaction.date == ~D[2026-03-16]
      assert transaction.source == :import
    end

    test "rejects PDFs it does not know without creating a batch" do
      assert {:error, {:unknown_layout, _text}} = Imports.ingest_file(fixture("outro.pdf"))
      assert Imports.list_batches() == []
    end
  end

  describe "transfers between own accounts still in the inbox" do
    test "marks both pending items as transfer when the amounts mirror each other" do
      nubank = bank_account_fixture(%{name: "Nubank PJ", bank: :nubank, kind: :checking})
      itau = bank_account_fixture(%{name: "Itaú conta", bank: :itau, kind: :checking})

      assert {:ok, _batch} =
               Imports.ingest_file(fixture("nubank_conta.ofx"), bank_account_id: nubank.id)

      tax = Enum.find(Imports.list_inbox(), &Decimal.equal?(&1.amount, Decimal.new("390.00")))
      assert tax.kind == :expense

      csv =
        "Data,Valor,Identificador,Descrição\n" <>
          "12/05/2026,390.00,99999999-9999-9999-9999-999999999999,Transferência recebida pelo Pix - CLIENTE EXEMPLO - 000.000.000-00 - BANCO EXEMPLO\n"

      assert {:ok, batch} = Imports.ingest_binary(csv, "itau.csv", bank_account_id: itau.id)
      assert batch.counts["transfers"] == 1

      [incoming] = Imports.list_inbox(%{batch_id: batch.id})
      assert incoming.kind == :transfer
      assert "transfer" in incoming.flags
      assert incoming.payload["counterpart_item_id"] == tax.id

      tax = Imports.get_item!(tax.id)
      assert tax.kind == :transfer
      assert "transfer" in tax.flags
      refute "uncategorized" in tax.flags
    end
  end
end
