defmodule CashCadenceWeb.InboxLiveTest do
  use CashCadenceWeb.ConnCase, async: true

  import CashCadence.LedgerFixtures
  import Phoenix.LiveViewTest

  alias CashCadence.{Imports, Ledger}

  @fixtures Path.expand("../../support/fixtures/imports", __DIR__)

  setup :register_and_log_in_user

  test "shows the empty state and the sidebar badge", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/entrada")
    assert html =~ "Nada pendente"
    refute has_element?(view, "aside .badge-primary")
  end

  describe "with pending items" do
    setup do
      food = category_fixture(%{name: "Comida"})

      manual =
        transaction_fixture(%{
          date: ~D[2026-05-22],
          amount: "48.82",
          category_id: food.id,
          description: "Padaria"
        })

      {:ok, batch} = Imports.ingest_file(Path.join(@fixtures, "nubank_conta.ofx"))
      %{batch: batch, manual: manual, items: Imports.list_inbox()}
    end

    test "lists items with their proposals and the pending badge", %{
      conn: conn,
      items: [bakery, tax, income]
    } do
      {:ok, view, html} = live(conn, ~p"/entrada")

      assert html =~ "3 itens aguardam sua revisão"
      assert has_element?(view, "aside .badge-primary", "3")
      assert has_element?(view, "#item-#{bakery.id}", "Compra no débito - PADARIA EXEMPLO")
      assert has_element?(view, "#item-#{bakery.id} button", "Conciliar")
      assert has_element?(view, "#item-#{tax.id} button", "Aprovar")
      assert has_element?(view, "#item-#{income.id}", "R$ 1.000,00")
    end

    test "approves an item with a category typed in the form", %{
      conn: conn,
      items: [_bakery, tax, _income]
    } do
      {:ok, view, _html} = live(conn, ~p"/entrada")

      view
      |> form("#item-#{tax.id}-form",
        item: %{kind: "expense", category_name: "DAS", description: "Simples Nacional"}
      )
      |> render_submit()

      refute has_element?(view, "#item-#{tax.id}")
      assert render(view) =~ "aprovado"
      [transaction] = Ledger.list_transactions(%{competence: ~D[2026-05-01], search: "Simples"})
      assert transaction.category.name == "DAS"
      assert transaction.external_id == tax.external_id
      assert has_element?(view, "aside .badge-primary", "2")
    end

    test "reconciles with the manual transaction and ignores another item", %{
      conn: conn,
      items: [bakery, _tax, income],
      manual: manual
    } do
      {:ok, view, _html} = live(conn, ~p"/entrada")

      view |> element("#item-#{bakery.id} button", "Conciliar") |> render_click()
      refute has_element?(view, "#item-#{bakery.id}")
      assert Ledger.get_transaction!(manual.id).external_id == bakery.external_id

      view |> element("#item-#{income.id} button", "Ignorar") |> render_click()
      refute has_element?(view, "#item-#{income.id}")
      assert Imports.count_pending() == 1
    end

    test "filters by batch and bulk-approves confident items", %{conn: conn, batch: batch} do
      {:ok, view, html} = live(conn, ~p"/entrada?batch=#{batch.id}")
      assert html =~ batch.file_name
      refute has_element?(view, "button", "com alta confiança")
    end
  end
end
