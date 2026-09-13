defmodule CashCadence.Imports.Parsers.PDF.ItauCard do
  @moduledoc false

  alias CashCadence.Imports.{BrFormat, Raw}
  alias CashCadence.Money

  @purchases_anchor "Lançamentos: compras e saques"
  @payments_anchor "Pagamentos efetuados"
  @purchases_total ~r/Total dos lançamentos atuais\s+(-?[\d.]*\d,\d{2})/u
  @payments_total ~r/Total dos pagamentos\s+(-?[\d.]*\d,\d{2})/u
  @line ~r/^\s*(\d{2}\/\d{2})\s+(.+?)\s{2,}(-?[\d.]*\d,\d{2})(?:\s{2,}.*)?$/
  @installment ~r/^(.*?)\s+(\d{2})\/(\d{2})$/
  @hint ~r/^\s*(\p{Ll}\S*(?:\s\p{Ll}\S*)*)(?:\s+(\S.*?))?\s*$/u
  @issued ~r/Emissão:\s*(\d{2}\/\d{2}\/\d{4})/u
  @due ~r/Vencimento:\s*(\d{2}\/\d{2}\/\d{4})/u
  @total ~r/O total da sua fatura é:[^\n]*\n\s*R\$\s*(-?[\d.]*\d,\d{2})/u
  @card ~r/Cartão\s+([\dX]{4}(?:\.[\dX]{4}){3})/u

  def recognizes?(text) when is_binary(text) do
    String.contains?(text, @purchases_anchor) and Regex.match?(@purchases_total, text)
  end

  def parse_text(text) when is_binary(text) do
    with {:ok, issued} <- issued_on(text) do
      %{purchases: purchases, payments: payments} =
        text |> String.split(~r/\r?\n/) |> sections(issued)

      transactions =
        Enum.map(payments, &payment_raw/1) ++ Enum.map(purchases, &purchase_raw(&1, issued))

      if transactions == [] do
        {:error, :no_transactions}
      else
        {:ok,
         %{
           bank: :itau,
           account: %{bank_id: "341", account_ref: card_ref(text), kind: :credit_card},
           currency: "BRL",
           period_start: transactions |> Enum.map(& &1.date) |> Enum.min(Date),
           period_end: issued,
           due_on: printed_date(text, @due),
           balance: printed_amount(text, @total) || printed_amount(text, @purchases_total),
           transactions: transactions,
           warnings:
             total_warning("das compras lidas", purchases, printed_amount(text, @purchases_total)) ++
               total_warning(
                 "dos pagamentos lidos",
                 payments,
                 printed_amount(text, @payments_total)
               )
         }}
      end
    end
  end

  defp issued_on(text) do
    case printed_date(text, @issued) do
      nil -> {:error, :missing_issue_date}
      date -> {:ok, date}
    end
  end

  defp sections(lines, issued) do
    {_state, acc} =
      Enum.reduce(lines, {:outside, %{purchases: [], payments: []}}, &step(&1, &2, issued))

    %{purchases: Enum.reverse(acc.purchases), payments: Enum.reverse(acc.payments)}
  end

  defp step(line, {state, acc}, issued) do
    cond do
      String.contains?(line, @payments_anchor) -> {:payments, acc}
      String.contains?(line, @purchases_anchor) -> {:purchases, acc}
      total_line?(line) -> {:outside, acc}
      state == :outside -> {state, acc}
      true -> {state, collect(state, line, acc, issued)}
    end
  end

  defp total_line?(line),
    do: Regex.match?(@payments_total, line) or Regex.match?(@purchases_total, line)

  defp collect(state, line, acc, issued) do
    case Regex.run(@line, line) do
      [_, day_month, label, amount] ->
        add_entry(
          state,
          acc,
          BrFormat.day_month(day_month, issued),
          String.trim(label),
          Money.parse(amount)
        )

      nil ->
        attach_hint(state, acc, line)
    end
  end

  defp add_entry(state, acc, {:ok, date}, label, {:ok, amount}) do
    Map.update!(acc, state, &[%{date: date, label: label, signed: amount, hint: nil} | &1])
  end

  defp add_entry(_state, acc, _date, _label, _amount), do: acc

  defp attach_hint(:purchases, %{purchases: [last | rest]} = acc, line) do
    case Regex.run(@hint, line) do
      [_, category] ->
        %{acc | purchases: [%{last | hint: %{category: category, city: nil}} | rest]}

      [_, category, city] ->
        %{acc | purchases: [%{last | hint: %{category: category, city: city}} | rest]}

      nil ->
        acc
    end
  end

  defp attach_hint(_state, acc, _line), do: acc

  defp purchase_raw(%{date: date, label: label, signed: signed, hint: hint}, issued) do
    {name, installment} = split_installment(label)

    %Raw{
      date: date,
      posted_on: date,
      competence: competence(date, installment, issued),
      amount: Decimal.abs(signed),
      kind: if(Decimal.negative?(signed), do: :income, else: :expense),
      raw_description: label,
      description: describe(name, installment),
      payload:
        %{"section" => "purchases", "issued_on" => Date.to_iso8601(issued)}
        |> put_hint(hint)
        |> put_installment(installment)
    }
  end

  defp payment_raw(%{date: date, label: label, signed: signed}) do
    %Raw{
      date: date,
      posted_on: date,
      amount: Decimal.abs(signed),
      kind: :transfer,
      raw_description: label,
      description: "Pagamento da fatura",
      payload: %{"section" => "payments"}
    }
  end

  defp split_installment(label) do
    case Regex.run(@installment, label) do
      [_, name, number, of] ->
        {String.trim(name), %{number: String.to_integer(number), of: String.to_integer(of)}}

      nil ->
        {label, nil}
    end
  end

  defp competence(date, nil, _issued), do: Date.beginning_of_month(date)
  defp competence(_date, _installment, issued), do: Date.beginning_of_month(issued)

  defp describe(name, nil), do: name
  defp describe(name, %{number: number, of: of}), do: "#{name} (#{number}/#{of})"

  defp put_hint(payload, nil), do: payload

  defp put_hint(payload, %{category: category, city: city}) do
    payload |> Map.put("itau_category", category) |> Map.put("city", city)
  end

  defp put_installment(payload, nil), do: payload

  defp put_installment(payload, %{number: number, of: of}),
    do: Map.put(payload, "installment", %{"number" => number, "of" => of})

  defp total_warning(_label, _entries, nil), do: []

  defp total_warning(label, entries, printed) do
    sum = entries |> Enum.map(& &1.signed) |> Money.sum()

    if Decimal.equal?(sum, printed) do
      []
    else
      [
        "Soma #{label} (#{BrFormat.money(sum)}) difere do total impresso na fatura " <>
          "(#{BrFormat.money(printed)}): confira o texto extraído."
      ]
    end
  end

  defp printed_date(text, regex) do
    with [_, value] <- Regex.run(regex, text), {:ok, date} <- BrFormat.date(value) do
      date
    else
      _ -> nil
    end
  end

  defp printed_amount(text, regex) do
    with [_, value] <- Regex.run(regex, text), {:ok, amount} <- Money.parse(value) do
      amount
    else
      _ -> nil
    end
  end

  defp card_ref(text) do
    case Regex.run(@card, text) do
      [_, masked] -> masked
      nil -> nil
    end
  end
end
