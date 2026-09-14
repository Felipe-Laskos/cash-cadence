defmodule CashCadence.Imports.Parsers.PDF do
  @moduledoc false

  alias CashCadence.Imports.Parsers.PDF.{ItauCard, ItauStatement, OCR, Text}

  @card_crop %{x: 0, y: 0, w: 330, h: 842}
  @ocr_warning "Texto obtido por OCR, porque o arquivo era só imagem: confira datas e valores antes de aprovar."

  def parse(binary, opts \\ []) when is_binary(binary) do
    with {:ok, unlocked} <- Text.unlock(binary, opts[:password]),
         {:ok, text} <- Text.extract(unlocked) do
      if scanned?(text),
        do: parse_scanned(unlocked),
        else: parse_recognized(unlocked, text, false)
    end
  end

  def parse_recognized(binary, text, ocr?) do
    cond do
      ItauStatement.recognizes?(text) -> text |> ItauStatement.parse_text() |> finish(text, ocr?)
      ItauCard.recognizes?(text) -> parse_card(binary, text, ocr?)
      true -> {:error, {:unknown_layout, text}}
    end
  end

  defp parse_scanned(binary) do
    with {:ok, searchable} <- OCR.recognize_pdf(binary),
         {:ok, text} <- Text.extract(searchable) do
      parse_recognized(searchable, OCR.clean(text), true)
    end
  end

  defp scanned?(text) do
    text |> String.replace(~r/[^\p{L}\d]/u, "") |> String.length() < 40
  end

  defp parse_card(binary, full_text, ocr?) do
    text =
      case Text.extract(binary, crop: @card_crop) do
        {:ok, cropped} -> pick_card_text(maybe_clean(cropped, ocr?), full_text)
        {:error, _} -> full_text
      end

    text |> ItauCard.parse_text() |> finish(text, ocr?)
  end

  defp pick_card_text(cropped, full_text),
    do: if(ItauCard.recognizes?(cropped), do: cropped, else: full_text)

  defp maybe_clean(text, true), do: OCR.clean(text)
  defp maybe_clean(text, false), do: text

  defp finish({:ok, parsed}, text, false), do: {:ok, Map.put(parsed, :raw_text, text)}

  defp finish({:ok, parsed}, text, true) do
    transactions =
      Enum.map(parsed.transactions, &%{&1 | payload: Map.put(&1.payload, "ocr", true)})

    {:ok,
     parsed
     |> Map.put(:raw_text, text)
     |> Map.put(:transactions, transactions)
     |> Map.update(:warnings, [@ocr_warning], &[@ocr_warning | &1])}
  end

  defp finish(error, _text, _ocr?), do: error
end
