defmodule CashCadenceWeb.InboxLiveTest do
  use CashCadenceWeb.ConnCase, async: false

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

  test "shows the batch warnings and the extracted text when filtering by batch", %{conn: conn} do
    {:ok, batch} = Imports.ingest_file(Path.join(@fixtures, "nubank_conta.ofx"))

    batch =
      batch
      |> Ecto.Changeset.change(
        warnings: ["Saldo de 20/05/2026 não bate: o extrato mostra R$ 1,00."],
        raw_text: "TEXTO BRUTO DO EXTRATO"
      )
      |> CashCadence.Repo.update!()

    {:ok, view, html} = live(conn, ~p"/entrada?batch=#{batch.id}")
    assert html =~ "O arquivo não fechou por completo"
    assert html =~ "Saldo de 20/05/2026 não bate"
    assert has_element?(view, "details summary", "Texto extraído do arquivo")
    assert has_element?(view, "details pre", "TEXTO BRUTO DO EXTRATO")

    {:ok, _view, html} = live(conn, ~p"/entrada")
    refute html =~ "O arquivo não fechou por completo"
  end

  test "approves with a corrected date and amount", %{conn: conn} do
    {:ok, _batch} = Imports.ingest_file(Path.join(@fixtures, "nubank_conta.ofx"))

    bakery =
      Enum.find(Imports.list_inbox(), &(&1.description == "Compra no débito: PADARIA EXEMPLO"))

    {:ok, view, _html} = live(conn, ~p"/entrada")

    view
    |> form("#item-#{bakery.id}-form",
      item: %{
        kind: "expense",
        category_name: "Comida",
        description: "Padaria",
        date: "2026-04-28",
        amount: "49,90"
      }
    )
    |> render_submit()

    assert render(view) =~ "49,90 aprovado."
    [transaction] = Ledger.list_transactions()
    assert transaction.date == ~D[2026-04-28]
    assert transaction.competence == ~D[2026-04-01]
    assert Decimal.equal?(transaction.amount, Decimal.new("49.90"))
  end

  test "keeps the item when the corrected amount is invalid", %{conn: conn} do
    {:ok, _batch} = Imports.ingest_file(Path.join(@fixtures, "nubank_conta.ofx"))

    bakery =
      Enum.find(Imports.list_inbox(), &(&1.description == "Compra no débito: PADARIA EXEMPLO"))

    {:ok, view, _html} = live(conn, ~p"/entrada")

    html =
      view
      |> form("#item-#{bakery.id}-form",
        item: %{kind: "expense", category_name: "Comida", amount: "abc"}
      )
      |> render_submit()

    assert html =~ "Não foi possível aprovar"
    assert Imports.count_pending() == 3
  end

  test "wires the item category field to the suggestion combobox", %{conn: conn} do
    category_fixture(%{name: "Comida"})
    {:ok, _batch} = Imports.ingest_file(Path.join(@fixtures, "nubank_conta.ofx"))

    bakery =
      Enum.find(Imports.list_inbox(), &(&1.description == "Compra no débito: PADARIA EXEMPLO"))

    {:ok, view, _html} = live(conn, ~p"/entrada")

    field = "#item-#{bakery.id}-category[phx-hook='Combobox'][role='combobox']"

    assert has_element?(view, field)
    assert has_element?(view, "#item-#{bakery.id}-category-listbox[role='listbox']")
    assert render(element(view, field)) =~ "Comida"
  end
end
