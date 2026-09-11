defmodule CashCadenceWeb.UserLive.RegistrationTest do
  use CashCadenceWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import CashCadence.IdentityFixtures

  describe "Registration page" do
    test "renders registration page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/register")

      assert html =~ "Criar conta"
      assert html =~ "Entrar"
    end

    test "redirects if already logged in", %{conn: conn} do
      result =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/register")
        |> follow_redirect(conn, ~p"/")

      assert {:ok, _conn} = result
    end

    test "renders errors for invalid data", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      result =
        lv
        |> element("#registration_form")
        |> render_change(user: %{"email" => "with spaces"})

      assert result =~ "Criar conta"
      assert result =~ "precisa ter @ e nenhum espaço"
    end
  end

  describe "register user" do
    test "creates account but does not log in", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      email = unique_user_email()
      form = form(lv, "#registration_form", user: valid_user_attributes(email: email))

      {:ok, _lv, html} =
        render_submit(form)
        |> follow_redirect(conn, ~p"/users/log-in")

      assert html =~
               ~r/Enviamos um e-mail para .*; abra o link para confirmar a conta/
    end

    test "renders errors for duplicated email", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      user = user_fixture(%{email: "test@email.com"})

      result =
        lv
        |> form("#registration_form",
          user: %{"email" => user.email}
        )
        |> render_submit()

      assert result =~ "já está em uso"
    end
  end

  describe "registration navigation" do
    test "redirects to login page when the Log in button is clicked", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      {:ok, _login_live, login_html} =
        lv
        |> element("main a", "Entrar")
        |> render_click()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert login_html =~ "Entrar"
    end
  end
end
