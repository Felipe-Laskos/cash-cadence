defmodule CashCadence.Imports.ParsersTest do
  use ExUnit.Case, async: true

  alias CashCadence.Imports.{Normalizer, Sniffer}
  alias CashCadence.Imports.Parsers

  @fixtures Path.expand("../../support/fixtures/imports", __DIR__)

  defp fixture(name), do: File.read!(Path.join(@fixtures, name))

  describe "Sniffer.detect/1" do
    test "recognizes a Nubank checking OFX" do
      assert {:ok,
              %{
                format: :ofx,
                bank: :nubank,
                account_kind: :checking,
                encoding: :utf8,
                parser: Parsers.OFX
              }} =
               Sniffer.detect(fixture("nubank_conta.ofx"))
    end

    test "recognizes the Nubank CSV files by header" do
      assert {:ok, %{format: :csv, bank: :nubank, account_kind: :checking}} =
               Sniffer.detect(fixture("nubank_conta.csv"))

      assert {:ok, %{format: :csv, bank: :nubank, account_kind: :credit_card}} =
               Sniffer.detect("﻿" <> fixture("nubank_cartao.csv"))
    end

    test "flags latin1 OFX headers and rejects unknown content" do
      assert {:ok, %{encoding: :latin1, bank: :itau}} =
               Sniffer.detect(
                 "OFXHEADER:100\nDATA:OFXSGML\nENCODING:USASCII\nCHARSET:1252\n<OFX><SONRS><FI><ORG>Banco Itau</ORG></FI></SONRS></OFX>"
               )

      assert {:error, :unknown_format} = Sniffer.detect("nada a ver com extrato")
    end
  end

  describe "Parsers.OFX.parse/1" do
    test "extracts account, period, balance and transactions" do
      assert {:ok, parsed} = Parsers.OFX.parse(fixture("nubank_conta.ofx"))
      assert parsed.account == %{bank_id: "0260", account_ref: "1234567-8", kind: :checking}
      assert parsed.period_start == ~D[2026-05-01]
      assert parsed.period_end == ~D[2026-05-31]
      assert Decimal.equal?(parsed.balance, Decimal.new("561.18"))

      [income, tax, bakery] = parsed.transactions
      assert income.kind == :income
      assert Decimal.equal?(income.amount, Decimal.new("1000.00"))
      assert income.date == ~D[2026-05-07]
      assert income.external_id == "11111111-1111-1111-1111-111111111111"
      assert tax.kind == :expense
      assert Decimal.equal?(tax.amount, Decimal.new("390.00"))
      assert bakery.raw_description == "Compra no débito - PADARIA EXEMPLO"
      assert bakery.payload["trntype"] == "DEBIT"
    end

    test "fails without transactions" do
      assert {:error, :no_transactions} = Parsers.OFX.parse("<OFX></OFX>")
    end
  end

  describe "CSV adapters" do
    test "Nubank checking rows keep the identifier as external id" do
      assert {:ok, parsed} = Parsers.CSV.NubankChecking.parse(fixture("nubank_conta.csv"))
      assert parsed.period_start == ~D[2026-05-07]
      assert parsed.period_end == ~D[2026-05-22]
      [income, tax, _] = parsed.transactions
      assert income.kind == :income
      assert income.external_id == "11111111-1111-1111-1111-111111111111"
      assert tax.kind == :expense
      assert Decimal.equal?(tax.amount, Decimal.new("390.00"))
    end

    test "Nubank card rows classify purchases, refunds and statement payments" do
      assert {:ok, parsed} = Parsers.CSV.NubankCard.parse(fixture("nubank_cartao.csv"))
      [purchase, fuel, payment] = parsed.transactions
      assert purchase.kind == :expense
      assert purchase.payload["bank_category"] == "eletrônicos"
      assert fuel.raw_description == "Posto Exemplo"
      assert payment.kind == :transfer
      assert Decimal.equal?(payment.amount, Decimal.new("229.90"))
    end
  end

  describe "Normalizer" do
    test "normalize/1 strips accents, digits, punctuation and dates" do
      assert Normalizer.normalize("Compra no débito - PADARIA EXEMPLO 22/05") ==
               "COMPRA NO DEBITO PADARIA EXEMPLO"

      assert Normalizer.normalize("PIX QRS ZAMP S.A.05/09") == "PIX QRS ZAMP S A"
      assert Normalizer.normalize(nil) == ""
    end

    test "short_description/1 keeps the operation and the counterparty" do
      assert Normalizer.short_description(
               "Transferência enviada pelo Pix - RECEITA FEDERAL - 00.000.000/0001-91 - BANCO"
             ) == "Transferência enviada pelo Pix: RECEITA FEDERAL"

      assert Normalizer.short_description("Compra no débito - PADARIA EXEMPLO") ==
               "Compra no débito: PADARIA EXEMPLO"

      assert Normalizer.short_description("PIX QRS LOJA") == "PIX QRS LOJA"
    end
  end
end
