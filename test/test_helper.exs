exclude = if System.find_executable("pdftotext"), do: [], else: [:pdftotext]
ExUnit.start(exclude: exclude)
Ecto.Adapters.SQL.Sandbox.mode(CashCadence.Repo, :manual)
