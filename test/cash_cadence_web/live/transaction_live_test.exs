defmodule CashCadenceWeb.TransactionLiveTest do
  use CashCadenceWeb.ConnCase, async: true

  import CashCadence.LedgerFixtures
  import Phoenix.LiveViewTest

  alias CashCadence.Ledger

  setup :register_and_log_in_user

  test "adds a transaction with the quick form", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/lancamentos?m=2026-05")

    view
    |> form("#transaction-form",
      transaction: %{
        date: "2026-05-22",
        kind: "expense",
        category_name: "Comida",
        description: "Padaria",
        amount: "48,82"
      }
    )
    |> render_submit()

    assert has_element?(view, "#days", "Padaria")
    assert render(view) =~ "48,82"

    [transaction] = Ledger.list_transactions(%{competence: ~D[2026-05-01]})
    assert transaction.category.name == "Comida"
    assert Decimal.equal?(transaction.amount, Decimal.new("48.82"))
  end

  test "shows validation errors", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/lancamentos?m=2026-05")

    html =
      view
      |> form("#transaction-form",
        transaction: %{date: "2026-05-22", kind: "expense", amount: "0"}
      )
      |> render_submit()

    assert html =~ "deve ser maior que 0"
    assert Ledger.list_transactions() == []
  end

  test "filters by kind and by search", %{conn: conn} do
    fuel = category_fixture(%{name: "Combustível"})

    transaction_fixture(%{
      date: ~D[2026-05-13],
      kind: :expense,
      amount: "100.00",
      category_id: fuel.id,
      description: "Posto"
    })

    transaction_fixture(%{
      date: ~D[2026-05-21],
      kind: :income,
      amount: "75.00",
      description: "Freela"
    })

    {:ok, view, _html} = live(conn, ~p"/lancamentos?m=2026-05&kind=income")
    assert has_element?(view, "#days", "Freela")
    refute has_element?(view, "#days", "Posto")

    view |> form("#filters", %{q: "posto", category: ""}) |> render_change()
    assert_patch(view, ~p"/lancamentos?kind=income&m=2026-05&q=posto")
    refute has_element?(view, "#days", "Freela")

    {:ok, view, _html} = live(conn, ~p"/lancamentos?m=2026-05&q=posto")
    assert has_element?(view, "#days", "Posto")
    refute has_element?(view, "#days", "Freela")
  end

  test "edits and deletes a transaction", %{conn: conn} do
    transaction =
      transaction_fixture(%{date: ~D[2026-05-13], amount: "100.00", description: "Posto"})

    {:ok, view, _html} = live(conn, ~p"/lancamentos?m=2026-05&edit=#{transaction.id}")
    assert has_element?(view, "#transaction-form button", "Salvar")

    view |> form("#transaction-form", transaction: %{amount: "99,00"}) |> render_submit()
    assert_patch(view, ~p"/lancamentos?m=2026-05")
    assert render(view) =~ "Lançamento atualizado."
    assert Decimal.equal?(Ledger.get_transaction!(transaction.id).amount, Decimal.new("99.00"))

    view |> element("button[phx-value-id='#{transaction.id}']") |> render_click()
    refute has_element?(view, "#days", "Posto")
    assert render(view) =~ "Lançamento excluído."
    assert Ledger.list_transactions() == []
  end

  test "prefills the quick form from the query string", %{conn: conn} do
    {:ok, view, _html} =
      live(
        conn,
        ~p"/lancamentos?m=2026-05&new=1&kind=expense&category_name=Combust%C3%ADvel&amount=350%2C00"
      )

    assert has_element?(view, "#transaction_category_name[value='Combustível']")
    assert has_element?(view, "#transaction_amount[value='350,00']")
  end

  test "saves an explicit competence month and shows it on the row", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/lancamentos?m=2026-06")

    view
    |> form("#transaction-form",
      transaction: %{
        date: "2026-05-30",
        kind: "expense",
        category_name: "Comida",
        amount: "10,00",
        competence_month: "2026-06"
      }
    )
    |> render_submit()

    [transaction] = Ledger.list_transactions(%{competence: ~D[2026-06-01]})
    assert transaction.date == ~D[2026-05-30]
    assert has_element?(view, "#days", "comp. jun/26")
  end

  test "links an income as reimbursement of an expense and undoes it", %{conn: conn} do
    food = category_fixture(%{name: "Comida"})

    dinner =
      transaction_fixture(%{
        date: ~D[2026-05-10],
        amount: "120.00",
        category_id: food.id,
        description: "Jantar"
      })

    refund = transaction_fixture(%{date: ~D[2026-05-12], kind: :income, amount: "60.00"})

    {:ok, view, _html} = live(conn, ~p"/lancamentos?m=2026-05")
    view |> element("a[aria-label='É reembolso']") |> render_click()
    assert_patch(view, ~p"/lancamentos?m=2026-05&reimburse=#{refund.id}")
    assert has_element?(view, "#reimbursement-form option", "Jantar")

    view |> form("#reimbursement-form", %{expense_id: dinner.id}) |> render_submit()
    assert_patch(view, ~p"/lancamentos?m=2026-05")
    html = render(view)
    assert html =~ "Reembolso ligado"
    assert html =~ "reembolso de"
    assert html =~ "reembolsado 60,00"
    assert html =~ "já descontados"
    assert Ledger.get_transaction!(refund.id).reimbursement_of_id == dinner.id

    view |> element("button[aria-label='Desfazer reembolso']") |> render_click()
    assert Ledger.get_transaction!(refund.id).reimbursement_of_id == nil
  end
end
