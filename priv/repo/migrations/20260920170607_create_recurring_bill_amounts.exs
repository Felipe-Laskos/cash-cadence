defmodule CashCadence.Repo.Migrations.CreateRecurringBillAmounts do
  use Ecto.Migration

  def change do
    create table(:recurring_bill_amounts) do
      add :recurring_bill_id, references(:recurring_bills, on_delete: :delete_all), null: false
      add :starts_on, :date, null: false
      add :expected_amount, :decimal, precision: 12, scale: 2, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:recurring_bill_amounts, [:recurring_bill_id, :starts_on])
  end
end
