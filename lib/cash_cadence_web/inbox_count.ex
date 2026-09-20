defmodule CashCadenceWeb.InboxCount do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  alias CashCadence.{Duplicates, Imports}

  def on_mount(:default, _params, _session, socket) do
    {:cont,
     socket
     |> assign(:inbox_count, Imports.count_pending())
     |> assign(:duplicate_count, Duplicates.count())}
  end
end
