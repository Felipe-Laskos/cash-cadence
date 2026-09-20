defmodule CashCadence.Imports.PDFParsersTest do
  use ExUnit.Case, async: true

  alias CashCadence.Imports.{BrFormat, Sniffer}
  alias CashCadence.Imports.Parsers
  alias CashCadence.Imports.Parsers.PDF.{ItauCard, ItauStatement, NubankStatement, Text}

  @fixtures Path.expand("../../support/fixtures/imports", __DIR__)

  defp fixture(name), do: File.read!(Path.join(@fixtures, name))

  describe "Sniffer.detect/1" do
    test "recognizes a PDF by its magic bytes" do
      assert {:ok, %{format: :pdf, parser: Parsers.PDF, encoding: :binary}} =
               Sniffer.detect("%PDF-1.7\n%\xE2\xE3\xCF\xD3\n")
    end
  end

  describe "BrFormat" do
    test "reads a date written the Brazilian way or in ISO" do
      assert BrFormat.any_date("10/05/2026") == {:ok, ~D[2026-05-10]}
      assert BrFormat.any_date("2026-05-10") == {:ok, ~D[2026-05-10]}
      assert BrFormat.any_date("31/02/2026") == {:error, :invalid_date}
      assert BrFormat.any_date("qualquer coisa") == {:error, :invalid_date}
    end

    test "normalizes a typed date before it reaches the changeset" do
      assert BrFormat.normalize_param(%{"date" => "10/05/2026"}, :date) == %{
               "date" => "2026-05-10"
             }

      assert BrFormat.normalize_param(%{date: "2026-05-10"}, :date) == %{date: "2026-05-10"}
      assert BrFormat.normalize_param(%{"date" => "nada"}, :date) == %{"date" => "nada"}
    end

    test "resolves dd/mm against a reference date, rolling back a year when needed" do
      assert BrFormat.day_month("05/09", ~D[2026-09-08]) == {:ok, ~D[2026-09-05]}
      assert BrFormat.day_month("28/12", ~D[2027-01-30]) == {:ok, ~D[2026-12-28]}
      assert BrFormat.day_month("31/02", ~D[2026-03-01]) == {:error, :invalid_date}
    end

    test "formats money the Brazilian way" do
      assert BrFormat.money(Decimal.new("35148.71")) == "R$ 35.148,71"
      assert BrFormat.money(Decimal.new("-33.88")) == "-R$ 33,88"
      assert BrFormat.money(Decimal.new("0")) == "R$ 0,00"
    end
  end

  describe "ItauStatement.parse_text/1" do
    test "reads transactions, effective dates and kinds, and validates the balance chain" do
      text = fixture("itau_extrato.txt")
      assert ItauStatement.recognizes?(text)
      assert {:ok, parsed} = ItauStatement.parse_text(text)

      assert parsed.bank == :itau
      assert parsed.account == %{bank_id: "341", account_ref: "0001/12345-6", kind: :checking}
      assert parsed.period_start == ~D[2026-05-01]
      assert parsed.period_end == ~D[2026-05-31]
      assert Decimal.equal?(parsed.balance, Decimal.new("1180.50"))
      assert parsed.warnings == []

      [bakery, own_transfer, card_payment, friend, yield, fuel, market] = parsed.transactions
      assert bakery.posted_on == ~D[2026-05-20]
      assert bakery.date == ~D[2026-05-18]
      assert bakery.kind == :expense
      assert Decimal.equal?(bakery.amount, Decimal.new("12.50"))
      assert bakery.raw_description == "PIX QRS PADARIA EXEMPLO18/05"
      assert bakery.description == "Pix QR: PADARIA EXEMPLO"

      assert own_transfer.kind == :income
      assert own_transfer.description == "Pix: CLIENTE"
      assert own_transfer.date == ~D[2026-05-20]

      assert card_payment.kind == :transfer
      assert card_payment.description == "Fatura do cartão: Banco Exemplo"

      assert friend.date == ~D[2026-05-10]
      assert friend.description == "Pix: AMIGO EX"
      assert yield.description == "Rendimento da conta"
      assert yield.kind == :income
      assert fuel.date == ~D[2026-05-05]
      assert market.date == ~D[2026-05-04]
      assert Decimal.equal?(market.amount, Decimal.new("82.50"))
    end

    test "keeps the balance of the period even when the file shows a later one" do
      text =
        String.replace(
          fixture("itau_extrato.txt"),
          "Aviso!",
          "15/09/2026       SALDO DO DIA                                                         9.999,99\nAviso!"
        )

      assert {:ok, parsed} = ItauStatement.parse_text(text)
      assert parsed.period_end == ~D[2026-05-31]
      assert Decimal.equal?(parsed.balance, Decimal.new("1180.50"))
      assert parsed.warnings == []
    end

    test "flags days whose balance does not match the movements and unknown dated lines" do
      text =
        fixture("itau_extrato.txt")
        |> String.replace("1.180,50", "1.200,00")
        |> String.replace("Aviso!", "13/05/2026 linha estranha sem valor\nAviso!")

      assert {:ok, parsed} = ItauStatement.parse_text(text)
      assert [balance_warning, unknown_warning] = parsed.warnings
      assert balance_warning =~ "Saldo de 20/05/2026 não bate"
      assert balance_warning =~ "o extrato mostra R$ 1.200,00"
      assert balance_warning =~ "diferença de R$ 19,50"
      assert unknown_warning == "Linha não reconhecida: 13/05/2026 linha estranha sem valor"
    end

    test "rejects text without transactions" do
      assert ItauStatement.parse_text("data  lançamentos  valor\n01/05/2026 SALDO DO DIA  1,00") ==
               {:error, :no_transactions}
    end
  end

  describe "ItauCard.parse_text/1" do
    test "reads payments as transfers, purchases with installments and hints, and checks totals" do
      text = fixture("itau_fatura.txt")
      assert ItauCard.recognizes?(text)
      assert {:ok, parsed} = ItauCard.parse_text(text)

      assert parsed.account == %{
               bank_id: "341",
               account_ref: "5555.XXXX.XXXX.1234",
               kind: :credit_card
             }

      assert parsed.period_start == ~D[2026-03-16]
      assert parsed.period_end == ~D[2026-05-30]
      assert parsed.due_on == ~D[2026-06-08]
      assert Decimal.equal?(parsed.balance, Decimal.new("358.00"))
      assert parsed.warnings == []

      [payment, workshop, subscription] = parsed.transactions
      assert payment.kind == :transfer
      assert payment.date == ~D[2026-05-06]
      assert Decimal.equal?(payment.amount, Decimal.new("150.00"))
      assert payment.description == "Pagamento da fatura"

      assert workshop.kind == :expense
      assert workshop.date == ~D[2026-03-16]
      assert workshop.competence == ~D[2026-05-01]
      assert workshop.description == "OficinaExemplo (3/3)"
      assert workshop.payload["installment"] == %{"number" => 3, "of" => 3}
      assert workshop.payload["bank_category"] == "serviços"
      assert workshop.payload["city"] == "CIDADE EXEMPLO"

      assert subscription.date == ~D[2026-05-07]
      assert subscription.competence == ~D[2026-05-01]
      assert subscription.description == "ASSINATURAEXEMPLO"
      assert subscription.payload["city"] == "SAO PAULO"
      refute Map.has_key?(subscription.payload, "installment")
    end

    test "warns when the purchases do not add up to the printed total" do
      text =
        Regex.replace(
          ~r/ASSINATURAEXEMPLO(\s+)150,00/,
          fixture("itau_fatura.txt"),
          "ASSINATURAEXEMPLO\\g{1}151,00"
        )

      assert {:ok, parsed} = ItauCard.parse_text(text)
      assert [warning] = parsed.warnings

      assert warning =~
               "Soma das compras lidas (R$ 359,00) difere do total impresso na fatura (R$ 358,00)"
    end

    test "requires the issue date to resolve the years" do
      text = String.replace(fixture("itau_fatura.txt"), "Emissão: 30/05/2026", "")
      assert ItauCard.parse_text(text) == {:error, :missing_issue_date}
    end
  end

  describe "Parsers.PDF.parse/1" do
    @describetag :pdftotext

    test "extracts the statement text and parses it" do
      assert {:ok, parsed} = Parsers.PDF.parse(fixture("itau_extrato.pdf"))
      assert parsed.bank == :itau
      assert parsed.account.kind == :checking
      assert length(parsed.transactions) == 7
      assert parsed.raw_text =~ "SALDO DO DIA"
    end

    test "crops the card statement to the left column before parsing" do
      assert {:ok, parsed} = Parsers.PDF.parse(fixture("itau_fatura.pdf"))
      assert parsed.account.kind == :credit_card
      assert length(parsed.transactions) == 3
      refute parsed.raw_text =~ "Boleto avulso"
    end

    test "rejects unknown layouts and encrypted files" do
      assert {:error, {:unknown_layout, text}} = Parsers.PDF.parse(fixture("outro.pdf"))
      assert text =~ "Documento qualquer"
      assert Parsers.PDF.parse("%PDF-1.4\n/Encrypt 1 0 R\n") == {:error, :encrypted}
    end
  end

  describe "Text.extract/2" do
    @describetag :pdftotext

    test "reads the same file in raw mode, which keeps words the layout mode splits" do
      binary = fixture("itau_extrato.pdf")

      assert {:ok, layout} = Text.extract(binary)
      assert {:ok, raw} = Text.extract(binary, mode: :raw)

      assert layout =~ "SALDO DO DIA"
      assert raw =~ "SALDO DO DIA"
      refute layout == raw
    end
  end

  describe "NubankStatement.parse_text/1" do
    test "reads the day sections, joins wrapped descriptions and validates the balance chain" do
      text = fixture("nubank_extrato.txt")
      assert NubankStatement.recognizes?(text)
      refute ItauStatement.recognizes?(text)
      assert {:ok, parsed} = NubankStatement.parse_text(text)

      assert parsed.bank == :nubank
      assert parsed.account == %{bank_id: "260", account_ref: "1234567-8", kind: :checking}
      assert parsed.period_start == ~D[2026-05-01]
      assert parsed.period_end == ~D[2026-06-30]
      assert Decimal.equal?(parsed.balance, Decimal.new("4500.50"))
      assert parsed.warnings == []

      [salary, agency, own, supplier, june] = parsed.transactions

      assert salary.date == ~D[2026-05-07]
      assert salary.posted_on == ~D[2026-05-07]
      assert salary.kind == :income
      assert Decimal.equal?(salary.amount, Decimal.new("3000.00"))
      assert salary.payload["signed_amount"] == "3000.00"

      assert salary.raw_description ==
               "Transferência recebida pelo Pix - EMPRESA EXEMPLO LTDA - 00.000.000/0001-00 - " <>
                 "BANCO EXEMPLO S.A. (0999) Agência: 50 Conta: 430090-7"

      assert agency.date == ~D[2026-05-11]
      assert agency.kind == :expense
      assert Decimal.equal?(agency.amount, Decimal.new("500.00"))
      assert agency.payload["signed_amount"] == "-500.00"
      assert agency.raw_description =~ "Conta: 12345-6"

      assert own.kind == :expense
      assert Decimal.equal?(own.amount, Decimal.new("700.00"))
      assert supplier.raw_description == "Pagamento de boleto efetuado - FORNECEDOR EXEMPLO LTDA"

      assert june.date == ~D[2026-06-05]
      assert june.kind == :income
    end

    test "reads an entry even when a single space separates the description from the amount" do
      text = String.replace(fixture("nubank_extrato.txt"), ~r/ {2,}1\.300,00/, " 1.300,00")

      assert {:ok, parsed} = NubankStatement.parse_text(text)
      assert length(parsed.transactions) == 5
      assert parsed.warnings == []
    end

    test "flags a day whose balance does not match the movements" do
      text = String.replace(fixture("nubank_extrato.txt"), "1.500,00", "1.600,00")

      assert {:ok, parsed} = NubankStatement.parse_text(text)
      assert [broken_day, next_day] = parsed.warnings
      assert broken_day =~ "Saldo de 11/05/2026 não bate"
      assert broken_day =~ "o extrato mostra R$ 1.600,00"
      assert broken_day =~ "diferença de R$ 100,00"
      assert next_day =~ "Saldo de 05/06/2026 não bate"
    end
  end

  describe "ItauCard.parse_text/1 with the printed invoice layout" do
    test "reads it despite the letter spacing and skips the next-invoice section" do
      text = fixture("itau_fatura_impressa.txt")
      assert ItauCard.recognizes?(text)
      assert {:ok, parsed} = ItauCard.parse_text(text)

      assert parsed.account == %{
               bank_id: "341",
               account_ref: "1234.XXXX.XXXX.5678",
               kind: :credit_card
             }

      assert parsed.due_on == ~D[2026-08-06]
      assert Decimal.equal?(parsed.balance, Decimal.new("300.00"))
      assert parsed.warnings == []

      [payment, store, subscription] = parsed.transactions

      assert payment.kind == :transfer
      assert payment.description == "Pagamento da fatura"
      assert Decimal.equal?(payment.amount, Decimal.new("180.00"))

      assert store.description == "LojaExemplo (2/3)"
      assert store.payload["installment"] == %{"number" => 2, "of" => 3}
      assert store.payload["city"] == "CIDADE EXEMPLO"

      assert subscription.description == "ASSINATURAEXEMPLO"
      assert subscription.payload["city"] == "OUTRA CIDADE"

      refute Enum.any?(parsed.transactions, &(&1.description =~ "(3/3)"))
    end

    test "warns when the payment did not cover the previous invoice" do
      text =
        fixture("itau_fatura_impressa.txt")
        |> String.replace(
          "06/07 Pagamento via conta -180,00",
          "06/07 Pagamento via conta -100,00"
        )
        |> String.replace("P Total dos pagamentos -180,00", "P Total dos pagamentos -100,00")

      assert {:ok, parsed} = ItauCard.parse_text(text)
      assert [warning] = parsed.warnings
      assert warning =~ "A fatura anterior era de R$ 180,00"
      assert warning =~ "pagamento registrado foi de R$ 100,00"
      assert warning =~ "R$ 80,00"
    end
  end
end
