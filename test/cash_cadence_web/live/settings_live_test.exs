defmodule CashCadenceWeb.SettingsLiveTest do
  use CashCadenceWeb.ConnCase, async: false

  import CashCadence.LedgerFixtures
  import Phoenix.LiveViewTest

  alias CashCadence.{Classifier, Imports, Ledger}

  @fixtures Path.expand("../../support/fixtures/imports", __DIR__)

  setup :register_and_log_in_user

  test "renders every section with its empty state", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/configuracoes")
    assert html =~ "Nenhuma importação ainda."
    assert html =~ "Nenhuma regra ainda."
    assert html =~ "Nada aprendido ainda."
    assert has_element?(view, "#conta", "Alterar e-mail ou senha")
    assert has_element?(view, "#backup a", "Lançamentos (CSV)")
    assert has_element?(view, "#backup a[href='/backup.json']", "Baixar backup completo")
    assert has_element?(view, "#celular", "Adicionar à tela inicial")
    assert has_element?(view, "aside a.btn-active", "Configurações")
  end

  test "creates a rule, reclassifies pending items and shows the preview", %{conn: conn} do
    {:ok, _batch} = Imports.ingest_file(Path.join(@fixtures, "nubank_conta.ofx"))

    {:ok, view, _html} = live(conn, ~p"/configuracoes?rule=new")

    view
    |> form("#rule-form",
      rule: %{
        pattern: "receita federal",
        match_kind: "contains",
        category_name: "Impostos",
        kind_override: ""
      }
    )
    |> render_submit()

    assert_patch(view, ~p"/configuracoes")
    assert render(view) =~ "Regra salva. 1 item pendente foi reclassificado."

    [rule] = Classifier.list_rules()
    assert has_element?(view, "#rule-#{rule.id}", "contém “receita federal”")
    assert has_element?(view, "#rule-#{rule.id}", "Impostos")
    assert has_element?(view, "#rule-#{rule.id}", "0 lançamentos · 1 pendente")

    tax = Enum.find(Imports.list_inbox(), &Decimal.equal?(&1.amount, Decimal.new("390.00")))
    assert tax.suggested_category_id == rule.category_id

    view |> element("#rule-#{rule.id} input[type=checkbox]") |> render_click()
    assert render(view) =~ "Regra desativada. 1 item pendente foi reclassificado."
    refute Classifier.get_rule!(rule.id).active

    view |> element("#rule-#{rule.id} button[aria-label='Excluir']") |> render_click()
    assert Classifier.list_rules() == []
  end

  test "shows validation errors on the rule form", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/configuracoes?rule=new")
    html = view |> form("#rule-form", rule: %{pattern: "POSTO"}) |> render_submit()
    assert html =~ "escolha uma categoria ou um tipo"
    assert Classifier.list_rules() == []
  end

  test "manages bank accounts and their file links", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/configuracoes?account=new")

    view
    |> form("#account-form", bank_account: %{name: "Conta teste", bank: "itau", kind: "checking"})
    |> render_submit()

    assert render(view) =~ "Conta “Conta teste” salva."
    [account] = Ledger.list_bank_accounts()
    assert has_element?(view, "#account-#{account.id}", "liga no próximo arquivo")

    {:ok, _} = Ledger.update_bank_account(account, %{external_ref: "0001/12345-6"})
    {:ok, view, _html} = live(conn, ~p"/configuracoes")
    assert has_element?(view, "#account-#{account.id}", "0001/12345-6")
    view |> element("#account-#{account.id} button", "esquecer") |> render_click()
    assert Ledger.get_bank_account!(account.id).external_ref == nil

    {:ok, view, _html} = live(conn, ~p"/configuracoes?account=#{account.id}")
    view |> form("#account-form", bank_account: %{name: "Conta renomeada"}) |> render_submit()
    assert Ledger.get_bank_account!(account.id).name == "Conta renomeada"

    view |> element("#account-#{account.id} button[aria-label='Excluir']") |> render_click()
    assert Ledger.list_bank_accounts() == []
  end

  test "lists, searches and forgets learned descriptions", %{conn: conn} do
    food = category_fixture(%{name: "Padarias"})
    :ok = Classifier.learn("PIX QRS PADARIA EXEMPLO", food.id)
    :ok = Classifier.learn("PIX QRS POSTO EXEMPLO", food.id)

    {:ok, view, html} = live(conn, ~p"/configuracoes")
    assert html =~ "2 descrições aprendidas"
    assert has_element?(view, "#memoria td", "PIX QRS PADARIA EXEMPLO")

    view |> form("#memory-search", q: "posto") |> render_change()
    assert_patch(view, ~p"/configuracoes?q=posto")
    refute has_element?(view, "#memoria td", "PIX QRS PADARIA EXEMPLO")
    assert has_element?(view, "#memoria td", "PIX QRS POSTO EXEMPLO")

    [memory] = Classifier.list_memory("posto")
    view |> element("#memory-#{memory.id} button", "Esquecer") |> render_click()
    assert Classifier.count_memory() == 1
  end

  test "stores the card competence mode", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/configuracoes?account=new")

    view
    |> form("#account-form",
      bank_account: %{
        name: "Cartão teste",
        bank: "itau",
        kind: "credit_card",
        competence_mode: "statement_month"
      }
    )
    |> render_submit()

    [account] = Ledger.list_bank_accounts()
    assert account.competence_mode == :statement_month
    assert has_element?(view, "#account-#{account.id}", "mês da fatura")
  end

  test "toggles automatic approval and runs a backup on demand", %{conn: conn} do
    dir = CashCadence.Backup.Scheduler.config() |> Keyword.fetch!(:dir)
    File.rm_rf!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, view, html} = live(conn, ~p"/configuracoes")
    assert html =~ "Backup automático desligado"
    assert html =~ "Nenhum backup automático gravado ainda."
    refute CashCadence.Settings.auto_approve?()

    view |> element("#auto-approve") |> render_click()
    assert render(view) =~ "passam a ser aprovados na importação"
    assert CashCadence.Settings.auto_approve?()

    view |> element("#auto-backup button", "Fazer backup agora") |> render_click()
    assert render(view) =~ "Backup gravado em"
    assert [_file] = CashCadence.Backup.list_files(dir)
    assert has_element?(view, "#auto-backup li", "cashcadence-")
  end

  test "opens the account and rule forms in modals", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/configuracoes")
    refute has_element?(view, "#account-modal")
    refute has_element?(view, "#rule-modal")

    {:ok, view, _html} = live(conn, ~p"/configuracoes?account=new")
    assert has_element?(view, "#account-modal #account-form")

    view |> element("#account-modal-close") |> render_click()
    assert_patch(view, ~p"/configuracoes")
    refute has_element?(view, "#account-modal")

    {:ok, view, _html} = live(conn, ~p"/configuracoes?rule=new")
    assert has_element?(view, "#rule-modal #rule-form")
  end

  test "wires the rule category field to the suggestion combobox", %{conn: conn} do
    category_fixture(%{name: "Combustível"})

    {:ok, view, _html} = live(conn, ~p"/configuracoes?rule=new")

    field = "#rule-form input[phx-hook='Combobox'][role='combobox']"

    assert has_element?(view, field)
    assert has_element?(view, "#rule-form ul[role='listbox']")
    assert render(element(view, field)) =~ "Combustível"
  end
end
