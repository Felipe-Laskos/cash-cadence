defmodule CashCadenceWeb.DuplicateLive do
  use CashCadenceWeb, :live_view

  alias CashCadence.Duplicates
  alias CashCadence.Ledger

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Possíveis duplicatas", weak?: false) |> reload()}
  end

  defp reload(%{assigns: %{weak?: weak?}} = socket) do
    pairs = Duplicates.list(weak: weak?)

    assign(socket,
      pairs: pairs,
      weak_count: Duplicates.weak_count(),
      duplicate_count: Enum.count(pairs, &(&1.strength == :strong))
    )
  end

  @impl true
  def handle_event("toggle_weak", _params, socket) do
    {:noreply, socket |> update(:weak?, &(not &1)) |> reload()}
  end

  def handle_event("resolve", %{"keep" => keep_id, "remove" => remove_id}, socket) do
    kept = Ledger.get_transaction!(keep_id)
    removed = Ledger.get_transaction!(remove_id)

    case Duplicates.resolve(kept, removed) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Ficou o lançamento de #{brl(kept.amount)}; o outro foi apagado.")
         |> reload()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Não foi possível apagar o lançamento.")}
    end
  end

  def handle_event("dismiss", %{"left" => left_id, "right" => right_id}, socket) do
    left = Ledger.get_transaction!(left_id)
    right = Ledger.get_transaction!(right_id)

    {:ok, _} = Duplicates.dismiss(left, right)

    {:noreply, socket |> put_flash(:info, "Par marcado como lançamentos diferentes.") |> reload()}
  end

  defp reason_label(:fingerprint), do: "mesma data, valor e descrição"
  defp reason_label(:description), do: "descrições parecidas"
  defp reason_label(:category), do: "mesma categoria"
  defp reason_label(:amount), do: "mesmo valor, datas próximas"

  defp reason_kind(:fingerprint), do: :unpaid
  defp reason_kind(:description), do: :partial
  defp reason_kind(_reason), do: :paid

  defp origin(%{source: :import, bank_account: account}) when not is_nil(account),
    do: "banco · #{account.name}"

  defp origin(%{source: :import}), do: "banco"
  defp origin(%{source: :spreadsheet}), do: "planilha"
  defp origin(%{source: :manual}), do: "lançado à mão"

  defp detail(transaction) do
    transaction.description || transaction.raw_description || "sem descrição"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      nav={:duplicates}
      inbox_count={@inbox_count}
      duplicate_count={@duplicate_count}
    >
      <div class="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 class="text-3xl font-bold tracking-tight">Possíveis duplicatas</h1>
          <p class="text-sm text-base-content/60">
            Pares com o mesmo valor em até {Duplicates.window_days()} dias de diferença, fora linhas
            repetidas do mesmo arquivo e parcelas da mesma compra. Escolha qual lançamento fica ou
            diga que são diferentes.
          </p>
        </div>
        <div class="flex items-center gap-2">
          <span :if={@pairs != []} class="badge badge-warning">{length(@pairs)} para revisar</span>
          <button
            :if={@weak_count > 0 or @weak?}
            type="button"
            phx-click="toggle_weak"
            class="btn btn-ghost btn-sm"
          >
            {if @weak?,
              do: "Esconder palpites fracos",
              else: "Ver #{@weak_count} palpite(s) fraco(s)"}
          </button>
        </div>
      </div>

      <div :if={@weak?} class="alert alert-info alert-soft">
        <.icon name="hero-information-circle" class="size-5" />
        <span>
          Palpite fraco é par que só tem o valor em comum: categorias e descrições diferentes.
          Quase sempre são gastos distintos que calharam de ter o mesmo valor.
        </span>
      </div>

      <div :if={@pairs == []} class="alert alert-success alert-soft">
        <.icon name="hero-check-circle" class="size-5" />
        <span>Nenhum par suspeito no livro.</span>
      </div>

      <div id="duplicate-pairs" class="flex flex-col gap-4">
        <div
          :for={pair <- @pairs}
          id={"pair-#{pair.left.id}-#{pair.right.id}"}
          class="card bg-base-200/40 border-base-300 border p-4"
        >
          <div class="mb-3 flex flex-wrap items-center justify-between gap-2">
            <div class="flex flex-wrap items-center gap-2">
              <.badge kind={reason_kind(pair.reason)}>{reason_label(pair.reason)}</.badge>
              <.badge :if={pair.strength == :weak} kind={:neutral}>palpite fraco</.badge>
              <span class="tabular text-lg font-bold">{brl(pair.left.amount)}</span>
              <span :if={pair.same_day?} class="text-sm text-base-content/60">no mesmo dia</span>
            </div>
            <button
              type="button"
              phx-click="dismiss"
              phx-value-left={pair.left.id}
              phx-value-right={pair.right.id}
              class="btn btn-ghost btn-sm"
            >
              São diferentes
            </button>
          </div>

          <div class="grid gap-3 sm:grid-cols-2">
            <div
              :for={{one, other} <- [{pair.left, pair.right}, {pair.right, pair.left}]}
              class="border-base-300 flex flex-col gap-2 rounded-lg border p-3"
            >
              <div class="flex items-center justify-between gap-2">
                <span class="font-mono text-xs text-base-content/60">{origin(one)}</span>
                <span class="text-sm">{short_date(one.date)}</span>
              </div>
              <div class="text-sm font-medium">{detail(one)}</div>
              <div class="flex flex-wrap items-center gap-2">
                <.category_chip category={one.category} show_fixed={false} />
                <span class="text-base-content/50 text-sm">
                  competência {month_label(one.competence)}
                </span>
              </div>
              <button
                type="button"
                phx-click="resolve"
                phx-value-keep={one.id}
                phx-value-remove={other.id}
                data-confirm={"Apagar o lançamento de #{short_date(other.date)} e manter este?"}
                class="btn btn-sm"
              >
                <.icon name="hero-check-micro" class="size-4" /> Manter este
              </button>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
