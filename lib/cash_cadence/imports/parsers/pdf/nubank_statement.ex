defmodule CashCadence.Imports.Parsers.PDF.NubankStatement do
  @moduledoc false

  alias CashCadence.Imports.{BrFormat, Raw}
  alias CashCadence.Money

  @day ~r/^\s*(\d{2})\s+([A-ZÇ]{3})\s+(\d{4})\b\s*(.*)$/u
  @section ~r/Total de (entradas|saídas)/iu
  @balance ~r/^\s{2,}Saldo do dia\s{2,}(-?[\d.]*\d,\d{2})\s*$/u
  @entry ~r/^\s{2,}(\S.*?)\s{2,}(\S.*?)\s+(-?[\d.]*\d,\d{2})\s*$/u
  @bare_entry ~r/^\s{2,}(\S.*?)\s+(-?[\d.]*\d,\d{2})\s*$/u
  @continuation ~r/^\s{2,}(\S.*?)\s*$/u
  @noise ~r/^\s*(VALORES EM|CNPJ|CPF|Extrato gerado|Tem alguma|Caso a solu|Movimenta|Saldo inicial|Saldo final|Rendimento|Nu Pagamentos|nubank\.com)/iu
  @account ~r/Ag[êe]ncia\s+(\S+)\s+Conta\s+([\d-]+)/iu
  @period ~r/(\d{2})\s+DE\s+([A-ZÇ]+)\s+DE\s+(\d{4})\s+a\s+(\d{2})\s+DE\s+([A-ZÇ]+)\s+DE\s+(\d{4})/iu
  @opening ~r/Saldo inicial\s+(-?[\d.]*\d,\d{2})/iu
  @closing ~r/Saldo final do período\s+(-?[\d.]*\d,\d{2})/iu

  @months ~w(JAN FEV MAR ABR MAI JUN JUL AGO SET OUT NOV DEZ)

  def recognizes?(text) when is_binary(text) do
    Regex.match?(~r/nubank\.com|Nu Pagamentos/iu, text) and
      String.contains?(text, "Saldo do dia") and Regex.match?(@section, text)
  end

  def parse_text(text) when is_binary(text) do
    state =
      text
      |> String.split(~r/\r?\n/)
      |> Enum.reduce(
        %{date: nil, sign: nil, open?: false, entries: [], balances: []},
        &classify/2
      )

    entries = Enum.reverse(state.entries)

    if entries == [] do
      {:error, :no_transactions}
    else
      {period_start, period_end} = period(text)
      balances = Enum.reverse(state.balances)

      {:ok,
       %{
         bank: :nubank,
         account: %{bank_id: "260", account_ref: account_ref(text), kind: :checking},
         currency: "BRL",
         period_start: period_start || min_date(entries),
         period_end: period_end || max_date(entries),
         balance: closing_balance(text, balances),
         transactions: Enum.map(entries, &to_raw/1),
         warnings: balance_warnings(opening(text, period_start, entries) ++ balances, entries)
       }}
    end
  end

  defp classify(line, state) do
    case parse_line(line, state) do
      {:day, date, sign} ->
        %{state | date: date, sign: sign || state.sign, open?: false}

      {:section, sign} ->
        %{state | sign: sign, open?: false}

      {:balance, amount} ->
        balance = %{date: state.date, amount: amount}
        %{state | balances: [balance | state.balances], open?: false}

      {:entry, label, description, amount} ->
        add_entry(state, label, description, amount)

      {:continuation, text} ->
        continue(state, text)

      :noise ->
        %{state | open?: false}

      :skip ->
        state
    end
  end

  defp parse_line(line, state) do
    cond do
      String.contains?(line, "\f") -> :noise
      String.trim(line) == "" -> :skip
      true -> parse_content(line, state)
    end
  end

  defp parse_content(line, state) do
    case Regex.run(@day, line) do
      [_, day, month, year, rest] -> day_line(day, month, year, rest)
      nil -> parse_movement(line, state)
    end
  end

  defp parse_movement(_line, %{date: nil}), do: :skip

  defp parse_movement(line, state) do
    cond do
      Regex.match?(@noise, line) -> :noise
      balance = capture(@balance, line) -> {:balance, balance}
      Regex.match?(@section, line) -> {:section, sign(line)}
      true -> parse_entry(line, state)
    end
  end

  defp parse_entry(line, state) do
    case Regex.run(@entry, line) do
      [_, label, description, amount] ->
        entry(label, description, amount)

      nil ->
        case Regex.run(@bare_entry, line) do
          [_, label, amount] -> entry(label, "", amount)
          nil -> continuation(line, state)
        end
    end
  end

  defp continuation(line, %{open?: true}) do
    case Regex.run(@continuation, line) do
      [_, text] -> {:continuation, text}
      nil -> :skip
    end
  end

  defp continuation(_line, _state), do: :skip

  defp entry(label, description, amount) do
    case Money.parse(amount) do
      {:ok, value} -> {:entry, String.trim(label), String.trim(description), value}
      :error -> :skip
    end
  end

  defp day_line(day, month, year, rest) do
    with {:ok, index} <- month_index(month),
         {:ok, date} <- Date.new(String.to_integer(year), index, String.to_integer(day)) do
      {:day, date, if(Regex.match?(@section, rest), do: sign(rest), else: nil)}
    else
      _ -> :noise
    end
  end

  defp month_index(month) do
    case Enum.find_index(@months, &(&1 == String.upcase(month))) do
      nil -> :error
      index -> {:ok, index + 1}
    end
  end

  defp sign(text), do: if(Regex.match?(~r/saídas/iu, text), do: :out, else: :in)

  defp add_entry(state, label, description, amount) do
    entry = %{
      date: state.date,
      label: label,
      description: description,
      signed: signed(amount, state.sign)
    }

    %{state | entries: [entry | state.entries], open?: true}
  end

  defp signed(amount, :out), do: Decimal.negate(Decimal.abs(amount))
  defp signed(amount, _sign), do: Decimal.abs(amount)

  defp continue(%{entries: [entry | rest]} = state, text),
    do: %{state | entries: [%{entry | description: join(entry.description, text)} | rest]}

  defp continue(state, _text), do: state

  defp join("", text), do: text

  defp join(description, text) do
    if wrapped?(description), do: description <> text, else: description <> " " <> text
  end

  defp wrapped?(description),
    do: String.ends_with?(description, "-") and not String.ends_with?(description, " -")

  defp to_raw(%{date: date, label: label, description: description, signed: signed}) do
    %Raw{
      date: date,
      posted_on: date,
      amount: Decimal.abs(signed),
      kind: if(Decimal.negative?(signed), do: :expense, else: :income),
      raw_description: raw_description(label, description),
      payload: %{"signed_amount" => Decimal.to_string(signed, :normal)}
    }
  end

  defp raw_description(label, ""), do: label
  defp raw_description(label, description), do: label <> " - " <> description

  defp opening(text, period_start, entries) do
    date = period_start || min_date(entries)

    case capture(@opening, text) do
      nil -> []
      amount -> [%{date: Date.add(date, -1), amount: amount}]
    end
  end

  defp closing_balance(text, balances) do
    capture(@closing, text) || balances |> List.last() |> then(&(&1 && &1.amount))
  end

  defp balance_warnings(balances, entries) do
    balances
    |> Enum.sort_by(& &1.date, Date)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [previous, current] ->
      movement =
        entries
        |> Enum.filter(&between?(&1.date, previous.date, current.date))
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
      [_, _agency, account] -> account
      nil -> nil
    end
  end

  defp period(text) do
    with [_, start_day, start_month, start_year, end_day, end_month, end_year] <-
           Regex.run(@period, text),
         {:ok, period_start} <- full_date(start_day, start_month, start_year),
         {:ok, period_end} <- full_date(end_day, end_month, end_year) do
      {period_start, period_end}
    else
      _ -> {nil, nil}
    end
  end

  defp full_date(day, month, year) do
    with {:ok, index} <- month |> String.slice(0, 3) |> month_index() do
      Date.new(String.to_integer(year), index, String.to_integer(day))
    end
  end

  defp capture(regex, text) do
    with [_, value] <- Regex.run(regex, text),
         {:ok, amount} <- Money.parse(value) do
      amount
    else
      _ -> nil
    end
  end

  defp min_date(entries), do: entries |> Enum.map(& &1.date) |> Enum.min(Date)
  defp max_date(entries), do: entries |> Enum.map(& &1.date) |> Enum.max(Date)
end
