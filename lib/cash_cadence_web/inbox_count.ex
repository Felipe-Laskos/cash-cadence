defmodule CashCadenceWeb.InboxCount do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  alias CashCadence.Imports

  def on_mount(:default, _params, _session, socket) do
    {:cont, assign(socket, :inbox_count, Imports.count_pending())}
  end
end
