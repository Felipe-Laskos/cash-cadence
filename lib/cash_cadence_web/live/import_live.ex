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
        password: "",
        batches: Imports.list_batches(),
        detail: nil
      )
      |> allow_upload(:files, accept: :any, max_entries: 10, max_file_size: 10_000_000)

    {:ok, socket}
  end

  @impl true
  def handle_event("validate", params, socket) do
    {:noreply,
     assign(socket,
       account_id: params["account_id"] || socket.assigns.account_id,
       password: params["password"] || socket.assigns.password
     )}
  end

  def handle_event("cancel", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :files, ref)}

  def handle_event("show_batch", %{"id" => id}, socket),
    do: {:noreply, assign(socket, detail: Imports.get_batch!(id))}

  def handle_event("close_detail", _params, socket), do: {:noreply, assign(socket, detail: nil)}

  def handle_event("import", params, socket) do
    account_id = parse_account(params["account_id"])

    results =
      consume_uploaded_entries(socket, :files, fn %{path: path}, entry ->
        {:ok,
         {entry.client_name,
          Imports.ingest_binary(File.read!(path), entry.client_name,
            source: :upload,
            bank_account_id: account_id,
            password: params["password"]
          )}}
      end)

    {imported, rest} = Enum.split_with(results, &match?({_, {:ok, _}}, &1))
    batches = Enum.map(imported, fn {_, {:ok, batch}} -> batch end)
    new_items = batches |> Enum.map(& &1.counts["new"]) |> Enum.sum()
    auto_approved = batches |> Enum.map(&(&1.counts["auto_approved"] || 0)) |> Enum.sum()
    pending = new_items - auto_approved
    warnings = batches |> Enum.map(&length(&1.warnings)) |> Enum.sum()

    socket =
      socket
      |> assign(batches: Imports.list_batches(), inbox_count: Imports.count_pending())
      |> put_flash(
        flash_kind(imported, rest),
        summary(imported, rest, new_items, warnings, auto_approved)
      )

    case batches do
      [batch] when pending > 0 ->
        {:noreply, push_navigate(socket, to: ~p"/entrada?#{%{"batch" => batch.id}}")}

      _ when pending > 0 ->
        {:noreply, push_navigate(socket, to: ~p"/entrada")}

      _ ->
        {:noreply, socket}
    end
  end

  defp parse_account(""), do: nil
  defp parse_account(nil), do: nil
  defp parse_account(id), do: String.to_integer(id)

  defp flash_kind([], _rest), do: :error
  defp flash_kind(_imported, _rest), do: :info

  defp summary(imported, rest, new_items, warnings, auto_approved) do
    parts =
      [
        imported != [] &&
          "#{length(imported)} #{plural(length(imported), "arquivo lido", "arquivos lidos")}, #{new_items} #{plural(new_items, "item novo", "itens novos")} na caixa de entrada",
        auto_approved > 0 &&
          "#{auto_approved} #{plural(auto_approved, "aprovado automaticamente", "aprovados automaticamente")}",
        warnings > 0 && "#{warnings} #{plural(warnings, "alerta", "alertas")} para conferir"
      ] ++ Enum.map(rest, &failure/1)

    parts |> Enum.reject(&(&1 in [nil, false])) |> Enum.join(" · ")
  end

  defp failure({name, {:error, {:already_imported, _}}}), do: "#{name}: já tinha sido importado"

  defp failure({name, {:error, :unknown_format}}),
    do: "#{name}: formato não reconhecido (aceito OFX, CSV do Nubank e PDF do Itaú)"

  defp failure({name, {:error, {:unknown_layout, _text}}}),
    do:
      "#{name}: PDF não reconhecido, por enquanto só extrato e fatura do Itaú e extrato do Nubank"

  defp failure({name, {:error, :encrypted}}),
    do: "#{name}: PDF protegido por senha, informe a senha no campo ao lado da conta"

  defp failure({name, {:error, :wrong_password}}), do: "#{name}: senha do PDF incorreta"

  defp failure({name, {:error, :qpdf_missing}}),
    do: "#{name}: qpdf não encontrado neste computador para abrir PDF com senha"

  defp failure({name, {:error, :ocr_missing}}),
    do: "#{name}: OCR (ocrmypdf) não encontrado neste computador"

  defp failure({name, {:error, {:ocr_failed, _status}}}),
    do: "#{name}: o OCR não conseguiu ler a imagem"

  defp failure({name, {:error, :timeout}}),
    do: "#{name}: a leitura demorou demais e foi cancelada"

  defp failure({name, {:error, :pdftotext_missing}}),
    do: "#{name}: leitor de PDF (pdftotext) não encontrado neste computador"

  defp failure({name, {:error, :no_transactions}}), do: "#{name}: nenhuma transação encontrada"
  defp failure({name, {:error, _}}), do: "#{name}: não foi possível ler"

  defp plural(1, singular, _plural), do: singular
  defp plural(_, _singular, plural), do: plural

  defp upload_error(:too_large), do: "arquivo maior que 10 MB"
  defp upload_error(:not_accepted), do: "só OFX, CSV, PDF e imagens"
  defp upload_error(:too_many_files), do: "no máximo 10 arquivos por vez"
  defp upload_error(other), do: to_string(other)

  defp format_label(:ofx), do: "OFX"
  defp format_label(:csv), do: "CSV"
  defp format_label(:pdf), do: "PDF"
  defp format_label(:image), do: "Foto"

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
      duplicate_count={@duplicate_count}
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
          subtitle="OFX de conta, CSV do Nubank, PDF do Itaú (extrato e fatura, inclusive escaneado ou foto)"
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
              <label class="form-control w-48">
                <span class="label-text mb-1 text-xs font-semibold text-base-content/60">Senha do PDF (se tiver)</span>
                <input
                  type="password"
                  name="password"
                  value={@password}
                  autocomplete="off"
                  placeholder="só para PDF protegido"
                  class="input w-full"
                />
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
            Os arquivos são lidos e descartados; fica guardado o resumo do lote e, para PDF, o texto extraído para conferência.
            A leitura confere saldo por saldo e total da fatura: qualquer diferença vira alerta. PDF só imagem e fotos passam por OCR local e os itens pedem conferência de data e valor.
            A senha não é guardada.
          </p>
        </.card>

        <.card title="Como exportar" subtitle="Onde encontrar os arquivos no banco">
          <ul class="space-y-3 text-sm text-base-content/80">
            <li>
              <b>Nubank conta</b>: no app, Extrato → ícone de exportar → período → OFX ou CSV. O arquivo chega por e-mail.
            </li>
            <li><b>Nubank cartão</b>: só faturas fechadas; abra a fatura → exportar → CSV.</li>
            <li>
              <b>Itaú conta</b>: no app ou internet banking, Extrato → compartilhar/exportar → PDF.
            </li>
            <li>
              <b>Itaú cartão</b>: Cartões → fatura fechada → PDF. Se o PDF pedir senha, informe-a no campo ao lado da conta.
            </li>
            <li>
              <b>Escaneado ou foto</b>: PDF sem texto, JPG ou PNG do extrato ou da fatura. Foto reta, bem iluminada e com a página inteira.
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
                <td class="whitespace-nowrap text-right">
                  <button
                    :if={batch.warnings != []}
                    type="button"
                    phx-click="show_batch"
                    phx-value-id={batch.id}
                    class="btn btn-warning btn-soft btn-xs"
                  >
                    <.icon name="hero-exclamation-triangle-micro" class="size-3" />
                    {length(batch.warnings)} {if length(batch.warnings) == 1,
                      do: "alerta",
                      else: "alertas"}
                  </button>
                  <button
                    :if={batch.warnings == [] and batch.raw_text}
                    type="button"
                    phx-click="show_batch"
                    phx-value-id={batch.id}
                    class="btn btn-ghost btn-xs"
                  >
                    Texto extraído
                  </button>
                  <.link
                    :if={batch.status == :pending}
                    navigate={~p"/entrada?#{%{"batch" => batch.id}}"}
                    class="btn btn-ghost btn-xs"
                  >
                    Ver na caixa de entrada
                  </.link>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </.card>

      <.modal
        :if={@detail}
        id="batch-detail"
        title={@detail.file_name}
        subtitle="Texto extraído do arquivo, do jeito que o leitor de PDF enxergou. Se algo ficou de fora da caixa de entrada, é daqui que você lança à mão."
        on_cancel={JS.push("close_detail")}
        max_width="max-w-4xl"
      >
        <.modal_body>
          <div
            :if={@detail.warnings != []}
            class="alert alert-warning alert-soft mb-3 items-start text-sm"
          >
            <.icon name="hero-exclamation-triangle-micro" class="mt-0.5 size-4" />
            <ul class="list-disc space-y-1 pl-4">
              <li :for={warning <- @detail.warnings}>{warning}</li>
            </ul>
          </div>
          <pre
            :if={@detail.raw_text}
            class="overflow-x-auto rounded-box bg-base-200 p-3 font-mono text-xs leading-relaxed"
          >{@detail.raw_text}</pre>
        </.modal_body>
        <.modal_footer>
          <.link navigate={~p"/lancamentos"} class="btn btn-ghost btn-sm">Lançar à mão</.link>
          <button type="button" phx-click="close_detail" class="btn btn-sm">Fechar</button>
        </.modal_footer>
      </.modal>
    </Layouts.app>
    """
  end
end
