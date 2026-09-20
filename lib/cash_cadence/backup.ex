defmodule CashCadence.Backup do
  @moduledoc false

  import Ecto.Query, warn: false

  alias CashCadence.Repo

  @version 1
  @tables [
    {"categories", CashCadence.Ledger.Category},
    {"bank_accounts", CashCadence.Ledger.BankAccount},
    {"import_batches", CashCadence.Imports.Batch},
    {"transactions", CashCadence.Ledger.Transaction},
    {"recurring_bills", CashCadence.Budgets.RecurringBill},
    {"recurring_bill_amounts", CashCadence.Budgets.BillAmount},
    {"rules", CashCadence.Classifier.Rule},
    {"category_memory", CashCadence.Classifier.Memory},
    {"inbox_items", CashCadence.Imports.InboxItem}
  ]

  def tables, do: Enum.map(@tables, &elem(&1, 0))

  def dump do
    %{
      "app" => "CashCadence",
      "version" => @version,
      "exported_at" => DateTime.utc_now(:second) |> DateTime.to_iso8601(),
      "tables" =>
        Map.new(@tables, fn {name, schema} ->
          rows = Repo.all(from s in schema, order_by: s.id)
          {name, Enum.map(rows, &row(schema, &1))}
        end)
    }
  end

  def encode(dump \\ dump()), do: Jason.encode!(dump, pretty: true)

  def write!(path) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, encode())
    path
  end

  def read!(path), do: path |> File.read!() |> Jason.decode!()

  def list_files(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(
          &(String.starts_with?(&1, "cashcadence-") and String.ends_with?(&1, ".json"))
        )
        |> Enum.map(fn name ->
          path = Path.join(dir, name)
          %File.Stat{size: size, mtime: mtime} = File.stat!(path, time: :posix)
          %{name: name, path: path, size: size, modified_at: DateTime.from_unix!(mtime)}
        end)
        |> Enum.sort_by(& &1.name, :desc)

      {:error, _} ->
        []
    end
  end

  def rotate!(dir, keep) when is_integer(keep) and keep > 0 do
    dir
    |> list_files()
    |> Enum.drop(keep)
    |> Enum.each(&File.rm!(&1.path))
  end

  def restore(%{"app" => "CashCadence", "version" => @version, "tables" => tables})
      when is_map(tables) do
    Repo.transaction(fn ->
      Repo.query!("TRUNCATE #{Enum.join(tables(), ", ")} RESTART IDENTITY CASCADE")

      Map.new(@tables, fn {name, schema} ->
        rows = tables |> Map.get(name, []) |> Enum.map(&cast_row(schema, &1))
        rows |> Enum.chunk_every(500) |> Enum.each(&Repo.insert_all(schema, &1))
        reset_sequence(name)
        {name, length(rows)}
      end)
    end)
  end

  def restore(_data), do: {:error, :unrecognized_backup}

  defp row(schema, struct) do
    Map.new(schema.__schema__(:fields), fn field ->
      {Atom.to_string(field), json_value(Map.get(struct, field))}
    end)
  end

  defp json_value(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp json_value(value), do: value

  defp cast_row(schema, row) do
    Map.new(row, fn {key, value} ->
      field = String.to_existing_atom(key)
      {:ok, cast} = Ecto.Type.cast(schema.__schema__(:type, field), value)
      {field, cast}
    end)
  end

  defp reset_sequence(table) do
    Repo.query!(
      "SELECT setval(pg_get_serial_sequence($1, 'id'), COALESCE((SELECT MAX(id) FROM #{table}), 0) + 1, false)",
      [table]
    )
  end
end
