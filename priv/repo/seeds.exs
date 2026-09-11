private_dir = Path.join(~w(priv repo seeds private))
transactions = Path.join(private_dir, "lancamentos_planilha.csv")

optional = fn file ->
  path = Path.join(private_dir, file)
  if File.exists?(path), do: path
end

if File.exists?(transactions) do
  {:ok, result} =
    CashCadence.Imports.Spreadsheet.run(
      transactions: transactions,
      bills: optional.("despesas_fixas.csv"),
      accounts: optional.("contas.csv")
    )

  IO.puts("Planilha importada: #{inspect(result)}")
else
  IO.puts("Sem dados privados em #{private_dir}; nada a importar.")
end
