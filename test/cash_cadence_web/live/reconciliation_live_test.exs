defmodule CashCadenceWeb.ReconciliationLiveTest do
  use CashCadenceWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import CashCadence.LedgerFixtures

  alias CashCadence.Imports.Batch
  alias CashCadence.Repo

  setup :register_and_log_in_user

  defp statement(account, period_end, balance) do
    Repo.insert!(%Batch{
      source: :upload,
      format: :pdf,
      bank: :itau,
      file_name: "extrato-#{period_end}.pdf",
      file_sha256: "sha-#{period_end}",
      period_end: period_end,
      statement_balance: Decimal.new(balance),
      bank_account_id: account.id
    })
  end

  test "explains how to get a check when there is only one statement", %{conn: conn} do
    account = bank_account_fixture(%{name: "Conta", kind: :checking})
    statement(account, ~D[2026-04-30], "1000.00")

    {:ok, _view, html} = live(conn, ~p"/conferencia")
    assert html =~ "dois extratos importados"
  end

  test "shows the interval between two statements and whether it closes", %{conn: conn} do
    account = bank_account_fixture(%{name: "Conta corrente", kind: :checking})
    statement(account, ~D[2026-04-30], "1000.00")
    statement(account, ~D[2026-05-31], "1200.00")

    transaction_fixture(%{
      date: ~D[2026-05-10],
      kind: :income,
      amount: "200.00",
      bank_account_id: account.id,
      category_id: category_fixture(%{name: "Salário", kind: :income}).id
    })

    {:ok, view, html} = live(conn, ~p"/conferencia")

    assert html =~ "Conta corrente"
    assert html =~ "30/04"
    assert html =~ "fecha"
    refute has_element?(view, "a[href='/duplicatas'] .badge")
  end
end
