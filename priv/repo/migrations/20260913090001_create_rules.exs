defmodule CashCadence.Repo.Migrations.CreateRules do
  use Ecto.Migration

  def change do
    create table(:rules) do
      add :position, :integer, null: false
      add :pattern, :string, null: false
      add :match_kind, :string, null: false, default: "contains"
      add :target, :string, null: false, default: "description"
      add :category_id, references(:categories, on_delete: :nilify_all)
      add :kind_override, :string
      add :active, :boolean, null: false, default: true
      add :hits, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:rules, [:position])
    create index(:rules, [:category_id])
  end
end
