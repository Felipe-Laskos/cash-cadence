defmodule CashCadence.Repo.Migrations.CreateCategories do
  use Ecto.Migration

  def change do
    create table(:categories) do
      add :name, :string, null: false
      add :kind, :string, null: false
      add :color, :string
      add :fixed, :boolean, null: false, default: false
      add :archived_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:categories, ["lower(name)"], name: :categories_lower_name_index)
    create index(:categories, [:kind])
  end
end
