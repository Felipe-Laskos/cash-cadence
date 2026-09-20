defmodule CashCadence.Reconciliation do
  @moduledoc false

  import Ecto.Query, warn: false

  alias CashCadence.{Budgets, Duplicates, Imports, Ledger, Money}
  alias CashCadence.Imports.Batch
  alias CashCadence.Ledger.{BankAccount, Transaction}
  alias CashCadence.Repo

  def statement_checks do
    Repo.all(from a in BankAccount, where: a.kind == :checking and a.own, order_by: a.name)
    |> Enum.map(&%{account: &1, steps: steps(&1)})
    |> Enum.reject(&(&1.steps == []))
  end

  def open_checks, do: statement_checks() |> Enum.flat_map(& &1.steps) |> Enum.reject(& &1.ok?)

  def month_checklist(%Date{} = competence) do
    competence = Date.beginning_of_month(competence)
    panel = Budgets.month_panel(competence)

    %{
      inbox: Imports.count_pending(),
      uncategorized: Ledger.count_uncategorized(competence),
      open_bills: panel.count - panel.paid_count,
      duplicates: Duplicates.count(),
      open_checks: length(open_checks())
    }
  end

  defp steps(%BankAccount{} = account) do
    account
    |> statements()
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [previous, current] -> step(account, previous, current) end)
  end

  defp statements(%BankAccount{id: id}) do
    Repo.all(
      from b in Batch,
        where:
          b.bank_account_id == ^id and not is_nil(b.statement_balance) and
            not is_nil(b.period_end),
        order_by: [asc: b.period_end, asc: b.id]
    )
  end

  defp step(account, previous, current) do
    expected = Decimal.sub(current.statement_balance, previous.statement_balance)
    movement = movement(account.id, previous.period_end, current.period_end)
    difference = Decimal.sub(expected, movement.total)

    %{
      account: account,
      from: previous,
      to: current,
      expected: expected,
      moved: movement.total,
      difference: difference,
      unknown_transfers: movement.unknown,
      last_entry: movement.last_entry,
      silent_days: silent_days(movement.last_entry, current.period_end),
      ok?: Decimal.equal?(difference, Money.zero()) and movement.unknown == 0
    }
  end

  defp silent_days(%Date{} = last_entry, %Date{} = period_end) do
    case Date.diff(period_end, last_entry) do
      days when days > 0 -> days
      _days -> 0
    end
  end

  defp silent_days(_last_entry, _period_end), do: 0

  defp movement(account_id, from_date, to_date) do
    totals =
      Repo.one(
        from t in Transaction,
          where:
            t.bank_account_id == ^account_id and is_nil(t.deleted_at) and
              t.date > ^from_date and t.date <= ^to_date,
          select: %{
            income: coalesce(sum(t.amount) |> filter(t.kind == :income), 0),
            expense: coalesce(sum(t.amount) |> filter(t.kind == :expense), 0),
            transfer_in:
              coalesce(sum(t.amount) |> filter(t.kind == :transfer and t.direction == :in), 0),
            transfer_out:
              coalesce(sum(t.amount) |> filter(t.kind == :transfer and t.direction == :out), 0),
            unknown: count(t.id) |> filter(t.kind == :transfer and is_nil(t.direction)),
            last_entry: max(t.date)
          }
      )

    total =
      totals.income
      |> Decimal.sub(totals.expense)
      |> Decimal.add(totals.transfer_in)
      |> Decimal.sub(totals.transfer_out)

    Map.put(totals, :total, total)
  end

  def entries(%{account: account, from: previous, to: current}) do
    Repo.all(
      from t in Transaction,
        where:
          t.bank_account_id == ^account.id and is_nil(t.deleted_at) and
            t.date > ^previous.period_end and t.date <= ^current.period_end,
        order_by: [asc: t.date, asc: t.id],
        preload: :category
    )
  end
end
