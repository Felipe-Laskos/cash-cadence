defmodule CashCadence.Imports.Parsers.PDF.Text do
  @moduledoc false

  @timeout 20_000

  def available?, do: System.find_executable("pdftotext") != nil

  def extract(binary, opts \\ []) when is_binary(binary) do
    cond do
      encrypted?(binary) -> {:error, :encrypted}
      not available?() -> {:error, :pdftotext_missing}
      true -> with_temp_file(binary, &run(&1, opts[:crop]))
    end
  end

  defp run(path, crop) do
    exe = System.find_executable("pdftotext")
    args = ["-q", "-layout", "-enc", "UTF-8"] ++ crop_args(crop) ++ [path, "-"]
    task = Task.async(fn -> System.cmd(exe, args) end)

    case Task.yield(task, @timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {text, 0}} -> {:ok, String.replace(text, "\f", "\n")}
      {:ok, {_output, status}} -> {:error, {:pdftotext_failed, status}}
      nil -> {:error, :timeout}
    end
  end

  defp crop_args(nil), do: []

  defp crop_args(%{x: x, y: y, w: w, h: h}),
    do: ["-x", to_string(x), "-y", to_string(y), "-W", to_string(w), "-H", to_string(h)]

  defp encrypted?(binary), do: String.contains?(binary, "/Encrypt")

  defp with_temp_file(binary, fun) do
    dir = Path.join(System.tmp_dir!(), "cash_cadence")
    File.mkdir_p!(dir)
    name = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false) <> ".pdf"
    path = Path.join(dir, name)

    try do
      File.write!(path, binary)
      fun.(path)
    after
      File.rm(path)
    end
  end
end
