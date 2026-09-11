defmodule CashCadence.Repo.Migrations.CreateRecurringBills do
  use Ecto.Migration

  def change do
    create table(:recurring_bills) do
      add :name, :string, null: false
      add :expected_amount, :decimal, precision: 12, scale: 2, null: false
      add :due_day, :integer
      add :active, :boolean, null: false, default: true
      add :category_id, references(:categories, on_delete: :restrict), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:recurring_bills, [:name])
    create index(:recurring_bills, [:category_id])
  end
end
