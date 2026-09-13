defmodule CashCadence.Classifier.Memory do
  @moduledoc false

  use Ecto.Schema

  alias CashCadence.Ledger.Category

  schema "category_memory" do
    field :normalized_description, :string
    field :uses, :integer, default: 1
    field :last_used_at, :utc_datetime

    belongs_to :category, Category

    timestamps(type: :utc_datetime)
  end
end
