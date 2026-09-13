defmodule CashCadence.Imports.Parsers.PDF do
  @moduledoc false

  alias CashCadence.Imports.Parsers.PDF.{ItauCard, ItauStatement, Text}

  @card_crop %{x: 0, y: 0, w: 330, h: 842}

  def parse(binary) when is_binary(binary) do
    with {:ok, text} <- Text.extract(binary) do
      cond do
        ItauStatement.recognizes?(text) -> text |> ItauStatement.parse_text() |> with_text(text)
        ItauCard.recognizes?(text) -> parse_card(binary, text)
        true -> {:error, {:unknown_layout, text}}
      end
    end
  end

  defp parse_card(binary, full_text) do
    text =
      case Text.extract(binary, crop: @card_crop) do
        {:ok, cropped} -> if ItauCard.recognizes?(cropped), do: cropped, else: full_text
        {:error, _} -> full_text
      end

    text |> ItauCard.parse_text() |> with_text(text)
  end

  defp with_text({:ok, parsed}, text), do: {:ok, Map.put(parsed, :raw_text, text)}
  defp with_text(error, _text), do: error
end
