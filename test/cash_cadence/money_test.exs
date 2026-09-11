defmodule CashCadence.MoneyTest do
  use ExUnit.Case, async: true

  alias CashCadence.Money

  describe "parse/1" do
    test "accepts Brazilian and dotted formats" do
      assert {:ok, d} = Money.parse("1.234,56")
      assert Decimal.equal?(d, Decimal.new("1234.56"))
      assert {:ok, d} = Money.parse("48,82")
      assert Decimal.equal?(d, Decimal.new("48.82"))
      assert {:ok, d} = Money.parse("R$ 50")
      assert Decimal.equal?(d, Decimal.new("50"))
      assert {:ok, d} = Money.parse("-12.5")
      assert Decimal.equal?(d, Decimal.new("-12.5"))
    end

    test "rejects garbage" do
      assert Money.parse("abc") == :error
      assert Money.parse("") == :error
    end
  end

  test "normalize_param/2 rewrites the amount in string- or atom-keyed maps" do
    assert Money.normalize_param(%{"amount" => "1.000,50"}, :amount) == %{"amount" => "1000.50"}
    assert Money.normalize_param(%{amount: "9,90"}, :amount) == %{amount: "9.90"}
    assert Money.normalize_param(%{amount: Decimal.new(1)}, :amount) == %{amount: Decimal.new(1)}
  end

  test "pct_change/2 and ratio/2" do
    assert Money.pct_change(Decimal.new(110), Decimal.new(100))
           |> Decimal.equal?(Decimal.new("10.0"))

    assert Money.pct_change(Decimal.new(50), Decimal.new(0)) == nil
    assert Money.ratio(Decimal.new(1), Decimal.new(0)) == nil
    assert Money.ratio(Decimal.new(1), Decimal.new(4)) |> Decimal.equal?(Decimal.new("0.25"))
  end
end
