defmodule CashCadence.Settings do
  @moduledoc false

  alias CashCadence.Repo
  alias CashCadence.Settings.Setting

  def get(key, default \\ nil) when is_binary(key) do
    case Repo.get(Setting, key) do
      %Setting{value: %{"value" => value}} -> value
      _ -> default
    end
  end

  def put(key, value) when is_binary(key) do
    now = DateTime.utc_now(:second)

    Repo.insert!(
      %Setting{key: key, value: %{"value" => value}, inserted_at: now, updated_at: now},
      on_conflict: [set: [value: %{"value" => value}, updated_at: now]],
      conflict_target: :key
    )

    :ok
  end

  def auto_approve?, do: get("auto_approve", false) == true

  def set_auto_approve(enabled) when is_boolean(enabled), do: put("auto_approve", enabled)
end
