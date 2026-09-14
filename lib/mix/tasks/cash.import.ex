defmodule Mix.Tasks.Cash.Import do
  @moduledoc false

  use Mix.Task

  alias CashCadence.Imports
  alias CashCadence.Ledger

  @shortdoc "Imports bank statement files (OFX, CSV, PDF) into the review inbox"

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
          Enum.each(batch.warnings, &Mix.shell().info("  aviso: #{&1}"))

        {:error, {:already_imported, _batch}} ->
          Mix.shell().info("#{Path.basename(file)}: já importado antes, ignorado")

        {:error, reason} ->
          Mix.shell().error("#{Path.basename(file)}: #{explain(reason)}")
      end
    end)
  end

  defp describe(counts) do
    "#{counts["total"]} transações · #{counts["new"]} novas na caixa de entrada · #{counts["duplicates"]} já conhecidas · " <>
      "#{counts["matched"]} casam com lançamentos manuais · #{counts["transfers"]} parecem transferência" <>
      auto_approved(counts["auto_approved"])
  end

  defp auto_approved(count) when is_integer(count) and count > 0,
    do: " · #{count} aprovadas automaticamente"

  defp auto_approved(_count), do: ""

  defp explain(:unknown_format),
    do: "formato não reconhecido (aceito: OFX, CSV do Nubank, PDF do Itaú)"

  defp explain({:unknown_layout, _text}),
    do: "PDF não reconhecido: por enquanto só extrato e fatura do Itaú"

  defp explain(:encrypted), do: "PDF protegido por senha: remova a senha e tente de novo"
  defp explain(:pdftotext_missing), do: "pdftotext não encontrado: instale o poppler-utils"
  defp explain(:no_transactions), do: "nenhuma transação encontrada no arquivo"
  defp explain(reason), do: "falhou (#{inspect(reason)})"
end
