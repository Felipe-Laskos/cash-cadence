defmodule CashCadence.Imports.Similarity do
  @moduledoc false

  @min_length 4

  @generic ~w(
    PIX TRANSF QRS COMPRA DEBITO CREDITO PAGAMENTO PAGTO FATURA CARTAO CONTA BANCO
    TRANSFERENCIA ENVIADA RECEBIDA EFETUADO EFETUADA PARA PELO PELA LTDA EIRELI
  )

  def tokens(nil), do: MapSet.new()

  def tokens(text) when is_binary(text) do
    text
    |> String.split(~r/\s+/, trim: true)
    |> Enum.filter(&distinctive?/1)
    |> MapSet.new()
  end

  def shared(left, right) do
    left |> tokens() |> MapSet.intersection(tokens(right)) |> MapSet.size()
  end

  def best(candidates, normalized, %Date{} = date) do
    Enum.min_by(candidates, &rank(&1, normalized, date), fn -> nil end)
  end

  defp rank(candidate, normalized, date) do
    {
      -shared(normalized, candidate.normalized_description),
      abs(Date.diff(candidate.date, date)),
      candidate.id
    }
  end

  defp distinctive?(token), do: String.length(token) >= @min_length and token not in @generic
end
