defmodule Mix.Tasks.Cash.Rebalance do
  @moduledoc false

  use Mix.Task

  import Ecto.Query, warn: false

  alias CashCadence.Imports.Batch
  alias CashCadence.Imports.Parsers.PDF.{ItauCard, ItauStatement, NubankStatement}
  alias CashCadence.Repo

  @shortdoc "Recomputes the statement balance of imported files from the text already stored"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    changed =
      Repo.all(from b in Batch, where: not is_nil(b.raw_text), order_by: b.id)
      |> Enum.reduce(0, &rebalance/2)

    Mix.shell().info("#{changed} lote(s) com saldo corrigido")
  end

  defp rebalance(%Batch{} = batch, changed) do
    case reparse(batch.raw_text) do
      {:ok, %{balance: balance} = parsed} when not is_nil(balance) ->
        if batch.statement_balance && Decimal.equal?(batch.statement_balance, balance) do
          changed
        else
          batch
          |> Ecto.Changeset.change(
            statement_balance: balance,
            warnings: parsed[:warnings] || []
          )
          |> Repo.update!()

          Mix.shell().info(
            "lote #{batch.id} (#{batch.file_name}): #{batch.statement_balance} -> #{balance}"
          )

          changed + 1
        end

      _other ->
        Mix.shell().info("lote #{batch.id} (#{batch.file_name}): texto não reconhecido, mantido")
        changed
    end
  end

  defp reparse(text) do
    cond do
      ItauStatement.recognizes?(text) -> ItauStatement.parse_text(text)
      NubankStatement.recognizes?(text) -> NubankStatement.parse_text(text)
      ItauCard.recognizes?(text) -> ItauCard.parse_text(text)
      true -> :error
    end
  end
end
