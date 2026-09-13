defmodule CashCadenceWeb.ImportLiveTest do
  use CashCadenceWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias CashCadence.Imports

  @fixtures Path.expand("../../support/fixtures/imports", __DIR__)

  setup :register_and_log_in_user

  defp upload(view, name) do
    view
    |> file_input("#import-form", :files, [
      %{
        name: name,
        content: File.read!(Path.join(@fixtures, name)),
        type: "application/octet-stream"
      }
    ])
    |> render_upload(name)
  end

  test "uploads a statement, creates a batch and goes to the inbox", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/importar")
    assert html =~ "Nenhum arquivo importado ainda."

    upload(view, "nubank_conta.ofx")
    assert has_element?(view, "#upload-entries", "nubank_conta.ofx")

    view |> form("#import-form", %{account_id: ""}) |> render_submit()
    {path, flash} = assert_redirect(view)
    [batch] = Imports.list_batches()
    assert path == ~p"/entrada?#{%{"batch" => batch.id}}"
    assert flash["info"] =~ "1 arquivo lido, 3 itens novos"

    assert batch.file_name == "nubank_conta.ofx"
    assert batch.source == :upload
  end

  test "reports files that were already imported", %{conn: conn} do
    {:ok, _batch} = Imports.ingest_file(Path.join(@fixtures, "nubank_conta.ofx"))

    {:ok, view, _html} = live(conn, ~p"/importar")
    assert has_element?(view, "#batch-#{hd(Imports.list_batches()).id}", "nubank_conta.ofx")

    upload(view, "nubank_conta.ofx")
    html = view |> form("#import-form", %{account_id: ""}) |> render_submit()
    assert html =~ "já tinha sido importado"
    assert length(Imports.list_batches()) == 1
  end

  @tag :pdftotext
  test "imports an Itaú PDF, reports warnings and shows the extracted text", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/importar")
    upload(view, "itau_extrato_divergente.pdf")
    view |> form("#import-form", %{account_id: ""}) |> render_submit()
    {path, flash} = assert_redirect(view)

    [batch] = Imports.list_batches()
    assert path == ~p"/entrada?#{%{"batch" => batch.id}}"
    assert flash["info"] =~ "7 itens novos"
    assert flash["info"] =~ "1 alerta para conferir"

    {:ok, view, html} = live(conn, ~p"/importar")
    assert html =~ "Itaú · PDF conta"
    assert has_element?(view, "#batch-#{batch.id} button", "1 alerta")

    html = view |> element("#batch-#{batch.id} button", "1 alerta") |> render_click()
    assert html =~ "Saldo de 20/05/2026 não bate"
    assert has_element?(view, "#batch-detail pre", "SALDO DO DIA")

    view |> element("#batch-detail .modal-action button", "Fechar") |> render_click()
    refute has_element?(view, "#batch-detail")
  end

  test "explains PDFs it cannot read", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/importar")
    upload(view, "outro.pdf")
    html = view |> form("#import-form", %{account_id: ""}) |> render_submit()
    assert html =~ "outro.pdf: PDF não reconhecido" or html =~ "outro.pdf: leitor de PDF"
    assert Imports.list_batches() == []
  end
end
