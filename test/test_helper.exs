missing = fn binary, tag -> if System.find_executable(binary), do: [], else: [tag] end

exclude =
  missing.("pdftotext", :pdftotext) ++ missing.("qpdf", :qpdf) ++ missing.("ocrmypdf", :ocr)

ExUnit.start(exclude: exclude)
Ecto.Adapters.SQL.Sandbox.mode(CashCadence.Repo, :manual)
