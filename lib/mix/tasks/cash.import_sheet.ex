defmodule Mix.Tasks.Cash.ImportSheet do
  @moduledoc false

  use Mix.Task

  alias CashCadence.Imports.Spreadsheet

  @shortdoc "Imports the spreadsheet export (transactions, fixed expenses, accounts) into the ledger"

  @private_dir Path.join(~w(priv repo seeds private))
  @switches [transactions: :string, bills: :string, accounts: :string]

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: @switches)
    Mix.Task.run("app.start")

    paths = [
      transactions: opts[:transactions] || default_path("lancamentos_planilha.csv"),
      bills: opts[:bills] || optional_default("despesas_fixas.csv"),
      accounts: opts[:accounts] || optional_default("contas.csv")
    ]

    case Spreadsheet.run(paths) do
      {:ok, result} -> report(result)
      {:error, reason} -> Mix.raise("Importação abortada: #{inspect(reason)}")
    end
  end

  defp report(%{transactions: tx, bills: bills, accounts: accounts}) do
    Mix.shell().info(
      "Lançamentos: #{tx.created} criados, #{tx.skipped} já existiam, #{tx.ignored} com valor zero ignorados, #{tx.uncategorized} sem categoria, " <>
        "#{tx.categories_created} categorias novas"
    )

    if bills,
      do:
        Mix.shell().info("Despesas fixas: #{bills.created} criadas, #{bills.skipped} já existiam")

    if accounts,
      do: Mix.shell().info("Contas: #{accounts.created} criadas, #{accounts.skipped} já existiam")
  end

  defp default_path(file) do
    path = Path.join(@private_dir, file)
    if File.exists?(path), do: path, else: Mix.raise("Arquivo não encontrado: #{path}")
  end

  defp optional_default(file) do
    path = Path.join(@private_dir, file)
    if File.exists?(path), do: path
  end
end
