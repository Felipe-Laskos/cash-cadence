defmodule CashCadence.Imports.Parsers.Image do
  @moduledoc false

  alias CashCadence.Imports.Parsers.PDF
  alias CashCadence.Imports.Parsers.PDF.{OCR, Text}

  def parse(binary, _opts \\ []) when is_binary(binary) do
    with {:ok, pdf} <- OCR.recognize_image(binary, extension(binary)),
         {:ok, text} <- Text.extract(pdf) do
      PDF.parse_recognized(pdf, OCR.clean(text), true)
    end
  end

  defp extension(<<0x89, "PNG", _rest::binary>>), do: ".png"
  defp extension(_binary), do: ".jpg"
end
