defmodule CashCadence.Repo.Migrations.AddImportFieldsToTransactions do
  use Ecto.Migration

  def change do
    alter table(:transactions) do
      add :normalized_description, :string
      add :posted_on, :date
      add :import_batch_id, references(:import_batches, on_delete: :nilify_all)
    end

    create index(:transactions, [:normalized_description])
    create index(:transactions, [:import_batch_id])
    create index(:transactions, [:external_id])
  end
end
