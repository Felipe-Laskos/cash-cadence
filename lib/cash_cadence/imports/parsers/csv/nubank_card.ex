defmodule CashCadence.Imports.Parsers.CSV.NubankCard do
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
         account: %{bank_id: nil, account_ref: nil, kind: :credit_card},
         currency: "BRL",
         period_start: Enum.min(dates, Date),
         period_end: Enum.max(dates, Date),
         balance: nil,
         transactions: transactions
       }}
    end
  end

  defp raw([date, category, title, value | _]) do
    amount = Decimal.new(String.trim(value))
    date = Date.from_iso8601!(String.trim(date))
    title = String.trim(title)

    kind =
      cond do
        String.contains?(String.downcase(title), "pagamento") -> :transfer
        Decimal.negative?(amount) -> :income
        true -> :expense
      end

    %Raw{
      date: date,
      posted_on: date,
      amount: Decimal.abs(amount),
      kind: kind,
      raw_description: title,
      external_id: nil,
      payload: %{"bank_category" => String.trim(category)}
    }
  end
end
