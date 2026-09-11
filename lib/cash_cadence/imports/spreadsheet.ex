defmodule CashCadence.Imports.Spreadsheet do
  @moduledoc false

  import Ecto.Query, warn: false

  alias CashCadence.{Budgets, Ledger, Repo}
  alias CashCadence.Ledger.Transaction
  alias NimbleCSV.RFC4180, as: CSV

  def run(opts) do
    transactions_path = Keyword.fetch!(opts, :transactions)

    Repo.transaction(fn ->
      transactions = import_transactions(transactions_path)
      bills = opts[:bills] && import_bills(opts[:bills])
      accounts = opts[:accounts] && import_accounts(opts[:accounts])
      %{transactions: transactions, bills: bills, accounts: accounts}
    end)
  end

  defp import_transactions(path) do
    initial = %{created: 0, skipped: 0, ignored: 0, uncategorized: 0, categories_created: 0}

    path
    |> rows()
    |> Enum.reduce(initial, fn row, acc -> import_transaction(row, acc) end)
  end

  defp import_transaction(
         [row, _date, _type, _category, _kind, _description, amount] = fields,
         acc
       ) do
    external_id = "planilha:" <> row

    cond do
      transaction_exists?(external_id) -> %{acc | skipped: acc.skipped + 1}
      Decimal.equal?(Decimal.new(amount), 0) -> %{acc | ignored: acc.ignored + 1}
      true -> create_transaction(fields, external_id, acc)
    end
  end

  defp import_transaction(row, _acc), do: Repo.rollback({:unexpected_columns, row})

  defp create_transaction(
         [row, date, type, category, category_kind, description, amount],
         external_id,
         acc
       ) do
    kind = kind(type)
    {category_id, acc} = category_id(category, category_kind, kind, acc)

    attrs = %{
      date: Date.from_iso8601!(date),
      kind: kind,
      amount: Decimal.new(amount),
      category_id: category_id,
      description: blank_to_nil(description),
      source: :spreadsheet,
      external_id: external_id
    }

    case Ledger.create_transaction(attrs) do
      {:ok, _transaction} -> %{acc | created: acc.created + 1}
      {:error, changeset} -> Repo.rollback({:invalid_row, row, changeset})
    end
  end

  defp category_id(name, category_kind, kind, acc) do
    case blank_to_nil(name) do
      nil -> {nil, %{acc | uncategorized: acc.uncategorized + 1}}
      "?" -> {nil, %{acc | uncategorized: acc.uncategorized + 1}}
      name -> find_or_create(name, category_kind(category_kind, kind), acc)
    end
  end

  defp find_or_create(name, kind, acc) do
    case Ledger.get_category_by_name(name) do
      nil ->
        case Ledger.create_category(%{name: name, kind: kind}) do
          {:ok, category} ->
            {category.id, %{acc | categories_created: acc.categories_created + 1}}

          {:error, changeset} ->
            Repo.rollback({:invalid_category, name, changeset})
        end

      category ->
        {category.id, acc}
    end
  end

  defp import_bills(path) do
    Enum.reduce(rows(path), %{created: 0, skipped: 0}, fn [name, category, expected], acc ->
      {:ok, category} = Ledger.find_or_create_category(category, :expense)
      unless category.fixed, do: {:ok, _} = Ledger.update_category(category, %{fixed: true})

      if Budgets.get_recurring_bill_by_name(name) do
        %{acc | skipped: acc.skipped + 1}
      else
        {:ok, _bill} =
          Budgets.create_recurring_bill(%{
            name: name,
            expected_amount: Decimal.new(expected),
            category_id: category.id
          })

        %{acc | created: acc.created + 1}
      end
    end)
  end

  defp import_accounts(path) do
    Enum.reduce(rows(path), %{created: 0, skipped: 0}, fn [name, bank, kind], acc ->
      if Ledger.get_bank_account_by_name(name) do
        %{acc | skipped: acc.skipped + 1}
      else
        {:ok, _account} = Ledger.create_bank_account(%{name: name, bank: bank, kind: kind})
        %{acc | created: acc.created + 1}
      end
    end)
  end

  defp rows(path), do: path |> File.stream!() |> CSV.parse_stream() |> Enum.to_list()

  defp transaction_exists?(external_id) do
    Repo.exists?(
      from t in Transaction, where: t.source == :spreadsheet and t.external_id == ^external_id
    )
  end

  defp kind("income"), do: :income
  defp kind("expense"), do: :expense
  defp kind(other), do: Repo.rollback({:unknown_type, other})

  defp category_kind("person", _kind), do: :person
  defp category_kind("income", _kind), do: :income
  defp category_kind("expense", _kind), do: :expense
  defp category_kind(_, kind), do: kind

  defp blank_to_nil(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
