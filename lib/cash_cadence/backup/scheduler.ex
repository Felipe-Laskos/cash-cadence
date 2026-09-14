defmodule CashCadence.Backup.Scheduler do
  @moduledoc false

  use GenServer

  require Logger

  alias CashCadence.Backup

  @first_tick :timer.minutes(1)
  @tick :timer.hours(6)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def config do
    defaults = [enabled: false, dir: "backups", keep: 14, interval_hours: 24]
    Keyword.merge(defaults, Application.get_env(:cash_cadence, :backup, []))
  end

  def run_now(config \\ config()) do
    dir = Keyword.fetch!(config, :dir)
    path = Backup.write!(Path.join(dir, file_name()))
    Backup.rotate!(dir, Keyword.fetch!(config, :keep))
    {:ok, path}
  end

  def due?(config \\ config()) do
    interval = Keyword.fetch!(config, :interval_hours) * 3600

    case Backup.list_files(Keyword.fetch!(config, :dir)) do
      [] -> true
      [latest | _] -> DateTime.diff(DateTime.utc_now(), latest.modified_at) >= interval
    end
  end

  def file_name, do: "cashcadence-#{Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M%S")}.json"

  @impl true
  def init(_opts) do
    if Keyword.get(config(), :enabled, false), do: Process.send_after(self(), :tick, @first_tick)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    config = config()

    if Keyword.get(config, :enabled, false) and due?(config) do
      case run_now(config) do
        {:ok, path} -> Logger.info("backup automático gravado em #{path}")
        other -> Logger.warning("backup automático falhou: #{inspect(other)}")
      end
    end

    Process.send_after(self(), :tick, @tick)
    {:noreply, state}
  rescue
    error ->
      Logger.warning("backup automático falhou: #{Exception.message(error)}")
      Process.send_after(self(), :tick, @tick)
      {:noreply, state}
  end
end
