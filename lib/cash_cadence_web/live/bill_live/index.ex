defmodule CashCadenceWeb.BillLive.Index do
  use CashCadenceWeb, :live_view

  alias CashCadence.Budgets
  alias CashCadence.Budgets.RecurringBill
  alias CashCadence.Ledger
  alias CashCadence.Money

  @kinds [{"Despesa", "expense"}, {"Receita", "income"}]

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Despesas fixas", kinds: @kinds)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    month =
      case parse_month(params["m"]) do
        {:ok, date} -> date
        :error -> Date.beginning_of_month(Date.utc_today())
      end

    editing = params["edit"] && Budgets.get_recurring_bill!(params["edit"])
    form_open? = params["new"] == "1" or not is_nil(editing)

    socket =
      socket
      |> assign(month: month, editing: editing, form_open?: form_open?)
      |> assign(amounts: bill_amounts(editing), amount_decision: nil, new_amount: %{})
      |> assign_form(bill_changeset(editing, params["kind"], month))
      |> reload()

    {:noreply, socket}
  end

  defp reload(%{assigns: %{month: month}} = socket) do
    totals = Ledger.month_totals(month)
    coverage = Budgets.coverage(month, totals.income)

    assign(socket,
      totals: totals,
      coverage: coverage,
      panel: coverage.panel,
      incomes: Budgets.expected_incomes(month),
      adherence: Budgets.adherence(month, 3),
      category_options: category_options(Ledger.category_suggestions())
    )
  end

  defp bill_amounts(nil), do: []
  defp bill_amounts(%RecurringBill{} = bill), do: Budgets.list_bill_amounts(bill)

  defp bill_changeset(nil, kind, _month),
    do: Budgets.change_recurring_bill(%RecurringBill{}, %{kind: new_kind(kind)})

  defp bill_changeset(%RecurringBill{} = bill, _kind, month),
    do: bill |> editing_struct(month) |> Budgets.change_recurring_bill()

  defp editing_struct(%RecurringBill{} = bill, month) do
    %{
      bill
      | expected_amount: Budgets.expected_amount_at(bill, month),
        category_name: bill.category && bill.category.name,
        starts_month: bill.starts_on && month_param(bill.starts_on),
        ends_month: bill.ends_on && month_param(bill.ends_on)
    }
  end

  defp new_kind("income"), do: :income
  defp new_kind(_kind), do: :expense

  defp assign_form(socket, changeset) do
    assign(socket,
      form: to_form(changeset),
      form_kind: Ecto.Changeset.get_field(changeset, :kind) || :expense
    )
  end

  defp kind_noun(:income), do: "receita fixa"
  defp kind_noun(_kind), do: "despesa fixa"

  defp form_title(nil, kind), do: "Nova #{kind_noun(kind)}"
  defp form_title(_editing, kind), do: "Editar #{kind_noun(kind)}"

  defp form_subtitle(:income), do: "O que entra todo mês, com o valor que você espera receber"
  defp form_subtitle(_kind), do: "O que sai todo mês, com o valor que você espera pagar"

  defp due_day_label(:income), do: "Dia do recebimento"
  defp due_day_label(_kind), do: "Dia do vencimento"

  defp validity_hint(kind) do
    {noun, event} =
      if kind == :income, do: {"receita", "recebimento"}, else: {"despesa", "pagamento"}

    "Opcional. Sem vigência, a #{noun} vale todo mês. O texto no extrato ajuda a reconhecer o #{event} na importação."
  end

  defp bills_path(assigns, overrides \\ %{}) do
    params =
      %{"m" => month_param(assigns.month)}
      |> Map.merge(overrides)
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.new()

    ~p"/fixas?#{params}"
  end

  defp resolve_category(params) do
    kind = if params["kind"] == "income", do: :income, else: :expense

    case String.trim(params["category_name"] || "") do
      "" ->
        {:ok, params}

      name ->
        with {:ok, category} <- Ledger.find_or_create_category(name, kind) do
          {:ok, Map.put(params, "category_id", category.id)}
        end
    end
  end

  @impl true
  def handle_event("validate", %{"recurring_bill" => params} = payload, socket) do
    changeset =
      (socket.assigns.editing || %RecurringBill{})
      |> Budgets.change_recurring_bill(params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket |> assign(new_amount: payload["new_amount"] || %{}) |> assign_form(changeset)}
  end

  def handle_event("save", %{"recurring_bill" => params}, socket) do
    case amount_change(socket.assigns.editing, socket.assigns.month, params) do
      nil -> persist(socket, params, nil)
      decision -> {:noreply, assign(socket, amount_decision: decision)}
    end
  end

  def handle_event("confirm_amount", %{"mode" => mode}, socket),
    do: persist(socket, socket.assigns.amount_decision.params, mode)

  def handle_event("cancel_amount", _params, socket),
    do: {:noreply, assign(socket, amount_decision: nil)}

  def handle_event("add_amount", _params, socket), do: add_amount(socket)

  def handle_event("remove_amount", %{"id" => id}, socket) do
    case Budgets.delete_bill_amount(socket.assigns.editing, String.to_integer(id)) do
      {:ok, _bill} ->
        {:noreply,
         socket |> put_flash(:info, "Valor removido do histórico.") |> refresh_editing()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Não consegui remover esse valor.")}
    end
  end

  def handle_event("cancel", _params, socket),
    do: {:noreply, push_patch(socket, to: bills_path(socket.assigns))}

  def handle_event("delete", %{"id" => id}, socket) do
    bill = Budgets.get_recurring_bill!(id)
    {:ok, _} = Budgets.delete_recurring_bill(bill)

    {:noreply,
     socket
     |> put_flash(:info, "#{String.capitalize(kind_noun(bill.kind))} excluída.")
     |> reload()}
  end

  def handle_event("adjust", %{"id" => id, "amount" => amount}, socket) do
    bill = Budgets.get_recurring_bill!(id)
    month = socket.assigns.month
    {:ok, _bill} = Budgets.change_amount_from(bill, month, amount)

    {:noreply,
     socket
     |> put_flash(
       :info,
       "Esperado ajustado para #{brl(Decimal.new(amount))} de #{month_short(month)} em diante."
     )
     |> reload()}
  end

  def handle_event("end_bill", %{"id" => id}, socket) do
    bill = Budgets.get_recurring_bill!(id)
    ends_on = Date.shift(socket.assigns.month, month: -1)

    case Budgets.update_recurring_bill(bill, %{ends_on: ends_on}) do
      {:ok, _bill} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "#{String.capitalize(kind_noun(bill.kind))} encerrada em #{month_short(ends_on)}. " <>
             "Os meses anteriores continuam como estavam."
         )
         |> reload()}

      {:error, _changeset} ->
        {:noreply,
         put_flash(socket, :error, "Essa fixa começa depois de #{month_short(ends_on)}.")}
    end
  end

  defp amount_change(nil, _month, _params), do: nil

  defp amount_change(%RecurringBill{} = bill, month, params) do
    effective = Budgets.expected_amount_at(bill, month)

    case Money.parse(params["expected_amount"] || "") do
      {:ok, amount} ->
        if Decimal.equal?(amount, effective),
          do: nil,
          else: %{params: params, from: effective, to: amount}

      :error ->
        nil
    end
  end

  defp persist(%{assigns: %{editing: editing, month: month}} = socket, params, mode) do
    result =
      with {:ok, params} <- resolve_category(params) do
        save_bill(editing, params, month, mode)
      end

    case result do
      {:ok, bill} ->
        {:noreply,
         socket
         |> put_flash(:info, saved_flash(bill, mode, month))
         |> push_patch(to: bills_path(socket.assigns))}

      {:error, %Ecto.Changeset{data: %RecurringBill{}} = changeset} ->
        {:noreply, socket |> assign(amount_decision: nil) |> assign_form(changeset)}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(amount_decision: nil)
         |> put_flash(:error, "Não consegui salvar esse valor.")}
    end
  end

  defp save_bill(nil, params, _month, _mode), do: Budgets.create_recurring_bill(params)

  defp save_bill(bill, params, month, "from") do
    {amount, params} = Map.pop(params, "expected_amount")

    with {:ok, bill} <- Budgets.update_recurring_bill(bill, params, on: month),
         do: Budgets.change_amount_from(bill, month, amount)
  end

  defp save_bill(bill, params, month, _mode),
    do: Budgets.update_recurring_bill(bill, params, on: month)

  defp saved_flash(bill, "from", month) do
    "#{String.capitalize(kind_noun(bill.kind))} salva. O novo valor vale de " <>
      "#{month_short(month)} em diante."
  end

  defp saved_flash(bill, _mode, _month), do: "#{String.capitalize(kind_noun(bill.kind))} salva."

  defp add_amount(%{assigns: %{editing: %RecurringBill{} = bill}} = socket) do
    new = socket.assigns.new_amount

    with {:ok, starts_on} <- parse_month(new["month"]),
         {:ok, amount} <- Money.parse(new["value"] || ""),
         {:ok, _bill} <- Budgets.put_bill_amount(bill, starts_on, amount) do
      {:noreply,
       socket
       |> put_flash(:info, "De #{month_short(starts_on)} em diante: #{brl(amount)}.")
       |> refresh_editing()}
    else
      :error ->
        {:noreply, put_flash(socket, :error, "Informe o mês e um valor maior que zero.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Não consegui gravar esse valor.")}
    end
  end

  defp add_amount(socket), do: {:noreply, socket}

  defp refresh_editing(%{assigns: %{month: month}} = socket) do
    bill = Budgets.get_recurring_bill!(socket.assigns.editing.id)

    socket
    |> assign(editing: bill, amounts: Budgets.list_bill_amounts(bill), amount_decision: nil)
    |> assign_form(typed_changeset(bill, month, socket.assigns.form.params))
    |> reload()
  end

  defp typed_changeset(bill, month, params) when is_map(params) do
    bill
    |> editing_struct(month)
    |> Budgets.change_recurring_bill(
      Map.put(params, "expected_amount", input_amount(Budgets.expected_amount_at(bill, month)))
    )
  end

  defp typed_changeset(bill, month, _params), do: bill_changeset(bill, nil, month)

  defp due_soon?(%{due_in: due_in}), do: is_integer(due_in) and due_in >= 0 and due_in <= 7

  defp due_soon_label(0), do: "vence hoje"
  defp due_soon_label(1), do: "vence amanhã"
  defp due_soon_label(days), do: "vence em #{days} dias"

  defp status_text(%{status: :paid, over: over}) do
    if Money.positive?(over), do: "Pago · #{amount(over)} acima", else: "Pago"
  end

  defp status_text(%{status: :partial, remaining: remaining}),
    do: "Parcial · faltam #{amount(remaining)}"

  defp status_text(%{status: :unpaid}), do: "Em aberto"

  defp adherence_text(%{status: :paid, paid: paid}), do: "Pago · #{amount(paid)}"
  defp adherence_text(%{status: :partial, paid: paid}), do: "Parcial · #{amount(paid)}"
  defp adherence_text(%{status: :unpaid}), do: "Em aberto"
  defp adherence_text(%{status: :none}), do: "—"

  defp shares_category?(items, item) do
    Enum.count(items, &(&1.bill.category_id == item.bill.category_id)) > 1
  end

  defp launch_path(month, item) do
    ~p"/lancamentos?#{%{"m" => month_param(month), "new" => "1", "kind" => "expense", "category_name" => item.bill.category.name, "amount" => input_amount(item.remaining)}}"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      nav={:bills}
      inbox_count={@inbox_count}
      duplicate_count={@duplicate_count}
    >
      <div class="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 class="text-3xl font-bold tracking-tight">Despesas fixas</h1>
          <p class="text-sm text-base-content/60">
            Despesas e receitas que se repetem todo mês: valor esperado × o que já foi pago ou recebido em {month_label(
              @month
            )}
          </p>
        </div>
        <div class="flex flex-wrap items-center gap-2">
          <.month_nav month={@month} base={~p"/fixas"} />
          <.link
            id="new-income-bill"
            patch={bills_path(assigns, %{"new" => "1", "kind" => "income"})}
            class="btn btn-sm"
          >
            <.icon name="hero-plus-micro" class="size-4" /> Nova receita fixa
          </.link>
          <.link
            id="new-bill"
            patch={bills_path(assigns, %{"new" => "1"})}
            class="btn btn-primary btn-sm"
          >
            <.icon name="hero-plus-micro" class="size-4" /> Nova despesa fixa
          </.link>
        </div>
      </div>

      <div class="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
        <.kpi label="Esperado no mês">
          <span class="text-base font-medium text-base-content/50">R$</span> {amount(
            @panel.expected_total
          )}
          <:footer>
            {@panel.count} {if @panel.count == 1, do: "despesa fixa", else: "despesas fixas"}
          </:footer>
        </.kpi>
        <.kpi label="Pago até agora">
          <span class="text-base font-medium text-base-content/50">R$</span> {amount(
            @panel.paid_total
          )}
          <:footer>
            <div class="space-y-2">
              <.progress
                value={progress_share(@panel.paid_total, @panel.expected_total)}
                kind={:paid}
              />
              <span><b>{progress_share(@panel.paid_total, @panel.expected_total)}%</b> do esperado</span>
            </div>
          </:footer>
        </.kpi>
        <.kpi label="Em aberto">
          <span class={[Money.positive?(@panel.open_total) && "text-warning"]}>
            <span class="text-base font-medium text-base-content/50">R$</span> {amount(
              @panel.open_total
            )}
          </span>
          <:footer>{open_text(@panel)}</:footer>
        </.kpi>
        <.kpi label="Cobertura">
          <div class="flex items-center gap-3 text-sm">
            <.badge :if={@panel.count > 0} kind={if(@coverage.covered?, do: :paid, else: :unpaid)}>
              <.icon
                name={
                  if(@coverage.covered?,
                    do: "hero-check-micro",
                    else: "hero-exclamation-triangle-micro"
                  )
                }
                class="size-3"
              />
              {if @coverage.covered?, do: "Coberto", else: "Déficit"}
            </.badge>
          </div>
          <:footer>
            <span :if={@coverage.ratio}>a receita de {month_name(@month)} ({brl(@totals.income)}) paga as fixas
            <b>{@coverage.ratio
            |> Decimal.round(1)
            |> Decimal.to_string(:normal)
            |> String.replace(".", ",")}×</b></span>
            <span :if={!@coverage.ratio}>sem despesas fixas cadastradas</span>
          </:footer>
        </.kpi>
      </div>

      <.modal
        :if={@form_open?}
        id="bill-modal"
        title={form_title(@editing, @form_kind)}
        subtitle={form_subtitle(@form_kind)}
        on_cancel={JS.patch(bills_path(assigns))}
        max_width="max-w-2xl"
      >
        <.form
          for={@form}
          id="bill-form"
          phx-change="validate"
          phx-submit="save"
          class="flex min-h-0 flex-1 flex-col"
        >
          <.modal_body>
            <div class="grid gap-x-4 sm:grid-cols-2">
              <div class="sm:col-span-2">
                <.input
                  field={@form[:name]}
                  type="text"
                  label="Nome"
                  placeholder="Ex.: Internet"
                  required
                  data-autofocus
                />
              </div>
              <.input field={@form[:kind]} type="select" label="Tipo" options={@kinds} />
              <.combobox
                field={@form[:category_name]}
                label="Categoria vinculada"
                options={@category_options}
                placeholder="Categoria"
              />
              <.input
                field={@form[:expected_amount]}
                type="text"
                label="Valor esperado"
                inputmode="decimal"
                placeholder="0,00"
                value={input_amount(@form[:expected_amount].value)}
                required
                class="input tabular w-full text-right"
              />
              <.input
                field={@form[:due_day]}
                type="number"
                label={due_day_label(@form_kind)}
                min="1"
                max="31"
                placeholder="—"
              />
            </div>

            <.form_section title="Vigência e parcelas" hint={validity_hint(@form_kind)}>
              <div class="grid gap-x-4 sm:grid-cols-3">
                <.input field={@form[:starts_month]} type="month" label="Começa em" />
                <.input field={@form[:ends_month]} type="month" label="Termina em" />
                <.input
                  field={@form[:installments_total]}
                  type="number"
                  label="Parcelas"
                  min="2"
                  placeholder="—"
                />
                <div class="sm:col-span-3">
                  <.input
                    field={@form[:match_text]}
                    type="text"
                    label="Texto no extrato"
                    placeholder="Ex.: RECEITA FEDERAL"
                    class="input w-full font-mono uppercase"
                  />
                  <p class="mt-1 text-xs text-base-content/50">
                    O que conta como pago continua sendo tudo da categoria no mês. Este texto só
                    filtra, por descrição e valor (10% de folga), quando duas fixas dividem a mesma
                    categoria.
                  </p>
                </div>
              </div>
            </.form_section>

            <.form_section
              :if={@editing}
              title="Histórico de valores"
              hint="Cada valor vale do mês dele em diante. Os meses anteriores guardam o que valia neles."
            >
              <ul
                id="bill-amounts"
                class="divide-y divide-base-300 rounded-lg border border-base-300 text-sm"
              >
                <li :if={@amounts == []} class="px-3 py-2 text-base-content/60">
                  Um valor só, que vale em todos os meses.
                </li>
                <li
                  :for={{row, index} <- Enum.with_index(@amounts)}
                  id={"bill-amount-#{row.id}"}
                  class="flex items-center justify-between gap-3 px-3 py-2"
                >
                  <span class="flex items-center gap-2">
                    <span class="font-medium">{amount_range_label(@amounts, index)}</span>
                    <.badge :if={current_amount_id(@amounts, @month) == row.id} kind={:accent}>
                      vale em {month_short(@month)}
                    </.badge>
                  </span>
                  <span class="flex items-center gap-2">
                    <span class="tabular font-semibold">{brl(row.expected_amount)}</span>
                    <button
                      type="button"
                      phx-click="remove_amount"
                      phx-value-id={row.id}
                      class="btn btn-ghost btn-xs btn-square"
                      aria-label="Remover valor"
                    >
                      <.icon name="hero-trash-micro" class="size-4" />
                    </button>
                  </span>
                </li>
              </ul>

              <div
                id={"new-amount-#{length(@amounts)}"}
                class="mt-3 grid gap-x-4 gap-y-2 sm:grid-cols-[1fr_1fr_auto] sm:items-end"
              >
                <.input
                  type="month"
                  name="new_amount[month]"
                  value={month_param(@month)}
                  label="A partir de"
                />
                <.input
                  type="text"
                  name="new_amount[value]"
                  value=""
                  label="Valor"
                  inputmode="decimal"
                  placeholder="0,00"
                  class="input tabular w-full text-right"
                />
                <button
                  type="button"
                  id="add-bill-amount"
                  phx-click="add_amount"
                  class="btn btn-sm mb-1"
                >
                  Registrar valor
                </button>
              </div>
            </.form_section>
          </.modal_body>

          <div
            :if={@amount_decision}
            id="amount-decision"
            class="border-t border-base-300 bg-base-200/40 px-5 py-4"
          >
            <p class="text-sm font-semibold">
              O valor passa de {brl(@amount_decision.from)} para {brl(@amount_decision.to)}.
            </p>
            <p class="mt-1 text-xs text-base-content/60">
              Em {month_label(@month)} vale {brl(@amount_decision.from)} hoje. O que aconteceu?
            </p>
            <div class="mt-3 flex flex-wrap gap-2">
              <button
                type="button"
                id="amount-from"
                phx-click="confirm_amount"
                phx-value-mode="from"
                class="btn btn-primary btn-sm"
              >
                Mudou a partir de {month_short(@month)}
              </button>
              <button
                type="button"
                id="amount-correct"
                phx-click="confirm_amount"
                phx-value-mode="correct"
                class="btn btn-sm"
              >
                {correct_label(@amounts, @month)}
              </button>
              <button type="button" phx-click="cancel_amount" class="btn btn-ghost btn-sm">
                Voltar
              </button>
            </div>
          </div>

          <.modal_footer :if={is_nil(@amount_decision)}>
            <button type="button" phx-click="cancel" class="btn btn-ghost">Cancelar</button>
            <.button variant="primary" phx-disable-with="Salvando…">{if @editing,
              do: "Salvar",
              else: "Adicionar"}</.button>
          </.modal_footer>
        </.form>
      </.modal>

      <section class="card border border-base-300 bg-base-100">
        <.empty_state :if={@panel.items == []} icon="hero-arrow-path">
          Nenhuma despesa fixa cadastrada. Comece pelas que se repetem todo mês.
        </.empty_state>
        <div :if={@panel.items != []} class="overflow-x-auto">
          <table class="table">
            <thead>
              <tr>
                <th>Despesa fixa</th>
                <th>Categoria</th>
                <th>Vencimento</th>
                <th class="text-right">Esperado</th>
                <th class="text-right">Pago em {month_name(@month)}</th>
                <th class="w-40">Progresso</th>
                <th>Status</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={item <- @panel.items} id={"bill-#{item.bill.id}"}>
                <td class="font-medium">
                  {item.bill.name}
                  <span :if={item.installment} class="text-base-content/60">
                    ({item.installment.number}/{item.installment.of})
                  </span>
                  <span :if={item.bill.ends_on} class="block text-xs font-normal text-base-content/50">
                    até {month_short(item.bill.ends_on)}
                  </span>
                </td>
                <td>
                  <.category_chip category={item.bill.category} show_fixed={false} />
                  <span
                    :if={shares_category?(@panel.items, item)}
                    class="text-base-content/50 block text-xs"
                    title="Com duas fixas na mesma categoria, o que conta como pago é filtrado pelo texto no extrato e pelo valor"
                  >
                    divide a categoria
                  </span>
                </td>
                <td class="text-base-content/60">
                  {if item.due_on, do: "dia #{item.due_on.day}", else: "—"}
                  <.badge :if={item.overdue?} kind={:unpaid}>atrasada</.badge>
                  <.badge :if={due_soon?(item)} kind={:warn}>{due_soon_label(item.due_in)}</.badge>
                </td>
                <td class="tabular text-right">{amount(item.expected)}</td>
                <td class="tabular text-right">{amount(item.paid)}</td>
                <td><.progress value={item.progress} kind={item.status} /></td>
                <td>
                  <.badge kind={item.status}>{status_text(item)}</.badge>
                </td>
                <td>
                  <div class="flex items-center justify-end gap-1">
                    <.link
                      :if={item.status != :paid}
                      navigate={launch_path(@month, item)}
                      class="btn btn-ghost btn-xs"
                    >
                      <.icon name="hero-plus-micro" class="size-4" /> Lançar pagamento
                    </.link>
                    <button
                      :if={Money.positive?(item.over)}
                      type="button"
                      phx-click="adjust"
                      phx-value-id={item.bill.id}
                      phx-value-amount={Decimal.to_string(item.paid, :normal)}
                      class="btn btn-ghost btn-xs"
                    >
                      Ajustar esperado para {amount(item.paid)}
                    </button>
                    <.link
                      patch={bills_path(assigns, %{"edit" => item.bill.id})}
                      class="btn btn-ghost btn-xs btn-square"
                      aria-label="Editar"
                    >
                      <.icon name="hero-pencil-square-micro" class="size-4" />
                    </.link>
                    <button
                      :if={is_nil(item.bill.ends_on)}
                      type="button"
                      phx-click="end_bill"
                      phx-value-id={item.bill.id}
                      data-confirm={"Encerrar #{item.bill.name} a partir de #{month_label(@month)}? Os meses anteriores continuam como estão."}
                      class="btn btn-ghost btn-xs btn-square"
                      aria-label="Encerrar"
                    >
                      <.icon name="hero-archive-box-micro" class="size-4" />
                    </button>
                    <button
                      type="button"
                      phx-click="delete"
                      phx-value-id={item.bill.id}
                      data-confirm="Excluir esta despesa fixa? Ela some de todos os meses, inclusive os passados. Os lançamentos continuam no livro."
                      class="btn btn-ghost btn-xs btn-square"
                      aria-label="Excluir"
                    >
                      <.icon name="hero-trash-micro" class="size-4" />
                    </button>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <div class="grid gap-4 xl:grid-cols-5">
        <.card
          title="Receitas fixas esperadas"
          subtitle="O que entra todo mês: salário, lucros, qualquer receita certa"
          class="xl:col-span-2"
        >
          <:actions>
            <.link
              id="new-income-bill-card"
              patch={bills_path(assigns, %{"new" => "1", "kind" => "income"})}
              class="btn btn-sm"
            >
              <.icon name="hero-plus-micro" class="size-4" /> Nova receita fixa
            </.link>
          </:actions>
          <.empty_state :if={@incomes == []} icon="hero-banknotes">
            Nenhuma receita fixa cadastrada. O salário e as outras entradas certas do mês ficam aqui.
          </.empty_state>
          <div :if={@incomes != []} class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Receita</th><th class="text-right">Esperado</th><th>
                    {String.capitalize(month_name(@month))}
                  </th><th></th>
                </tr>
              </thead>
              <tbody>
                <tr :for={income <- @incomes} id={"income-#{income.bill.id}"}>
                  <td class="font-medium">
                    {income.bill.name}
                    <span
                      :if={shares_category?(@incomes, income)}
                      class="text-base-content/50 block text-xs"
                    >
                      divide a categoria com outra receita fixa
                    </span>
                  </td>
                  <td class="tabular text-right">{amount(income.expected)}</td>
                  <td>
                    <.badge :if={income.status == :received} kind={:paid}>
                      Recebido{if income.received_on, do: " em #{short_date(income.received_on)}"}
                    </.badge>
                    <.badge :if={income.status == :pending} kind={:neutral}>Sem recebimento</.badge>
                  </td>
                  <td>
                    <div class="flex items-center justify-end gap-1">
                      <.link
                        patch={bills_path(assigns, %{"edit" => income.bill.id})}
                        class="btn btn-ghost btn-xs btn-square"
                        aria-label="Editar"
                      >
                        <.icon name="hero-pencil-square-micro" class="size-4" />
                      </.link>
                      <button
                        type="button"
                        phx-click="delete"
                        phx-value-id={income.bill.id}
                        data-confirm="Excluir esta receita fixa? Ela some de todos os meses, inclusive os passados. Os lançamentos continuam no livro."
                        class="btn btn-ghost btn-xs btn-square"
                        aria-label="Excluir"
                      >
                        <.icon name="hero-trash-micro" class="size-4" />
                      </button>
                    </div>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </.card>

        <.card
          title="Adesão nos últimos 3 meses"
          subtitle="Pago × parcial × em aberto, por mês de competência"
          class="xl:col-span-3"
        >
          <.empty_state :if={@adherence.rows == []} icon="hero-calendar-days">
            Sem despesas fixas para acompanhar.
          </.empty_state>
          <div :if={@adherence.rows != []} class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Fixa</th>
                  <th :for={month <- @adherence.months}>{month_short(month)}</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={row <- @adherence.rows}>
                  <td class="font-medium">{row.bill.name}</td>
                  <td :for={cell <- row.statuses}>
                    <.badge kind={cell.status}>{adherence_text(cell)}</.badge>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  defp progress_share(paid, expected) do
    case Money.ratio(paid, expected) do
      nil ->
        0

      ratio ->
        ratio
        |> Decimal.mult(100)
        |> Decimal.min(Decimal.new(100))
        |> Decimal.round(0)
        |> Decimal.to_integer()
    end
  end

  defp current_amount_id(amounts, month) do
    case Budgets.effective_bill_amount(amounts, month) do
      nil -> nil
      row -> row.id
    end
  end

  defp amount_range_label(amounts, index) do
    row = Enum.at(amounts, index)

    case Enum.at(amounts, index + 1) do
      nil when index == 0 ->
        "todos os meses"

      nil ->
        "de #{month_short(row.starts_on)} em diante"

      next when index == 0 ->
        "até #{month_short(Date.shift(next.starts_on, month: -1))}"

      next ->
        "#{month_short(row.starts_on)} a #{month_short(Date.shift(next.starts_on, month: -1))}"
    end
  end

  defp correct_label([], _month), do: "Corrigir: sempre foi esse valor"
  defp correct_label([_single], _month), do: "Corrigir: sempre foi esse valor"

  defp correct_label(amounts, month) do
    index = Enum.find_index(amounts, &(&1.id == current_amount_id(amounts, month)))
    "Corrigir o valor de #{amount_range_label(amounts, index)}"
  end

  defp open_text(%{items: items}) do
    case Enum.reject(items, &(&1.status == :paid)) do
      [] -> "tudo pago neste mês"
      [item] -> "só #{item.bill.name} ainda não fechou"
      pending -> "#{length(pending)} despesas ainda não fecharam"
    end
  end
end
