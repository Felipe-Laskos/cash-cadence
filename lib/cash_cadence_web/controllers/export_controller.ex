defmodule CashCadenceWeb.ExportController do
  use CashCadenceWeb, :controller

  import CashCadenceWeb.Format, only: [parse_month: 1, month_param: 1]

  alias CashCadence.Ledger
  alias NimbleCSV.RFC4180, as: CSV

  @header ~w(data competencia tipo categoria descricao valor conta origem)

  def transactions(conn, params) do
    with {:ok, from} <- parse_month(params["from"]),
         {:ok, to} <- parse_month(params["to"]) do
      rows = Enum.map(Ledger.export_rows(from, to), &row/1)
      body = CSV.dump_to_iodata([@header | rows])
      filename = "cashcadence-#{month_param(from)}-#{month_param(to)}.csv"

      conn
      |> put_resp_content_type("text/csv")
      |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
      |> send_resp(200, body)
    else
      _ -> conn |> put_flash(:error, "Período inválido.") |> redirect(to: ~p"/relatorios")
    end
  end

  defp row(transaction) do
    [
      Date.to_iso8601(transaction.date),
      month_param(transaction.competence),
      Atom.to_string(transaction.kind),
      (transaction.category && transaction.category.name) || "",
      transaction.description || "",
      Decimal.to_string(transaction.amount, :normal),
      (transaction.bank_account && transaction.bank_account.name) || "",
      Atom.to_string(transaction.source)
    ]
  end
end
