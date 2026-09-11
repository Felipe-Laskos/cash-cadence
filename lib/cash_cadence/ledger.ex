defmodule CashCadence.Ledger do
  @moduledoc false

  import Ecto.Query, warn: false

  alias CashCadence.Ledger.{BankAccount, Category, Transaction}
  alias CashCadence.Money
  alias CashCadence.Repo

  def list_categories(opts \\ []) do
    Category
    |> where([c], is_nil(c.archived_at))
    |> maybe_kind(opts[:kind])
    |> order_by([c], asc: fragment("lower(?)", c.name))
    |> Repo.all()
  end

  defp maybe_kind(query, nil), do: query
  defp maybe_kind(query, kind), do: where(query, [c], c.kind == ^kind)

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

  def create_bank_account(attrs),
    do: %BankAccount{} |> BankAccount.changeset(attrs) |> Repo.insert()

  def list_transactions(filters \\ %{}) do
    active_transactions()
    |> filter_competence(filters[:competence])
    |> filter_kind(filters[:kind])
    |> filter_category(filters[:category_id])
    |> filter_search(filters[:search])
    |> order_by([t], desc: t.date, desc: t.id)
    |> preload(:category)
    |> Repo.all()
  end

  def get_transaction!(id) do
    active_transactions() |> preload(:category) |> Repo.get!(id)
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
    rows =
      Repo.all(
        from t in query,
          where: t.kind in [:income, :expense],
          group_by: t.kind,
          select: {t.kind, sum(t.amount), count(t.id)}
      )

    by_kind = Map.new(rows, fn {kind, sum, count} -> {kind, {sum || Money.zero(), count}} end)
    {income, income_count} = Map.get(by_kind, :income, {Money.zero(), 0})
    {expense, expense_count} = Map.get(by_kind, :expense, {Money.zero(), 0})

    %{
      income: income,
      expense: expense,
      net: Decimal.sub(income, expense),
      count: income_count + expense_count,
      income_count: income_count,
      expense_count: expense_count
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

    rows =
      Repo.all(
        from t in active_transactions(),
          where: t.competence >= ^from and t.competence <= ^to and t.kind in [:income, :expense],
          group_by: [t.competence, t.kind],
          select: {t.competence, t.kind, sum(t.amount)}
      )

    sums = Map.new(rows, fn {competence, kind, sum} -> {{competence, kind}, sum} end)

    from
    |> months_until(to)
    |> Enum.map(fn month ->
      income = Map.get(sums, {month, :income}, Money.zero())
      expense = Map.get(sums, {month, :expense}, Money.zero())
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
    Repo.all(
      from t in active_transactions(),
        left_join: c in assoc(t, :category),
        where: t.competence == ^Date.beginning_of_month(competence) and t.kind == :expense,
        group_by: [c.id, c.name, c.color],
        order_by: [desc: sum(t.amount)],
        select: %{
          category_id: c.id,
          name: c.name,
          color: c.color,
          total: sum(t.amount),
          count: count(t.id)
        }
    )
  end

  def recent_transactions(limit \\ 5) do
    active_transactions()
    |> order_by([t], desc: t.date, desc: t.id)
    |> limit(^limit)
    |> preload(:category)
    |> Repo.all()
  end

  def count_uncategorized(%Date{} = competence) do
    active_transactions()
    |> where(
      [t],
      t.competence == ^Date.beginning_of_month(competence) and is_nil(t.category_id) and
        t.kind != :transfer
    )
    |> Repo.aggregate(:count)
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
