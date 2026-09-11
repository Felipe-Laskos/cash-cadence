defmodule CashCadence.Repo do
  use Ecto.Repo,
    otp_app: :cash_cadence,
    adapter: Ecto.Adapters.Postgres
end
