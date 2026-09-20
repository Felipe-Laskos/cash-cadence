defmodule Mix.Tasks.Cash.Directions do
  @moduledoc false

  use Mix.Task

  import Ecto.Query, warn: false

  alias CashCadence.Imports.InboxItem
  alias CashCadence.Ledger.Transaction
  alias CashCadence.Repo

  @shortdoc "Fills in whether each imported transfer left or entered the account"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    pending =
      Repo.all(
        from t in Transaction,
          join: i in InboxItem,
          on: i.transaction_id == t.id,
          where: t.kind == :transfer and is_nil(t.direction) and is_nil(t.deleted_at),
          select: {t, fragment("?->>'signed_amount'", i.payload)}
      )

    {filled, skipped} = Enum.reduce(pending, {0, 0}, &fill/2)

    remaining =
      Repo.aggregate(
        from(t in Transaction,
          where: t.kind == :transfer and is_nil(t.direction) and is_nil(t.deleted_at)
        ),
        :count
      )

    Mix.shell().info("#{filled} transferência(s) com direção preenchida")
    Mix.shell().info("#{skipped} sem sinal no item de origem")
    Mix.shell().info("#{remaining} ainda sem direção (lançadas à mão ou sem item de origem)")
  end

  defp fill({transaction, signed}, {filled, skipped}) do
    case direction(signed) do
      nil ->
        {filled, skipped + 1}

      direction ->
        transaction |> Ecto.Changeset.change(direction: direction) |> Repo.update!()
        {filled + 1, skipped}
    end
  end

  defp direction("-" <> _rest), do: :out
  defp direction(signed) when is_binary(signed), do: :in
  defp direction(_signed), do: nil
end
