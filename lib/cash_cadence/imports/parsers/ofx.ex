defmodule CashCadence.Imports.Parsers.OFX do
  @moduledoc false

  alias CashCadence.Imports.Raw

  def parse(binary, _opts \\ []) when is_binary(binary) do
    blocks = Regex.scan(~r/<STMTTRN>(.*?)<\/STMTTRN>/s, binary)

    if blocks == [] do
      {:error, :no_transactions}
    else
      {:ok,
       %{
         account: %{
           bank_id: tag(binary, "BANKID"),
           account_ref: tag(binary, "ACCTID"),
           kind: account_kind(binary)
         },
         currency: tag(binary, "CURDEF"),
         period_start: date(tag(binary, "DTSTART")),
         period_end: date(tag(binary, "DTEND")),
         balance: decimal(tag(binary, "BALAMT")),
         transactions: Enum.map(blocks, fn [_, block] -> raw(block) end)
       }}
    end
  end

  defp raw(block) do
    amount = decimal(tag(block, "TRNAMT")) || Decimal.new(0)
    posted = date(tag(block, "DTPOSTED"))
    description = tag(block, "MEMO") || tag(block, "NAME") || ""

    %Raw{
      date: posted,
      posted_on: posted,
      amount: Decimal.abs(amount),
      kind: if(Decimal.negative?(amount), do: :expense, else: :income),
      raw_description: description,
      external_id: tag(block, "FITID"),
      payload: %{
        "trntype" => tag(block, "TRNTYPE"),
        "name" => tag(block, "NAME"),
        "memo" => tag(block, "MEMO"),
        "checknum" => tag(block, "CHECKNUM")
      }
    }
  end

  defp account_kind(binary),
    do: if(String.contains?(binary, "<CCACCTFROM>"), do: :credit_card, else: :checking)

  defp tag(text, name) do
    case Regex.run(~r/<#{name}>([^<\r\n]*)/, text) do
      [_, value] -> value |> String.trim() |> blank_to_nil()
      nil -> nil
    end
  end

  defp date(nil), do: nil

  defp date(<<year::binary-size(4), month::binary-size(2), day::binary-size(2), _rest::binary>>) do
    case Date.from_iso8601("#{year}-#{month}-#{day}") do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp date(_), do: nil

  defp decimal(nil), do: nil

  defp decimal(value) do
    case Decimal.parse(String.replace(value, ",", ".")) do
      {decimal, _} -> decimal
      :error -> nil
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
