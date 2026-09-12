defmodule CashCadenceWeb.CategoryLiveTest do
  use CashCadenceWeb.ConnCase, async: true

  import CashCadence.LedgerFixtures
  import Phoenix.LiveViewTest

  alias CashCadence.Ledger

  setup :register_and_log_in_user

  test "lists categories with usage stats per tab", %{conn: conn} do
    food = category_fixture(%{name: "Comida"})
    salary = category_fixture(%{name: "Salário", kind: :income})
    transaction_fixture(%{date: ~D[2026-04-10], amount: "100.00", category_id: food.id})
    transaction_fixture(%{date: ~D[2026-05-10], amount: "50.00", category_id: food.id})

    transaction_fixture(%{
      date: ~D[2026-05-07],
      kind: :income,
      amount: "6500.00",
      category_id: salary.id
    })

    transaction_fixture(%{date: ~D[2026-05-08], amount: "9.50"})

    {:ok, view, html} = live(conn, ~p"/categorias")

    assert has_element?(view, "#category-#{food.id}", "150,00")
    assert has_element?(view, "#category-#{food.id}", "75,00")
    refute has_element?(view, "#category-#{salary.id}")
    assert html =~ "lançamento está</span> sem categoria" or html =~ "sem categoria"

    view |> element("a", "Receitas · 1") |> render_click()
    assert_patch(view, ~p"/categorias?tab=income")
    assert has_element?(view, "#category-#{salary.id}", "6.500,00")
  end

  test "creates and edits a category", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/categorias?new=1")

    view
    |> form("#category-form", category: %{name: "Mercado", kind: "expense"})
    |> render_submit()

    assert render(view) =~ "Categoria “Mercado” salva."
    [category] = Ledger.list_categories()

    {:ok, view, _html} = live(conn, ~p"/categorias?edit=#{category.id}")
    view |> form("#category-form", category: %{name: "Supermercado"}) |> render_submit()
    assert Ledger.get_category!(category.id).name == "Supermercado"
  end

  test "archives, reactivates and merges categories", %{conn: conn} do
    tim = category_fixture(%{name: "Tim"})
    upper = category_fixture(%{name: "Telefonia"})
    transaction_fixture(%{date: ~D[2026-05-04], amount: "41.99", category_id: tim.id})

    {:ok, view, _html} = live(conn, ~p"/categorias")
    view |> element("#category-#{upper.id} button[aria-label='Arquivar']") |> render_click()
    refute has_element?(view, "#category-#{upper.id}")

    {:ok, view, _html} = live(conn, ~p"/categorias?tab=archived")
    view |> element("#category-#{upper.id} button", "Reativar") |> render_click()
    assert Ledger.get_category!(upper.id).archived_at == nil

    {:ok, view, _html} = live(conn, ~p"/categorias?merge=#{tim.id}")
    view |> form("#merge-form", %{target_id: upper.id}) |> render_submit()
    assert_patch(view, ~p"/categorias?tab=expense")
    assert render(view) =~ "foi mesclada em"
    assert [%{category_id: id}] = Ledger.list_transactions()
    assert id == upper.id
    assert Ledger.get_category!(tim.id).archived_at != nil
  end
end
