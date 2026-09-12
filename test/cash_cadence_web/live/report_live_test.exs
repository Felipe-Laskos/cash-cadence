defmodule CashCadenceWeb.ReportLiveTest do
  use CashCadenceWeb.ConnCase, async: true

  import CashCadence.LedgerFixtures
  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  setup do
    food = category_fixture(%{name: "Comida"})
    salary = category_fixture(%{name: "Salário", kind: :income})

    transaction_fixture(%{
      date: ~D[2026-03-13],
      kind: :income,
      amount: "6500.00",
      category_id: salary.id
    })

    transaction_fixture(%{
      date: ~D[2026-05-07],
      kind: :income,
      amount: "6500.00",
      category_id: salary.id
    })

    transaction_fixture(%{date: ~D[2026-03-16], amount: "30.00", category_id: food.id})
    transaction_fixture(%{date: ~D[2026-05-22], amount: "48.82", category_id: food.id})
    :ok
  end

  test "renders the monthly series, the category matrix and incomes for the latest months", %{
    conn: conn
  } do
    {:ok, view, html} = live(conn, ~p"/relatorios")

    assert html =~ "mar–mai/2026"
    assert has_element?(view, "#report-chart canvas")
    assert html =~ "13.000,00"
    assert html =~ "78,82"
    assert has_element?(view, "table td", "Comida")
    assert has_element?(view, "table td", "Salário")
    assert has_element?(view, "a[download]")
  end

  test "changes the period and anchor month", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/relatorios?p=6m&to=2026-05")
    assert render(view) =~ "dez/25–mai/26"

    view |> element("a[aria-label='Mês anterior']") |> render_click()
    assert_patch(view, ~p"/relatorios?m=2026-04&p=6m")
  end

  test "exports the period as CSV", %{conn: conn} do
    conn = get(conn, ~p"/relatorios/export.csv?from=2026-03&to=2026-05")
    assert response_content_type(conn, :csv) =~ "text/csv"
    body = response(conn, 200)
    assert body =~ "data,competencia,tipo,categoria,descricao,valor,conta,origem"
    assert body =~ "2026-05-22,2026-05,expense,Comida,,48.82,,manual"
    assert length(String.split(String.trim(body), "\n")) == 5
  end

  test "rejects an invalid export period", %{conn: conn} do
    conn = get(conn, ~p"/relatorios/export.csv?from=nope&to=2026-05")
    assert redirected_to(conn) == ~p"/relatorios"
  end
end
