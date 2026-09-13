defmodule CashCadenceWeb.MonthLive do
  use CashCadenceWeb, :live_view

  alias CashCadence.{Budgets, Ledger, Money}

  @category_colors ~w(--chart-cat-1 --chart-cat-2 --chart-cat-3 --chart-cat-4 --chart-cat-5 --chart-cat-6)

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(params, _uri, socket) do
    month =
      case parse_month(params["m"]) do
        {:ok, date} -> date
        :error -> Date.beginning_of_month(Date.utc_today())
      end

    {:noreply, socket |> assign(month: month, page_title: month_title(month)) |> load()}
  end

  defp load(%{assigns: %{month: month}} = socket) do
    totals = Ledger.month_totals(month)
    previous = Ledger.month_totals(Date.shift(month, month: -1))
    coverage = Budgets.coverage(month, totals.income)
    series = Ledger.monthly_series(Date.shift(month, month: -5), month)
    {top, rest} = month |> Ledger.expenses_by_category() |> Enum.split(6)
    slices = category_slices(top, rest)
    monthly_chart = monthly_chart(series)
    category_chart = category_chart(slices)

    socket
    |> assign(
      totals: totals,
      previous: previous,
      coverage: coverage,
      panel: coverage.panel,
      slices: slices,
      slice_total: totals.expense,
      recent: %{competence: month} |> Ledger.list_transactions() |> Enum.take(5),
      all_time: Ledger.all_time_totals(),
      savings_rate: Money.ratio(totals.net, totals.income),
      monthly_chart: monthly_chart,
      category_chart: category_chart
    )
    |> push_event("chart:monthly-chart", monthly_chart)
    |> push_event("chart:category-chart", category_chart)
  end

  defp category_slices(top, rest) do
    slices =
      top
      |> Enum.with_index()
      |> Enum.map(fn {row, index} ->
        %{
          name: row.name || "Sem categoria",
          total: row.total,
          color: Enum.at(@category_colors, index)
        }
      end)

    case rest do
      [] ->
        slices

      rest ->
        slices ++
          [
            %{
              name: "Outros",
              total: rest |> Enum.map(& &1.total) |> Money.sum(),
              color: "--chart-cat-other"
            }
          ]
    end
  end

  defp monthly_chart(series) do
    %{
      type: "bar",
      labels: Enum.map(series, &month_short(&1.competence)),
      datasets: [
        %{
          label: "Receitas",
          color: "--chart-income",
          data: Enum.map(series, &Decimal.to_float(&1.income))
        },
        %{
          label: "Despesas",
          color: "--chart-expense",
          data: Enum.map(series, &Decimal.to_float(&1.expense))
        }
      ]
    }
  end

  defp category_chart(slices) do
    %{
      type: "doughnut",
      labels: Enum.map(slices, & &1.name),
      datasets: [
        %{
          data: Enum.map(slices, &Decimal.to_float(&1.total)),
          colors: Enum.map(slices, & &1.color)
        }
      ]
    }
  end

  defp share(%Decimal{} = part, total) do
    case Money.ratio(part, total) do
      nil -> 0
      ratio -> ratio |> Decimal.mult(100) |> Decimal.round(0) |> Decimal.to_integer()
    end
  end

  defp status_text(%{status: :paid, over: over}) do
    if Money.positive?(over), do: "Pago · #{amount(over)} acima", else: "Pago"
  end

  defp status_text(%{status: :partial, remaining: remaining}),
    do: "Parcial · faltam #{amount(remaining)}"

  defp status_text(%{status: :unpaid}), do: "Em aberto"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} nav={:month} inbox_count={@inbox_count}>
      <div class="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 class="text-3xl font-bold tracking-tight">{month_title(@month)}</h1>
          <p class="text-sm text-base-content/60">
            Mês de competência · {@totals.count} {if @totals.count == 1,
              do: "lançamento",
              else: "lançamentos"}
          </p>
        </div>
        <div class="flex flex-wrap items-center gap-2">
          <.month_nav month={@month} base={~p"/"} />
          <.link
            navigate={~p"/lancamentos?#{%{"m" => month_param(@month), "new" => "1"}}"}
            class="btn btn-primary btn-sm"
          >
            <.icon name="hero-plus-micro" class="size-4" /> Adicionar lançamento
          </.link>
        </div>
      </div>

      <div class="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
        <.kpi label="Receitas do mês">
          <span class="text-base font-medium text-base-content/50">R$</span> {amount(@totals.income)}
          <:footer>
            <.delta current={@totals.income} previous={@previous.income} label="vs mês anterior" />
          </:footer>
        </.kpi>
        <.kpi label="Despesas do mês">
          <span class="text-base font-medium text-base-content/50">R$</span> {amount(@totals.expense)}
          <:footer>
            <.delta
              current={@totals.expense}
              previous={@previous.expense}
              label="vs mês anterior"
              good_when={:down}
            />
          </:footer>
        </.kpi>
        <.kpi label="Saldo do mês">
          <span class={[@totals.net |> Money.positive?() && "text-income"]}>
            <span class="text-base font-medium text-base-content/50">R$</span> {amount(@totals.net)}
          </span>
          <:footer>
            <span :if={@savings_rate}><b>{@savings_rate |> Decimal.mult(100) |> percent()}</b>
            da receita ficou guardada</span>
            <span :if={!@savings_rate}>sem receita no mês</span>
          </:footer>
        </.kpi>
        <.kpi label="Cobertura das fixas">
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
            <span class="font-medium text-base-content/70">{@panel.paid_count} de {@panel.count} pagas</span>
          </div>
          <:footer>
            <div class="space-y-2">
              <.progress value={share(@panel.expected_total, @totals.income)} kind={:paid} />
              <span>{brl(@panel.expected_total)} esperado ·
              <b>{share(@panel.expected_total, @totals.income)}%</b>
              da receita</span>
            </div>
          </:footer>
        </.kpi>
      </div>

      <div class="grid gap-4 xl:grid-cols-3">
        <.card
          title="Receitas × despesas por mês"
          subtitle="Últimos 6 meses de competência"
          class="xl:col-span-2"
        >
          <:actions>
            <span class="flex items-center gap-1 text-xs text-base-content/70"><span class="size-2 rounded-full bg-chart-income"></span>
            Receitas</span>
            <span class="flex items-center gap-1 text-xs text-base-content/70"><span class="size-2 rounded-full bg-chart-expense"></span>
            Despesas</span>
          </:actions>
          <div
            id="monthly-chart"
            phx-hook="Chart"
            phx-update="ignore"
            data-chart={Jason.encode!(@monthly_chart)}
            class="h-64"
          >
            <canvas></canvas>
          </div>
        </.card>

        <.card
          title="Despesas por categoria"
          subtitle={"#{month_label(@month)} · #{length(@slices)} categorias"}
        >
          <.empty_state :if={@slices == []} icon="hero-chart-pie">
            Nenhuma despesa neste mês.
          </.empty_state>
          <div :if={@slices != []} class="flex items-center gap-5">
            <div
              id="category-chart"
              phx-hook="Chart"
              phx-update="ignore"
              data-chart={Jason.encode!(@category_chart)}
              class="relative size-36 shrink-0"
            >
              <canvas></canvas>
            </div>
            <ul class="flex-1 space-y-1.5 text-sm">
              <li :for={slice <- @slices} class="flex items-center gap-2">
                <span class="size-2 shrink-0 rounded-full" style={"background: var(#{slice.color})"}></span>
                <span class="truncate">{slice.name}</span>
                <span class="tabular ml-auto font-medium">{brl(slice.total)}</span>
                <span class="tabular w-10 text-right text-base-content/50">{share(
                  slice.total,
                  @slice_total
                )}%</span>
              </li>
            </ul>
          </div>
        </.card>
      </div>

      <div class="grid gap-4 xl:grid-cols-3">
        <.card
          title={"Despesas fixas · #{month_name(@month)}"}
          subtitle="Esperado × pago no mês, por categoria"
          class="xl:col-span-2"
        >
          <.empty_state :if={@panel.items == []} icon="hero-arrow-path">
            Nenhuma despesa fixa cadastrada.
          </.empty_state>
          <div :if={@panel.items != []} class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Despesa fixa</th>
                  <th class="text-right">Esperado</th>
                  <th class="text-right">Pago</th>
                  <th class="w-44">Progresso</th>
                  <th>Status</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={item <- @panel.items}>
                  <td class="font-medium">
                    {item.bill.name}
                    <span :if={item.installment} class="text-base-content/60">
                      ({item.installment.number}/{item.installment.of})
                    </span>
                  </td>
                  <td class="tabular text-right">{amount(item.expected)}</td>
                  <td class="tabular text-right">{amount(item.paid)}</td>
                  <td><.progress value={item.progress} kind={item.status} /></td>
                  <td>
                    <.badge kind={item.status}>{status_text(item)}</.badge>
                    <.badge :if={item.overdue?} kind={:unpaid}>venceu dia {item.due_on.day}</.badge>
                  </td>
                </tr>
              </tbody>
            </table>
            <div class="flex flex-wrap justify-between gap-4 pt-3 text-sm text-base-content/70">
              <span>Esperado <b class="tabular text-base-content">{brl(@panel.expected_total)}</b></span>
              <span>Pago <b class="tabular text-base-content">{brl(@panel.paid_total)}</b></span>
              <span>Em aberto <b class="tabular text-warning">{brl(@panel.open_total)}</b></span>
            </div>
          </div>
        </.card>

        <div class="space-y-4">
          <.card title="Últimos lançamentos">
            <:actions>
              <.link navigate={~p"/lancamentos?#{%{"m" => month_param(@month)}}"}>Ver todos</.link>
            </:actions>
            <.empty_state :if={@recent == []} icon="hero-list-bullet">
              Nenhum lançamento em {month_label(@month)}.
            </.empty_state>
            <ul :if={@recent != []} class="divide-y divide-base-300 text-sm">
              <li :for={transaction <- @recent} class="flex items-center gap-3 py-2">
                <span class="font-mono text-xs text-base-content/50">{short_date(transaction.date)}</span>
                <span class="truncate">{(transaction.category && transaction.category.name) ||
                  transaction.description || "Sem categoria"}</span>
                <.money value={transaction.amount} kind={transaction.kind} class="ml-auto" />
              </li>
            </ul>
          </.card>

          <.card title="Acumulado" subtitle="Todos os meses registrados">
            <dl class="space-y-2 text-sm">
              <div class="flex justify-between">
                <dt class="text-base-content/70">Receitas</dt><dd class="tabular font-semibold text-income">
                  {brl(@all_time.income)}
                </dd>
              </div>
              <div class="flex justify-between">
                <dt class="text-base-content/70">Despesas</dt><dd class="tabular font-semibold">
                  {brl(@all_time.expense)}
                </dd>
              </div>
              <div class="flex justify-between border-t border-base-300 pt-2">
                <dt class="text-base-content/70">Saldo</dt><dd class="tabular text-base font-bold">
                  {brl(@all_time.net)}
                </dd>
              </div>
            </dl>
          </.card>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
