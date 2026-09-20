defmodule CashCadence.Imports.BrFormat do
  @moduledoc false

  alias CashCadence.Money

  def date(<<day::binary-size(2), "/", month::binary-size(2), "/", year::binary-size(4)>>) do
    Date.from_iso8601("#{year}-#{month}-#{day}")
  end

  def date(_), do: {:error, :invalid_date}

  def day_month(<<day::binary-size(2), "/", month::binary-size(2)>>, %Date{} = reference) do
    with {:ok, date} <- Date.from_iso8601("#{reference.year}-#{month}-#{day}") do
      if Date.compare(date, reference) == :gt,
        do: Date.from_iso8601("#{reference.year - 1}-#{month}-#{day}"),
        else: {:ok, date}
    end
  end

  def day_month(_, _reference), do: {:error, :invalid_date}

  def decimal(text) when is_binary(text), do: Money.parse(text)

  def any_date(<<_::binary-size(4), "-", _::binary>> = text), do: Date.from_iso8601(text)
  def any_date(text) when is_binary(text), do: date(text)
  def any_date(_text), do: {:error, :invalid_date}

  def normalize_param(attrs, key) when is_map(attrs) do
    string_key = Atom.to_string(key)

    cond do
      is_binary(Map.get(attrs, string_key)) -> Map.update!(attrs, string_key, &to_iso/1)
      is_binary(Map.get(attrs, key)) -> Map.update!(attrs, key, &to_iso/1)
      true -> attrs
    end
  end

  defp to_iso(text) do
    case any_date(String.trim(text)) do
      {:ok, date} -> Date.to_iso8601(date)
      _error -> text
    end
  end

  def money(%Decimal{} = value) do
    rounded = Decimal.round(value, 2)
    sign = if Decimal.negative?(rounded), do: "-", else: ""

    [integer, fraction] =
      rounded |> Decimal.abs() |> Decimal.to_string(:normal) |> String.split(".")

    grouped =
      integer
      |> String.reverse()
      |> String.replace(~r/(\d{3})(?=\d)/, "\\1.")
      |> String.reverse()

    "#{sign}R$ #{grouped},#{fraction}"
  end
end
