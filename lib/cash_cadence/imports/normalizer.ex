defmodule CashCadence.Imports.Normalizer do
  @moduledoc false

  def normalize(nil), do: ""

  def normalize(text) when is_binary(text) do
    text
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.upcase()
    |> String.replace(~r/[^A-Z ]+/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  def short_description(text) when is_binary(text) do
    case String.split(text, " - ", parts: 3) do
      [kind, counterparty | _] -> String.trim(kind) <> ": " <> String.trim(counterparty)
      _ -> String.trim(text)
    end
  end

  def short_description(nil), do: nil
end
