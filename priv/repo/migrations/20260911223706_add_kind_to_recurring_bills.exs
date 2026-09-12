defmodule CashCadence.Repo.Migrations.AddKindToRecurringBills do
  use Ecto.Migration

  def change do
    alter table(:recurring_bills) do
      add :kind, :string, null: false, default: "expense"
    end

    create index(:recurring_bills, [:kind])
  end
end
