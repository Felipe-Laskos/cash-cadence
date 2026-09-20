defmodule CashCadence.Budgets do
  @moduledoc false

  import Ecto.Query, warn: false

  alias CashCadence.Budgets.BillAmount
  alias CashCadence.Budgets.RecurringBill
  alias CashCadence.Ledger.Transaction
  alias CashCadence.Money
  alias CashCadence.Repo

  @tolerance Decimal.new("0.10")

  def list_recurring_bills(opts \\ []) do
    competence = opts[:competence] && Date.beginning_of_month(opts[:competence])

    RecurringBill
    |> maybe_active(Keyword.get(opts, :active, true))
    |> maybe_kind(opts[:kind])
    |> maybe_competence(competence)
    |> order_by([b], asc: fragment("lower(?)", b.name))
    |> preload(:category)
    |> Repo.all()
    |> put_effective_amounts(competence)
  end

  defp maybe_active(query, true), do: where(query, [b], b.active)
  defp maybe_active(query, _), do: query

  defp maybe_kind(query, nil), do: query
  defp maybe_kind(query, kind), do: where(query, [b], b.kind == ^kind)

  defp maybe_competence(query, nil), do: query

  defp maybe_competence(query, %Date{} = month) do
    where(
      query,
      [b],
      (is_nil(b.starts_on) or b.starts_on <= ^month) and
        (is_nil(b.ends_on) or b.ends_on >= ^month)
    )
  end

  def get_recurring_bill!(id), do: RecurringBill |> preload(:category) |> Repo.get!(id)

  def get_recurring_bill_by_name(name), do: Repo.get_by(RecurringBill, name: name)

  def create_recurring_bill(attrs) do
    %RecurringBill{} |> RecurringBill.changeset(attrs) |> Repo.insert()
  end

  def update_recurring_bill(%RecurringBill{} = bill, attrs, opts \\ []) do
    month = opts |> Keyword.get(:on, Date.utc_today()) |> Date.beginning_of_month()

    Repo.transact(fn ->
      with {:ok, updated} <- bill |> RecurringBill.changeset(attrs) |> Repo.update() do
        correct_amount(updated, bill.expected_amount, month)
      end
    end)
  end

  def expected_amount_at(%RecurringBill{} = bill, %Date{} = competence) do
    case list_bill_amounts(bill) do
      [] -> bill.expected_amount
      rows -> rows |> effective_bill_amount(competence) |> Map.fetch!(:expected_amount)
    end
  end

  def list_bill_amounts(%RecurringBill{id: id}) do
    BillAmount
    |> where([a], a.recurring_bill_id == ^id)
    |> order_by([a], asc: a.starts_on)
    |> Repo.all()
  end

  def effective_bill_amount([], _competence), do: nil

  def effective_bill_amount([first | _] = rows, %Date{} = competence) do
    month = Date.beginning_of_month(competence)

    rows
    |> Enum.take_while(&(Date.compare(&1.starts_on, month) != :gt))
    |> List.last()
    |> Kernel.||(first)
  end

  def change_amount_from(%RecurringBill{} = bill, %Date{} = month, amount) do
    month = Date.beginning_of_month(month)

    Repo.transact(fn ->
      with :ok <- keep_previous_amount(bill, month),
           {:ok, _row} <- upsert_bill_amount(bill, month, amount) do
        sync_current_amount(bill)
      end
    end)
  end

  def put_bill_amount(%RecurringBill{} = bill, %Date{} = month, amount) do
    Repo.transact(fn ->
      with {:ok, _row} <- upsert_bill_amount(bill, Date.beginning_of_month(month), amount) do
        sync_current_amount(bill)
      end
    end)
  end

  def delete_bill_amount(%RecurringBill{} = bill, id) when is_integer(id) do
    row = Repo.get_by(BillAmount, id: id, recurring_bill_id: bill.id)

    Repo.transact(fn -> drop_bill_amount(bill, row) end)
  end

  defp drop_bill_amount(_bill, nil), do: {:error, :not_found}

  defp drop_bill_amount(bill, row) do
    with {:ok, _deleted} <- Repo.delete(row), do: sync_current_amount(bill)
  end

  defp put_effective_amounts(bills, nil), do: bills
  defp put_effective_amounts([], _competence), do: []

  defp put_effective_amounts(bills, competence) do
    rows =
      BillAmount
      |> where([a], a.recurring_bill_id in ^Enum.map(bills, & &1.id))
      |> order_by([a], asc: a.starts_on)
      |> Repo.all()
      |> Enum.group_by(& &1.recurring_bill_id)

    Enum.map(bills, fn bill ->
      case rows |> Map.get(bill.id, []) |> effective_bill_amount(competence) do
        nil -> bill
        row -> %{bill | expected_amount: row.expected_amount}
      end
    end)
  end

  defp correct_amount(bill, previous, month) do
    if Decimal.equal?(bill.expected_amount, previous),
      do: {:ok, bill},
      else: rewrite_amount(bill, list_bill_amounts(bill), month)
  end

  defp rewrite_amount(bill, [], _month), do: {:ok, bill}

  defp rewrite_amount(bill, rows, month) do
    with {:ok, _row} <-
           rows
           |> effective_bill_amount(month)
           |> BillAmount.changeset(%{expected_amount: bill.expected_amount})
           |> Repo.update() do
      sync_current_amount(bill)
    end
  end

  defp keep_previous_amount(bill, month) do
    case list_bill_amounts(bill) do
      [] ->
        with {:ok, _row} <-
               upsert_bill_amount(bill, previous_month(bill, month), bill.expected_amount),
             do: :ok

      _rows ->
        :ok
    end
  end

  defp previous_month(%RecurringBill{starts_on: %Date{} = starts_on}, month) do
    if Date.compare(starts_on, month) == :lt, do: starts_on, else: Date.shift(month, month: -1)
  end

  defp previous_month(_bill, month), do: Date.shift(month, month: -1)

  defp upsert_bill_amount(bill, month, amount) do
    attrs = %{recurring_bill_id: bill.id, starts_on: month, expected_amount: amount}

    case Repo.get_by(BillAmount, recurring_bill_id: bill.id, starts_on: month) do
      nil -> %BillAmount{} |> BillAmount.changeset(attrs) |> Repo.insert()
      row -> row |> BillAmount.changeset(attrs) |> Repo.update()
    end
  end

  defp sync_current_amount(bill) do
    current = expected_amount_at(bill, Date.utc_today())

    if Decimal.equal?(current, bill.expected_amount),
      do: {:ok, bill},
      else: bill |> Ecto.Changeset.change(expected_amount: current) |> Repo.update()
  end

  def delete_recurring_bill(%RecurringBill{} = bill), do: Repo.delete(bill)

  def change_recurring_bill(%RecurringBill{} = bill, attrs \\ %{}),
    do: RecurringBill.changeset(bill, attrs)

  def month_panel(%Date{} = competence) do
    competence = Date.beginning_of_month(competence)
    bills = list_recurring_bills(kind: :expense, competence: competence)
    paid = paid_amounts(bills, competence, :expense)

    items =
      Enum.map(bills, fn bill ->
        build_item(bill, Map.fetch!(paid, bill.id), competence)
      end)

    %{
      items: items,
      expected_total: items |> Enum.map(& &1.expected) |> Money.sum(),
      paid_total: items |> Enum.map(& &1.paid) |> Money.sum(),
      open_total: items |> Enum.map(& &1.remaining) |> Money.sum(),
      paid_count: Enum.count(items, &(&1.status == :paid)),
      overdue_count: Enum.count(items, & &1.overdue?),
      count: length(items)
    }
  end

  def expected_incomes(%Date{} = competence) do
    competence = Date.beginning_of_month(competence)
    bills = list_recurring_bills(kind: :income, competence: competence)
    received = paid_amounts(bills, competence, :income)

    Enum.map(bills, fn bill ->
      amount = Map.fetch!(received, bill.id)

      %{
        bill: bill,
        expected: bill.expected_amount,
        received: amount,
        status: if(Money.positive?(amount), do: :received, else: :pending),
        received_on: received_on(bill.category_id, competence)
      }
    end)
  end

  def adherence(%Date{} = competence, months \\ 3) do
    range =
      Enum.map((months - 1)..0//-1, &Date.shift(Date.beginning_of_month(competence), month: -&1))

    panels = Map.new(range, fn month -> {month, month_panel(month)} end)

    rows =
      Enum.map(list_recurring_bills(kind: :expense), fn bill ->
        %{bill: bill, statuses: Enum.map(range, &month_status(panels[&1].items, bill, &1))}
      end)

    %{months: range, rows: rows}
  end

  defp month_status(items, bill, month) do
    case Enum.find(items, &(&1.bill.id == bill.id)) do
      nil -> %{competence: month, status: :none, paid: Money.zero()}
      item -> %{competence: month, status: item.status, paid: item.paid}
    end
  end

  def coverage(%Date{} = competence, %Decimal{} = income) do
    %{expected_total: expected_total} = panel = month_panel(competence)

    %{
      expected_total: expected_total,
      income: income,
      covered?: Decimal.compare(income, expected_total) != :lt,
      ratio: Money.ratio(income, expected_total),
      share: Money.ratio(expected_total, income),
      panel: panel
    }
  end

  def find_bill_match(kind, %Decimal{} = amount, %Date{} = competence, normalized)
      when kind in [:expense, :income] do
    competence = Date.beginning_of_month(competence)
    bills = list_recurring_bills(kind: kind, competence: competence)
    paid = paid_amounts(bills, competence, kind)

    bills
    |> Enum.reject(&fully_paid?(&1, Map.fetch!(paid, &1.id)))
    |> Enum.flat_map(fn bill ->
      case bill_score(bill, amount, normalized || "") do
        nil -> []
        score -> [{bill, score}]
      end
    end)
    |> Enum.min_by(fn {_bill, score} -> score end, fn -> nil end)
    |> case do
      nil -> nil
      {bill, {0, _distance}} -> %{bill: bill, strong?: true}
      {bill, _score} -> %{bill: bill, strong?: false}
    end
  end

  def find_bill_match(_kind, _amount, _competence, _normalized), do: nil

  defp bill_score(bill, amount, normalized) do
    text? = is_binary(bill.match_text) and String.contains?(normalized, bill.match_text)
    distance = amount |> Decimal.sub(bill.expected_amount) |> Decimal.abs()
    within? = Decimal.compare(distance, tolerance(bill.expected_amount)) != :gt

    cond do
      text? and within? -> {0, distance}
      is_nil(bill.match_text) and within? -> {1, distance}
      true -> nil
    end
  end

  defp tolerance(expected), do: Decimal.mult(expected, @tolerance)

  defp fully_paid?(bill, paid), do: Decimal.compare(paid, bill.expected_amount) != :lt

  def plan_installments(%{number: number, of: of} = plan)
      when is_integer(number) and is_integer(of) and number < of do
    starts_on = plan.competence |> Date.beginning_of_month() |> Date.shift(month: -(number - 1))

    attrs = %{
      name: String.slice(plan.name, 0, 60),
      expected_amount: plan.amount,
      kind: :expense,
      category_id: plan.category_id,
      starts_on: starts_on,
      ends_on: Date.shift(starts_on, month: of - 1),
      installments_total: of,
      match_text: plan.match_text,
      active: true
    }

    case get_recurring_bill_by_name(attrs.name) do
      nil ->
        create_recurring_bill(attrs)

      %RecurringBill{installments_total: total} = bill when is_integer(total) ->
        update_recurring_bill(bill, attrs)

      _other ->
        create_recurring_bill(%{attrs | name: String.slice(attrs.name, 0, 49) <> " (parcelas)"})
    end
  end

  def plan_installments(_plan), do: {:ok, nil}

  defp build_item(bill, paid, competence) do
    expected = bill.expected_amount

    status =
      cond do
        not Money.positive?(paid) -> :unpaid
        Decimal.compare(paid, expected) == :lt -> :partial
        true -> :paid
      end

    due_on = due_on(bill, competence)

    %{
      bill: bill,
      expected: expected,
      paid: paid,
      status: status,
      remaining: if(status == :paid, do: Money.zero(), else: Decimal.sub(expected, paid)),
      over:
        if(Decimal.compare(paid, expected) == :gt,
          do: Decimal.sub(paid, expected),
          else: Money.zero()
        ),
      progress: progress(paid, expected),
      due_on: due_on,
      due_in: due_in(due_on, status),
      overdue?: status != :paid and overdue?(due_on),
      installment: installment(bill, competence)
    }
  end

  defp due_in(nil, _status), do: nil
  defp due_in(_due_on, :paid), do: nil
  defp due_in(%Date{} = due_on, _status), do: Date.diff(due_on, Date.utc_today())

  def upcoming(days \\ 7) do
    items = month_panel(Date.utc_today()).items

    %{
      soon: Enum.filter(items, &(is_integer(&1.due_in) and &1.due_in >= 0 and &1.due_in <= days)),
      overdue: Enum.filter(items, & &1.overdue?)
    }
  end

  defp due_on(%RecurringBill{due_day: nil}, _competence), do: nil

  defp due_on(%RecurringBill{due_day: day}, competence) do
    Date.new!(competence.year, competence.month, min(day, Date.days_in_month(competence)))
  end

  defp overdue?(nil), do: false
  defp overdue?(%Date{} = due_on), do: Date.compare(due_on, Date.utc_today()) == :lt

  defp installment(
         %RecurringBill{installments_total: total, starts_on: %Date{} = starts_on},
         competence
       )
       when is_integer(total) do
    number = (competence.year - starts_on.year) * 12 + competence.month - starts_on.month + 1
    %{number: number |> max(1) |> min(total), of: total}
  end

  defp installment(_bill, _competence), do: nil

  defp progress(paid, expected) do
    case Money.ratio(paid, expected) do
      nil ->
        0

      ratio ->
        ratio
        |> Decimal.mult(100)
        |> Decimal.min(Decimal.new(100))
        |> Decimal.round(0)
        |> Decimal.to_integer()
    end
  end

  defp paid_amounts(bills, competence, kind) do
    by_category = paid_by_category(competence, kind)
    shared = shared_categories(bills)

    Map.new(bills, fn bill ->
      {bill.id, paid_amount(bill, competence, by_category, shared)}
    end)
  end

  defp shared_categories(bills) do
    bills
    |> Enum.frequencies_by(& &1.category_id)
    |> Enum.filter(fn {_category_id, bills} -> bills > 1 end)
    |> MapSet.new(fn {category_id, _bills} -> category_id end)
  end

  defp paid_amount(%RecurringBill{match_text: text} = bill, competence, by_category, shared)
       when is_binary(text) do
    if MapSet.member?(shared, bill.category_id),
      do: paid_by_match_text(bill, competence, text),
      else: Map.get(by_category, bill.category_id, Money.zero())
  end

  defp paid_amount(bill, _competence, by_category, _shared),
    do: Map.get(by_category, bill.category_id, Money.zero())

  defp paid_by_match_text(bill, competence, text) do
    lower = Decimal.sub(bill.expected_amount, tolerance(bill.expected_amount))
    upper = Decimal.add(bill.expected_amount, tolerance(bill.expected_amount))

    Money.sum([
      Repo.one(
        from t in Transaction,
          where:
            is_nil(t.deleted_at) and t.kind == ^bill.kind and t.competence == ^competence and
              t.category_id == ^bill.category_id and
              t.amount >= ^lower and t.amount <= ^upper and
              ilike(t.normalized_description, ^"%#{text}%"),
          select: sum(t.amount)
      )
    ])
  end

  defp paid_by_category(competence, kind) do
    Repo.all(
      from t in Transaction,
        where:
          is_nil(t.deleted_at) and t.kind == ^kind and not is_nil(t.category_id) and
            t.competence == ^Date.beginning_of_month(competence),
        group_by: t.category_id,
        select: {t.category_id, sum(t.amount)}
    )
    |> Map.new()
  end

  defp received_on(category_id, competence) do
    Repo.one(
      from t in Transaction,
        where:
          is_nil(t.deleted_at) and t.kind == :income and t.category_id == ^category_id and
            t.competence == ^Date.beginning_of_month(competence),
        select: max(t.date)
    )
  end
end
