defmodule Mix.Tasks.Cash.Import do
  @moduledoc false

  use Mix.Task

  alias CashCadence.Imports
  alias CashCadence.Ledger

  @shortdoc "Imports bank statement files (OFX, CSV) into the review inbox"

  @impl Mix.Task
  def run(args) do
    {opts, files} = OptionParser.parse!(args, strict: [account: :string])
    Mix.Task.run("app.start")

    if files == [], do: Mix.raise("Uso: mix cash.import ARQUIVO [ARQUIVO...] [--account NOME]")

    account_id =
      case opts[:account] do
        nil ->
          nil

        name ->
          (Ledger.get_bank_account_by_name(name) || Mix.raise("Conta não encontrada: #{name}")).id
      end

    Enum.each(files, fn file ->
      case Imports.ingest_file(file, source: :cli, bank_account_id: account_id) do
        {:ok, batch} ->
          Mix.shell().info("#{Path.basename(file)}: #{describe(batch.counts)}")

        {:error, {:already_imported, _batch}} ->
          Mix.shell().info("#{Path.basename(file)}: já importado antes, ignorado")

        {:error, reason} ->
          Mix.shell().error("#{Path.basename(file)}: falhou (#{inspect(reason)})")
      end
    end)
  end

  defp describe(counts) do
    "#{counts["total"]} transações · #{counts["new"]} novas na caixa de entrada · #{counts["duplicates"]} já conhecidas · " <>
      "#{counts["matched"]} casam com lançamentos manuais · #{counts["transfers"]} parecem transferência"
  end
end
