defmodule Mix.Tasks.Cash.Restore do
  @moduledoc false

  use Mix.Task

  alias CashCadence.Backup

  @shortdoc "Replaces all financial data with the contents of a JSON backup"

  @impl Mix.Task
  def run(args) do
    {opts, files} = OptionParser.parse!(args, strict: [yes: :boolean])

    case files do
      [path] -> restore(path, opts[:yes])
      _ -> Mix.raise("Uso: mix cash.restore ARQUIVO.json --yes")
    end
  end

  defp restore(_path, nil) do
    Mix.raise(
      "Restaurar apaga TODOS os lançamentos, fixas, regras e itens da caixa de entrada atuais. " <>
        "Repita com --yes para confirmar."
    )
  end

  defp restore(path, true) do
    Mix.Task.run("app.start")

    case Backup.restore(Backup.read!(path)) do
      {:ok, counts} ->
        Enum.each(counts, fn {table, count} -> Mix.shell().info("#{table}: #{count}") end)
        Mix.shell().info("Restaurado de #{path}")

      {:error, :unrecognized_backup} ->
        Mix.raise("O arquivo não parece um backup do CashCadence")

      {:error, reason} ->
        Mix.raise("Falhou: #{inspect(reason)}")
    end
  end
end
