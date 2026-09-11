defmodule CashCadence.Ledger.Category do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @kinds [:expense, :income, :person]

  schema "categories" do
    field :name, :string
    field :kind, Ecto.Enum, values: @kinds
    field :color, :string
    field :fixed, :boolean, default: false
    field :archived_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds

  def changeset(category, attrs) do
    category
    |> cast(attrs, [:name, :kind, :color, :fixed, :archived_at])
    |> update_change(:name, &trim/1)
    |> validate_required([:name, :kind])
    |> validate_length(:name, min: 1, max: 60)
    |> unique_constraint(:name,
      name: :categories_lower_name_index,
      message: "já existe uma categoria com esse nome"
    )
  end

  defp trim(nil), do: nil
  defp trim(name), do: String.trim(name)
end
