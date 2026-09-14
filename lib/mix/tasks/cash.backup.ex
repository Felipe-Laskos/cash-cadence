defmodule Mix.Tasks.Cash.Backup do
  @moduledoc false

  use Mix.Task

  alias CashCadence.Backup

  @shortdoc "Writes a full JSON backup of the ledger, bills, rules and inbox"

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [out: :string])
    Mix.Task.run("app.start")

    path = opts[:out] || Path.join("backups", "cashcadence-#{stamp()}.json")
    Backup.write!(path)
    Mix.shell().info("Backup gravado em #{path} (#{File.stat!(path).size} bytes)")
  end

  defp stamp, do: Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M%S")
end
