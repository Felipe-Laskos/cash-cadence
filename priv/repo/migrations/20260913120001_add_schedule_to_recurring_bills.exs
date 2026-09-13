defmodule CashCadence.Repo.Migrations.AddScheduleToRecurringBills do
  use Ecto.Migration

  def change do
    alter table(:recurring_bills) do
      add :starts_on, :date
      add :ends_on, :date
      add :installments_total, :integer
      add :match_text, :string
    end
  end
end
