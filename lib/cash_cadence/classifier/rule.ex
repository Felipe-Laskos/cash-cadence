defmodule CashCadence.Classifier.Rule do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  alias CashCadence.Ledger.Category

  @match_kinds [:contains, :starts_with, :regex]
  @targets [:description, :bank_hint]
  @kind_overrides [:income, :expense, :transfer]

  schema "rules" do
    field :position, :integer
    field :pattern, :string
    field :match_kind, Ecto.Enum, values: @match_kinds, default: :contains
    field :target, Ecto.Enum, values: @targets, default: :description
    field :kind_override, Ecto.Enum, values: @kind_overrides
    field :active, :boolean, default: true
    field :hits, :integer, default: 0
    field :category_name, :string, virtual: true

    belongs_to :category, Category

    timestamps(type: :utc_datetime)
  end

  def match_kinds, do: @match_kinds
  def targets, do: @targets
  def kind_overrides, do: @kind_overrides

  def changeset(rule, attrs) do
    rule
    |> cast(attrs, [
      :position,
      :pattern,
      :match_kind,
      :target,
      :kind_override,
      :active,
      :hits,
      :category_id,
      :category_name
    ])
    |> update_change(:pattern, &String.trim/1)
    |> validate_required([:pattern, :match_kind, :target])
    |> validate_length(:pattern, min: 2, max: 120)
    |> validate_regex()
    |> validate_outcome()
  end

  defp validate_regex(changeset) do
    with :regex <- get_field(changeset, :match_kind),
         pattern when is_binary(pattern) <- get_field(changeset, :pattern),
         {:error, {reason, _at}} <- Regex.compile(pattern, "iu") do
      add_error(changeset, :pattern, "expressão inválida: #{reason}")
    else
      _ -> changeset
    end
  end

  defp validate_outcome(changeset) do
    category? =
      get_field(changeset, :category_id) || present?(get_field(changeset, :category_name))

    if category? || get_field(changeset, :kind_override),
      do: changeset,
      else: add_error(changeset, :category_name, "escolha uma categoria ou um tipo")
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
