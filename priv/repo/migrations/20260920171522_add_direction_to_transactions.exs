defmodule CashCadence.Repo.Migrations.AddDirectionToTransactions do
  use Ecto.Migration

  def change do
    alter table(:transactions) do
      add :direction, :string
    end
  end
end
