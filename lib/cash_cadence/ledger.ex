defmodule CashCadence.Ledger do
  @moduledoc false

  import Ecto.Query, warn: false

  alias CashCadence.Ledger.{BankAccount, Category, Transaction}
  alias CashCadence.Money
  alias CashCadence.Repo

  def list_categories(opts \\ []) do
    Category
    |> maybe_archived(opts[:archived])
    |> maybe_kind(opts[:kind])
    |> order_by([c], asc: fragment("lower(?)", c.name))
    |> Repo.all()
  end

  defp maybe_archived(query, :only), do: where(query, [c], not is_nil(c.archived_at))
  defp maybe_archived(query, :all), do: query
  defp maybe_archived(query, _), do: where(query, [c], is_nil(c.archived_at))

  defp maybe_kind(query, nil), do: query
  defp maybe_kind(query, kind), do: where(query, [c], c.kind == ^kind)

  def archive_category(%Category{} = category) do
    update_category(category, %{archived_at: DateTime.utc_now(:second)})
  end

  def unarchive_category(%Category{} = category),
    do: update_category(category, %{archived_at: nil})

  def merge_categories(%Category{id: source_id} = source, %Category{id: target_id})
      when source_id != target_id do
    Repo.transaction(fn ->
      from(t in Transaction, where: t.category_id == ^source_id)
      |> Repo.update_all(set: [category_id: target_id])

      from(b in CashCadence.Budgets.RecurringBill, where: b.category_id == ^source_id)
      |> Repo.update_all(set: [category_id: target_id])

      CashCadence.Classifier.remap_memory(source_id, target_id)

      case archive_category(source) do
        {:ok, _} -> get_category!(target_id)
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  def category_stats(opts \\ []) do
    bills =
      Repo.all(
        from b in CashCadence.Budgets.RecurringBill, where: b.active, select: b.category_id
      )
      |> MapSet.new()

    Category
    |> maybe_archived(opts[:archived])
    |> maybe_kind(opts[:kind])
    |> join(:left, [c], t in Transaction, on: t.category_id == c.id and is_nil(t.deleted_at))
    |> group_by([c], c.id)
    |> select([c, t], %{
      category: c,
      count: count(t.id),
      expense_total: coalesce(sum(t.amount) |> filter(t.kind == :expense), 0),
      income_total: coalesce(sum(t.amount) |> filter(t.kind == :income), 0),
      first_competence: min(t.competence),
      last_competence: max(t.competence),
      last_date: max(t.date)
    })
    |> Repo.all()
    |> Enum.map(fn row ->
      total = Decimal.add(row.expense_total, row.income_total)
      months = months_span(row.first_competence, row.last_competence)

      row
      |> Map.put(:total, total)
      |> Map.put(
        :monthly_average,
        if(months > 0, do: Decimal.div(total, months) |> Decimal.round(2), else: Money.zero())
      )
      |> Map.put(:has_bill?, MapSet.member?(bills, row.category.id))
    end)
    |> Enum.sort_by(&Decimal.to_float(&1.total), :desc)
  end

  defp months_span(nil, _), do: 0

  defp months_span(%Date{} = first, %Date{} = last),
    do: (last.year - first.year) * 12 + (last.month - first.month) + 1

  def get_category!(id), do: Repo.get!(Category, id)

  def get_category_by_name(name) when is_binary(name) do
    lowered = name |> String.trim() |> String.downcase()

    Repo.one(from c in Category, where: fragment("lower(?)", c.name) == ^lowered, limit: 1)
  end

  def create_category(attrs), do: %Category{} |> Category.changeset(attrs) |> Repo.insert()

  def update_category(%Category{} = category, attrs) do
    category |> Category.changeset(attrs) |> Repo.update()
  end

  def change_category(%Category{} = category, attrs \\ %{}),
    do: Category.changeset(category, attrs)

  def find_or_create_category(name, kind) when is_binary(name) do
    case get_category_by_name(name) do
      %Category{} = category -> {:ok, category}
      nil -> create_category(%{name: name, kind: kind})
    end
  end

  def category_suggestions(limit \\ 100) do
    Repo.all(
      from c in Category,
        left_join: t in Transaction,
        on: t.category_id == c.id and is_nil(t.deleted_at),
        where: is_nil(c.archived_at),
        group_by: c.id,
        order_by: [desc: count(t.id), asc: fragment("lower(?)", c.name)],
        select: %{id: c.id, name: c.name, kind: c.kind, fixed: c.fixed, uses: count(t.id)},
        limit: ^limit
    )
  end

  def list_bank_accounts, do: Repo.all(from a in BankAccount, order_by: a.name)

  def get_bank_account_by_name(name), do: Repo.get_by(BankAccount, name: name)

  def get_bank_account!(id), do: Repo.get!(BankAccount, id)

  def change_bank_account(%BankAccount{} = account, attrs \\ %{}),
    do: BankAccount.changeset(account, attrs)

  def create_bank_account(attrs),
    do: %BankAccount{} |> BankAccount.changeset(attrs) |> Repo.insert()

  def update_bank_account(%BankAccount{} = account, attrs),
    do: account |> BankAccount.changeset(attrs) |> Repo.update()

  def delete_bank_account(%BankAccount{} = account), do: Repo.delete(account)

  def forget_bank_account_ref(%BankAccount{} = account),
    do: account |> Ecto.Changeset.change(external_ref: nil) |> Repo.update()

  def list_transactions(filters \\ %{}) do
    active_transactions()
    |> filter_competence(filters[:competence])
    |> filter_kind(filters[:kind])
    |> filter_category(filters[:category_id])
    |> filter_search(filters[:search])
    |> order_by([t], desc: t.date, desc: t.id)
    |> preload([:category, reimbursement_of: :category, reimbursements: ^active_transactions()])
    |> Repo.all()
  end

  def get_transaction!(id) do
    active_transactions()
    |> preload([:category, reimbursement_of: :category, reimbursements: ^active_transactions()])
    |> Repo.get!(id)
  end

  def link_reimbursement(%Transaction{kind: :income, id: income_id} = income, %Transaction{
        kind: :expense,
        id: expense_id
      })
      when income_id != expense_id do
    income |> Ecto.Changeset.change(reimbursement_of_id: expense_id) |> Repo.update()
  end

  def link_reimbursement(_income, _expense), do: {:error, :invalid_pair}

  def unlink_reimbursement(%Transaction{} = income) do
    income |> Ecto.Changeset.change(reimbursement_of_id: nil) |> Repo.update()
  end

  def reimbursement_candidates(%Transaction{} = income, days \\ 60) do
    from_date = Date.add(income.date, -days)

    active_transactions()
    |> where(
      [t],
      t.kind == :expense and t.date >= ^from_date and t.date <= ^income.date and
        t.id != ^income.id
    )
    |> order_by([t],
      asc: fragment("abs(? - ?)", t.amount, type(^income.amount, :decimal)),
      desc: t.date
    )
    |> limit(12)
    |> preload(:category)
    |> Repo.all()
  end

  def find_reimbursement_candidate(%Decimal{} = amount, %Date{} = date, days) do
    from_date = Date.add(date, -days)

    Repo.one(
      from t in Transaction,
        as: :expense,
        where:
          is_nil(t.deleted_at) and t.kind == :expense and t.amount == ^amount and
            t.date >= ^from_date and t.date <= ^date,
        where:
          not exists(
            from r in Transaction,
              where: r.reimbursement_of_id == parent_as(:expense).id and is_nil(r.deleted_at),
              select: 1
          ),
        order_by: [desc: t.date, desc: t.id],
        limit: 1,
        preload: :category
    )
  end

  def create_transaction(attrs) do
    with {:ok, attrs} <- resolve_category(attrs) do
      %Transaction{} |> Transaction.changeset(attrs) |> Repo.insert()
    end
  end

  def update_transaction(%Transaction{} = transaction, attrs) do
    with {:ok, attrs} <- resolve_category(attrs) do
      transaction |> Transaction.changeset(attrs) |> Repo.update()
    end
  end

  def delete_transaction(%Transaction{} = transaction) do
    transaction
    |> Ecto.Changeset.change(deleted_at: DateTime.utc_now(:second))
    |> Repo.update()
  end

  def change_transaction(%Transaction{} = transaction, attrs \\ %{}) do
    Transaction.changeset(transaction, attrs)
  end

  def month_totals(%Date{} = competence) do
    active_transactions()
    |> where([t], t.competence == ^Date.beginning_of_month(competence))
    |> totals()
  end

  def all_time_totals, do: totals(active_transactions())

  defp totals(query) do
    row =
      Repo.one(
        from t in query,
          select: %{
            income: sum(t.amount) |> filter(t.kind == :income and is_nil(t.reimbursement_of_id)),
            income_count:
              count(t.id) |> filter(t.kind == :income and is_nil(t.reimbursement_of_id)),
            expense: sum(t.amount) |> filter(t.kind == :expense),
            expense_count: count(t.id) |> filter(t.kind == :expense),
            reimbursed:
              sum(t.amount) |> filter(t.kind == :income and not is_nil(t.reimbursement_of_id))
          }
      )

    income = row.income || Money.zero()
    gross = row.expense || Money.zero()
    reimbursed = row.reimbursed || Money.zero()
    expense = Decimal.sub(gross, reimbursed)

    %{
      income: income,
      expense: expense,
      gross_expense: gross,
      reimbursed: reimbursed,
      net: Decimal.sub(income, expense),
      count: row.income_count + row.expense_count,
      income_count: row.income_count,
      expense_count: row.expense_count
    }
  end

  def count_transactions(%Date{} = competence) do
    active_transactions()
    |> where([t], t.competence == ^Date.beginning_of_month(competence))
    |> Repo.aggregate(:count)
  end

  def monthly_series(%Date{} = from, %Date{} = to) do
    from = Date.beginning_of_month(from)
    to = Date.beginning_of_month(to)

    sums =
      Repo.all(
        from t in active_transactions(),
          where: t.competence >= ^from and t.competence <= ^to and t.kind in [:income, :expense],
          group_by: t.competence,
          select:
            {t.competence,
             sum(t.amount) |> filter(t.kind == :income and is_nil(t.reimbursement_of_id)),
             sum(t.amount) |> filter(t.kind == :expense),
             sum(t.amount) |> filter(t.kind == :income and not is_nil(t.reimbursement_of_id))}
      )
      |> Map.new(fn {competence, income, expense, reimbursed} ->
        {competence,
         {income || Money.zero(), expense || Money.zero(), reimbursed || Money.zero()}}
      end)

    from
    |> months_until(to)
    |> Enum.map(fn month ->
      {income, gross, reimbursed} =
        Map.get(sums, month, {Money.zero(), Money.zero(), Money.zero()})

      expense = Decimal.sub(gross, reimbursed)
      %{competence: month, income: income, expense: expense, net: Decimal.sub(income, expense)}
    end)
  end

  def months_until(%Date{} = from, %Date{} = to) do
    Stream.unfold(from, fn month ->
      if Date.compare(month, to) == :gt, do: nil, else: {month, Date.shift(month, month: 1)}
    end)
    |> Enum.to_list()
  end

  def expenses_by_category(%Date{} = competence) do
    month = Date.beginning_of_month(competence)

    refunds =
      month
      |> reimbursements_by_original_category(month)
      |> Enum.group_by(fn {category_id, _competence, _sum} -> category_id end)
      |> Map.new(fn {category_id, cells} ->
        {category_id, cells |> Enum.map(&elem(&1, 2)) |> Money.sum()}
      end)

    Repo.all(
      from t in active_transactions(),
        left_join: c in assoc(t, :category),
        where: t.competence == ^month and t.kind == :expense,
        group_by: [c.id, c.name, c.color],
        select: %{
          category_id: c.id,
          name: c.name,
          color: c.color,
          total: sum(t.amount),
          count: count(t.id)
        }
    )
    |> Enum.map(
      &%{&1 | total: Decimal.sub(&1.total, Map.get(refunds, &1.category_id, Money.zero()))}
    )
    |> Enum.filter(&Money.positive?(&1.total))
    |> Enum.sort_by(&Decimal.to_float(&1.total), :desc)
  end

  defp reimbursements_by_original_category(%Date{} = from, %Date{} = to) do
    Repo.all(
      from t in active_transactions(),
        join: o in Transaction,
        on: o.id == t.reimbursement_of_id,
        where: t.kind == :income and t.competence >= ^from and t.competence <= ^to,
        group_by: [o.category_id, t.competence],
        select: {o.category_id, t.competence, sum(t.amount)}
    )
  end

  def recent_transactions(limit \\ 5) do
    active_transactions()
    |> order_by([t], desc: t.date, desc: t.id)
    |> limit(^limit)
    |> preload(:category)
    |> Repo.all()
  end

  def count_uncategorized do
    active_transactions()
    |> where(
      [t],
      is_nil(t.category_id) and t.kind != :transfer and is_nil(t.reimbursement_of_id)
    )
    |> Repo.aggregate(:count)
  end

  def count_uncategorized(%Date{} = competence) do
    active_transactions()
    |> where(
      [t],
      t.competence == ^Date.beginning_of_month(competence) and is_nil(t.category_id) and
        t.kind != :transfer and is_nil(t.reimbursement_of_id)
    )
    |> Repo.aggregate(:count)
  end

  def category_month_matrix(%Date{} = from, %Date{} = to, limit \\ 12) do
    from = Date.beginning_of_month(from)
    to = Date.beginning_of_month(to)
    months = months_until(from, to)

    rows =
      Repo.all(
        from t in active_transactions(),
          left_join: c in assoc(t, :category),
          where: t.competence >= ^from and t.competence <= ^to and t.kind == :expense,
          group_by: [c.id, c.name, t.competence],
          select: %{
            category_id: c.id,
            name: c.name,
            competence: t.competence,
            total: sum(t.amount)
          }
      )

    refunds =
      from
      |> reimbursements_by_original_category(to)
      |> Map.new(fn {category_id, competence, sum} -> {{category_id, competence}, sum} end)

    rows
    |> Enum.group_by(&{&1.category_id, &1.name})
    |> Enum.map(fn {{category_id, name}, cells} ->
      totals =
        Map.new(cells, fn cell ->
          refund = Map.get(refunds, {category_id, cell.competence}, Money.zero())
          {cell.competence, Decimal.sub(cell.total, refund)}
        end)

      total = totals |> Map.values() |> Money.sum()

      %{
        category_id: category_id,
        name: name || "Sem categoria",
        totals: totals,
        total: total,
        average: Decimal.div(total, length(months)) |> Decimal.round(2)
      }
    end)
    |> Enum.sort_by(&Decimal.to_float(&1.total), :desc)
    |> Enum.take(limit)
    |> then(&%{months: months, rows: &1})
  end

  def income_by_category(%Date{} = from, %Date{} = to) do
    rows =
      Repo.all(
        from t in active_transactions(),
          left_join: c in assoc(t, :category),
          where:
            t.competence >= ^Date.beginning_of_month(from) and
              t.competence <= ^Date.beginning_of_month(to) and t.kind == :income and
              is_nil(t.reimbursement_of_id),
          group_by: [c.id, c.name, c.kind],
          order_by: [desc: sum(t.amount)],
          select: %{
            category_id: c.id,
            name: c.name,
            kind: c.kind,
            total: sum(t.amount),
            count: count(t.id)
          }
      )

    total = rows |> Enum.map(& &1.total) |> Money.sum()
    Enum.map(rows, &Map.put(&1, :share, Money.ratio(&1.total, total)))
  end

  def export_rows(%Date{} = from, %Date{} = to) do
    active_transactions()
    |> where(
      [t],
      t.competence >= ^Date.beginning_of_month(from) and
        t.competence <= ^Date.beginning_of_month(to)
    )
    |> order_by([t], asc: t.date, asc: t.id)
    |> preload([:category, :bank_account])
    |> Repo.all()
  end

  def find_manual_match(kind, %Decimal{} = amount, %Date{} = date, window_days) do
    from_date = Date.add(date, -window_days)
    to_date = Date.add(date, window_days)

    Repo.one(
      from t in active_transactions(),
        where:
          t.kind == ^kind and t.amount == ^amount and t.source != :import and
            is_nil(t.fingerprint) and t.date >= ^from_date and t.date <= ^to_date,
        order_by: [asc: fragment("abs(? - ?)", t.date, type(^date, :date)), asc: t.id],
        limit: 1,
        preload: :category
    )
  end

  def find_transfer_counterpart(%Decimal{} = amount, %Date{} = date, account_id, window_days) do
    from_date = Date.add(date, -window_days)
    to_date = Date.add(date, window_days)

    active_transactions()
    |> where([t], t.amount == ^amount and t.date >= ^from_date and t.date <= ^to_date)
    |> counterpart_scope(account_id)
    |> order_by([t], asc: fragment("abs(? - ?)", t.date, type(^date, :date)), asc: t.id)
    |> limit(1)
    |> preload(:category)
    |> Repo.one()
  end

  defp counterpart_scope(query, nil), do: where(query, [t], t.kind == :transfer)

  defp counterpart_scope(query, account_id) do
    where(
      query,
      [t],
      t.kind == :transfer or (not is_nil(t.bank_account_id) and t.bank_account_id != ^account_id)
    )
  end

  def attach_import(%Transaction{} = transaction, attrs) do
    transaction |> Transaction.changeset(attrs) |> Repo.update()
  end

  def months_with_data do
    Repo.all(
      from t in active_transactions(),
        distinct: true,
        order_by: [desc: t.competence],
        select: t.competence
    )
  end

  defp active_transactions, do: from(t in Transaction, where: is_nil(t.deleted_at))

  defp filter_competence(query, nil), do: query

  defp filter_competence(query, %Date{} = competence) do
    where(query, [t], t.competence == ^Date.beginning_of_month(competence))
  end

  defp filter_kind(query, kind) when kind in [:income, :expense, :transfer],
    do: where(query, [t], t.kind == ^kind)

  defp filter_kind(query, _), do: query

  defp filter_category(query, nil), do: query

  defp filter_category(query, :none),
    do: where(query, [t], is_nil(t.category_id) and t.kind != :transfer)

  defp filter_category(query, id), do: where(query, [t], t.category_id == ^id)

  defp filter_search(query, search) when is_binary(search) and search != "" do
    like = "%" <> String.replace(search, ~r/[%_]/, "") <> "%"

    from t in query,
      left_join: c in assoc(t, :category),
      where:
        ilike(t.description, ^like) or ilike(t.raw_description, ^like) or ilike(c.name, ^like)
  end

  defp filter_search(query, _), do: query

  defp resolve_category(attrs) do
    case fetch_attr(attrs, :category_name) do
      {:ok, name} when is_binary(name) ->
        case String.trim(name) do
          "" -> {:ok, put_attr(attrs, :category_id, nil)}
          trimmed -> resolve_category_name(attrs, trimmed)
        end

      _ ->
        {:ok, attrs}
    end
  end

  defp resolve_category_name(attrs, name) do
    kind =
      case fetch_attr(attrs, :kind) do
        {:ok, kind} when kind in ["income", :income] -> :income
        _ -> :expense
      end

    with {:ok, category} <- find_or_create_category(name, kind) do
      {:ok, put_attr(attrs, :category_id, category.id)}
    end
  end

  defp fetch_attr(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(attrs, Atom.to_string(key))
    end
  end

  defp put_attr(attrs, key, value) do
    if Enum.any?(Map.keys(attrs), &is_binary/1) do
      Map.put(attrs, Atom.to_string(key), value)
    else
      Map.put(attrs, key, value)
    end
  end
end
