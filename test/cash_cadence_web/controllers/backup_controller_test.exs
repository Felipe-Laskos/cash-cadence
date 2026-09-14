defmodule CashCadenceWeb.BackupControllerTest do
  use CashCadenceWeb.ConnCase, async: true

  import CashCadence.LedgerFixtures

  setup :register_and_log_in_user

  test "downloads the full backup as JSON", %{conn: conn} do
    category_fixture(%{name: "Comida"})
    conn = get(conn, ~p"/backup.json")

    assert response_content_type(conn, :json)
    [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ ~r/attachment; filename="cashcadence-backup-\d{8}-\d{4}\.json"/

    body = json_response(conn, 200)
    assert body["app"] == "CashCadence"
    assert [%{"name" => "Comida"}] = body["tables"]["categories"]
  end

  test "requires a logged in user" do
    conn = build_conn() |> get(~p"/backup.json")
    assert redirected_to(conn) == ~p"/users/log-in"
  end
end
