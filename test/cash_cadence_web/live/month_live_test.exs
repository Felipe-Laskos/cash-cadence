defmodule CashCadenceWeb.MonthLiveTest do
  use CashCadenceWeb.ConnCase, async: true

  import CashCadence.BudgetsFixtures
  import CashCadence.LedgerFixtures
  import CashCadenceWeb.Format, only: [month_title: 1]
  import Phoenix.LiveViewTest

  test "redirects anonymous users to the login page", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/")
  end

  describe "when logged in" do
    setup :register_and_log_in_user

    setup do
      food = category_fixture(%{name: "Comida"})
      transaction_fixture(%{date: ~D[2026-05-07], kind: :income, amount: "6500.00"})

      transaction_fixture(%{
        date: ~D[2026-05-22],
        kind: :expense,
        amount: "48.82",
        category_id: food.id
      })

      bill = recurring_bill_fixture(%{name: "Academia", expected_amount: "120.00"})

      transaction_fixture(%{
        date: ~D[2026-05-10],
        kind: :expense,
        amount: "60.00",
        category_id: bill.category_id
      })

      :ok
    end

    test "renders totals, charts and the fixed-expense panel", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/?m=2026-05")

      assert html =~ "Maio 2026"
      assert html =~ "6.500,00"
      assert html =~ "108,82"
      assert has_element?(view, "#monthly-chart canvas")
      assert has_element?(view, "#category-chart canvas")
      assert has_element?(view, "table td", "Academia")
      assert html =~ "Parcial · faltam 60,00"
      assert html =~ "Coberto"
    end

    test "navigates to the previous month", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/?m=2026-05")

      html = view |> element("a[aria-label='Mês anterior']") |> render_click()
      assert_patch(view, ~p"/?m=2026-04")
      assert html =~ "Abril 2026"
      assert html =~ "Nenhum lançamento em abril 2026"
    end

    test "falls back to the current month for invalid params", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/?m=nope")
      assert html =~ month_title(Date.utc_today())
    end
  end
end
