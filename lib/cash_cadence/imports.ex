defmodule CashCadence.Imports do
  @moduledoc false

  import Ecto.Query, warn: false

  alias CashCadence.Imports.{Batch, InboxItem, Normalizer, Sniffer}
  alias CashCadence.Ledger
  alias CashCadence.Ledger.Transaction
  alias CashCadence.Repo

  @match_window_days 3
  @transfer_window_days 2

  def ingest_file(path, opts \\ []) do
    ingest_binary(File.read!(path), Path.basename(path), opts)
  end

  def ingest_binary(binary, file_name, opts \\ []) do
    sha = :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)

    with nil <- Repo.get_by(Batch, file_sha256: sha),
         {:ok, meta} <- Sniffer.detect(binary),
         decoded = binary |> Sniffer.strip_bom() |> Sniffer.transcode(meta.encoding),
         {:ok, parsed} <- meta.parser.parse(decoded) do
      account = resolve_account(parsed.account.account_ref, opts[:bank_account_id])

      Repo.transaction(fn ->
        batch =
          %Batch{}
          |> Batch.changeset(%{
            source: Keyword.get(opts, :source, :upload),
            format: meta.format,
            bank: meta.bank,
            account_kind: parsed.account.kind || meta.account_kind,
            file_name: file_name,
            file_sha256: sha,
            period_start: parsed.period_start,
            period_end: parsed.period_end,
            statement_balance: parsed.balance,
            bank_account_id: account && account.id
          })
          |> Repo.insert!()

        counts =
          Enum.reduce(parsed.transactions, empty_counts(), &ingest_raw(&1, batch, account, &2))

        batch
        |> Ecto.Changeset.change(counts: counts)
        |> Repo.update!()
        |> Repo.preload(:bank_account)
      end)
    else
      %Batch{} = batch -> {:error, {:already_imported, batch}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp empty_counts,
    do: %{
      "total" => 0,
      "new" => 0,
      "duplicates" => 0,
      "matched" => 0,
      "transfers" => 0,
      "suggested" => 0
    }

  defp ingest_raw(raw, batch, account, counts) do
    counts = Map.update!(counts, "total", &(&1 + 1))

    if duplicate?(raw) do
      Map.update!(counts, "duplicates", &(&1 + 1))
    else
      item = build_item(raw, batch, account)
      Repo.insert!(InboxItem.changeset(%InboxItem{}, item))

      counts
      |> Map.update!("new", &(&1 + 1))
      |> Map.update!("matched", &(&1 + if(item.match_transaction_id, do: 1, else: 0)))
      |> Map.update!("transfers", &(&1 + if(item.kind == :transfer, do: 1, else: 0)))
      |> Map.update!("suggested", &(&1 + if(item.suggested_category_id, do: 1, else: 0)))
    end
  end

  defp duplicate?(%{external_id: nil}), do: false

  defp duplicate?(%{external_id: external_id}) do
    Repo.exists?(
      from t in Transaction, where: t.external_id == ^external_id and is_nil(t.deleted_at)
    ) or
      Repo.exists?(
        from i in InboxItem, where: i.external_id == ^external_id and i.status == :pending
      )
  end

  defp build_item(raw, batch, account) do
    account_id = account && account.id
    normalized = Normalizer.normalize(raw.raw_description)
    fingerprint = fingerprint(account_id, raw.date, raw.amount, normalized)
    {suggested_category_id, confidence} = suggestion(normalized)
    match = find_match(raw)

    counterpart =
      Ledger.find_transfer_counterpart(raw.amount, raw.date, account_id, @transfer_window_days)

    kind = if counterpart, do: :transfer, else: raw.kind

    %{
      batch_id: batch.id,
      bank_account_id: account_id,
      external_id: raw.external_id,
      fingerprint: fingerprint,
      posted_on: raw.posted_on || raw.date,
      date: raw.date,
      competence: Date.beginning_of_month(raw.date),
      amount: raw.amount,
      kind: kind,
      raw_description: raw.raw_description,
      normalized_description: normalized,
      description: Normalizer.short_description(raw.raw_description),
      suggested_category_id: suggested_category_id,
      confidence: confidence,
      match_transaction_id: match && match.id,
      counterpart_transaction_id: counterpart && counterpart.id,
      flags:
        flags(match, counterpart, known_fingerprint?(fingerprint), suggested_category_id, kind),
      payload: raw.payload
    }
  end

  defp find_match(%{kind: :transfer}), do: nil

  defp find_match(raw),
    do: Ledger.find_manual_match(raw.kind, raw.amount, raw.date, @match_window_days)

  defp known_fingerprint?(fingerprint) do
    Repo.exists?(
      from t in Transaction, where: t.fingerprint == ^fingerprint and is_nil(t.deleted_at)
    )
  end

  defp flags(match, counterpart, possible_duplicate?, suggested_category_id, kind) do
    [
      {match != nil, "match"},
      {counterpart != nil, "transfer"},
      {possible_duplicate?, "possible_duplicate"},
      {is_nil(suggested_category_id) and kind != :transfer, "uncategorized"}
    ]
    |> Enum.filter(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp suggestion(""), do: {nil, :none}

  defp suggestion(normalized) do
    case Ledger.suggest_category(normalized) do
      {category_id, uses} when uses >= 2 -> {category_id, :high}
      {category_id, _uses} -> {category_id, :medium}
      nil -> {nil, :none}
    end
  end

  def fingerprint(account_id, %Date{} = date, %Decimal{} = amount, normalized) do
    :crypto.hash(
      :sha256,
      "#{account_id}|#{Date.to_iso8601(date)}|#{Decimal.to_string(amount, :normal)}|#{normalized}"
    )
    |> Base.encode16(case: :lower)
  end

  defp resolve_account(account_ref, nil) when is_binary(account_ref),
    do: Repo.get_by(CashCadence.Ledger.BankAccount, external_ref: account_ref)

  defp resolve_account(_account_ref, nil), do: nil

  defp resolve_account(account_ref, account_id) do
    account = Repo.get!(CashCadence.Ledger.BankAccount, account_id)

    if is_binary(account_ref) and is_nil(account.external_ref) do
      account |> Ecto.Changeset.change(external_ref: account_ref) |> Repo.update!()
    else
      account
    end
  end

  def list_batches(limit \\ 20) do
    Repo.all(
      from b in Batch,
        order_by: [desc: b.inserted_at, desc: b.id],
        limit: ^limit,
        preload: :bank_account
    )
  end

  def get_batch!(id), do: Batch |> preload(:bank_account) |> Repo.get!(id)

  def list_inbox(filters \\ %{}) do
    InboxItem
    |> where([i], i.status == :pending)
    |> filter_batch(filters[:batch_id])
    |> order_by([i], desc: i.date, desc: i.id)
    |> preload([
      :suggested_category,
      :bank_account,
      batch: :bank_account,
      match_transaction: :category,
      counterpart_transaction: :category
    ])
    |> Repo.all()
  end

  defp filter_batch(query, nil), do: query
  defp filter_batch(query, batch_id), do: where(query, [i], i.batch_id == ^batch_id)

  def count_pending, do: Repo.aggregate(from(i in InboxItem, where: i.status == :pending), :count)

  def get_item!(id) do
    InboxItem
    |> preload([
      :suggested_category,
      :bank_account,
      :batch,
      match_transaction: :category,
      counterpart_transaction: :category
    ])
    |> Repo.get!(id)
  end

  def approve(%InboxItem{status: :pending} = item, attrs \\ %{}) do
    Repo.transaction(fn ->
      attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

      transaction_attrs =
        %{
          "date" => item.date,
          "kind" => Map.get(attrs, "kind", Atom.to_string(item.kind)),
          "amount" => item.amount,
          "description" => Map.get(attrs, "description", item.description),
          "category_id" => item.suggested_category_id,
          "source" => :import,
          "external_id" => item.external_id,
          "fingerprint" => item.fingerprint,
          "bank_account_id" => item.bank_account_id,
          "raw_description" => item.raw_description,
          "normalized_description" => item.normalized_description,
          "posted_on" => item.posted_on,
          "import_batch_id" => item.batch_id
        }
        |> maybe_put_category(attrs)

      case Ledger.create_transaction(transaction_attrs) do
        {:ok, transaction} ->
          finish(item, :approved, transaction)
          transaction

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  defp maybe_put_category(transaction_attrs, %{"category_name" => name}) when is_binary(name) do
    transaction_attrs |> Map.put("category_name", name) |> Map.delete("category_id")
  end

  defp maybe_put_category(transaction_attrs, %{"category_id" => id}) when id not in [nil, ""] do
    Map.put(transaction_attrs, "category_id", id)
  end

  defp maybe_put_category(transaction_attrs, _attrs), do: transaction_attrs

  def merge(%InboxItem{status: :pending} = item, %Transaction{} = transaction) do
    Repo.transaction(fn ->
      case Ledger.attach_import(transaction, %{
             amount: item.amount,
             external_id: item.external_id,
             fingerprint: item.fingerprint,
             bank_account_id: item.bank_account_id || transaction.bank_account_id,
             raw_description: item.raw_description,
             normalized_description: item.normalized_description,
             posted_on: item.posted_on,
             import_batch_id: item.batch_id
           }) do
        {:ok, transaction} ->
          finish(item, :merged, transaction)
          transaction

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  def ignore(%InboxItem{status: :pending} = item) do
    item |> InboxItem.changeset(%{status: :ignored}) |> Repo.update()
  end

  def approve_high_confidence(filters \\ %{}) do
    filters
    |> list_inbox()
    |> Enum.filter(&(&1.confidence == :high and &1.flags == []))
    |> Enum.reduce(0, fn item, count ->
      case approve(item) do
        {:ok, _} -> count + 1
        {:error, _} -> count
      end
    end)
  end

  defp finish(item, status, transaction) do
    item
    |> InboxItem.changeset(%{status: status, transaction_id: transaction.id})
    |> Repo.update!()

    maybe_review_batch(item.batch_id)
  end

  defp maybe_review_batch(batch_id) do
    pending =
      Repo.aggregate(
        from(i in InboxItem, where: i.batch_id == ^batch_id and i.status == :pending),
        :count
      )

    if pending == 0 do
      from(b in Batch, where: b.id == ^batch_id) |> Repo.update_all(set: [status: "reviewed"])
    end
  end
end
