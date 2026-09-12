defmodule CashCadence.Repo.Migrations.AddExternalRefToBankAccounts do
  use Ecto.Migration

  def change do
    alter table(:bank_accounts) do
      add :external_ref, :string
    end

    create index(:bank_accounts, [:external_ref])
  end
end
