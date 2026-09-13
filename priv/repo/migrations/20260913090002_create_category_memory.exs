defmodule CashCadence.Repo.Migrations.CreateCategoryMemory do
  use Ecto.Migration

  def up do
    create table(:category_memory) do
      add :normalized_description, :string, null: false
      add :category_id, references(:categories, on_delete: :delete_all), null: false
      add :uses, :integer, null: false, default: 1
      add :last_used_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:category_memory, [:normalized_description])
    create index(:category_memory, [:category_id])

    execute """
    INSERT INTO category_memory (normalized_description, category_id, uses, last_used_at, inserted_at, updated_at)
    SELECT DISTINCT ON (normalized_description)
           normalized_description, category_id, COUNT(*), MAX(date)::timestamp, NOW(), NOW()
    FROM transactions
    WHERE normalized_description IS NOT NULL AND normalized_description <> ''
      AND category_id IS NOT NULL AND deleted_at IS NULL
    GROUP BY normalized_description, category_id
    ORDER BY normalized_description, COUNT(*) DESC, MAX(date) DESC
    """
  end

  def down do
    drop table(:category_memory)
  end
end
