defmodule CashCadenceWeb.DuplicateLiveTest do
  use CashCadenceWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import CashCadence.LedgerFixtures

  alias CashCadence.Ledger

  setup :register_and_log_in_user

  defp pair_of_duplicates do
    food = category_fixture(%{name: "Comida"})

    sheet =
      transaction_fixture(%{
        date: ~D[2026-05-10],
        amount: "48.82",
        description: "Padaria",
        category_id: food.id
      })

    bank =
      transaction_fixture(%{
        date: ~D[2026-05-11],
        amount: "48.82",
        source: :import,
        category_id: food.id,
        description: "Pix QR: PADARIA",
        normalized_description: "PIX QRS PADARIA EXEMPLO"
      })

    {sheet, bank}
  end

  test "lists nothing when the ledger is clean", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/duplicatas")

    assert has_element?(view, "#duplicate-pairs")
    refute has_element?(view, "[id^='pair-']")
  end

  test "shows the pending count on the sidebar", %{conn: conn} do
    {sheet, bank} = pair_of_duplicates()

    {:ok, view, _html} = live(conn, ~p"/lancamentos")
    assert render(view) =~ "Duplicatas"
    assert has_element?(view, "a[href='/duplicatas'] .badge", "1")

    {:ok, duplicates, _html} = live(conn, ~p"/duplicatas")

    duplicates
    |> element("#pair-#{sheet.id}-#{bank.id} button[phx-value-keep='#{bank.id}']")
    |> render_click()

    refute has_element?(duplicates, "a[href='/duplicatas'] .badge")
  end

  test "keeps the chosen side and deletes the other", %{conn: conn} do
    {sheet, bank} = pair_of_duplicates()

    {:ok, view, _html} = live(conn, ~p"/duplicatas")
    assert has_element?(view, "#pair-#{sheet.id}-#{bank.id}")

    view
    |> element("#pair-#{sheet.id}-#{bank.id} button[phx-value-keep='#{bank.id}']")
    |> render_click()

    refute has_element?(view, "#pair-#{sheet.id}-#{bank.id}")
    assert Ledger.get_transaction!(bank.id)
    assert_raise Ecto.NoResultsError, fn -> Ledger.get_transaction!(sheet.id) end
  end

  test "dismissing the pair takes it off the list", %{conn: conn} do
    {sheet, bank} = pair_of_duplicates()

    {:ok, view, _html} = live(conn, ~p"/duplicatas")

    view
    |> element("#pair-#{sheet.id}-#{bank.id} button[phx-click='dismiss']")
    |> render_click()

    refute has_element?(view, "#pair-#{sheet.id}-#{bank.id}")
    assert Ledger.get_transaction!(sheet.id)
    assert Ledger.get_transaction!(bank.id)
  end
end
