defmodule CashCadence.Imports.Parsers.CSV.NubankChecking do
  @moduledoc false

  alias CashCadence.Imports.Raw
  alias NimbleCSV.RFC4180, as: CSV

  def parse(binary) when is_binary(binary) do
    rows = binary |> CSV.parse_string() |> Enum.reject(&(&1 == [] or &1 == [""]))

    if rows == [] do
      {:error, :no_transactions}
    else
      transactions = Enum.map(rows, &raw/1)
      dates = Enum.map(transactions, & &1.date)

      {:ok,
       %{
         account: %{bank_id: nil, account_ref: nil, kind: :checking},
         currency: "BRL",
         period_start: Enum.min(dates, Date),
         period_end: Enum.max(dates, Date),
         balance: nil,
         transactions: transactions
       }}
    end
  end

  defp raw([date, value, id, description | _]) do
    amount = Decimal.new(String.trim(value))
    date = parse_date(String.trim(date))

    %Raw{
      date: date,
      posted_on: date,
      amount: Decimal.abs(amount),
      kind: if(Decimal.negative?(amount), do: :expense, else: :income),
      raw_description: String.trim(description),
      external_id: blank_to_nil(String.trim(id)),
      payload: %{}
    }
  end

  defp parse_date(<<day::binary-size(2), "/", month::binary-size(2), "/", year::binary-size(4)>>) do
    Date.from_iso8601!("#{year}-#{month}-#{day}")
  end

  defp parse_date(iso), do: Date.from_iso8601!(iso)

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
