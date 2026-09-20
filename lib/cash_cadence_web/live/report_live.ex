defmodule CashCadenceWeb.ReportLive do
  use CashCadenceWeb, :live_view

  alias CashCadence.Ledger
  alias CashCadence.Money

  @periods [{"3m", "3 meses", 3}, {"6m", "6 meses", 6}, {"12m", "12 meses", 12}]

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, assign(socket, page_title: "Relatórios", periods: @periods)}

  @impl true
  def handle_params(params, _uri, socket) do
    to =
      case parse_month(params["to"]) do
        {:ok, date} ->
          date

        :error ->
          List.first(Ledger.months_with_data()) || Date.beginning_of_month(Date.utc_today())
      end

    period = Enum.find(@periods, hd(@periods), fn {key, _, _} -> key == params["p"] end)
    {key, _label, months} = period
    from = Date.shift(to, month: -(months - 1))

    series = Ledger.monthly_series(from, to)
    matrix = Ledger.category_month_matrix(from, to, 12)

    chart = %{
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

    socket =
      socket
      |> assign(
        from: from,
        to: to,
        period: key,
        series: series,
        totals: totals(series),
        matrix: matrix,
        steps: heat_steps(matrix),
        incomes: Ledger.income_by_category(from, to),
        chart: chart
      )
      |> push_event("chart:report-chart", chart)

    {:noreply, socket}
  end

  defp totals(series) do
    income = series |> Enum.map(& &1.income) |> Money.sum()
    expense = series |> Enum.map(& &1.expense) |> Money.sum()
    %{income: income, expense: expense, net: Decimal.sub(income, expense)}
  end

  defp heat_steps(%{rows: rows}) do
    values =
      rows
      |> Enum.flat_map(fn row -> Map.values(row.totals) end)
      |> Enum.map(&Decimal.to_float/1)
      |> Enum.sort()

    case values do
      [] ->
        []

      values ->
        Enum.map([0.25, 0.5, 0.75], fn q ->
          Enum.at(values, min(round(q * length(values)), length(values) - 1))
        end)
    end
  end

  defp heat_style(nil, _steps), do: nil

  defp heat_style(%Decimal{} = value, steps) do
    float = Decimal.to_float(value)
    step = 1 + Enum.count(steps, &(float > &1))
    "background: var(--seq-#{step})"
  end

  defp saved_share(%{income: income, net: net}) do
    case Money.ratio(net, income) do
      nil -> "—"
      ratio -> ratio |> Decimal.mult(100) |> percent()
    end
  end

  defp period_path(to, key), do: ~p"/relatorios?#{%{"p" => key, "to" => month_param(to)}}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      nav={:reports}
      inbox_count={@inbox_count}
      duplicate_count={@duplicate_count}
    >
      <div class="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 class="text-3xl font-bold tracking-tight">Relatórios</h1>
          <p class="text-sm text-base-content/60">
            {month_range_label(@from, @to)} · {length(@series)} meses de competência
          </p>
        </div>
        <div class="flex flex-wrap items-center gap-2">
          <div class="join">
            <.link
              :for={{key, label, _} <- @periods}
              patch={period_path(@to, key)}
              class={["btn btn-sm join-item", @period == key && "btn-active"]}
            >{label}</.link>
          </div>
          <.month_nav month={@to} base={~p"/relatorios"} params={%{"p" => @period}} />
          <a
            href={
              ~p"/relatorios/export.csv?#{%{"from" => month_param(@from), "to" => month_param(@to)}}"
            }
            class="btn btn-sm"
            download
          >
            <.icon name="hero-arrow-down-tray-micro" class="size-4" /> Exportar CSV
          </a>
        </div>
      </div>

      <.card
        title="Evolução mensal"
        subtitle="Receitas, despesas e quanto sobrou em cada mês de competência"
      >
        <:actions>
          <span class="flex items-center gap-1 text-xs text-base-content/70"><span class="size-2 rounded-full bg-chart-income"></span>
          Receitas</span>
          <span class="flex items-center gap-1 text-xs text-base-content/70"><span class="size-2 rounded-full bg-chart-expense"></span>
          Despesas</span>
        </:actions>
        <div class="grid gap-6 xl:grid-cols-5">
          <div
            id="report-chart"
            phx-hook="Chart"
            phx-update="ignore"
            data-chart={Jason.encode!(@chart)}
            class="h-64 xl:col-span-3"
          >
            <canvas></canvas>
          </div>
          <div class="overflow-x-auto xl:col-span-2">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Mês</th><th class="text-right">Receitas</th><th class="text-right">Despesas</th><th class="text-right">
                    Saldo
                  </th><th class="text-right">Guardado</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={month <- @series}>
                  <td>
                    <.link navigate={~p"/?#{%{"m" => month_param(month.competence)}}"}>{month_short(
                      month.competence
                    )}</.link>
                  </td>
                  <td class="tabular text-right text-income">{amount(month.income)}</td>
                  <td class="tabular text-right">{amount(month.expense)}</td>
                  <td class="tabular text-right">{amount(month.net)}</td>
                  <td class="tabular text-right text-base-content/60">{saved_share(month)}</td>
                </tr>
                <tr class="font-semibold">
                  <td>Total</td>
                  <td class="tabular text-right text-income">{amount(@totals.income)}</td>
                  <td class="tabular text-right">{amount(@totals.expense)}</td>
                  <td class="tabular text-right">{amount(@totals.net)}</td>
                  <td class="tabular text-right text-base-content/60">{saved_share(@totals)}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </.card>

      <div class="grid gap-4 xl:grid-cols-3">
        <.card
          title="Categorias × mês (despesas)"
          subtitle={"#{length(@matrix.rows)} maiores categorias · quanto mais escura a célula, maior o gasto"}
          class="xl:col-span-2"
        >
          <.empty_state :if={@matrix.rows == []} icon="hero-table-cells">
            Nenhuma despesa no período.
          </.empty_state>
          <div :if={@matrix.rows != []} class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Categoria</th>
                  <th :for={month <- @matrix.months} class="text-right">{month_short(month)}</th>
                  <th class="text-right">Total</th>
                  <th class="text-right">Média</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={row <- @matrix.rows}>
                  <td class="font-medium">{row.name}</td>
                  <td
                    :for={month <- @matrix.months}
                    class="tabular text-right"
                    style={heat_style(row.totals[month], @steps)}
                  >
                    {if row.totals[month], do: amount(row.totals[month]), else: "—"}
                  </td>
                  <td class="tabular text-right font-semibold">{amount(row.total)}</td>
                  <td class="tabular text-right text-base-content/60">{amount(row.average)}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </.card>

        <.card title="Receitas por origem" subtitle={month_range_label(@from, @to)}>
          <.empty_state :if={@incomes == []} icon="hero-banknotes">
            Nenhuma receita no período.
          </.empty_state>
          <div :if={@incomes != []} class="overflow-x-auto">
            <table class="table table-sm">
              <tbody>
                <tr :for={income <- @incomes}>
                  <td>
                    <span :if={income.name}>{income.name}</span>
                    <span
                      :if={income.kind == :person}
                      class="text-[10px] uppercase text-base-content/50"
                    > pessoa</span>
                    <.badge :if={!income.name} kind={:warn}>Sem categoria</.badge>
                  </td>
                  <td class="tabular text-right">{amount(income.total)}</td>
                  <td class="tabular w-16 text-right text-base-content/60">
                    {if income.share, do: income.share |> Decimal.mult(100) |> percent(), else: "—"}
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
end
