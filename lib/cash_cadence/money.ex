defmodule CashCadence.Money do
  @moduledoc false

  @zero Decimal.new(0)

  def zero, do: @zero

  def parse(value) when is_binary(value) do
    case Decimal.parse(normalize(value)) do
      {decimal, ""} -> {:ok, decimal}
      _ -> :error
    end
  end

  def parse(%Decimal{} = value), do: {:ok, value}
  def parse(value) when is_integer(value), do: {:ok, Decimal.new(value)}
  def parse(_), do: :error

  def normalize(value) when is_binary(value) do
    cleaned = String.replace(value, ~r/[R$\s\x{00A0}]/u, "")

    if String.contains?(cleaned, ",") do
      cleaned |> String.replace(".", "") |> String.replace(",", ".")
    else
      cleaned
    end
  end

  def normalize_param(attrs, key) when is_map(attrs) do
    string_key = Atom.to_string(key)

    cond do
      is_binary(Map.get(attrs, string_key)) -> Map.update!(attrs, string_key, &normalize/1)
      is_binary(Map.get(attrs, key)) -> Map.update!(attrs, key, &normalize/1)
      true -> attrs
    end
  end

  def sum(decimals), do: Enum.reduce(decimals, @zero, &Decimal.add(&2, &1 || @zero))

  def positive?(%Decimal{} = value), do: Decimal.compare(value, @zero) == :gt

  def pct_change(_current, nil), do: nil

  def pct_change(current, previous) do
    if Decimal.equal?(previous, @zero) do
      nil
    else
      current
      |> Decimal.sub(previous)
      |> Decimal.div(previous)
      |> Decimal.mult(100)
      |> Decimal.round(1)
    end
  end

  def ratio(_numerator, %Decimal{} = denominator) when denominator == @zero, do: nil

  def ratio(numerator, denominator) do
    if Decimal.equal?(denominator, @zero), do: nil, else: Decimal.div(numerator, denominator)
  end
end
