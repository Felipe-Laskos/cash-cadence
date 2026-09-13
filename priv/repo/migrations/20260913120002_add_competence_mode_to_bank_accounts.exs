defmodule CashCadence.Repo.Migrations.AddCompetenceModeToBankAccounts do
  use Ecto.Migration

  def change do
    alter table(:bank_accounts) do
      add :competence_mode, :string, null: false, default: "purchase_date"
    end
  end
end
