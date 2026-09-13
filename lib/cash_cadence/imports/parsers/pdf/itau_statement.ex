defmodule CashCadence.Imports.Parsers.PDF.ItauStatement do
  @moduledoc false

  alias CashCadence.Imports.{BrFormat, Raw}
  alias CashCadence.Money

  @line ~r/^\s*(\d{2}\/\d{2}\/\d{4})\s+(.+?)\s{2,}(-?[\d.]*\d,\d{2})\s*$/
  @dated ~r/^\s*\d{2}\/\d{2}\/\d{4}\s/
  @effective ~r/^(.*?)\s?(\d{2}\/\d{2})$/
  @header ~r/data\s+lançamentos\s+valor/iu
  @account ~r/agência:\s*([\w-]+)\s+conta:\s*([\w-]+)/iu
  @period ~r/período de visualização:\s*(\d{2}\/\d{2}\/\d{4})\s+até\s+(\d{2}\/\d{2}\/\d{4})/iu

  def recognizes?(text) when is_binary(text) do
    String.contains?(text, "SALDO DO DIA") and Regex.match?(@header, text)
  end

  def parse_text(text) when is_binary(text) do
    {transactions, balances, unknown} =
      text
      |> String.split(~r/\r?\n/)
      |> Enum.reduce({[], [], []}, &classify/2)

    transactions = Enum.reverse(transactions)
    balances = balances |> Enum.reverse() |> Enum.sort_by(& &1.date, Date)

    if transactions == [] do
      {:error, :no_transactions}
    else
      {:ok,
       %{
         bank: :itau,
         account: %{bank_id: "341", account_ref: account_ref(text), kind: :checking},
         currency: "BRL",
         period_start: period(text, 1) || min_date(transactions),
         period_end: period(text, 2) || max_date(transactions),
         balance: balances |> List.last() |> then(&(&1 && &1.amount)),
         transactions: Enum.map(transactions, &to_raw/1),
         warnings:
           balance_warnings(balances, transactions) ++
             Enum.map(Enum.reverse(unknown), &"Linha não reconhecida: #{&1}")
       }}
    end
  end

  defp classify(line, {transactions, balances, unknown}) do
    case parse_line(line) do
      {:transaction, entry} -> {[entry | transactions], balances, unknown}
      {:balance, entry} -> {transactions, [entry | balances], unknown}
      {:unknown, text} -> {transactions, balances, [text | unknown]}
      :noise -> {transactions, balances, unknown}
    end
  end

  defp parse_line(line) do
    case Regex.run(@line, line) do
      [_, date, description, amount] ->
        build_entry(BrFormat.date(date), String.trim(description), Money.parse(amount), line)

      nil ->
        if Regex.match?(@dated, line), do: {:unknown, String.trim(line)}, else: :noise
    end
  end

  defp build_entry({:ok, date}, "SALDO" <> _, {:ok, amount}, _line),
    do: {:balance, %{date: date, amount: amount}}

  defp build_entry({:ok, date}, description, {:ok, amount}, _line),
    do: {:transaction, %{posted_on: date, description: description, signed: amount}}

  defp build_entry(_date, _description, _amount, line), do: {:unknown, String.trim(line)}

  defp to_raw(%{posted_on: posted_on, description: description, signed: signed}) do
    {label, effective} = split_effective(description, posted_on)

    %Raw{
      date: effective,
      posted_on: posted_on,
      amount: Decimal.abs(signed),
      kind: kind(label, signed),
      raw_description: description,
      description: humanize(label),
      payload: %{
        "signed_amount" => Decimal.to_string(signed, :normal),
        "effective_date" => Date.to_iso8601(effective)
      }
    }
  end

  defp split_effective(description, posted_on) do
    with [_, label, day_month] <- Regex.run(@effective, description),
         {:ok, date} <- BrFormat.day_month(day_month, posted_on) do
      {String.trim(label), date}
    else
      _ -> {description, posted_on}
    end
  end

  defp kind("FATURA PAGA" <> _, _signed), do: :transfer
  defp kind(_label, signed), do: if(Decimal.negative?(signed), do: :expense, else: :income)

  defp humanize("PIX QRS " <> rest), do: "Pix QR: " <> String.trim(rest)
  defp humanize("PIX TRANSF " <> rest), do: "Pix: " <> String.trim(rest)
  defp humanize("FATURA PAGA " <> rest), do: "Fatura do cartão: " <> String.trim(rest)
  defp humanize("REND PAGO APLIC AUT" <> _), do: "Rendimento da conta"
  defp humanize(label), do: label

  defp balance_warnings(balances, transactions) do
    balances
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [previous, current] ->
      movement =
        transactions
        |> Enum.filter(&between?(&1.posted_on, previous.date, current.date))
        |> Enum.map(& &1.signed)
        |> Money.sum()

      expected = Decimal.add(previous.amount, movement)

      if Decimal.equal?(expected, current.amount) do
        []
      else
        [
          "Saldo de #{Calendar.strftime(current.date, "%d/%m/%Y")} não bate: o extrato mostra " <>
            "#{BrFormat.money(current.amount)} e a soma dos lançamentos dá #{BrFormat.money(expected)} " <>
            "(diferença de #{BrFormat.money(Decimal.sub(current.amount, expected))})."
        ]
      end
    end)
  end

  defp between?(date, after_date, until_date),
    do: Date.compare(date, after_date) == :gt and Date.compare(date, until_date) != :gt

  defp account_ref(text) do
    case Regex.run(@account, text) do
      [_, agency, account] -> "#{agency}/#{account}"
      nil -> nil
    end
  end

  defp period(text, index) do
    with [_ | parts] <- Regex.run(@period, text),
         {:ok, date} <- BrFormat.date(Enum.at(parts, index - 1)) do
      date
    else
      _ -> nil
    end
  end

  defp min_date(transactions), do: transactions |> Enum.map(& &1.posted_on) |> Enum.min(Date)
  defp max_date(transactions), do: transactions |> Enum.map(& &1.posted_on) |> Enum.max(Date)
end
