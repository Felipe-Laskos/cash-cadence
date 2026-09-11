defmodule CashCadence.LedgerFixtures do
  @moduledoc false

  alias CashCadence.Ledger

  def unique_name(prefix), do: "#{prefix} #{System.unique_integer([:positive])}"

  def category_fixture(attrs \\ %{}) do
    {:ok, category} =
      attrs
      |> Enum.into(%{name: unique_name("Categoria"), kind: :expense})
      |> Ledger.create_category()

    category
  end

  def transaction_fixture(attrs \\ %{}) do
    {:ok, transaction} =
      attrs
      |> Enum.into(%{date: ~D[2026-05-10], kind: :expense, amount: Decimal.new("10.00")})
      |> Ledger.create_transaction()

    transaction
  end

  def bank_account_fixture(attrs \\ %{}) do
    {:ok, account} =
      attrs
      |> Enum.into(%{name: unique_name("Conta"), bank: :other, kind: :checking})
      |> Ledger.create_bank_account()

    account
  end
end
