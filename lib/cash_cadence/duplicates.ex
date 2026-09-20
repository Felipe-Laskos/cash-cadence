defmodule CashCadence.Duplicates do
  @moduledoc false

  import Ecto.Query, warn: false

  alias CashCadence.Imports.Similarity
  alias CashCadence.Ledger
  alias CashCadence.Ledger.{DuplicateDismissal, Transaction}
  alias CashCadence.Repo

  @window_days 3

  def window_days, do: @window_days

  @installment ~r/\((\d+)\/(\d+)\)\s*$/

  def list(opts \\ []) do
    window = Keyword.get(opts, :window_days, @window_days)
    dismissed = dismissed_pairs()

    window
    |> candidates()
    |> Repo.all()
    |> load_pairs()
    |> Enum.reject(fn {left, right} = pair ->
      MapSet.member?(dismissed, {left.id, right.id}) or two_sided_transfer?(pair) or
        same_file?(pair) or other_installment?(pair)
    end)
    |> Enum.map(&describe/1)
    |> filter_strength(Keyword.get(opts, :weak, false))
    |> Enum.sort_by(&{&1.rank, Date.to_erl(&1.left.date)}, :desc)
  end

  def weak_count(opts \\ []) do
    opts |> Keyword.put(:weak, true) |> list() |> Enum.count(&(&1.strength == :weak))
  end

  defp filter_strength(pairs, true), do: pairs
  defp filter_strength(pairs, _weak), do: Enum.reject(pairs, &(&1.strength == :weak))

  defp same_file?({left, right}) do
    not is_nil(left.import_batch_id) and left.import_batch_id == right.import_batch_id
  end

  defp other_installment?({left, right}) do
    with [_, number, of] <- Regex.run(@installment, left.description || ""),
         [_, other_number, ^of] <- Regex.run(@installment, right.description || "") do
      number != other_number
    else
      _ -> false
    end
  end

  def count(opts \\ []), do: opts |> list() |> length()

  def dismiss(%Transaction{} = left, %Transaction{} = right) do
    {first, second} = ordered(left, right)

    %DuplicateDismissal{}
    |> DuplicateDismissal.changeset(%{
      transaction_id: first.id,
      other_transaction_id: second.id
    })
    |> Repo.insert(on_conflict: :nothing)
  end

  def resolve(%Transaction{} = kept, %Transaction{} = removed) when kept.id != removed.id do
    Repo.transaction(fn ->
      from(t in Transaction, where: t.reimbursement_of_id == ^removed.id)
      |> Repo.update_all(set: [reimbursement_of_id: kept.id])

      case Ledger.delete_transaction(removed) do
        {:ok, deleted} -> deleted
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  defp candidates(window) do
    from(a in Transaction,
      join: b in Transaction,
      on:
        a.id < b.id and a.kind == b.kind and a.amount == b.amount and
          fragment("abs(? - ?) <= ?", a.date, b.date, ^window),
      where: is_nil(a.deleted_at) and is_nil(b.deleted_at),
      order_by: [desc: a.date, desc: a.id],
      select: {a, b}
    )
  end

  defp load_pairs(rows) do
    loaded =
      rows
      |> Enum.flat_map(fn {left, right} -> [left, right] end)
      |> Repo.preload([:category, :bank_account])
      |> Map.new(&{&1.id, &1})

    Enum.map(rows, fn {left, right} ->
      {Map.fetch!(loaded, left.id), Map.fetch!(loaded, right.id)}
    end)
  end

  defp two_sided_transfer?({left, right}) do
    left.kind == :transfer and not is_nil(left.bank_account_id) and
      not is_nil(right.bank_account_id) and left.bank_account_id != right.bank_account_id
  end

  defp describe({left, right}) do
    reason = reason(left, right)

    %{
      left: left,
      right: right,
      reason: reason,
      rank: rank(reason),
      strength: if(reason == :amount, do: :weak, else: :strong),
      same_day?: Date.compare(left.date, right.date) == :eq
    }
  end

  defp reason(left, right) do
    cond do
      not is_nil(left.fingerprint) and left.fingerprint == right.fingerprint ->
        :fingerprint

      Similarity.shared(left.normalized_description, right.normalized_description) > 0 ->
        :description

      left.category_id == right.category_id and not is_nil(left.category_id) ->
        :category

      true ->
        :amount
    end
  end

  defp rank(:fingerprint), do: 4
  defp rank(:description), do: 3
  defp rank(:category), do: 2
  defp rank(:amount), do: 1

  defp ordered(left, right) do
    if left.id <= right.id, do: {left, right}, else: {right, left}
  end

  defp dismissed_pairs do
    from(d in DuplicateDismissal, select: {d.transaction_id, d.other_transaction_id})
    |> Repo.all()
    |> MapSet.new()
  end
end
