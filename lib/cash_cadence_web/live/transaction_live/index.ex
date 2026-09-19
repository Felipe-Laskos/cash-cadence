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
    reimbursing = params["reimburse"] && Ledger.get_transaction!(params["reimburse"])

    socket =
      socket
      |> assign(month: month, filters: filters, editing: editing, focus_new: params["new"] == "1")
      |> assign(
        reimbursing: reimbursing,
        candidates: (reimbursing && Ledger.reimbursement_candidates(reimbursing)) || []
      )
      |> assign_form(form_changeset(editing, month, prefill(params)))
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

  defp form_changeset(nil, month, prefill) do
    attrs =
      Map.merge(%{"date" => Date.to_iso8601(default_date(month)), "kind" => "expense"}, prefill)

    Ledger.change_transaction(%Transaction{}, attrs)
  end

  defp form_changeset(%Transaction{} = transaction, _month, _prefill) do
    Ledger.change_transaction(%{
      transaction
      | category_name: transaction.category && transaction.category.name,
        competence_month: competence_override(transaction)
    })
  end

  defp competence_override(%Transaction{date: date, competence: competence}) do
    if Date.beginning_of_month(date) == competence, do: nil, else: month_param(competence)
  end

  defp overridden?(%Transaction{date: date, competence: competence}),
    do: Date.beginning_of_month(date) != competence

  defp reimbursement_label(%Transaction{} = original) do
    Enum.join(
      Enum.reject(
        [
          short_date(original.date),
          original.description || (original.category && original.category.name),
          amount(original.amount)
        ],
        &is_nil/1
      ),
      " · "
    )
  end

  defp reimbursed_total(%Transaction{reimbursements: reimbursements})
       when is_list(reimbursements),
       do: reimbursements |> Enum.map(& &1.amount) |> Money.sum()

  defp reimbursed_total(_transaction), do: Money.zero()

  defp prefill(params) do
    params
    |> Map.take(["kind", "category_name", "amount", "description"])
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
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

        {:noreply, socket |> assign(focus_new: false) |> assign_form(changeset) |> reload()}

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

  def handle_event("link_reimbursement", %{"expense_id" => ""}, socket), do: {:noreply, socket}

  def handle_event("link_reimbursement", %{"expense_id" => expense_id}, socket) do
    expense = Ledger.get_transaction!(expense_id)

    case Ledger.link_reimbursement(socket.assigns.reimbursing, expense) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Reembolso ligado: a despesa passa a valer líquida nos totais.")
         |> push_patch(to: list_path(socket.assigns))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Não foi possível ligar como reembolso.")}
    end
  end

  def handle_event("unlink_reimbursement", %{"id" => id}, socket) do
    {:ok, _} = id |> Ledger.get_transaction!() |> Ledger.unlink_reimbursement()
    {:noreply, socket |> put_flash(:info, "Reembolso desfeito.") |> reload()}
  end

  def handle_event("filter", params, socket) do
    overrides = %{"category" => params["category"], "q" => params["q"]}
    {:noreply, push_patch(socket, to: list_path(socket.assigns, overrides))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      nav={:transactions}
      inbox_count={@inbox_count}
    >
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
          :if={!@editing}
          for={@form}
          id="transaction-form"
          phx-change="validate"
          phx-submit={JS.push("save") |> JS.focus(to: "#transaction_category_name")}
          class="grid gap-2 border-b border-base-300 p-4 md:grid-cols-2 md:items-start lg:grid-cols-[9rem_10rem_1fr_1fr] xl:grid-cols-[9rem_10rem_1fr_1fr_9rem_9rem_auto]"
        >
          <.input field={@form[:date]} type="date" required />
          <.input field={@form[:kind]} type="select" options={@kinds} />
          <div>
            <.input
              field={@form[:category_name]}
              type="text"
              list="category-options"
              phx-hook="Typeahead"
              autocomplete="off"
              placeholder="Categoria"
              phx-mounted={@focus_new && JS.focus()}
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
          <.input
            field={@form[:competence_month]}
            type="month"
            title="Competência (só se for diferente do mês da data)"
            aria-label="Competência"
          />
          <div class="flex gap-1">
            <.button variant="primary" phx-disable-with="Salvando…">Adicionar</.button>
          </div>
        </.form>
        <p :if={!@editing} class="px-4 py-2 text-xs text-base-content/50">
          Enter salva e mantém a data para o próximo · na categoria, o primeiro Enter completa com a sugestão e o seguinte salva · valores com vírgula ou ponto · o mês ao lado do valor só se a competência for outra
        </p>

        <.modal
          :if={@editing}
          id="transaction-modal"
          title="Editar lançamento"
          subtitle="A competência só muda se for diferente do mês da data"
          on_cancel={JS.patch(list_path(assigns))}
          max_width="max-w-2xl"
        >
          <.form
            for={@form}
            id="transaction-form"
            phx-change="validate"
            phx-submit="save"
            class="flex min-h-0 flex-1 flex-col"
          >
            <.modal_body>
              <div class="grid gap-x-4 sm:grid-cols-2">
                <.input field={@form[:date]} type="date" label="Data" required />
                <.input field={@form[:kind]} type="select" label="Tipo" options={@kinds} />
                <div>
                  <.input
                    field={@form[:category_name]}
                    type="text"
                    label="Categoria"
                    list="category-options"
                    phx-hook="Typeahead"
                    autocomplete="off"
                    placeholder="Categoria"
                    data-autofocus
                  />
                  <datalist id="category-options">
                    <option :for={suggestion <- @suggestions} value={suggestion.name}>
                      {suggestion.uses} usos{if suggestion.fixed, do: " · fixa"}
                    </option>
                  </datalist>
                </div>
                <.input
                  field={@form[:description]}
                  type="text"
                  label="Descrição"
                  placeholder="Opcional"
                />
                <.input
                  field={@form[:amount]}
                  type="text"
                  label="Valor"
                  inputmode="decimal"
                  placeholder="0,00"
                  value={input_amount(@form[:amount].value)}
                  required
                  class="input tabular w-full text-right"
                />
                <.input field={@form[:competence_month]} type="month" label="Competência" />
              </div>
            </.modal_body>
            <.modal_footer>
              <button type="button" phx-click="cancel" class="btn btn-ghost">Cancelar</button>
              <.button variant="primary" phx-disable-with="Salvando…">Salvar</.button>
            </.modal_footer>
          </.form>
        </.modal>

        <.modal
          :if={@reimbursing}
          id="reimbursement-modal"
          title={"Ligar a receita de #{amount(@reimbursing.amount)} em #{short_date(@reimbursing.date)} como reembolso de…"}
          subtitle="A despesa original passa a contar líquida e essa receita sai da soma de receitas. A lista traz as despesas dos últimos 60 dias, a mais próxima em valor primeiro."
          on_cancel={JS.patch(list_path(assigns))}
          max_width="max-w-xl"
        >
          <form
            id="reimbursement-form"
            phx-submit="link_reimbursement"
            class="flex min-h-0 flex-1 flex-col"
          >
            <.modal_body>
              <label class="fieldset" for="reimbursement-expense">
                <span class="label mb-1">Despesa original</span>
                <select
                  id="reimbursement-expense"
                  name="expense_id"
                  class="select w-full"
                  required
                  data-autofocus
                >
                  <option value="">Escolha a despesa…</option>
                  <option :for={candidate <- @candidates} value={candidate.id}>
                    {reimbursement_label(candidate)}
                  </option>
                </select>
              </label>
              <.empty_state :if={@candidates == []} icon="hero-arrow-uturn-left">
                Nenhuma despesa candidata nos últimos 60 dias.
              </.empty_state>
            </.modal_body>
            <.modal_footer>
              <.link patch={list_path(assigns)} class="btn btn-ghost">Cancelar</.link>
              <button type="submit" class="btn btn-warning">Ligar como reembolso</button>
            </.modal_footer>
          </form>
        </.modal>

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
              <span class="flex flex-wrap items-center gap-1">
                <.category_chip category={transaction.category} />
                <.badge :if={overridden?(transaction)} kind={:neutral}>
                  comp. {month_short(transaction.competence)}
                </.badge>
                <.badge :if={transaction.reimbursement_of} kind={:accent}>
                  <.icon name="hero-arrow-uturn-left-micro" class="size-3" />
                  reembolso de {reimbursement_label(transaction.reimbursement_of)}
                </.badge>
                <.badge :if={Money.positive?(reimbursed_total(transaction))} kind={:paid}>
                  reembolsado {amount(reimbursed_total(transaction))}
                </.badge>
              </span>
              <span class="hidden truncate text-base-content/70 md:block">{transaction.description ||
                "—"}</span>
              <.money value={transaction.amount} kind={transaction.kind} class="text-right" />
              <span class="flex items-center gap-1 text-base-content/50">
                <.link
                  :if={transaction.kind == :income and is_nil(transaction.reimbursement_of_id)}
                  patch={list_path(assigns, %{"reimburse" => transaction.id})}
                  class="btn btn-ghost btn-xs btn-square"
                  aria-label="É reembolso"
                  title="É reembolso de uma despesa"
                >
                  <.icon name="hero-arrow-uturn-left-micro" class="size-4" />
                </.link>
                <button
                  :if={transaction.reimbursement_of_id}
                  type="button"
                  phx-click="unlink_reimbursement"
                  phx-value-id={transaction.id}
                  class="btn btn-ghost btn-xs btn-square"
                  aria-label="Desfazer reembolso"
                  title="Desfazer reembolso"
                >
                  <.icon name="hero-x-mark-micro" class="size-4" />
                </button>
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
          <span :if={Money.positive?(@totals.reimbursed)}>
            já descontados <b class="tabular text-base-content">{amount(@totals.reimbursed)}</b>
            de reembolsos
          </span>
          <span>Saldo do mês <b class="tabular text-base text-base-content">{brl(@totals.net)}</b></span>
        </footer>
      </section>
    </Layouts.app>
    """
  end

  defp kind_active?(nil, ""), do: true
  defp kind_active?(kind, value), do: kind && Atom.to_string(kind) == value
end
