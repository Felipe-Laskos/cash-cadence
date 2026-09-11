defmodule CashCadence.Identity.UserNotifier do
  @moduledoc false

  import Swoosh.Email

  alias CashCadence.Identity.User
  alias CashCadence.Mailer

  defp deliver(recipient, subject, body) do
    email =
      new()
      |> to(recipient)
      |> from({"CashCadence", "contact@example.com"})
      |> subject(subject)
      |> text_body(body)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end

  def deliver_update_email_instructions(user, url) do
    deliver(user.email, "Confirmação de troca de e-mail", """

    ==============================

    Olá, #{user.email}.

    Para confirmar o novo e-mail, abra o link abaixo:

    #{url}

    Se você não pediu essa troca, ignore esta mensagem.

    ==============================
    """)
  end

  def deliver_login_instructions(user, url) do
    case user do
      %User{confirmed_at: nil} -> deliver_confirmation_instructions(user, url)
      _ -> deliver_magic_link_instructions(user, url)
    end
  end

  defp deliver_magic_link_instructions(user, url) do
    deliver(user.email, "Seu link de acesso ao CashCadence", """

    ==============================

    Olá, #{user.email}.

    Para entrar no CashCadence, abra o link abaixo:

    #{url}

    Se você não pediu este e-mail, ignore esta mensagem.

    ==============================
    """)
  end

  defp deliver_confirmation_instructions(user, url) do
    deliver(user.email, "Confirme sua conta no CashCadence", """

    ==============================

    Olá, #{user.email}.

    Para confirmar sua conta, abra o link abaixo:

    #{url}

    Se você não criou esta conta, ignore esta mensagem.

    ==============================
    """)
  end
end
