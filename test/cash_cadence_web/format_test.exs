defmodule CashCadenceWeb.FormatTest do
  use ExUnit.Case, async: true

  import CashCadenceWeb.Format

  test "amount/2 uses Brazilian separators" do
    assert amount(Decimal.new("1234.5")) == "1.234,50"
    assert amount(Decimal.new("1234567.891")) == "1.234.567,89"
    assert amount(Decimal.new("-48.86")) == "-48,86"
    assert amount(Decimal.new("75"), signed: true) == "+75,00"
    assert amount(Decimal.new("6647.36"), cents: false) == "6.647"
    assert amount(nil) == "0,00"
  end

  test "brl/2 prefixes the currency with a non-breaking space" do
    assert brl(Decimal.new("10")) == "R$ 10,00"
  end

  test "input_amount/1 renders decimals with comma" do
    assert input_amount(Decimal.new("48.8")) == "48,80"
    assert input_amount(nil) == ""
  end

  test "month helpers" do
    assert month_title(~D[2026-05-01]) == "Maio 2026"
    assert month_label(~D[2026-05-01]) == "maio 2026"
    assert month_short(~D[2026-05-01]) == "mai/26"
    assert month_param(~D[2026-05-17]) == "2026-05"
    assert parse_month("2026-05") == {:ok, ~D[2026-05-01]}
    assert parse_month("2026-13") == :error
    assert parse_month(nil) == :error
  end

  test "day helpers" do
    assert day_heading(~D[2026-05-22]) == "sexta, 22 de maio"
    assert short_date(~D[2026-05-22]) == "22/05"
    assert percent(Decimal.new("62.68")) == "62,7%"
  end
end
