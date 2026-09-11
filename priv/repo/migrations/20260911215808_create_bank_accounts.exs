defmodule CashCadence.Repo.Migrations.CreateBankAccounts do
  use Ecto.Migration

  def change do
    create table(:bank_accounts) do
      add :name, :string, null: false
      add :bank, :string, null: false
      add :kind, :string, null: false
      add :own, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:bank_accounts, [:name])
  end
end
