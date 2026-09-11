%{
  configs: [
    %{
      name: "default",
      files: %{included: ["lib/", "test/", "config/", "priv/repo/"], excluded: []},
      strict: true,
      checks: %{
        disabled: [
          {Credo.Check.Design.AliasUsage, []},
          {Credo.Check.Readability.AliasOrder, []},
          {Credo.Check.Readability.ModuleDoc, []}
        ]
      }
    }
  ]
}
