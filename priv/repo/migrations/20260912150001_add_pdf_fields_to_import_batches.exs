defmodule CashCadence.Repo.Migrations.AddPdfFieldsToImportBatches do
  use Ecto.Migration

  def change do
    alter table(:import_batches) do
      add :raw_text, :text
      add :warnings, {:array, :string}, default: [], null: false
    end
  end
end
