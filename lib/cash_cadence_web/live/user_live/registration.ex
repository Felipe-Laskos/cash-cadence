defmodule CashCadenceWeb.UserLive.Registration do
  use CashCadenceWeb, :live_view

  alias CashCadence.Identity
  alias CashCadence.Identity.User

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm">
        <div class="text-center">
          <.header>
            Criar conta
            <:subtitle>
              Já tem conta?
              <.link navigate={~p"/users/log-in"} class="font-semibold text-brand hover:underline">
                Entrar
              </.link>
            </:subtitle>
          </.header>
        </div>

        <.form for={@form} id="registration_form" phx-submit="save" phx-change="validate">
          <.input
            field={@form[:email]}
            type="email"
            label="E-mail"
            autocomplete="username"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />

          <.button phx-disable-with="Criando conta…" class="btn btn-primary w-full">
            Criar conta
          </.button>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, %{assigns: %{current_scope: %{user: user}}} = socket)
      when not is_nil(user) do
    {:ok, redirect(socket, to: CashCadenceWeb.UserAuth.signed_in_path(socket))}
  end

  def mount(_params, _session, socket) do
    if Identity.registration_open?() do
      changeset = Identity.change_user_email(%User{}, %{}, validate_unique: false)

      {:ok, socket |> assign(:page_title, "Criar conta") |> assign_form(changeset),
       temporary_assigns: [form: nil]}
    else
      {:ok,
       socket
       |> put_flash(:error, "O cadastro está fechado: este app é de um usuário só.")
       |> redirect(to: ~p"/users/log-in")}
    end
  end

  @impl true
  def handle_event("save", %{"user" => user_params}, socket) do
    case Identity.register_user(user_params) do
      {:ok, user} ->
        {:ok, _} =
          Identity.deliver_login_instructions(
            user,
            &url(~p"/users/log-in/#{&1}")
          )

        {:noreply,
         socket
         |> put_flash(
           :info,
           "Enviamos um e-mail para #{user.email}; abra o link para confirmar a conta."
         )
         |> push_navigate(to: ~p"/users/log-in")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset = Identity.change_user_email(%User{}, user_params, validate_unique: false)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    form = to_form(changeset, as: "user")
    assign(socket, form: form)
  end
end
