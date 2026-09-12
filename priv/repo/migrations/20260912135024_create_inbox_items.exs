defmodule CashCadence.Repo.Migrations.CreateInboxItems do
  use Ecto.Migration

  def change do
    create table(:inbox_items) do
      add :external_id, :string
      add :fingerprint, :string, null: false
      add :posted_on, :date
      add :date, :date, null: false
      add :competence, :date, null: false
      add :amount, :decimal, precision: 12, scale: 2, null: false
      add :kind, :string, null: false
      add :raw_description, :string, null: false
      add :normalized_description, :string, null: false
      add :description, :string
      add :confidence, :string, null: false, default: "none"
      add :status, :string, null: false, default: "pending"
      add :flags, {:array, :string}, null: false, default: []
      add :payload, :map, null: false, default: %{}
      add :batch_id, references(:import_batches, on_delete: :delete_all), null: false
      add :bank_account_id, references(:bank_accounts, on_delete: :nilify_all)
      add :suggested_category_id, references(:categories, on_delete: :nilify_all)
      add :match_transaction_id, references(:transactions, on_delete: :nilify_all)
      add :counterpart_transaction_id, references(:transactions, on_delete: :nilify_all)
      add :transaction_id, references(:transactions, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:inbox_items, [:batch_id])
    create index(:inbox_items, [:status])
    create index(:inbox_items, [:external_id])
    create index(:inbox_items, [:fingerprint])
    create constraint(:inbox_items, :inbox_amount_must_be_positive, check: "amount > 0")
  end
end
