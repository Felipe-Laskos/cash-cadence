defmodule CashCadence.ClassifierTest do
  use CashCadence.DataCase, async: true

  import CashCadence.LedgerFixtures

  alias CashCadence.Classifier

  defp subject(raw, hint \\ nil),
    do: %{raw: raw, normalized: CashCadence.Imports.Normalizer.normalize(raw), hint: hint}

  describe "rules" do
    test "matches by contains, starts with and regex, honouring order and the active flag" do
      fuel = category_fixture(%{name: "Combustível"})
      market = category_fixture(%{name: "Mercado"})

      assert {:ok, first} =
               Classifier.create_rule(%{
                 "pattern" => "posto",
                 "match_kind" => "contains",
                 "category_name" => "Combustível"
               })

      assert first.position == 1
      assert first.category_id == fuel.id

      assert {:ok, second} =
               Classifier.create_rule(%{
                 "pattern" => "PIX QRS",
                 "match_kind" => "starts_with",
                 "category_id" => market.id
               })

      assert second.position == 2

      classification = Classifier.classify(subject("PIX QRS AUTO POSTO 23/08"))
      assert classification.category_id == fuel.id
      assert classification.confidence == :high
      assert classification.source == :rule
      assert classification.rule_id == first.id

      assert %{category_id: market_id, source: :rule} =
               Classifier.classify(subject("PIX QRS PADARIA"))

      assert market_id == market.id

      assert {:ok, _} = Classifier.toggle_rule(first)
      assert %{category_id: market_id} = Classifier.classify(subject("PIX QRS AUTO POSTO 23/08"))
      assert market_id == market.id

      assert {:ok, regex_rule} =
               Classifier.create_rule(%{
                 "pattern" => "^REND PAGO",
                 "match_kind" => "regex",
                 "kind_override" => "income",
                 "category_name" => "Rendimentos"
               })

      assert %{kind: :income, source: :rule} =
               Classifier.classify(subject("REND PAGO APLIC AUT MAIS"))

      assert regex_rule.category.name == "Rendimentos"
    end

    test "a rule that only forces the kind still lets the memory pick the category" do
      me = category_fixture(%{name: "Transferências"})

      assert {:ok, _} =
               Classifier.create_rule(%{
                 "pattern" => "PIX TRANSF CLIENTE",
                 "kind_override" => "transfer"
               })

      assert %{kind: :transfer, category_id: nil, confidence: :none} =
               Classifier.classify(subject("PIX TRANSF CLIENTE 10/09"))

      :ok = Classifier.learn("PIX TRANSF CLIENTE", me.id)

      assert %{kind: :transfer, category_id: category_id, confidence: :medium, source: :memory} =
               Classifier.classify(subject("PIX TRANSF CLIENTE 10/09"))

      assert category_id == me.id
    end

    test "matches the bank hint when the rule targets it" do
      services = category_fixture(%{name: "Serviços"})

      assert {:ok, _} =
               Classifier.create_rule(%{
                 "pattern" => "serviços",
                 "target" => "bank_hint",
                 "category_id" => services.id
               })

      assert %{category_id: category_id} =
               Classifier.classify(subject("ASSINATURAEXEMPLO", "serviços"))

      assert category_id == services.id
      assert %{category_id: nil} = Classifier.classify(subject("ASSINATURAEXEMPLO", nil))
    end

    test "rejects invalid regexes and rules without an outcome" do
      assert {:error, changeset} =
               Classifier.create_rule(%{
                 "pattern" => "(abc",
                 "match_kind" => "regex",
                 "kind_override" => "expense"
               })

      assert %{pattern: [message]} = errors_on(changeset)
      assert message =~ "expressão inválida"

      assert {:error, changeset} = Classifier.create_rule(%{"pattern" => "POSTO"})
      assert %{category_name: ["escolha uma categoria ou um tipo"]} = errors_on(changeset)
    end

    test "moves rules up and down and counts previews" do
      category = category_fixture(%{name: "Padaria"})

      transaction_fixture(%{
        description: "pão",
        raw_description: "PIX QRS PADARIA EXEMPLO",
        normalized_description: "PIX QRS PADARIA EXEMPLO"
      })

      {:ok, a} = Classifier.create_rule(%{"pattern" => "PADARIA", "category_id" => category.id})
      {:ok, b} = Classifier.create_rule(%{"pattern" => "MERCADO", "category_id" => category.id})

      assert {:ok, moved} = Classifier.move_rule(b, :up)
      assert moved.position == 1
      assert Enum.map(Classifier.list_rules(), & &1.id) == [b.id, a.id]
      assert {:ok, _} = Classifier.move_rule(moved, :up)
      assert Enum.map(Classifier.list_rules(), & &1.id) == [b.id, a.id]

      assert Classifier.preview(a) == %{transactions: 1, pending: 0}
      assert Classifier.preview(b) == %{transactions: 0, pending: 0}
    end
  end

  describe "memory" do
    test "learns, reinforces and forgets descriptions" do
      food = category_fixture(%{name: "Comida"})
      other = category_fixture(%{name: "Lazer"})

      assert :ok = Classifier.learn("PIX QRS PADARIA", food.id)

      assert %{confidence: :medium, category_id: category_id} =
               Classifier.classify(subject("PIX QRS PADARIA"))

      assert category_id == food.id

      assert :ok = Classifier.learn("PIX QRS PADARIA", food.id)
      assert %{confidence: :high} = Classifier.classify(subject("PIX QRS PADARIA"))

      assert :ok = Classifier.learn("PIX QRS PADARIA", other.id)
      [memory] = Classifier.list_memory("padaria")
      assert memory.category_id == other.id
      assert memory.uses == 3
      assert Classifier.count_memory() == 1

      assert :ok = Classifier.learn("", food.id)
      assert :ok = Classifier.learn("QUALQUER", nil)
      assert Classifier.count_memory() == 1

      assert {:ok, _} = Classifier.forget(memory)
      assert %{confidence: :none} = Classifier.classify(subject("PIX QRS PADARIA"))
    end

    test "follows category merges" do
      tim = category_fixture(%{name: "Tim"})
      phone = category_fixture(%{name: "Telefonia"})
      :ok = Classifier.learn("PIX QRS TIM S A", tim.id)

      assert {:ok, _} = CashCadence.Ledger.merge_categories(tim, phone)
      assert %{category_id: category_id} = Classifier.classify(subject("PIX QRS TIM S A"))
      assert category_id == phone.id
    end
  end
end
