defmodule CashCadence.Repo.Migrations.CreateImportBatches do
  use Ecto.Migration

  def change do
    create table(:import_batches) do
      add :source, :string, null: false
      add :format, :string, null: false
      add :bank, :string, null: false, default: "unknown"
      add :account_kind, :string
      add :file_name, :string, null: false
      add :file_sha256, :string, null: false
      add :period_start, :date
      add :period_end, :date
      add :statement_balance, :decimal, precision: 12, scale: 2
      add :counts, :map, null: false, default: %{}
      add :status, :string, null: false, default: "pending"
      add :bank_account_id, references(:bank_accounts, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:import_batches, [:file_sha256])
    create index(:import_batches, [:bank_account_id])
  end
end
