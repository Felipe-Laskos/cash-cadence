defmodule CashCadenceWeb.ReconciliationLive do
  use CashCadenceWeb, :live_view

  alias CashCadence.Reconciliation

  @impl true
  def mount(_params, _session, socket) do
    month = Date.beginning_of_month(Date.utc_today())

    {:ok,
     assign(socket,
       page_title: "Conferência",
       month: month,
       checklist: Reconciliation.month_checklist(month),
       accounts: Reconciliation.statement_checks()
     )}
  end

  defp pendencias(checklist) do
    [
      {checklist.inbox, "item(ns) esperando na caixa de entrada", ~p"/entrada"},
      {checklist.uncategorized, "lançamento(s) sem categoria no mês",
       ~p"/lancamentos?#{%{"category" => "none"}}"},
      {checklist.open_bills, "fixa(s) em aberto no mês", ~p"/fixas"},
      {checklist.duplicates, "possível(is) duplicata(s)", ~p"/duplicatas"}
    ]
    |> Enum.filter(fn {count, _label, _path} -> count > 0 end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      nav={:reconciliation}
      inbox_count={@inbox_count}
      duplicate_count={@duplicate_count}
    >
      <div>
        <h1 class="text-3xl font-bold tracking-tight">Conferência</h1>
        <p class="text-sm text-base-content/60">
          O que o banco diz que moveu entre dois extratos, contra o que o seu livro registra no mesmo
          intervalo
        </p>
      </div>

      <.card title="Pendências de {month_label(@month)}" subtitle="O que ainda pede sua mão">
        <div :if={pendencias(@checklist) == []} class="alert alert-success alert-soft">
          <.icon name="hero-check-circle" class="size-5" />
          <span>Mês fechado: nada pendente.</span>
        </div>
        <ul class="flex flex-col gap-2">
          <li
            :for={{count, label, path} <- pendencias(@checklist)}
            class="flex items-center justify-between gap-3"
          >
            <span><b class="tabular">{count}</b> {label}</span>
            <.link navigate={path} class="btn btn-ghost btn-xs">Resolver</.link>
          </li>
        </ul>
      </.card>

      <.card
        :for={entry <- @accounts}
        title={entry.account.name}
        subtitle="Cada linha compara dois extratos seguidos dessa conta"
      >
        <div class="overflow-x-auto">
          <table class="table">
            <thead>
              <tr>
                <th>Intervalo</th>
                <th class="text-right">O banco moveu</th>
                <th class="text-right">Seu livro moveu</th>
                <th class="text-right">Diferença</th>
                <th>Situação</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={step <- entry.steps}>
                <td class="whitespace-nowrap">
                  {short_date(step.from.period_end)} → {short_date(step.to.period_end)}
                </td>
                <td class="tabular text-right">{amount(step.expected)}</td>
                <td class="tabular text-right">{amount(step.moved)}</td>
                <td class="tabular text-right font-semibold">{amount(step.difference)}</td>
                <td>
                  <.badge :if={step.ok?} kind={:paid}>fecha</.badge>
                  <.badge :if={!step.ok? && step.unknown_transfers > 0} kind={:partial}>
                    {step.unknown_transfers} transferência(s) sem direção
                  </.badge>
                  <.badge :if={!step.ok? && step.unknown_transfers == 0} kind={:unpaid}>
                    não fecha
                  </.badge>
                  <span
                    :if={!step.ok? && step.silent_days > 0}
                    class="text-base-content/60 mt-1 block text-xs"
                  >
                    o extrato fecha em {short_date(step.to.period_end)} mas só lista lançamentos até {short_date(
                      step.last_entry
                    )}: a diferença pode estar nesses {step.silent_days} dia(s) sem detalhe
                  </span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </.card>

      <div :if={@accounts == []} class="alert alert-info alert-soft">
        <.icon name="hero-information-circle" class="size-5" />
        <span>
          A conferência aparece quando a mesma conta tiver dois extratos importados: a diferença entre
          os saldos é o que o banco diz que moveu no intervalo.
        </span>
      </div>
    </Layouts.app>
    """
  end
end
