defmodule CashCadence.Repo.Migrations.RenameItauCategoryPayloadKey do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE inbox_items
       SET payload = (payload - 'itau_category')
                     || jsonb_build_object('bank_category', payload -> 'itau_category')
     WHERE payload ? 'itau_category'
    """)
  end

  def down do
    execute("""
    UPDATE inbox_items i
       SET payload = (i.payload - 'bank_category')
                     || jsonb_build_object('itau_category', i.payload -> 'bank_category')
      FROM import_batches b
     WHERE b.id = i.batch_id
       AND b.bank = 'itau'
       AND i.payload ? 'bank_category'
    """)
  end
end
