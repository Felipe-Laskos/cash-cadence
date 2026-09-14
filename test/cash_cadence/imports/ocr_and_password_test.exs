defmodule CashCadence.Imports.OCRAndPasswordTest do
  use ExUnit.Case, async: true

  alias CashCadence.Imports.Sniffer
  alias CashCadence.Imports.Parsers
  alias CashCadence.Imports.Parsers.PDF.{OCR, Text}

  @fixtures Path.expand("../../support/fixtures/imports", __DIR__)

  defp fixture(name), do: File.read!(Path.join(@fixtures, name))

  describe "Sniffer.detect/1" do
    test "recognizes JPEG and PNG images" do
      assert {:ok, %{format: :image, parser: Parsers.Image}} =
               Sniffer.detect(fixture("itau_extrato_foto.png"))

      assert {:ok, %{format: :image, parser: Parsers.Image}} =
               Sniffer.detect(<<0xFF, 0xD8, 0xFF, 0xE0, 0, 16, "JFIF">>)
    end
  end

  describe "OCR.clean/1" do
    test "fixes letter and digit confusions inside dates and amounts only" do
      text = "2O/O5/2026  PIX QRS LOJA O2 EXEMPLO2O/O5   -l2,5O   SALDO 1.18O,5O  Oi Ola"

      assert OCR.clean(text) ==
               "20/05/2026  PIX QRS LOJA O2 EXEMPLO2O/O5   -12,50   SALDO 1.180,50  Oi Ola"
    end
  end

  describe "password protected PDFs" do
    @describetag :pdftotext
    @describetag :qpdf

    test "refuses without a password, rejects a wrong one and reads with the right one" do
      binary = fixture("itau_extrato_senha.pdf")
      assert Text.encrypted?(binary)
      assert Parsers.PDF.parse(binary) == {:error, :encrypted}
      assert Parsers.PDF.parse(binary, password: "errada") == {:error, :wrong_password}

      assert {:ok, parsed} = Parsers.PDF.parse(binary, password: "senha123")
      assert length(parsed.transactions) == 7
      assert parsed.warnings == []
    end
  end

  describe "OCR" do
    @describetag :pdftotext
    @describetag :ocr

    test "reads a scanned PDF through OCR and flags every item" do
      assert {:ok, parsed} = Parsers.PDF.parse(fixture("itau_extrato_escaneado.pdf"))
      assert parsed.bank == :itau
      assert length(parsed.transactions) == 7
      assert [warning | _] = parsed.warnings
      assert warning =~ "Texto obtido por OCR"
      assert Enum.all?(parsed.transactions, &(&1.payload["ocr"] == true))
      assert Decimal.equal?(parsed.balance, Decimal.new("1180.50"))
    end

    test "reads a photo of the statement" do
      assert {:ok, parsed} = Parsers.Image.parse(fixture("itau_extrato_foto.png"))
      assert parsed.account.kind == :checking
      assert length(parsed.transactions) == 7
      assert hd(parsed.warnings) =~ "Texto obtido por OCR"
    end
  end
end
