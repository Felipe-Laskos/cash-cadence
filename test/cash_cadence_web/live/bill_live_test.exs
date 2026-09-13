defmodule CashCadenceWeb.BillLiveTest do
  use CashCadenceWeb.ConnCase, async: true

  import CashCadence.BudgetsFixtures
  import CashCadence.LedgerFixtures
  import Phoenix.LiveViewTest

  alias CashCadence.Budgets

  setup :register_and_log_in_user

  test "renders the panel with statuses, expected incomes and adherence", %{conn: conn} do
    fuel = recurring_bill_fixture(%{name: "Combustível", expected_amount: "450.00"})
    transaction_fixture(%{date: ~D[2026-05-13], amount: "100.00", category_id: fuel.category_id})
    salary = category_fixture(%{name: "Salário", kind: :income})

    recurring_bill_fixture(%{
      name: "Salário",
      kind: :income,
      expected_amount: "6500.00",
      category_id: salary.id
    })

    transaction_fixture(%{
      date: ~D[2026-05-07],
      kind: :income,
      amount: "6500.00",
      category_id: salary.id
    })

    {:ok, view, html} = live(conn, ~p"/fixas?m=2026-05")

    assert html =~ "Despesas fixas"
    assert has_element?(view, "#bill-#{fuel.id}", "Parcial · faltam 350,00")
    assert html =~ "Recebido em 07/05"
    assert html =~ "mai/26"
    assert has_element?(view, "a", "Lançar pagamento")
    assert html =~ "Coberto"
  end

  test "creates a bill with a new category from the form", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/fixas?m=2026-05&new=1")

    view
    |> form("#bill-form",
      recurring_bill: %{
        name: "Internet",
        kind: "expense",
        category_name: "Internet",
        expected_amount: "99,90",
        due_day: "10"
      }
    )
    |> render_submit()

    assert_patch(view, ~p"/fixas?m=2026-05")
    assert render(view) =~ "Despesa fixa salva."
    [bill] = Budgets.list_recurring_bills()
    assert bill.name == "Internet"
    assert bill.due_day == 10
    assert bill.category.name == "Internet"
    assert Decimal.equal?(bill.expected_amount, Decimal.new("99.90"))
  end

  test "adjusts the expected amount and deletes a bill", %{conn: conn} do
    phone = recurring_bill_fixture(%{name: "Telefone", expected_amount: "40.00"})
    transaction_fixture(%{date: ~D[2026-05-04], amount: "41.99", category_id: phone.category_id})

    {:ok, view, _html} = live(conn, ~p"/fixas?m=2026-05")
    assert has_element?(view, "#bill-#{phone.id}", "Pago · 1,99 acima")

    view |> element("#bill-#{phone.id} button", "Ajustar esperado") |> render_click()

    assert Decimal.equal?(
             Budgets.get_recurring_bill!(phone.id).expected_amount,
             Decimal.new("41.99")
           )

    assert has_element?(view, "#bill-#{phone.id}", "Pago")

    view |> element("#bill-#{phone.id} button[aria-label='Excluir']") |> render_click()
    refute has_element?(view, "#bill-#{phone.id}")
    assert Budgets.list_recurring_bills() == []
  end

  test "creates a bill with a validity window and shows installments and overdue state", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/fixas?m=2026-05&new=1")

    view
    |> form("#bill-form",
      recurring_bill: %{
        name: "Oficina",
        kind: "expense",
        category_name: "Mecânico",
        expected_amount: "208,00",
        due_day: "5",
        starts_month: "2026-04",
        ends_month: "2026-06",
        installments_total: "3",
        match_text: "oficina"
      }
    )
    |> render_submit()

    assert render(view) =~ "Despesa fixa salva."
    [bill] = Budgets.list_recurring_bills()
    assert bill.starts_on == ~D[2026-04-01]
    assert bill.ends_on == ~D[2026-06-01]
    assert bill.match_text == "OFICINA"
    assert has_element?(view, "#bill-#{bill.id}", "(2/3)")
    assert has_element?(view, "#bill-#{bill.id}", "até jun/26")
    assert has_element?(view, "#bill-#{bill.id}", "dia 5")
    assert has_element?(view, "#bill-#{bill.id}", "atrasada")

    {:ok, view, _html} = live(conn, ~p"/fixas?m=2026-07")
    refute has_element?(view, "#bill-#{bill.id}")
  end
end
