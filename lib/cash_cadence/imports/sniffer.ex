defmodule CashCadence.Imports.Sniffer do
  @moduledoc false

  alias CashCadence.Imports.Parsers

  @nubank_checking_header "Data,Valor,Identificador,Descrição"
  @nubank_card_header "date,category,title,amount"

  def detect(binary) when is_binary(binary) do
    head = binary |> strip_bom() |> String.slice(0, 4000)

    cond do
      ofx?(head) ->
        {:ok,
         %{
           format: :ofx,
           bank: ofx_bank(head),
           account_kind: ofx_kind(binary),
           encoding: ofx_encoding(head),
           parser: Parsers.OFX
         }}

      first_line(head) == @nubank_checking_header ->
        {:ok,
         %{
           format: :csv,
           bank: :nubank,
           account_kind: :checking,
           encoding: :utf8,
           parser: Parsers.CSV.NubankChecking
         }}

      first_line(head) == @nubank_card_header ->
        {:ok,
         %{
           format: :csv,
           bank: :nubank,
           account_kind: :credit_card,
           encoding: :utf8,
           parser: Parsers.CSV.NubankCard
         }}

      true ->
        {:error, :unknown_format}
    end
  end

  def strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  def strip_bom(binary), do: binary

  def transcode(binary, :latin1), do: :unicode.characters_to_binary(binary, :latin1)
  def transcode(binary, _), do: binary

  defp first_line(head), do: head |> String.split(~r/\r?\n/, parts: 2) |> hd() |> String.trim()

  defp ofx?(head),
    do:
      String.starts_with?(String.trim_leading(head), "OFXHEADER") or
        String.contains?(head, "<OFX>") or String.contains?(head, "<?OFX")

  defp ofx_bank(head) do
    org = head |> tag("ORG") |> to_string() |> String.upcase()

    cond do
      String.contains?(org, "NU ") or String.contains?(org, "NUBANK") -> :nubank
      String.contains?(org, "ITAU") or String.contains?(org, "ITAÚ") -> :itau
      true -> :unknown
    end
  end

  defp ofx_kind(binary),
    do: if(String.contains?(binary, "<CCACCTFROM>"), do: :credit_card, else: :checking)

  defp ofx_encoding(head) do
    charset = head |> header_value("CHARSET") |> to_string() |> String.upcase()
    encoding = head |> header_value("ENCODING") |> to_string() |> String.upcase()

    if charset in ["1252", "ISO-8859-1"] or
         (encoding == "USASCII" and charset != "NONE" and charset != ""),
       do: :latin1,
       else: :utf8
  end

  defp header_value(head, name) do
    case Regex.run(~r/^#{name}:(.*)$/m, head) do
      [_, value] -> String.trim(value)
      nil -> nil
    end
  end

  defp tag(text, name) do
    case Regex.run(~r/<#{name}>([^<\r\n]*)/, text) do
      [_, value] -> String.trim(value)
      nil -> nil
    end
  end
end
