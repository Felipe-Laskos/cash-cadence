defmodule CashCadenceWeb.InboxLive do
  use CashCadenceWeb, :live_view

  alias CashCadence.{Imports, Ledger}

  @kinds [{"Despesa", "expense"}, {"Receita", "income"}, {"Transferência", "transfer"}]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Caixa de entrada", kinds: @kinds)
     |> stream_configure(:items, dom_id: &"item-#{&1.id}")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    batch = params["batch"] && Imports.get_batch!(params["batch"])
    {:noreply, socket |> assign(batch: batch) |> reload()}
  end

  defp reload(%{assigns: %{batch: batch}} = socket) do
    items = Imports.list_inbox(%{batch_id: batch && batch.id})

    socket
    |> assign(
      count: length(items),
      confident: Enum.count(items, &(&1.confidence == :high and &1.flags == [])),
      suggestions: Ledger.category_suggestions(),
      inbox_count: Imports.count_pending(),
      batches: Imports.pending_batches()
    )
    |> stream(:items, items, reset: true)
  end

  defp other_competence?(%{competence: %Date{} = competence, date: %Date{} = date}),
    do: competence.year != date.year or competence.month != date.month

  defp other_competence?(_item), do: false

  defp counterpart_noun(:income), do: "receita"
  defp counterpart_noun(_kind), do: "despesa"

  defp after_action(socket, item, message) do
    socket
    |> stream_delete(:items, item)
    |> assign(count: socket.assigns.count - 1, inbox_count: Imports.count_pending())
    |> assign(
      confident:
        Enum.count(
          Imports.list_inbox(%{batch_id: socket.assigns.batch && socket.assigns.batch.id}),
          &(&1.confidence == :high and &1.flags == [])
        )
    )
    |> put_flash(:info, message)
  end

  @impl true
  def handle_event("approve", %{"item_id" => id, "item" => attrs}, socket) do
    item = Imports.get_item!(id)

    case Imports.approve(item, attrs) do
      {:ok, transaction} ->
        {:noreply,
         after_action(
           socket,
           item,
           "Lançamento de #{brl(transaction.amount)} aprovado." <>
             forecast_note(item, transaction)
         )}

      {:error, _changeset} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Não foi possível aprovar: confira tipo, categoria, data e valor."
         )}
    end
  end

  def handle_event("merge", %{"id" => id}, socket) do
    item = Imports.get_item!(id)

    case Imports.merge(item, item.match_transaction) do
      {:ok, _transaction} ->
        {:noreply, after_action(socket, item, "Conciliado com o lançamento já existente.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Não foi possível conciliar.")}
    end
  end

  def handle_event("ignore", %{"id" => id}, socket) do
    item = Imports.get_item!(id)
    {:ok, _} = Imports.ignore(item)
    {:noreply, after_action(socket, item, "Item ignorado.")}
  end

  def handle_event("approve_all", _params, socket) do
    approved =
      Imports.approve_high_confidence(%{
        batch_id: socket.assigns.batch && socket.assigns.batch.id
      })

    {:noreply,
     socket
     |> put_flash(
       :info,
       "#{approved} #{if approved == 1, do: "item aprovado", else: "itens aprovados"} automaticamente."
     )
     |> reload()}
  end

  defp forecast_note(item, transaction) do
    case Imports.installment_forecast(item, transaction) do
      nil ->
        ""

      %{remaining: remaining, ends_on: ends_on} ->
        " #{remaining} #{if remaining == 1, do: "parcela prevista", else: "parcelas previstas"} em Despesas fixas até #{month_short(ends_on)}."
    end
  end

  defp source_label(item) do
    bank =
      case item.batch.bank do
        :nubank -> "Nubank"
        :itau -> "Itaú"
        _ -> "Extrato"
      end

    account = item.bank_account && item.bank_account.name
    Enum.join(Enum.reject([bank, account, format_label(item.batch.format)], &is_nil/1), " · ")
  end

  defp format_label(:ofx), do: "OFX"
  defp format_label(:csv), do: "CSV"
  defp format_label(:pdf), do: "PDF"
  defp format_label(:image), do: "Foto"

  defp hint_label(%{"bank_category" => category} = payload) do
    Enum.join(Enum.reject([category, payload["city"]], &is_nil/1), " · ")
  end

  defp hint_label(_payload), do: nil

  defp confidence_badge(%{confidence: :high} = item),
    do: {:paid, "confiança alta" <> source(item)}

  defp confidence_badge(%{confidence: :medium} = item),
    do: {:warn, "confiança média" <> source(item)}

  defp confidence_badge(_item), do: nil

  defp source(%{payload: %{"suggestion_source" => "rule"}}), do: " · regra"
  defp source(%{payload: %{"suggestion_source" => "memory"}}), do: " · memória"
  defp source(%{payload: %{"suggestion_source" => "bill"}}), do: " · fixa"
  defp source(_item), do: ""

  defp category_default(item) do
    (item.suggested_category && item.suggested_category.name) ||
      (item.match_transaction && item.match_transaction.category &&
         item.match_transaction.category.name) || ""
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      nav={:inbox}
      inbox_count={@inbox_count}
      duplicate_count={@duplicate_count}
    >
      <div class="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 class="text-3xl font-bold tracking-tight">Caixa de entrada</h1>
          <p class="text-sm text-base-content/60">
            {@count} {if @count == 1, do: "item aguarda", else: "itens aguardam"} sua revisão
            <span :if={@batch}> · lote <span class="font-mono text-xs">{@batch.file_name}</span>
            <.link patch={~p"/entrada"} class="ml-1">ver todos</.link></span>
          </p>
        </div>
        <div class="flex flex-wrap items-center gap-2">
          <.link navigate={~p"/importar"} class="btn btn-sm"><.icon
            name="hero-arrow-up-tray-micro"
            class="size-4"
          /> Importar arquivo</.link>
          <button
            :if={@confident > 0}
            type="button"
            phx-click="approve_all"
            class="btn btn-primary btn-sm"
            data-confirm={"Aprovar #{@confident} itens de alta confiança sem revisar um a um?"}
          >
            <.icon name="hero-check-micro" class="size-4" /> Aprovar {@confident} com alta confiança
          </button>
        </div>
      </div>

      <div
        :if={@batch && @batch.warnings != []}
        class="alert alert-warning alert-soft items-start text-sm"
      >
        <.icon name="hero-exclamation-triangle-micro" class="mt-0.5 size-4" />
        <div>
          <p class="font-semibold">O arquivo não fechou por completo. Confira antes de aprovar:</p>
          <ul class="mt-1 list-disc space-y-1 pl-4">
            <li :for={warning <- @batch.warnings}>{warning}</li>
          </ul>
        </div>
      </div>
      <details
        :if={@batch && @batch.raw_text}
        class="collapse collapse-arrow border border-base-300 bg-base-100"
      >
        <summary class="collapse-title text-sm font-semibold">Texto extraído do arquivo</summary>
        <div class="collapse-content">
          <p class="mb-2 text-xs text-base-content/60">
            É o que o leitor de PDF enxergou. Se faltou algo na lista abaixo, lance à mão em <.link
              navigate={~p"/lancamentos"}
              class="underline"
            >Lançamentos</.link>.
          </p>
          <pre class="max-h-96 overflow-auto rounded-box bg-base-200 p-3 font-mono text-xs leading-relaxed">{@batch.raw_text}</pre>
        </div>
      </details>

      <div :if={length(@batches) > 1} class="flex flex-wrap items-center gap-2">
        <span class="text-base-content/60 text-sm">Revisar um arquivo por vez:</span>
        <.link
          :for={entry <- @batches}
          patch={~p"/entrada?#{%{"batch" => entry.id}}"}
          class={["btn btn-xs", @batch && @batch.id == entry.id && "btn-primary"]}
        >
          <span class="max-w-52 truncate font-mono">{entry.file_name}</span>
          <span class="badge badge-ghost badge-xs">{entry.count}</span>
        </.link>
        <.link :if={@batch} patch={~p"/entrada"} class="btn btn-ghost btn-xs">Todos</.link>
      </div>

      <div id="inbox" phx-update="stream" class="space-y-3">
        <div id="inbox-empty" class="hidden only:block">
          <.empty_state icon="hero-inbox">
            Nada pendente. Importe um extrato em <.link navigate={~p"/importar"} class="underline">Importar</.link>.
          </.empty_state>
        </div>
        <article
          :for={{dom_id, item} <- @streams.items}
          id={dom_id}
          class={[
            "card border bg-base-100",
            item.flags != [] && "border-warning/50",
            item.flags == [] && "border-base-300"
          ]}
        >
          <form
            id={"#{dom_id}-form"}
            phx-submit="approve"
            phx-hook=".TransferCategory"
            class="card-body gap-3 p-4 lg:grid lg:grid-cols-[12rem_1fr_9rem_auto] lg:items-center"
          >
            <input type="hidden" name="item_id" value={item.id} />
            <div class="min-w-0 space-y-1 text-xs text-base-content/60">
              <.badge kind={:neutral} class="h-auto max-w-full whitespace-normal py-1 text-left">
                <.icon name="hero-building-library-micro" class="size-3" /> {source_label(item)}
              </.badge>
              <div class="font-mono">{full_date(item.posted_on || item.date)}</div>
              <div :if={other_competence?(item)} class="text-base-content/50">
                competência {month_label(item.competence)}
              </div>
            </div>

            <div class="min-w-0 space-y-2">
              <p class="truncate font-mono text-sm text-base-content/70" title={item.raw_description}>
                {item.raw_description}
              </p>
              <div class="flex flex-wrap items-center gap-2">
                <select name="item[kind]" class="select select-sm w-36">
                  <option
                    :for={{label, value} <- @kinds}
                    value={value}
                    selected={Atom.to_string(item.kind) == value}
                  >
                    {label}
                  </option>
                </select>
                <input
                  type="text"
                  name="item[category_name]"
                  value={category_default(item)}
                  id={"#{dom_id}-category"}
                  list="inbox-category-options"
                  phx-hook="Typeahead"
                  autocomplete="off"
                  placeholder="Categoria"
                  class="input input-sm w-44"
                />
                <input
                  type="text"
                  name="item[description]"
                  value={item.description}
                  placeholder="Descrição"
                  class="input input-sm w-56"
                />
                <input
                  type="text"
                  name="item[date]"
                  value={full_date(item.date)}
                  inputmode="numeric"
                  maxlength="10"
                  placeholder="dd/mm/aaaa"
                  phx-hook=".BrDate"
                  id={"#{dom_id}-date"}
                  class="input input-sm w-32 font-mono"
                  aria-label="Data"
                />
                <input
                  type="text"
                  name="item[amount]"
                  value={input_amount(item.amount)}
                  inputmode="decimal"
                  class="input input-sm w-28 text-right font-mono"
                  aria-label="Valor"
                />
                <.badge :if={item.payload["ocr"]} kind={:warn}>
                  <.icon name="hero-eye-micro" class="size-3" /> lido por OCR: confira data e valor
                </.badge>
                <.badge
                  :if={confidence_badge(item)}
                  kind={elem(confidence_badge(item), 0)}
                >
                  <.icon name="hero-sparkles-micro" class="size-3" /> {elem(
                    confidence_badge(item),
                    1
                  )}
                </.badge>
                <.badge :if={"uncategorized" in item.flags} kind={:warn}>
                  sem categoria conhecida
                </.badge>
                <.badge :if={item.payload["installment"]} kind={:neutral}>
                  parcela {item.payload["installment"]["number"]}/{item.payload["installment"]["of"]}
                </.badge>
                <.badge :if={hint_label(item.payload)} kind={:neutral}>
                  Itaú: {hint_label(item.payload)}
                </.badge>
                <.badge :if={item.payload["bill_name"]} kind={:accent}>
                  <.icon name="hero-arrow-path-micro" class="size-3" />
                  fixa: {item.payload["bill_name"]}
                </.badge>
              </div>
              <div :if={item.match_transaction} class="alert alert-info alert-soft py-2 text-sm">
                <.icon name="hero-arrows-right-left-micro" class="size-4" />
                <span>
                  Você já lançou à mão <b>{(item.match_transaction.category && item.match_transaction.category.name) || item.match_transaction.description || "sem categoria"} · {brl(item.match_transaction.amount)} em {short_date(item.match_transaction.date)}</b>.
                  Conciliar só anexa os dados do banco a esse lançamento.
                  <b :if={item.match_transaction.competence != item.competence}>
                    Mas aquele lançamento está na competência de {month_label(
                      item.match_transaction.competence
                    )} e este é de {month_label(item.competence)}: se forem meses diferentes de
                    verdade, aprove como novo em vez de conciliar.
                  </b>
                </span>
              </div>
              <div :if={"settled" in item.flags} class="alert alert-info alert-soft py-2 text-sm">
                <.icon name="hero-check-circle-micro" class="size-4" />
                <span>
                  Este pagamento de fatura já está no livro pelo extrato da conta. Ignorar deixa o
                  livro mais enxuto; aprovar registra a contraparte no cartão, sem mexer em nenhum
                  total.
                </span>
              </div>
              <div
                :if={item.counterpart_transaction && "settled" not in item.flags}
                class="alert alert-warning alert-soft py-2 text-sm"
              >
                <.icon name="hero-arrow-path-micro" class="size-4" />
                <span :if={item.counterpart_transaction.kind == :transfer}>
                  Parece transferência: há um lançamento de {brl(item.counterpart_transaction.amount)} em {short_date(
                    item.counterpart_transaction.date
                  )} do outro lado.
                </span>
                <label
                  :if={item.counterpart_transaction.kind != :transfer}
                  class="flex flex-wrap items-center gap-2"
                >
                  <input
                    type="checkbox"
                    name="item[link_counterpart]"
                    value="true"
                    checked
                    class="checkbox checkbox-sm"
                  />
                  <span>
                    Parece transferência: há um lançamento de
                    <b>{brl(item.counterpart_transaction.amount)} em {short_date(
                      item.counterpart_transaction.date
                    )}</b>
                    do outro lado. Marcado, aquele lançamento também vira transferência e para de
                    contar como {counterpart_noun(item.counterpart_transaction.kind)}.
                  </span>
                </label>
              </div>
              <div
                :if={"transfer" in item.flags and is_nil(item.counterpart_transaction)}
                class="alert alert-warning alert-soft py-2 text-sm"
              >
                <.icon name="hero-arrow-path-micro" class="size-4" />
                <span>Parece transferência entre suas contas: o outro lado também está na caixa de entrada.</span>
              </div>
              <div
                :if={item.payload["reimbursement_of_id"]}
                class="alert alert-info alert-soft py-2 text-sm"
              >
                <.icon name="hero-arrow-uturn-left-micro" class="size-4" />
                <label class="flex flex-wrap items-center gap-2">
                  <input
                    type="checkbox"
                    name="item[link_reimbursement]"
                    value="true"
                    checked
                    class="checkbox checkbox-sm"
                  />
                  <span>
                    Parece reembolso da despesa <b>{item.payload["reimbursement_description"]} · {item.payload[
                      "reimbursement_date"
                    ]
                    |> Date.from_iso8601!()
                    |> short_date()}</b>. Marcado, abate da despesa em vez de contar como receita.
                  </span>
                </label>
              </div>
              <div
                :if={"possible_duplicate" in item.flags}
                class="alert alert-warning alert-soft py-2 text-sm"
              >
                <.icon name="hero-exclamation-triangle-micro" class="size-4" />
                <span>Já existe um lançamento com mesma data, valor e descrição.</span>
              </div>
            </div>

            <div class="tabular text-right text-lg font-bold">
              <.money value={item.amount} kind={item.kind} currency />
            </div>

            <div class="flex flex-wrap items-center justify-end gap-1">
              <button
                :if={item.match_transaction}
                type="button"
                phx-click="merge"
                phx-value-id={item.id}
                class="btn btn-primary btn-sm"
              >
                <.icon name="hero-arrows-right-left-micro" class="size-4" /> Conciliar
              </button>
              <button
                type="submit"
                data-confirm={
                  "possible_duplicate" in item.flags &&
                    "Já existe um lançamento com mesma data, valor e descrição. Aprovar mesmo assim?"
                }
                class={[
                  "btn btn-sm",
                  item.match_transaction && "btn-ghost",
                  !item.match_transaction && "btn-primary"
                ]}
              >
                <.icon name="hero-check-micro" class="size-4" /> {if item.match_transaction,
                  do: "É outro",
                  else: "Aprovar"}
              </button>
              <button
                type="button"
                phx-click="ignore"
                phx-value-id={item.id}
                class="btn btn-ghost btn-sm"
              >Ignorar</button>
            </div>
          </form>
          <script :type={Phoenix.LiveView.ColocatedHook} name=".BrDate">
            export default {
              mounted() { this.el.addEventListener("input", () => this.mask()) },
              mask() {
                const digits = this.el.value.replace(/\D/g, "").slice(0, 8)
                const parts = [digits.slice(0, 2), digits.slice(2, 4), digits.slice(4, 8)]
                this.el.value = parts.filter(part => part !== "").join("/")
              }
            }
          </script>
          <script :type={Phoenix.LiveView.ColocatedHook} name=".TransferCategory">
            export default {
              mounted() { this.sync(); this.el.addEventListener("change", () => this.sync()) },
              updated() { this.sync() },
              sync() {
                const kind = this.el.querySelector("select[name='item[kind]']")
                const category = this.el.querySelector("input[name='item[category_name]']")
                if (!kind || !category) return
                const transfer = kind.value === "transfer"
                category.disabled = transfer
                category.placeholder = transfer ? "transferência não tem categoria" : "Categoria"
                if (transfer) category.value = ""
              }
            }
          </script>
        </article>
      </div>

      <datalist id="inbox-category-options">
        <option :for={suggestion <- @suggestions} value={suggestion.name}>
          {suggestion.uses} usos
        </option>
      </datalist>
    </Layouts.app>
    """
  end
end
