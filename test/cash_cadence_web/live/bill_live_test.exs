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

  test "opens the bill form in a modal and closes it", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/fixas?m=2026-05")
    refute has_element?(view, "#bill-modal")

    {:ok, view, _html} = live(conn, ~p"/fixas?m=2026-05&new=1")
    assert has_element?(view, "#bill-modal #bill-form")
    assert has_element?(view, "#bill-modal", "Nova despesa fixa")

    view |> element("#bill-modal-close") |> render_click()
    assert_patch(view, ~p"/fixas?m=2026-05")
    refute has_element?(view, "#bill-modal")
  end

  test "offers the income form from the header and from the income card", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/fixas?m=2026-05")

    assert has_element?(view, "#new-income-bill-card", "Nova receita fixa")

    view |> element("#new-income-bill", "Nova receita fixa") |> render_click()

    assert_patch(view, ~p"/fixas?kind=income&m=2026-05&new=1")
    assert has_element?(view, "#bill-modal", "Nova receita fixa")
    assert has_element?(view, "#bill-form option[value='income'][selected]")
    assert has_element?(view, "#bill-form", "Dia do recebimento")
  end

  test "creates an expected income from the income form", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/fixas?m=2026-05&new=1&kind=income")

    view
    |> form("#bill-form",
      recurring_bill: %{
        name: "Salário",
        kind: "income",
        category_name: "Salário",
        expected_amount: "6.500,00"
      }
    )
    |> render_submit()

    assert_patch(view, ~p"/fixas?m=2026-05")
    assert render(view) =~ "Receita fixa salva."
    [bill] = Budgets.list_recurring_bills()
    assert bill.kind == :income
    assert bill.category.kind == :income
    assert has_element?(view, "#income-#{bill.id}", "Sem recebimento")
    refute has_element?(view, "#bill-#{bill.id}")
  end

  test "edits and deletes an expected income from its row", %{conn: conn} do
    salary = category_fixture(%{name: "Salário", kind: :income})

    income =
      recurring_bill_fixture(%{
        name: "Salário",
        kind: :income,
        expected_amount: "6500.00",
        category_id: salary.id
      })

    {:ok, view, _html} = live(conn, ~p"/fixas?m=2026-05")

    view |> element("#income-#{income.id} a[aria-label='Editar']") |> render_click()
    assert has_element?(view, "#bill-modal", "Editar receita fixa")

    view
    |> form("#bill-form", recurring_bill: %{expected_amount: "6.700,00"})
    |> render_submit()

    assert has_element?(view, "#amount-decision")
    view |> element("#amount-correct") |> render_click()

    assert Decimal.equal?(
             Budgets.get_recurring_bill!(income.id).expected_amount,
             Decimal.new("6700.00")
           )

    view |> element("#income-#{income.id} button[aria-label='Excluir']") |> render_click()
    assert render(view) =~ "Receita fixa excluída."
    refute has_element?(view, "#income-#{income.id}")
  end

  test "changes the amount from the open month and leaves the earlier ones alone", %{conn: conn} do
    fuel = recurring_bill_fixture(%{name: "Combustível", expected_amount: "500.00"})
    transaction_fixture(%{date: ~D[2026-08-12], amount: "300.00", category_id: fuel.category_id})

    {:ok, view, _html} = live(conn, ~p"/fixas?m=2026-09&edit=#{fuel.id}")

    view
    |> form("#bill-form", recurring_bill: %{expected_amount: "250,00"})
    |> render_submit()

    assert has_element?(view, "#amount-decision")
    assert has_element?(view, "#amount-from", "Mudou a partir de set/26")

    view |> element("#amount-from") |> render_click()

    assert render(view) =~ "O novo valor vale de set/26 em diante."
    assert has_element?(view, "#bill-#{fuel.id}", "250,00")

    {:ok, august, _html} = live(conn, ~p"/fixas?m=2026-08")
    assert has_element?(august, "#bill-#{fuel.id}", "500,00")
    assert has_element?(august, "#bill-#{fuel.id}", "Parcial · faltam 200,00")
  end

  test "records and removes a value in the history", %{conn: conn} do
    bill = recurring_bill_fixture(%{name: "Aluguel", expected_amount: "1000.00"})

    {:ok, view, _html} = live(conn, ~p"/fixas?m=2026-09&edit=#{bill.id}")
    assert has_element?(view, "#bill-amounts", "Um valor só")

    view
    |> form("#bill-form", new_amount: %{month: "2026-05", value: "1.200,00"})
    |> render_change()

    view |> element("#add-bill-amount") |> render_click()

    view
    |> form("#bill-form", new_amount: %{month: "2026-09", value: "1.500,00"})
    |> render_change()

    view |> element("#add-bill-amount") |> render_click()

    [may, september] = Budgets.list_bill_amounts(bill)
    assert has_element?(view, "#bill-amount-#{may.id}", "até ago/26")
    assert has_element?(view, "#bill-amount-#{september.id}", "de set/26 em diante")
    assert has_element?(view, "#bill-#{bill.id}", "1.500,00")

    view
    |> element("#bill-amount-#{september.id} button[aria-label='Remover valor']")
    |> render_click()

    assert has_element?(view, "#bill-#{bill.id}", "1.200,00")
    refute has_element?(view, "#bill-amount-#{september.id}")
  end

  test "ends a bill from the open month and keeps the earlier ones", %{conn: conn} do
    bill = recurring_bill_fixture(%{name: "Academia", expected_amount: "120.00"})

    {:ok, view, _html} = live(conn, ~p"/fixas?m=2026-09")
    view |> element("#bill-#{bill.id} button[aria-label='Encerrar']") |> render_click()

    assert render(view) =~ "encerrada em ago/26"
    refute has_element?(view, "#bill-#{bill.id}")

    {:ok, august, _html} = live(conn, ~p"/fixas?m=2026-08")
    assert has_element?(august, "#bill-#{bill.id}")
  end

  test "wires the category field to the suggestion combobox", %{conn: conn} do
    category_fixture(%{name: "Combustível"})

    {:ok, view, _html} = live(conn, ~p"/fixas?m=2026-05&new=1")

    field = "#bill-form input[phx-hook='Combobox'][role='combobox']"

    assert has_element?(view, field)
    assert has_element?(view, "#bill-form ul[role='listbox']")
    assert render(element(view, field)) =~ "Combustível"
  end
end
