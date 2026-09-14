defmodule CashCadence.SettingsAndBackupSchedulerTest do
  use CashCadence.DataCase, async: false

  alias CashCadence.{Backup, Settings}
  alias CashCadence.Backup.Scheduler

  @dir Path.join(System.tmp_dir!(), "cash_cadence_backup_test")

  setup do
    File.rm_rf!(@dir)
    on_exit(fn -> File.rm_rf!(@dir) end)
    :ok
  end

  test "settings are stored per key and default when absent" do
    refute Settings.auto_approve?()
    assert Settings.get("nada", :default) == :default
    :ok = Settings.set_auto_approve(true)
    assert Settings.auto_approve?()
    :ok = Settings.set_auto_approve(false)
    refute Settings.auto_approve?()
  end

  test "writes, lists, rotates and knows when a backup is due" do
    config = [enabled: true, dir: @dir, keep: 2, interval_hours: 24]
    assert Scheduler.due?(config)

    Backup.write!(Path.join(@dir, "cashcadence-20260101-000000.json"))
    Backup.write!(Path.join(@dir, "cashcadence-20260102-000000.json"))
    assert {:ok, path} = Scheduler.run_now(config)
    assert File.exists?(path)

    files = Backup.list_files(@dir)
    assert length(files) == 2
    assert hd(files).path == path
    refute Enum.any?(files, &(&1.name == "cashcadence-20260101-000000.json"))

    refute Scheduler.due?(config)
    assert Scheduler.due?(Keyword.put(config, :interval_hours, 0))
  end

  test "the scheduler starts idle in tests and ticks without crashing" do
    assert Process.whereis(Scheduler)
    assert Keyword.get(Scheduler.config(), :enabled) == false
    send(Scheduler, :tick)
    assert Process.alive?(Process.whereis(Scheduler))
  end
end
