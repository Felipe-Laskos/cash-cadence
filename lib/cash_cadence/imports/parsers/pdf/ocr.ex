defmodule CashCadence.Imports.Parsers.PDF.OCR do
  @moduledoc false

  alias CashCadence.Imports.Parsers.PDF.Text

  @timeout 180_000
  @date ~r/(?<![\p{L}\d])[\dOoIl|]{2}\/[\dOoIl|]{2}(?:\/[\dOoIl|]{4})?(?![\p{L}\d])/u
  @amount ~r/(?<![\p{L}\d])-?[\dOoIl|]{1,3}(?:\.[\dOoIl|]{3})*,[\dOoIl|]{2}(?![\p{L}\d])/u

  def available?, do: System.find_executable("ocrmypdf") != nil

  def recognize_pdf(binary) when is_binary(binary), do: run(binary, ".pdf", ["--skip-text"])

  def recognize_image(binary, extension) when is_binary(binary),
    do: run(binary, extension, ["--image-dpi", "300"])

  defp run(binary, extension, extra_args) do
    cond do
      not available?() -> {:error, :ocr_missing}
      not Text.available?() -> {:error, :pdftotext_missing}
      true -> Text.with_temp_files(binary, extension, &ocrmypdf(&1, &2, extra_args))
    end
  end

  defp ocrmypdf(input, output, extra_args) do
    exe = System.find_executable("ocrmypdf")
    args = ["-l", "por", "--deskew", "--rotate-pages", "--quiet"] ++ extra_args ++ [input, output]
    task = Task.async(fn -> System.cmd(exe, args, stderr_to_stdout: true) end)

    case Task.yield(task, @timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {_output, 0}} -> File.read(output)
      {:ok, {_output, status}} -> {:error, {:ocr_failed, status}}
      nil -> {:error, :timeout}
    end
  end

  def clean(text) when is_binary(text) do
    text
    |> replace_tokens(@date)
    |> replace_tokens(@amount)
  end

  defp replace_tokens(text, regex), do: Regex.replace(regex, text, &digits/1)

  defp digits(token) do
    token
    |> String.replace(~r/[Oo]/, "0")
    |> String.replace(~r/[Il|]/, "1")
  end
end
