defmodule CashCadenceWeb.LayoutsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  defp flash_group(flash) do
    CashCadenceWeb.Layouts.flash_group(%{__changed__: nil, id: "flash-group", flash: flash})
    |> rendered_to_string()
    |> LazyHTML.from_fragment()
  end

  defp autohide(document, id) do
    document
    |> LazyHTML.query("##{id}")
    |> LazyHTML.attribute("data-autohide")
  end

  test "notices dismiss themselves after a few seconds" do
    document = flash_group(%{"info" => "Salvo.", "error" => "Deu ruim."})

    assert autohide(document, "flash-info") == ["5000"]
    assert autohide(document, "flash-error") == ["8000"]
  end

  test "connection warnings stay until the connection is back" do
    document = flash_group(%{})

    assert autohide(document, "client-error") == []
    assert autohide(document, "server-error") == []
  end
end
