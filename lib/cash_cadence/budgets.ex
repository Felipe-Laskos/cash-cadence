defmodule CashCadence.Budgets do
  @moduledoc false

  import Ecto.Query, warn: false

  alias CashCadence.Budgets.RecurringBill
  alias CashCadence.Ledger.Transaction
  alias CashCadence.Money
  alias CashCadence.Repo

  def list_recurring_bills(opts \\ []) do
    RecurringBill
    |> maybe_active(Keyword.get(opts, :active, true))
    |> maybe_kind(opts[:kind])
    |> order_by([b], asc: fragment("lower(?)", b.name))
    |> preload(:category)
    |> Repo.all()
  end

  defp maybe_active(query, true), do: where(query, [b], b.active)
  defp maybe_active(query, _), do: query

  defp maybe_kind(query, nil), do: query
  defp maybe_kind(query, kind), do: where(query, [b], b.kind == ^kind)

  def get_recurring_bill!(id), do: RecurringBill |> preload(:category) |> Repo.get!(id)

  def get_recurring_bill_by_name(name), do: Repo.get_by(RecurringBill, name: name)

  def create_recurring_bill(attrs) do
    %RecurringBill{} |> RecurringBill.changeset(attrs) |> Repo.insert()
  end

  def update_recurring_bill(%RecurringBill{} = bill, attrs) do
    bill |> RecurringBill.changeset(attrs) |> Repo.update()
  end

  def delete_recurring_bill(%RecurringBill{} = bill), do: Repo.delete(bill)

  def change_recurring_bill(%RecurringBill{} = bill, attrs \\ %{}),
    do: RecurringBill.changeset(bill, attrs)

  def month_panel(%Date{} = competence) do
    paid = paid_by_category(competence, :expense)

    items =
      Enum.map(list_recurring_bills(kind: :expense), fn bill ->
        build_item(bill, Map.get(paid, bill.category_id, Money.zero()))
      end)

    %{
      items: items,
      expected_total: items |> Enum.map(& &1.expected) |> Money.sum(),
      paid_total: items |> Enum.map(& &1.paid) |> Money.sum(),
      open_total: items |> Enum.map(& &1.remaining) |> Money.sum(),
      paid_count: Enum.count(items, &(&1.status == :paid)),
      count: length(items)
    }
  end

  def expected_incomes(%Date{} = competence) do
    received = paid_by_category(competence, :income)

    Enum.map(list_recurring_bills(kind: :income), fn bill ->
      amount = Map.get(received, bill.category_id, Money.zero())

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
      list_recurring_bills(kind: :expense)
      |> Enum.map(fn bill ->
        statuses =
          Enum.map(range, fn month ->
            item = panels[month].items |> Enum.find(&(&1.bill.id == bill.id))
            %{competence: month, status: item.status, paid: item.paid}
          end)

        %{bill: bill, statuses: statuses}
      end)

    %{months: range, rows: rows}
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

  defp build_item(bill, paid) do
    expected = bill.expected_amount

    status =
      cond do
        not Money.positive?(paid) -> :unpaid
        Decimal.compare(paid, expected) == :lt -> :partial
        true -> :paid
      end

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
      progress: progress(paid, expected)
    }
  end

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
