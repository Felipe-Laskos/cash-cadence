defmodule CashCadenceWeb.BackupController do
  use CashCadenceWeb, :controller

  alias CashCadence.Backup

  def download(conn, _params) do
    filename = "cashcadence-backup-#{Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M")}.json"

    send_download(conn, {:binary, Backup.encode()},
      filename: filename,
      content_type: "application/json"
    )
  end
end
