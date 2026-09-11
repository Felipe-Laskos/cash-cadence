defmodule CashCadenceWeb.Format do
  @moduledoc false

  alias CashCadence.Money

  @months ~w(janeiro fevereiro março abril maio junho julho agosto setembro outubro novembro dezembro)
  @months_short ~w(jan fev mar abr mai jun jul ago set out nov dez)
  @weekdays ~w(segunda terça quarta quinta sexta sábado domingo)

  def brl(value, opts \\ []), do: "R$ " <> amount(value, opts)

  def amount(value, opts \\ [])
  def amount(nil, opts), do: amount(Money.zero(), opts)
  def amount(value, opts) when is_integer(value), do: amount(Decimal.new(value), opts)

  def amount(%Decimal{} = value, opts) do
    cents? = Keyword.get(opts, :cents, true)
    rounded = Decimal.round(value, if(cents?, do: 2, else: 0))
    {int, frac} = rounded |> Decimal.abs() |> Decimal.to_string(:normal) |> split_decimal()
    body = if cents?, do: group(int) <> "," <> String.pad_trailing(frac, 2, "0"), else: group(int)
    sign(rounded, Keyword.get(opts, :signed, false)) <> body
  end

  defp split_decimal(digits) do
    case String.split(digits, ".") do
      [int, frac] -> {int, frac}
      [int] -> {int, ""}
    end
  end

  defp group(int) do
    int
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1.")
    |> String.reverse()
  end

  defp sign(value, signed?) do
    cond do
      Decimal.negative?(value) -> "-"
      signed? and Money.positive?(value) -> "+"
      true -> ""
    end
  end

  def input_amount(nil), do: ""

  def input_amount(%Decimal{} = value),
    do: value |> Decimal.round(2) |> Decimal.to_string(:normal) |> String.replace(".", ",")

  def input_amount(value) when is_binary(value), do: value

  def percent(nil), do: "—"

  def percent(%Decimal{} = value, digits \\ 1) do
    value
    |> Decimal.round(digits)
    |> Decimal.to_string(:normal)
    |> String.replace(".", ",")
    |> Kernel.<>("%")
  end

  def month_name(%Date{month: month}), do: Enum.at(@months, month - 1)

  def month_title(%Date{} = date),
    do: String.capitalize(month_name(date)) <> " " <> Integer.to_string(date.year)

  def month_label(%Date{} = date), do: month_name(date) <> " " <> Integer.to_string(date.year)

  def month_short(%Date{} = date) do
    Enum.at(@months_short, date.month - 1) <>
      "/" <> String.slice(Integer.to_string(date.year), 2, 2)
  end

  def month_param(%Date{} = date), do: Calendar.strftime(date, "%Y-%m")

  def parse_month(<<year::binary-size(4), "-", month::binary-size(2)>>) do
    case Date.from_iso8601(year <> "-" <> month <> "-01") do
      {:ok, date} -> {:ok, date}
      {:error, _} -> :error
    end
  end

  def parse_month(_), do: :error

  def weekday(%Date{} = date), do: Enum.at(@weekdays, Date.day_of_week(date) - 1)
  def day_heading(%Date{} = date), do: "#{weekday(date)}, #{date.day} de #{month_name(date)}"
  def short_date(%Date{} = date), do: Calendar.strftime(date, "%d/%m")
  def full_date(%Date{} = date), do: Calendar.strftime(date, "%d/%m/%Y")
  def iso_date(%Date{} = date), do: Date.to_iso8601(date)
end
