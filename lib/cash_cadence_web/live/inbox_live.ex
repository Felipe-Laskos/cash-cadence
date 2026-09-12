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
      inbox_count: Imports.count_pending()
    )
    |> stream(:items, items, reset: true)
  end

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
         after_action(socket, item, "Lançamento de #{brl(transaction.amount)} aprovado.")}

      {:error, _changeset} ->
        {:noreply,
         put_flash(socket, :error, "Não foi possível aprovar: confira categoria e tipo.")}
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

  defp source_label(item) do
    bank =
      case item.batch.bank do
        :nubank -> "Nubank"
        :itau -> "Itaú"
        _ -> "Extrato"
      end

    account = item.bank_account && item.bank_account.name
    format = if item.batch.format == :ofx, do: "OFX", else: "CSV"
    Enum.join(Enum.reject([bank, account, format], &is_nil/1), " · ")
  end

  defp confidence_badge(:high), do: {:paid, "confiança alta"}
  defp confidence_badge(:medium), do: {:warn, "confiança média"}
  defp confidence_badge(_), do: nil

  defp category_default(item) do
    (item.suggested_category && item.suggested_category.name) ||
      (item.match_transaction && item.match_transaction.category &&
         item.match_transaction.category.name) || ""
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} nav={:inbox} inbox_count={@inbox_count}>
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
            class="card-body gap-3 p-4 lg:grid lg:grid-cols-[12rem_1fr_9rem_auto] lg:items-center"
          >
            <input type="hidden" name="item_id" value={item.id} />
            <div class="min-w-0 space-y-1 text-xs text-base-content/60">
              <.badge kind={:neutral} class="h-auto max-w-full whitespace-normal py-1 text-left">
                <.icon name="hero-building-library-micro" class="size-3" /> {source_label(item)}
              </.badge>
              <div class="font-mono">{full_date(item.posted_on || item.date)}</div>
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
                  list="inbox-category-options"
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
                <.badge
                  :if={confidence_badge(item.confidence)}
                  kind={elem(confidence_badge(item.confidence), 0)}
                >
                  <.icon name="hero-sparkles-micro" class="size-3" /> {elem(
                    confidence_badge(item.confidence),
                    1
                  )}
                </.badge>
                <.badge :if={"uncategorized" in item.flags} kind={:warn}>
                  sem categoria conhecida
                </.badge>
              </div>
              <div :if={item.match_transaction} class="alert alert-info alert-soft py-2 text-sm">
                <.icon name="hero-arrows-right-left-micro" class="size-4" />
                <span>
                  Você já lançou à mão <b>{(item.match_transaction.category && item.match_transaction.category.name) || item.match_transaction.description || "sem categoria"} · {brl(item.match_transaction.amount)} em {short_date(item.match_transaction.date)}</b>.
                  Conciliar só anexa os dados do banco a esse lançamento.
                </span>
              </div>
              <div
                :if={item.counterpart_transaction}
                class="alert alert-warning alert-soft py-2 text-sm"
              >
                <.icon name="hero-arrow-path-micro" class="size-4" />
                <span>Parece transferência: há um lançamento de {brl(
                  item.counterpart_transaction.amount
                )} em {short_date(item.counterpart_transaction.date)} do outro lado.</span>
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
