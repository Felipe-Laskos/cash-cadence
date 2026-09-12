defmodule CashCadenceWeb.ImportLive do
  use CashCadenceWeb, :live_view

  alias CashCadence.{Imports, Ledger}

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(
        page_title: "Importar",
        accounts: Ledger.list_bank_accounts(),
        account_id: "",
        batches: Imports.list_batches()
      )
      |> allow_upload(:files, accept: :any, max_entries: 10, max_file_size: 10_000_000)

    {:ok, socket}
  end

  @impl true
  def handle_event("validate", params, socket) do
    {:noreply, assign(socket, account_id: params["account_id"] || socket.assigns.account_id)}
  end

  def handle_event("cancel", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :files, ref)}

  def handle_event("import", params, socket) do
    account_id = parse_account(params["account_id"])

    results =
      consume_uploaded_entries(socket, :files, fn %{path: path}, entry ->
        {:ok,
         {entry.client_name,
          Imports.ingest_binary(File.read!(path), entry.client_name,
            source: :upload,
            bank_account_id: account_id
          )}}
      end)

    {imported, rest} = Enum.split_with(results, &match?({_, {:ok, _}}, &1))

    new_items =
      imported |> Enum.map(fn {_, {:ok, batch}} -> batch.counts["new"] end) |> Enum.sum()

    socket =
      socket
      |> assign(batches: Imports.list_batches(), inbox_count: Imports.count_pending())
      |> put_flash(flash_kind(imported, rest), summary(imported, rest, new_items))

    if new_items > 0 do
      {:noreply, push_navigate(socket, to: ~p"/entrada")}
    else
      {:noreply, socket}
    end
  end

  defp parse_account(""), do: nil
  defp parse_account(nil), do: nil
  defp parse_account(id), do: String.to_integer(id)

  defp flash_kind([], _rest), do: :error
  defp flash_kind(_imported, _rest), do: :info

  defp summary(imported, rest, new_items) do
    parts =
      [
        imported != [] &&
          "#{length(imported)} #{plural(length(imported), "arquivo lido", "arquivos lidos")}, #{new_items} #{plural(new_items, "item novo", "itens novos")} na caixa de entrada"
      ] ++ Enum.map(rest, &failure/1)

    parts |> Enum.reject(&(&1 in [nil, false])) |> Enum.join(" · ")
  end

  defp failure({name, {:error, {:already_imported, _}}}), do: "#{name}: já tinha sido importado"
  defp failure({name, {:error, :unknown_format}}), do: "#{name}: formato não reconhecido"
  defp failure({name, {:error, :no_transactions}}), do: "#{name}: nenhuma transação encontrada"
  defp failure({name, {:error, _}}), do: "#{name}: não foi possível ler"

  defp plural(1, singular, _plural), do: singular
  defp plural(_, _singular, plural), do: plural

  defp upload_error(:too_large), do: "arquivo maior que 10 MB"
  defp upload_error(:not_accepted), do: "só OFX e CSV"
  defp upload_error(:too_many_files), do: "no máximo 10 arquivos por vez"
  defp upload_error(other), do: to_string(other)

  defp format_label(:ofx), do: "OFX"
  defp format_label(:csv), do: "CSV"

  defp bank_label(:nubank), do: "Nubank"
  defp bank_label(:itau), do: "Itaú"
  defp bank_label(_), do: "Banco"

  defp kind_label(:credit_card), do: "cartão"
  defp kind_label(:checking), do: "conta"
  defp kind_label(_), do: ""

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      nav={:import}
      inbox_count={@inbox_count}
    >
      <div>
        <h1 class="text-3xl font-bold tracking-tight">Importar</h1>
        <p class="text-sm text-base-content/60">
          Extratos e faturas exportados do banco. Nada entra no livro sem passar pela caixa de entrada.
        </p>
      </div>

      <div class="grid gap-4 xl:grid-cols-3">
        <.card
          title="Enviar arquivos"
          subtitle="OFX de conta, CSV do Nubank (conta e cartão fechado)"
          class="xl:col-span-2"
        >
          <.form
            for={%{}}
            as={:import}
            id="import-form"
            phx-change="validate"
            phx-submit="import"
            class="space-y-4"
          >
            <label
              phx-drop-target={@uploads.files.ref}
              class="flex cursor-pointer flex-col items-center justify-center gap-2 rounded-box border-2 border-dashed border-base-300 px-6 py-10 text-center text-sm text-base-content/70 hover:border-primary"
            >
              <.icon name="hero-arrow-up-tray" class="size-7 opacity-70" />
              <span>Arraste os arquivos aqui ou
              <span class="font-semibold text-primary">escolha no computador</span></span>
              <span class="text-xs text-base-content/50">Até 10 arquivos, 10 MB cada</span>
              <.live_file_input upload={@uploads.files} class="hidden" />
            </label>

            <ul :if={@uploads.files.entries != []} id="upload-entries" class="space-y-2">
              <li
                :for={entry <- @uploads.files.entries}
                class="flex items-center gap-3 rounded-field border border-base-300 px-3 py-2 text-sm"
              >
                <.icon name="hero-document-text" class="size-5 opacity-60" />
                <span class="flex-1 truncate font-mono text-xs">{entry.client_name}</span>
                <progress class="progress progress-primary w-24" value={entry.progress} max="100"></progress>
                <span
                  :for={err <- upload_errors(@uploads.files, entry)}
                  class="badge badge-soft badge-error badge-sm"
                >{upload_error(err)}</span>
                <button
                  type="button"
                  phx-click="cancel"
                  phx-value-ref={entry.ref}
                  class="btn btn-ghost btn-xs btn-square"
                  aria-label="Remover"
                >
                  <.icon name="hero-x-mark-micro" class="size-4" />
                </button>
              </li>
            </ul>
            <p :for={err <- upload_errors(@uploads.files)} class="text-sm text-error">
              {upload_error(err)}
            </p>

            <div class="flex flex-wrap items-end gap-3">
              <label class="form-control w-64">
                <span class="label-text mb-1 text-xs font-semibold text-base-content/60">Conta (opcional)</span>
                <select name="account_id" class="select w-full">
                  <option value="">Detectar pelo arquivo</option>
                  <option
                    :for={account <- @accounts}
                    value={account.id}
                    selected={@account_id == Integer.to_string(account.id)}
                  >
                    {account.name}
                  </option>
                </select>
              </label>
              <.button
                variant="primary"
                disabled={@uploads.files.entries == []}
                phx-disable-with="Lendo…"
              >
                Importar {if length(@uploads.files.entries) > 1,
                  do: "#{length(@uploads.files.entries)} arquivos",
                  else: "arquivo"}
              </.button>
            </div>
          </.form>
          <p class="text-xs text-base-content/50">
            Os arquivos são lidos e descartados; só o resumo do lote fica guardado. PDFs do Itaú entram na próxima etapa.
          </p>
        </.card>

        <.card title="Como exportar" subtitle="Onde encontrar os arquivos no banco">
          <ul class="space-y-3 text-sm text-base-content/80">
            <li>
              <b>Nubank conta</b>: no app, Extrato → ícone de exportar → período → OFX ou CSV. O arquivo chega por e-mail.
            </li>
            <li><b>Nubank cartão</b>: só faturas fechadas; abra a fatura → exportar → CSV.</li>
            <li>
              <b>Itaú</b>: extrato e fatura em PDF pelo internet banking; leitura de PDF chega na próxima etapa.
            </li>
          </ul>
        </.card>
      </div>

      <.card
        title="Importações recentes"
        subtitle="Cada arquivo vira um lote; repetir o mesmo arquivo não duplica nada"
      >
        <.empty_state :if={@batches == []} icon="hero-inbox-stack">
          Nenhum arquivo importado ainda.
        </.empty_state>
        <div :if={@batches != []} class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Arquivo</th>
                <th>Origem</th>
                <th>Período</th>
                <th class="text-right">Novos</th>
                <th class="text-right">Já conhecidos</th>
                <th>Status</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={batch <- @batches} id={"batch-#{batch.id}"}>
                <td class="font-mono text-xs">{batch.file_name}</td>
                <td>
                  {bank_label(batch.bank)} · {format_label(batch.format)} {kind_label(
                    batch.account_kind
                  )}<span :if={batch.bank_account}> · {batch.bank_account.name}</span>
                </td>
                <td class="text-base-content/70">
                  {if batch.period_start,
                    do: "#{short_date(batch.period_start)} a #{full_date(batch.period_end)}",
                    else: "—"}
                </td>
                <td class="tabular text-right">{batch.counts["new"]}</td>
                <td class="tabular text-right text-base-content/60">{batch.counts["duplicates"]}</td>
                <td>
                  <.badge kind={if(batch.status == :reviewed, do: :paid, else: :warn)}>
                    {if batch.status == :reviewed, do: "Revisado", else: "Pendente"}
                  </.badge>
                </td>
                <td class="text-right">
                  <.link
                    :if={batch.status == :pending}
                    navigate={~p"/entrada?#{%{"batch" => batch.id}}"}
                  >Ver na caixa de entrada</.link>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </.card>
    </Layouts.app>
    """
  end
end
