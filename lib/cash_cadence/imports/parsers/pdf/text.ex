defmodule CashCadence.Imports.Parsers.PDF.Text do
  @moduledoc false

  @timeout 20_000

  def available?, do: System.find_executable("pdftotext") != nil

  def encrypted?(binary) when is_binary(binary), do: String.contains?(binary, "/Encrypt")

  def unlock(binary, password) when is_binary(binary) do
    cond do
      not encrypted?(binary) -> {:ok, binary}
      password in [nil, ""] -> {:error, :encrypted}
      is_nil(System.find_executable("qpdf")) -> {:error, :qpdf_missing}
      true -> decrypt(binary, password)
    end
  end

  defp decrypt(binary, password) do
    script = ~S(printf "%s\n" "$CC_PDF_PASSWORD" | qpdf --password-file=- --decrypt "$1" "$2")

    with_temp_files(binary, ".pdf", fn input, output ->
      case System.cmd("sh", ["-c", script, "sh", input, output],
             env: [{"CC_PDF_PASSWORD", password}],
             stderr_to_stdout: true
           ) do
        {_output, 0} -> File.read(output)
        {_output, _status} -> {:error, :wrong_password}
      end
    end)
  end

  def extract(binary, opts \\ []) when is_binary(binary) do
    cond do
      encrypted?(binary) -> {:error, :encrypted}
      not available?() -> {:error, :pdftotext_missing}
      true -> with_temp_files(binary, ".pdf", fn input, _output -> run(input, opts[:crop]) end)
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

  def with_temp_files(binary, extension, fun) do
    dir = Path.join(System.tmp_dir!(), "cash_cadence")
    File.mkdir_p!(dir)
    token = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    input = Path.join(dir, token <> extension)
    output = Path.join(dir, token <> "-out.pdf")

    try do
      File.write!(input, binary)
      fun.(input, output)
    after
      File.rm(input)
      File.rm(output)
    end
  end
end
