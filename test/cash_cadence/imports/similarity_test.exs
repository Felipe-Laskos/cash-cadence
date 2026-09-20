defmodule CashCadence.Imports.SimilarityTest do
  use ExUnit.Case, async: true

  alias CashCadence.Imports.Similarity

  test "ignores the words that show up in every bank line" do
    assert Similarity.shared("PIX TRANSF FELIPE", "PIX QRS PADARIA EXEMPLO") == 0

    assert Similarity.shared("PIX TRANSF FELIPE M L", "TRANSFERENCIA ENVIADA PELO PIX FELIPE") ==
             1

    assert Similarity.shared("FATURA PAGA BANCO EXEMPLO", "PAGAMENTO VIA CONTA") == 0
  end

  test "picks the candidate that shares words before the one that is closer in date" do
    close = %{id: 1, date: ~D[2026-05-22], normalized_description: "OUTRA COISA"}
    similar = %{id: 2, date: ~D[2026-05-24], normalized_description: "PADARIA EXEMPLO"}

    assert Similarity.best([close, similar], "COMPRA NO DEBITO PADARIA EXEMPLO", ~D[2026-05-22]) ==
             similar
  end

  test "falls back to the closest date when nothing shares words" do
    close = %{id: 1, date: ~D[2026-05-22], normalized_description: nil}
    far = %{id: 2, date: ~D[2026-05-25], normalized_description: nil}

    assert Similarity.best([far, close], "QUALQUER COISA", ~D[2026-05-22]) == close
    assert Similarity.best([], "QUALQUER COISA", ~D[2026-05-22]) == nil
  end
end
