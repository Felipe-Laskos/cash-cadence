defmodule CashCadence.Imports do
  @moduledoc false

  import Ecto.Query, warn: false

  alias CashCadence.{Budgets, Classifier}
  alias CashCadence.Imports.{Batch, InboxItem, Normalizer, Sniffer}
  alias CashCadence.Ledger
  alias CashCadence.Ledger.{BankAccount, Transaction}
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
         {:ok, parsed} <- meta.parser.parse(decoded, password: opts[:password]) do
      bank = parsed[:bank] || meta.bank
      account = resolve_account(parsed.account, opts[:bank_account_id], bank)
      statement_competence = statement_competence(parsed, account)

      Repo.transaction(fn ->
        batch =
          %Batch{}
          |> Batch.changeset(%{
            source: Keyword.get(opts, :source, :upload),
            format: meta.format,
            bank: bank,
            account_kind: parsed.account.kind || meta.account_kind,
            file_name: file_name,
            file_sha256: sha,
            period_start: parsed.period_start,
            period_end: parsed.period_end,
            statement_balance: parsed.balance,
            raw_text: parsed[:raw_text],
            warnings: parsed[:warnings] || [],
            bank_account_id: account && account.id
          })
          |> Repo.insert!()

        counts =
          Enum.reduce(
            parsed.transactions,
            empty_counts(),
            &ingest_raw(&1, batch, account, statement_competence, &2)
          )

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

  defp ingest_raw(raw, batch, account, statement_competence, counts) do
    counts = Map.update!(counts, "total", &(&1 + 1))

    if duplicate?(raw) do
      Map.update!(counts, "duplicates", &(&1 + 1))
    else
      item = build_item(raw, batch, account, statement_competence)
      Repo.insert!(InboxItem.changeset(%InboxItem{}, item))
      mark_counterpart(item.payload["counterpart_item_id"])
      Classifier.record_hit(item.payload["rule_id"])

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

  defp build_item(raw, batch, account, statement_competence) do
    account_id = id_of(account)
    normalized = Normalizer.normalize(raw.raw_description)
    fingerprint = fingerprint(account_id, raw.date, raw.amount, normalized)
    classification = classify(raw, normalized)

    raw = %{
      raw
      | kind: classification.kind || raw.kind,
        competence: statement_competence || raw.competence || Date.beginning_of_month(raw.date)
    }

    suggestion = with_bill_fallback(classification, raw, normalized)
    match = find_match(raw)
    {kind, counterpart, counterpart_item} = transfer_link(raw, account_id)
    transfer? = not is_nil(counterpart) or not is_nil(counterpart_item)

    %{
      batch_id: batch.id,
      bank_account_id: account_id,
      external_id: raw.external_id,
      fingerprint: fingerprint,
      posted_on: raw.posted_on || raw.date,
      date: raw.date,
      competence: raw.competence,
      amount: raw.amount,
      kind: kind,
      raw_description: raw.raw_description,
      normalized_description: normalized,
      description: raw.description || Normalizer.short_description(raw.raw_description),
      suggested_category_id: suggestion.category_id,
      confidence: suggestion.confidence,
      match_transaction_id: id_of(match),
      counterpart_transaction_id: id_of(counterpart),
      flags:
        flags(match, transfer?, known_fingerprint?(fingerprint), suggestion.category_id, kind),
      payload:
        raw.payload
        |> put_counterpart_item(counterpart_item)
        |> put_classification(suggestion)
    }
  end

  defp statement_competence(parsed, %BankAccount{
         kind: :credit_card,
         competence_mode: :statement_month
       }) do
    case parsed[:due_on] || parsed[:period_end] do
      %Date{} = date -> Date.beginning_of_month(date)
      _ -> nil
    end
  end

  defp statement_competence(_parsed, _account), do: nil

  defp with_bill_fallback(%{category_id: nil} = classification, subject, normalized) do
    case Budgets.find_bill_match(subject.kind, subject.amount, subject.competence, normalized) do
      nil ->
        classification

      %{bill: bill, strong?: strong?} ->
        Map.merge(classification, %{
          category_id: bill.category_id,
          confidence: if(strong?, do: :high, else: :medium),
          source: :bill,
          bill: bill
        })
    end
  end

  defp with_bill_fallback(classification, _subject, _normalized), do: classification

  defp id_of(nil), do: nil
  defp id_of(%{id: id}), do: id

  defp classify(raw, normalized) do
    Classifier.classify(%{
      raw: raw.raw_description,
      normalized: normalized,
      hint: raw.payload["itau_category"]
    })
  end

  defp put_classification(payload, classification) do
    source = classification.source
    bill = classification[:bill]

    payload
    |> put_or_delete("suggestion_source", source && Atom.to_string(source))
    |> put_or_delete("rule_id", classification[:rule_id])
    |> put_or_delete("bill_id", bill && bill.id)
    |> put_or_delete("bill_name", bill && bill.name)
  end

  defp put_or_delete(map, key, nil), do: Map.delete(map, key)
  defp put_or_delete(map, key, value), do: Map.put(map, key, value)

  def reclassify_pending do
    InboxItem
    |> where([i], i.status == :pending)
    |> Repo.all()
    |> Enum.count(&reclassify_item/1)
  end

  defp reclassify_item(item) do
    classification =
      Classifier.classify(%{
        raw: item.raw_description,
        normalized: item.normalized_description,
        hint: item.payload["itau_category"]
      })

    kind = reclassified_kind(item, classification)

    suggestion =
      with_bill_fallback(
        classification,
        %{kind: kind, amount: item.amount, competence: item.competence},
        item.normalized_description
      )

    changes = %{
      suggested_category_id: suggestion.category_id,
      confidence: suggestion.confidence,
      kind: kind,
      flags: uncategorized_flag(item.flags, suggestion.category_id, kind),
      payload: put_classification(item.payload, suggestion)
    }

    changed? =
      changes.suggested_category_id != item.suggested_category_id or
        changes.confidence != item.confidence or changes.kind != item.kind

    if changed?, do: item |> InboxItem.changeset(changes) |> Repo.update!()
    changed?
  end

  defp reclassified_kind(item, classification) do
    if "transfer" in item.flags or is_nil(classification.kind),
      do: item.kind,
      else: classification.kind
  end

  defp uncategorized_flag(flags, category_id, kind) do
    flags = List.delete(flags, "uncategorized")
    if is_nil(category_id) and kind != :transfer, do: flags ++ ["uncategorized"], else: flags
  end

  defp transfer_link(raw, account_id) do
    counterpart =
      Ledger.find_transfer_counterpart(raw.amount, raw.date, account_id, @transfer_window_days)

    counterpart_item = if is_nil(counterpart), do: find_pending_counterpart(raw, account_id)
    kind = if counterpart || counterpart_item, do: :transfer, else: raw.kind
    {kind, counterpart, counterpart_item}
  end

  defp find_pending_counterpart(%{kind: kind}, _account_id) when kind not in [:income, :expense],
    do: nil

  defp find_pending_counterpart(_raw, nil), do: nil

  defp find_pending_counterpart(raw, account_id) do
    opposite = if raw.kind == :expense, do: :income, else: :expense
    from_date = Date.add(raw.date, -@transfer_window_days)
    to_date = Date.add(raw.date, @transfer_window_days)

    Repo.one(
      from i in InboxItem,
        where:
          i.status == :pending and i.kind == ^opposite and i.amount == ^raw.amount and
            i.date >= ^from_date and i.date <= ^to_date and
            not is_nil(i.bank_account_id) and i.bank_account_id != ^account_id,
        order_by: [asc: fragment("abs(? - ?)", i.date, type(^raw.date, :date)), asc: i.id],
        limit: 1
    )
  end

  defp put_counterpart_item(payload, nil), do: payload
  defp put_counterpart_item(payload, item), do: Map.put(payload, "counterpart_item_id", item.id)

  defp mark_counterpart(nil), do: :ok

  defp mark_counterpart(item_id) do
    item = Repo.get!(InboxItem, item_id)
    flags = Enum.uniq(["transfer" | List.delete(item.flags, "uncategorized")])
    item |> InboxItem.changeset(%{kind: :transfer, flags: flags}) |> Repo.update!()
  end

  defp find_match(%{kind: :transfer}), do: nil

  defp find_match(raw),
    do: Ledger.find_manual_match(raw.kind, raw.amount, raw.date, @match_window_days)

  defp known_fingerprint?(fingerprint) do
    Repo.exists?(
      from t in Transaction, where: t.fingerprint == ^fingerprint and is_nil(t.deleted_at)
    )
  end

  defp flags(match, transfer?, possible_duplicate?, suggested_category_id, kind) do
    [
      {match != nil, "match"},
      {transfer?, "transfer"},
      {possible_duplicate?, "possible_duplicate"},
      {is_nil(suggested_category_id) and kind != :transfer, "uncategorized"}
    ]
    |> Enum.filter(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  def fingerprint(account_id, %Date{} = date, %Decimal{} = amount, normalized) do
    :crypto.hash(
      :sha256,
      "#{account_id}|#{Date.to_iso8601(date)}|#{Decimal.to_string(amount, :normal)}|#{normalized}"
    )
    |> Base.encode16(case: :lower)
  end

  defp resolve_account(%{account_ref: ref} = account, nil, bank) when is_binary(ref) do
    Repo.get_by(BankAccount, external_ref: ref) || default_account(ref, bank, account[:kind])
  end

  defp resolve_account(_account, nil, _bank), do: nil

  defp resolve_account(%{account_ref: ref}, account_id, _bank),
    do: remember_ref(Repo.get!(BankAccount, account_id), ref)

  defp default_account(ref, bank, kind)
       when bank in [:itau, :nubank] and kind in [:checking, :credit_card] do
    candidates =
      Repo.all(
        from a in BankAccount,
          where: a.bank == ^bank and a.kind == ^kind and a.own == true and is_nil(a.external_ref)
      )

    case candidates do
      [account] -> remember_ref(account, ref)
      _ -> nil
    end
  end

  defp default_account(_ref, _bank, _kind), do: nil

  defp remember_ref(%BankAccount{external_ref: nil} = account, ref) when is_binary(ref),
    do: account |> Ecto.Changeset.change(external_ref: ref) |> Repo.update!()

  defp remember_ref(account, _ref), do: account

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

      {date, competence} = approved_date(attrs["date"], item)

      transaction_attrs =
        %{
          "date" => date,
          "kind" => Map.get(attrs, "kind", Atom.to_string(item.kind)),
          "competence" => competence,
          "amount" => present_or(attrs["amount"], item.amount),
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
          Classifier.learn(item.normalized_description, transaction.category_id)
          plan_installments(item, transaction)
          transaction

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  def installment_forecast(
        %InboxItem{payload: %{"installment" => %{"number" => number, "of" => of}}} = item,
        %Transaction{category_id: category_id}
      )
      when number < of and not is_nil(category_id) do
    %{remaining: of - number, ends_on: Date.shift(item.competence, month: of - number)}
  end

  def installment_forecast(_item, _transaction), do: nil

  def installment_name(%InboxItem{} = item) do
    (item.description || item.raw_description)
    |> String.replace(~r/\s*\(\d+\/\d+\)\s*$/, "")
    |> String.trim()
  end

  defp plan_installments(_item, %Transaction{category_id: nil}), do: :ok

  defp plan_installments(
         %InboxItem{payload: %{"installment" => %{"number" => number, "of" => of}}} = item,
         transaction
       ) do
    name = installment_name(item)

    Budgets.plan_installments(%{
      name: name,
      amount: item.amount,
      category_id: transaction.category_id,
      competence: item.competence,
      number: number,
      of: of,
      match_text: Normalizer.normalize(name)
    })

    :ok
  end

  defp plan_installments(_item, _transaction), do: :ok

  defp approved_date(value, item) do
    with true <- is_binary(value) and String.trim(value) != "",
         {:ok, date} <- Date.from_iso8601(String.trim(value)),
         true <- date != item.date do
      {date, Date.beginning_of_month(date)}
    else
      _ -> {item.date, item.competence}
    end
  end

  defp present_or(value, default) when is_binary(value) do
    if String.trim(value) == "", do: default, else: value
  end

  defp present_or(_value, default), do: default

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
          Classifier.learn(item.normalized_description, transaction.category_id)
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
