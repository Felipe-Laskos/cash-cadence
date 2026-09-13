defmodule CashCadence.Classifier do
  @moduledoc false

  import Ecto.Query, warn: false

  alias CashCadence.Classifier.{Memory, Rule}
  alias CashCadence.Imports.{InboxItem, Normalizer}
  alias CashCadence.Ledger
  alias CashCadence.Ledger.Transaction
  alias CashCadence.Repo

  @memory_page 50

  def classify(%{normalized: normalized} = subject) do
    rule = subject |> Map.put_new(:raw, nil) |> Map.put_new(:hint, nil) |> first_matching_rule()

    if rule && rule.category_id do
      %{
        category_id: rule.category_id,
        kind: rule.kind_override,
        confidence: :high,
        source: :rule,
        rule_id: rule.id
      }
    else
      normalized
      |> from_memory()
      |> Map.merge(%{kind: rule && rule.kind_override, rule_id: rule && rule.id})
    end
  end

  defp first_matching_rule(subject) do
    list_rules() |> Enum.filter(& &1.active) |> Enum.find(&matches?(&1, subject))
  end

  defp from_memory(normalized) when normalized in [nil, ""],
    do: %{category_id: nil, confidence: :none, source: nil}

  defp from_memory(normalized) do
    case Repo.get_by(Memory, normalized_description: normalized) do
      %Memory{category_id: category_id, uses: uses} when uses >= 2 ->
        %{category_id: category_id, confidence: :high, source: :memory}

      %Memory{category_id: category_id} ->
        %{category_id: category_id, confidence: :medium, source: :memory}

      nil ->
        %{category_id: nil, confidence: :none, source: nil}
    end
  end

  def matches?(%Rule{} = rule, subject) do
    case {rule.target, rule.match_kind} do
      {:bank_hint, _} ->
        text_matches?(rule, subject[:hint])

      {:description, :regex} ->
        regex_matches?(rule.pattern, subject[:raw] || subject[:normalized])

      {:description, _} ->
        text_matches?(rule, subject[:normalized])
    end
  end

  defp text_matches?(_rule, nil), do: false

  defp text_matches?(%Rule{match_kind: :regex, pattern: pattern}, text),
    do: regex_matches?(pattern, text)

  defp text_matches?(%Rule{match_kind: match_kind, pattern: pattern}, text) do
    needle = Normalizer.normalize(pattern)
    haystack = Normalizer.normalize(text)

    needle != "" and
      case match_kind do
        :contains -> String.contains?(haystack, needle)
        :starts_with -> String.starts_with?(haystack, needle)
      end
  end

  defp regex_matches?(_pattern, nil), do: false

  defp regex_matches?(pattern, text) do
    case Regex.compile(pattern, "iu") do
      {:ok, regex} -> Regex.match?(regex, text)
      {:error, _} -> false
    end
  end

  def preview(%Rule{} = rule) do
    transactions =
      Repo.all(
        from t in Transaction,
          where: is_nil(t.deleted_at) and not is_nil(t.normalized_description),
          select: %{raw: t.raw_description, normalized: t.normalized_description}
      )

    pending =
      Repo.all(
        from i in InboxItem,
          where: i.status == :pending,
          select: %{
            raw: i.raw_description,
            normalized: i.normalized_description,
            payload: i.payload
          }
      )
      |> Enum.map(&%{raw: &1.raw, normalized: &1.normalized, hint: &1.payload["itau_category"]})

    %{
      transactions: Enum.count(transactions, &matches?(rule, &1)),
      pending: Enum.count(pending, &matches?(rule, &1))
    }
  end

  def list_rules do
    Repo.all(from r in Rule, order_by: [asc: r.position, asc: r.id], preload: :category)
  end

  def get_rule!(id), do: Rule |> preload(:category) |> Repo.get!(id)

  def change_rule(%Rule{} = rule, attrs \\ %{}), do: Rule.changeset(rule, attrs)

  def create_rule(attrs) do
    attrs = attrs |> stringify() |> Map.put_new("position", next_position())

    with {:ok, attrs} <- resolve_category(attrs) do
      %Rule{} |> Rule.changeset(attrs) |> Repo.insert() |> preload_result()
    end
  end

  def update_rule(%Rule{} = rule, attrs) do
    with {:ok, attrs} <- attrs |> stringify() |> resolve_category() do
      rule |> Rule.changeset(attrs) |> Repo.update() |> preload_result()
    end
  end

  def delete_rule(%Rule{} = rule), do: Repo.delete(rule)

  def toggle_rule(%Rule{} = rule),
    do: rule |> Ecto.Changeset.change(active: not rule.active) |> Repo.update()

  def move_rule(%Rule{} = rule, direction) when direction in [:up, :down] do
    rules = list_rules()
    index = Enum.find_index(rules, &(&1.id == rule.id))
    target = if direction == :up, do: index - 1, else: index + 1

    if target >= 0 and target < length(rules) do
      rules
      |> List.replace_at(index, Enum.at(rules, target))
      |> List.replace_at(target, rule)
      |> renumber(rule.id)
    else
      {:ok, rule}
    end
  end

  defp renumber(rules, rule_id) do
    Repo.transaction(fn ->
      rules
      |> Enum.with_index(1)
      |> Enum.each(fn {item, position} ->
        from(r in Rule, where: r.id == ^item.id) |> Repo.update_all(set: [position: position])
      end)

      get_rule!(rule_id)
    end)
  end

  def record_hit(nil), do: :ok

  def record_hit(rule_id) do
    from(r in Rule, where: r.id == ^rule_id) |> Repo.update_all(inc: [hits: 1])
    :ok
  end

  defp next_position do
    (Repo.one(from r in Rule, select: max(r.position)) || 0) + 1
  end

  defp resolve_category(%{"category_name" => name} = attrs) when is_binary(name) do
    case String.trim(name) do
      "" ->
        {:ok, Map.put(attrs, "category_id", nil)}

      trimmed ->
        kind = if attrs["kind_override"] in ["income", :income], do: :income, else: :expense

        with {:ok, category} <- Ledger.find_or_create_category(trimmed, kind) do
          {:ok, Map.put(attrs, "category_id", category.id)}
        end
    end
  end

  defp resolve_category(attrs), do: {:ok, attrs}

  defp stringify(attrs), do: Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

  defp preload_result({:ok, rule}), do: {:ok, Repo.preload(rule, :category, force: true)}
  defp preload_result(error), do: error

  def learn(normalized, category_id) when is_binary(normalized) and is_integer(category_id) do
    if normalized == "" do
      :ok
    else
      now = DateTime.utc_now(:second)

      Repo.insert!(
        %Memory{
          normalized_description: normalized,
          category_id: category_id,
          uses: 1,
          last_used_at: now
        },
        on_conflict: [inc: [uses: 1], set: [category_id: category_id, last_used_at: now]],
        conflict_target: :normalized_description
      )

      :ok
    end
  end

  def learn(_normalized, _category_id), do: :ok

  def list_memory(search \\ nil, limit \\ @memory_page) do
    Memory
    |> filter_memory(search)
    |> order_by([m], desc: m.last_used_at, desc: m.uses, asc: m.normalized_description)
    |> limit(^limit)
    |> preload(:category)
    |> Repo.all()
  end

  defp filter_memory(query, search) when search in [nil, ""], do: query

  defp filter_memory(query, search) do
    needle = "%" <> Normalizer.normalize(search) <> "%"
    where(query, [m], ilike(m.normalized_description, ^needle))
  end

  def count_memory, do: Repo.aggregate(Memory, :count)

  def get_memory!(id), do: Memory |> preload(:category) |> Repo.get!(id)

  def forget(%Memory{} = memory), do: Repo.delete(memory)

  def remap_memory(source_category_id, target_category_id) do
    from(m in Memory, where: m.category_id == ^source_category_id)
    |> Repo.update_all(set: [category_id: target_category_id])
  end
end
