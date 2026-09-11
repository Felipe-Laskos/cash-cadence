defmodule CashCadenceWeb.TransactionLive.Index do
  use CashCadenceWeb, :live_view

  alias CashCadence.Ledger
  alias CashCadence.Ledger.Transaction
  alias CashCadence.Money

  @kinds [{"Despesa", "expense"}, {"Receita", "income"}, {"Transferência", "transfer"}]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Lançamentos", kinds: @kinds)
     |> stream_configure(:days, dom_id: & &1.id)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    month =
      case parse_month(params["m"]) do
        {:ok, date} -> date
        :error -> Date.beginning_of_month(Date.utc_today())
      end

    filters = %{
      kind: parse_kind(params["kind"]),
      category: params["category"] || "",
      search: params["q"] || ""
    }

    editing = params["edit"] && Ledger.get_transaction!(params["edit"])

    socket =
      socket
      |> assign(month: month, filters: filters, editing: editing, focus_new: params["new"] == "1")
      |> assign_form(form_changeset(editing, month))
      |> reload()

    {:noreply, socket}
  end

  defp reload(%{assigns: %{month: month, filters: filters}} = socket) do
    transactions =
      Ledger.list_transactions(%{
        competence: month,
        kind: filters.kind,
        category_id: category_filter(filters.category),
        search: filters.search
      })

    socket
    |> assign(
      count: length(transactions),
      totals: Ledger.month_totals(month),
      uncategorized: Ledger.count_uncategorized(month),
      suggestions: Ledger.category_suggestions(),
      categories: Ledger.list_categories()
    )
    |> stream(:days, group_by_day(transactions), reset: true)
  end

  defp group_by_day(transactions) do
    transactions
    |> Enum.group_by(& &1.date)
    |> Enum.sort_by(fn {date, _} -> date end, {:desc, Date})
    |> Enum.map(fn {date, items} ->
      %{
        id: "day-" <> Date.to_iso8601(date),
        date: date,
        transactions: items,
        total: day_total(items)
      }
    end)
  end

  defp day_total(items) do
    Enum.reduce(items, Money.zero(), fn
      %{kind: :income, amount: amount}, acc -> Decimal.add(acc, amount)
      %{kind: :expense, amount: amount}, acc -> Decimal.sub(acc, amount)
      _transfer, acc -> acc
    end)
  end

  defp form_changeset(nil, month) do
    Ledger.change_transaction(%Transaction{}, %{date: default_date(month), kind: :expense})
  end

  defp form_changeset(%Transaction{} = transaction, _month) do
    Ledger.change_transaction(%{
      transaction
      | category_name: transaction.category && transaction.category.name
    })
  end

  defp default_date(month) do
    today = Date.utc_today()

    cond do
      Date.beginning_of_month(today) == month -> today
      Date.compare(month, today) == :lt -> Date.end_of_month(month)
      true -> month
    end
  end

  defp assign_form(socket, changeset), do: assign(socket, form: to_form(changeset))

  defp parse_kind(kind) when kind in ["income", "expense", "transfer"],
    do: String.to_existing_atom(kind)

  defp parse_kind(_), do: nil

  defp category_filter(""), do: nil
  defp category_filter("none"), do: :none

  defp category_filter(value) do
    case Integer.parse(value) do
      {id, ""} -> id
      _ -> nil
    end
  end

  defp list_path(assigns, overrides \\ %{}) do
    params =
      %{
        "m" => month_param(assigns.month),
        "kind" => assigns.filters.kind && Atom.to_string(assigns.filters.kind),
        "category" => assigns.filters.category,
        "q" => assigns.filters.search
      }
      |> Map.merge(overrides)
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.new()

    ~p"/lancamentos?#{params}"
  end

  @impl true
  def handle_event("validate", %{"transaction" => params}, socket) do
    changeset =
      (socket.assigns.editing || %Transaction{})
      |> Ledger.change_transaction(params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"transaction" => params}, %{assigns: %{editing: nil}} = socket) do
    case Ledger.create_transaction(params) do
      {:ok, transaction} ->
        changeset =
          Ledger.change_transaction(%Transaction{}, %{
            date: transaction.date,
            kind: transaction.kind
          })

        {:noreply, socket |> assign_form(changeset) |> reload()}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event(
        "save",
        %{"transaction" => params},
        %{assigns: %{editing: transaction}} = socket
      ) do
    case Ledger.update_transaction(transaction, params) do
      {:ok, _transaction} ->
        {:noreply,
         socket
         |> put_flash(:info, "Lançamento atualizado.")
         |> push_patch(to: list_path(socket.assigns))}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, push_patch(socket, to: list_path(socket.assigns))}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    {:ok, _} = id |> Ledger.get_transaction!() |> Ledger.delete_transaction()
    {:noreply, socket |> put_flash(:info, "Lançamento excluído.") |> reload()}
  end

  def handle_event("filter", params, socket) do
    overrides = %{"category" => params["category"], "q" => params["q"]}
    {:noreply, push_patch(socket, to: list_path(socket.assigns, overrides))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} nav={:transactions}>
      <div class="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 class="text-3xl font-bold tracking-tight">Lançamentos</h1>
          <p class="text-sm text-base-content/60">
            {month_label(@month)} · {@count} {if @count == 1, do: "lançamento", else: "lançamentos"}
            <span :if={@totals.count > 0}> · {@totals.income_count} receitas, {@totals.expense_count} despesas</span>
          </p>
        </div>
        <div class="flex flex-wrap items-center gap-2">
          <.month_nav
            month={@month}
            base={~p"/lancamentos"}
            params={
              %{"kind" => @filters.kind, "category" => @filters.category, "q" => @filters.search}
            }
          />
        </div>
      </div>

      <form id="filters" phx-change="filter" class="flex flex-wrap items-center gap-2">
        <div class="join">
          <.link
            :for={{label, value} <- [{"Todos", ""} | @kinds]}
            patch={list_path(assigns, %{"kind" => value})}
            class={["btn btn-sm join-item", kind_active?(@filters.kind, value) && "btn-active"]}
          >
            {label}
          </.link>
        </div>
        <select name="category" class="select select-sm w-48">
          <option value="">Categoria: todas</option>
          <option value="none" selected={@filters.category == "none"}>Sem categoria</option>
          <option
            :for={category <- @categories}
            value={category.id}
            selected={@filters.category == Integer.to_string(category.id)}
          >
            {category.name}
          </option>
        </select>
        <label class="input input-sm w-64">
          <.icon name="hero-magnifying-glass-micro" class="size-4 opacity-60" />
          <input
            type="search"
            name="q"
            value={@filters.search}
            placeholder="Buscar descrição ou categoria"
            phx-debounce="300"
          />
        </label>
        <.link
          :if={@uncategorized > 0}
          patch={list_path(assigns, %{"category" => "none"})}
          class="badge badge-soft badge-warning gap-1"
        >
          <.icon name="hero-exclamation-triangle-micro" class="size-3" /> {@uncategorized} sem categoria
        </.link>
      </form>

      <section class="card border border-base-300 bg-base-100">
        <.form
          for={@form}
          id="transaction-form"
          phx-change="validate"
          phx-submit={JS.push("save") |> JS.focus(to: "#transaction_category_name")}
          class={[
            "grid gap-2 border-b border-base-300 p-4 md:grid-cols-[9rem_10rem_1fr_1fr_9rem_auto] md:items-start",
            @editing && "bg-secondary/30"
          ]}
        >
          <.input field={@form[:date]} type="date" required />
          <.input field={@form[:kind]} type="select" options={@kinds} />
          <div>
            <.input
              field={@form[:category_name]}
              type="text"
              list="category-options"
              autocomplete="off"
              placeholder="Categoria"
              phx-mounted={(@focus_new || @editing) && JS.focus()}
            />
            <datalist id="category-options">
              <option :for={suggestion <- @suggestions} value={suggestion.name}>
                {suggestion.uses} usos{if suggestion.fixed, do: " · fixa"}
              </option>
            </datalist>
          </div>
          <.input field={@form[:description]} type="text" placeholder="Descrição (opcional)" />
          <.input
            field={@form[:amount]}
            type="text"
            inputmode="decimal"
            placeholder="0,00"
            value={input_amount(@form[:amount].value)}
            required
            class="input tabular text-right"
          />
          <div class="flex gap-1">
            <.button variant="primary" phx-disable-with="Salvando…">{if @editing,
              do: "Salvar",
              else: "Adicionar"}</.button>
            <button :if={@editing} type="button" phx-click="cancel" class="btn">Cancelar</button>
          </div>
        </.form>
        <p class="px-4 py-2 text-xs text-base-content/50">
          Enter salva e mantém a data para o próximo · a categoria aceita as primeiras letras · valores com vírgula ou ponto
        </p>

        <div id="days" phx-update="stream" class="divide-y divide-base-300">
          <div id="days-empty" class="hidden only:block">
            <.empty_state icon="hero-list-bullet">
              Nenhum lançamento em {month_label(@month)} com esses filtros.
            </.empty_state>
          </div>
          <section :for={{dom_id, day} <- @streams.days} id={dom_id}>
            <header class="flex items-center justify-between bg-base-200/60 px-4 py-1.5 text-xs font-semibold text-base-content/70">
              <span>{day_heading(day.date)}</span>
              <.money
                value={day.total}
                kind={if(Money.positive?(day.total), do: :income, else: :expense)}
              />
            </header>
            <div
              :for={transaction <- day.transactions}
              class="grid grid-cols-[3.5rem_1fr_auto_auto] items-center gap-3 px-4 py-2 text-sm hover:bg-base-200/40 md:grid-cols-[3.5rem_14rem_1fr_8rem_auto]"
            >
              <span class="font-mono text-xs text-base-content/50">{short_date(transaction.date)}</span>
              <span class="flex flex-wrap items-center gap-1"><.category_chip category={
                transaction.category
              } /></span>
              <span class="hidden truncate text-base-content/70 md:block">{transaction.description ||
                "—"}</span>
              <.money value={transaction.amount} kind={transaction.kind} class="text-right" />
              <span class="flex items-center gap-1 text-base-content/50">
                <.link
                  patch={list_path(assigns, %{"edit" => transaction.id})}
                  class="btn btn-ghost btn-xs btn-square"
                  aria-label="Editar"
                >
                  <.icon name="hero-pencil-square-micro" class="size-4" />
                </.link>
                <button
                  type="button"
                  phx-click="delete"
                  phx-value-id={transaction.id}
                  data-confirm="Excluir este lançamento?"
                  class="btn btn-ghost btn-xs btn-square"
                  aria-label="Excluir"
                >
                  <.icon name="hero-trash-micro" class="size-4" />
                </button>
              </span>
            </div>
          </section>
        </div>

        <footer class="flex flex-wrap items-center justify-end gap-6 border-t border-base-300 bg-base-200/60 px-4 py-3 text-sm text-base-content/70">
          <span>Receitas <b class="tabular text-income">{amount(@totals.income, signed: true)}</b></span>
          <span>Despesas <b class="tabular text-base-content">{amount(@totals.expense)}</b></span>
          <span>Saldo do mês <b class="tabular text-base text-base-content">{brl(@totals.net)}</b></span>
        </footer>
      </section>
    </Layouts.app>
    """
  end

  defp kind_active?(nil, ""), do: true
  defp kind_active?(kind, value), do: kind && Atom.to_string(kind) == value
end
