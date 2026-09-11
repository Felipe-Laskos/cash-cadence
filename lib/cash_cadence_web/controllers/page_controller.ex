defmodule CashCadenceWeb.PageController do
  use CashCadenceWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
