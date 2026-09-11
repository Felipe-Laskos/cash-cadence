defmodule CashCadence.Repo.Migrations.CreateTransactions do
  use Ecto.Migration

  def change do
    create table(:transactions) do
      add :date, :date, null: false
      add :competence, :date, null: false
      add :kind, :string, null: false
      add :amount, :decimal, precision: 12, scale: 2, null: false
      add :description, :string
      add :raw_description, :string
      add :source, :string, null: false, default: "manual"
      add :external_id, :string
      add :fingerprint, :string
      add :deleted_at, :utc_datetime
      add :category_id, references(:categories, on_delete: :nilify_all)
      add :bank_account_id, references(:bank_accounts, on_delete: :nilify_all)
      add :reimbursement_of_id, references(:transactions, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:transactions, [:competence])
    create index(:transactions, [:date])
    create index(:transactions, [:category_id])
    create index(:transactions, [:bank_account_id])
    create unique_index(:transactions, [:source, :external_id], where: "external_id IS NOT NULL")
    create constraint(:transactions, :amount_must_be_positive, check: "amount > 0")
  end
end
