defmodule CashCadence.ReconciliationTest do
  use CashCadence.DataCase, async: true

  import CashCadence.LedgerFixtures

  alias CashCadence.Imports.Batch
  alias CashCadence.{Reconciliation, Repo}

  defp statement(account, period_end, balance) do
    Repo.insert!(%Batch{
      source: :upload,
      format: :pdf,
      bank: :itau,
      file_name: "extrato-#{period_end}.pdf",
      file_sha256: "sha-#{period_end}",
      period_end: period_end,
      statement_balance: Decimal.new(balance),
      bank_account_id: account.id
    })
  end

  defp account_with_statements do
    account = bank_account_fixture(%{name: "Conta", kind: :checking})
    statement(account, ~D[2026-04-30], "1000.00")
    statement(account, ~D[2026-05-31], "1200.00")
    account
  end

  test "closes when the ledger moved exactly what the bank says" do
    account = account_with_statements()

    transaction_fixture(%{
      date: ~D[2026-05-10],
      kind: :income,
      amount: "500.00",
      bank_account_id: account.id
    })

    transaction_fixture(%{
      date: ~D[2026-05-20],
      kind: :expense,
      amount: "300.00",
      bank_account_id: account.id
    })

    assert [%{steps: [step]}] = Reconciliation.statement_checks()
    assert step.ok?
    assert Decimal.equal?(step.expected, Decimal.new("200.00"))
    assert Decimal.equal?(step.moved, Decimal.new("200.00"))
    assert Reconciliation.open_checks() == []
  end

  test "a transfer counts against the balance according to its direction" do
    account = account_with_statements()

    transaction_fixture(%{
      date: ~D[2026-05-10],
      kind: :income,
      amount: "500.00",
      bank_account_id: account.id
    })

    transaction_fixture(%{
      date: ~D[2026-05-15],
      kind: :transfer,
      direction: :out,
      amount: "300.00",
      bank_account_id: account.id
    })

    assert [%{steps: [step]}] = Reconciliation.statement_checks()
    assert step.ok?
    assert Decimal.equal?(step.moved, Decimal.new("200.00"))
    assert Decimal.equal?(step.difference, Decimal.new("0.00"))
    assert step.unknown_transfers == 0
  end

  test "a transfer without direction makes the interval unverifiable" do
    account = account_with_statements()

    transaction_fixture(%{
      date: ~D[2026-05-10],
      kind: :income,
      amount: "200.00",
      bank_account_id: account.id
    })

    transaction_fixture(%{
      date: ~D[2026-05-15],
      kind: :transfer,
      amount: "50.00",
      bank_account_id: account.id
    })

    assert [%{steps: [step]}] = Reconciliation.statement_checks()
    refute step.ok?
    assert step.unknown_transfers == 1
    assert [_step] = Reconciliation.open_checks()
  end

  test "points at the days the statement closes over without listing anything" do
    account = account_with_statements()

    transaction_fixture(%{
      date: ~D[2026-05-20],
      kind: :income,
      amount: "150.00",
      bank_account_id: account.id
    })

    assert [%{steps: [step]}] = Reconciliation.statement_checks()
    refute step.ok?
    assert step.last_entry == ~D[2026-05-20]
    assert step.silent_days == 11
    assert Decimal.equal?(step.difference, Decimal.new("50.00"))
  end

  test "counts what the month still needs" do
    account = account_with_statements()

    transaction_fixture(%{
      date: ~D[2026-05-10],
      kind: :expense,
      amount: "40.00",
      bank_account_id: account.id
    })

    checklist = Reconciliation.month_checklist(~D[2026-05-01])

    assert checklist.uncategorized == 1
    assert checklist.inbox == 0
    assert checklist.open_checks == 1
  end
end
