defmodule CashCadence.Repo.Migrations.CreateDuplicateDismissals do
  use Ecto.Migration

  def change do
    create table(:duplicate_dismissals) do
      add :transaction_id, references(:transactions, on_delete: :delete_all), null: false
      add :other_transaction_id, references(:transactions, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:duplicate_dismissals, [:transaction_id, :other_transaction_id])
    create index(:duplicate_dismissals, [:other_transaction_id])
  end
end
