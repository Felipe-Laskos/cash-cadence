defmodule CashCadenceWeb.CategoryLive.Index do
  use CashCadenceWeb, :live_view

  alias CashCadence.Ledger
  alias CashCadence.Ledger.Category

  @tabs [
    {:expense, "Despesas"},
    {:income, "Receitas"},
    {:person, "Pessoas"},
    {:archived, "Arquivadas"}
  ]
  @kinds [{"Despesa", "expense"}, {"Receita", "income"}, {"Pessoa", "person"}]

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Categorias", tabs: @tabs, kinds: @kinds)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = parse_tab(params["tab"])
    editing = params["edit"] && Ledger.get_category!(params["edit"])
    merging = params["merge"] && Ledger.get_category!(params["merge"])

    socket =
      socket
      |> assign(
        tab: tab,
        editing: editing,
        merging: merging,
        form_open?: params["new"] == "1" or not is_nil(editing)
      )
      |> assign_form(category_changeset(editing, tab))
      |> reload()

    {:noreply, socket}
  end

  defp reload(%{assigns: %{tab: tab}} = socket) do
    stats =
      case tab do
        :archived -> Ledger.category_stats(archived: :only)
        kind -> Ledger.category_stats(kind: kind)
      end

    counts =
      Map.new(@tabs, fn
        {:archived, _} -> {:archived, length(Ledger.list_categories(archived: :only))}
        {kind, _} -> {kind, length(Ledger.list_categories(kind: kind))}
      end)

    assign(socket,
      stats: stats,
      counts: counts,
      uncategorized: Ledger.count_uncategorized(),
      targets: Ledger.list_categories()
    )
  end

  defp parse_tab(tab) when tab in ["expense", "income", "person", "archived"],
    do: String.to_existing_atom(tab)

  defp parse_tab(_), do: :expense

  defp category_changeset(nil, tab) do
    Ledger.change_category(%Category{}, %{kind: if(tab == :archived, do: :expense, else: tab)})
  end

  defp category_changeset(%Category{} = category, _tab), do: Ledger.change_category(category)

  defp assign_form(socket, changeset), do: assign(socket, form: to_form(changeset))

  defp categories_path(assigns, overrides \\ %{}) do
    params =
      %{"tab" => Atom.to_string(assigns.tab)}
      |> Map.merge(overrides)
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.new()

    ~p"/categorias?#{params}"
  end

  @impl true
  def handle_event("validate", %{"category" => params}, socket) do
    changeset =
      (socket.assigns.editing || %Category{})
      |> Ledger.change_category(params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"category" => params}, socket) do
    result =
      case socket.assigns.editing do
        nil -> Ledger.create_category(params)
        category -> Ledger.update_category(category, params)
      end

    case result do
      {:ok, category} ->
        {:noreply,
         socket
         |> put_flash(:info, "Categoria “#{category.name}” salva.")
         |> push_patch(to: categories_path(socket.assigns))}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event("cancel", _params, socket),
    do: {:noreply, push_patch(socket, to: categories_path(socket.assigns))}

  def handle_event("archive", %{"id" => id}, socket) do
    {:ok, category} = id |> Ledger.get_category!() |> Ledger.archive_category()
    {:noreply, socket |> put_flash(:info, "Categoria “#{category.name}” arquivada.") |> reload()}
  end

  def handle_event("unarchive", %{"id" => id}, socket) do
    {:ok, category} = id |> Ledger.get_category!() |> Ledger.unarchive_category()
    {:noreply, socket |> put_flash(:info, "Categoria “#{category.name}” reativada.") |> reload()}
  end

  def handle_event("merge", %{"target_id" => ""}, socket), do: {:noreply, socket}

  def handle_event("merge", %{"target_id" => target_id}, socket) do
    source = socket.assigns.merging
    target = Ledger.get_category!(target_id)

    case Ledger.merge_categories(source, target) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "“#{source.name}” foi mesclada em “#{target.name}”.")
         |> push_patch(to: categories_path(socket.assigns))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Não foi possível mesclar as categorias.")}
    end
  end

  defp kind_label(:expense), do: "Despesa"
  defp kind_label(:income), do: "Receita"
  defp kind_label(:person), do: "Pessoa"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      nav={:categories}
      inbox_count={@inbox_count}
    >
      <div class="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 class="text-3xl font-bold tracking-tight">Categorias</h1>
          <p class="text-sm text-base-content/60">
            Cadastro com tipo, cor e vínculo com despesas fixas; mescle duplicatas sem perder lançamentos
          </p>
        </div>
        <.link patch={categories_path(assigns, %{"new" => "1"})} class="btn btn-primary btn-sm">
          <.icon name="hero-plus-micro" class="size-4" /> Nova categoria
        </.link>
      </div>

      <div :if={@uncategorized > 0} class="alert alert-warning alert-soft">
        <.icon name="hero-exclamation-triangle" class="size-5" />
        <span><b>{@uncategorized}</b> {if @uncategorized == 1,
          do: "lançamento está",
          else: "lançamentos estão"} sem categoria.</span>
        <.link navigate={~p"/lancamentos?#{%{"category" => "none"}}"} class="btn btn-sm">Revisar</.link>
      </div>

      <section :if={@form_open?} class="card border border-primary/40 bg-base-100">
        <.form
          for={@form}
          id="category-form"
          phx-change="validate"
          phx-submit="save"
          class="card-body grid gap-3 p-5 md:grid-cols-[1fr_10rem_8rem_auto_auto] md:items-start"
        >
          <.input field={@form[:name]} type="text" label="Nome" placeholder="Ex.: Mercado" required />
          <.input field={@form[:kind]} type="select" label="Tipo" options={@kinds} />
          <.input
            field={@form[:color]}
            type="color"
            label="Cor"
            value={@form[:color].value || "#67b5e1"}
            class="input h-10 w-full p-1"
          />
          <.unlabeled_field>
            <.input field={@form[:fixed]} type="checkbox" label="Despesa fixa" />
          </.unlabeled_field>
          <.unlabeled_field>
            <div class="flex gap-1">
              <.button variant="primary" phx-disable-with="Salvando…">{if @editing,
                do: "Salvar",
                else: "Adicionar"}</.button>
              <button type="button" phx-click="cancel" class="btn">Cancelar</button>
            </div>
          </.unlabeled_field>
        </.form>
      </section>

      <section :if={@merging} class="card border border-warning/60 bg-base-100">
        <form id="merge-form" phx-submit="merge" class="card-body flex flex-wrap items-end gap-3 p-5">
          <div class="text-sm">
            <p class="font-semibold">Mesclar “{@merging.name}” em outra categoria</p>
            <p class="text-base-content/60">
              Todos os lançamentos e despesas fixas passam para a categoria escolhida; “{@merging.name}” é arquivada.
            </p>
          </div>
          <select name="target_id" class="select w-64" required>
            <option value="">Escolha a categoria de destino</option>
            <option :for={target <- @targets} :if={target.id != @merging.id} value={target.id}>
              {target.name} · {kind_label(target.kind)}
            </option>
          </select>
          <button
            type="submit"
            class="btn btn-warning"
            data-confirm={"Mesclar “#{@merging.name}”? Isso não pode ser desfeito automaticamente."}
          >Mesclar</button>
          <.link patch={categories_path(assigns)} class="btn btn-ghost">Cancelar</.link>
        </form>
      </section>

      <div class="join max-w-full overflow-x-auto">
        <.link
          :for={{tab, label} <- @tabs}
          patch={categories_path(%{tab: tab})}
          class={["btn btn-sm join-item whitespace-nowrap", @tab == tab && "btn-active"]}
        >
          {label} · {@counts[tab]}
        </.link>
      </div>

      <section class="card border border-base-300 bg-base-100">
        <.empty_state :if={@stats == []} icon="hero-tag">Nenhuma categoria aqui.</.empty_state>
        <div :if={@stats != []} class="overflow-x-auto">
          <table class="table">
            <thead>
              <tr>
                <th class="w-8"></th>
                <th>Nome</th>
                <th>Tipo</th>
                <th>Fixa</th>
                <th class="text-right">Lançamentos</th>
                <th class="text-right">Total</th>
                <th class="text-right">Média / mês</th>
                <th>Último uso</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @stats} id={"category-#{row.category.id}"}>
                <td>
                  <span
                    class="block size-2.5 rounded-full"
                    style={"background: #{row.category.color || "var(--color-base-300)"}"}
                  ></span>
                </td>
                <td class="font-medium">{row.category.name}</td>
                <td class="text-base-content/70">{kind_label(row.category.kind)}</td>
                <td>
                  <.badge :if={row.has_bill? or row.category.fixed} kind={:accent}>fixa</.badge>
                </td>
                <td class="tabular text-right">{row.count}</td>
                <td class="tabular text-right">{amount(row.total)}</td>
                <td class="tabular text-right text-base-content/70">{amount(row.monthly_average)}</td>
                <td class="font-mono text-xs text-base-content/50">
                  {if row.last_date, do: short_date(row.last_date), else: "—"}
                </td>
                <td>
                  <div class="flex items-center justify-end gap-1">
                    <.link
                      :if={@tab != :archived}
                      patch={categories_path(assigns, %{"edit" => row.category.id})}
                      class="btn btn-ghost btn-xs btn-square"
                      aria-label="Editar"
                    >
                      <.icon name="hero-pencil-square-micro" class="size-4" />
                    </.link>
                    <.link
                      :if={@tab != :archived}
                      patch={categories_path(assigns, %{"merge" => row.category.id})}
                      class="btn btn-ghost btn-xs btn-square"
                      aria-label="Mesclar"
                    >
                      <.icon name="hero-arrows-pointing-in-micro" class="size-4" />
                    </.link>
                    <button
                      :if={@tab != :archived}
                      type="button"
                      phx-click="archive"
                      phx-value-id={row.category.id}
                      class="btn btn-ghost btn-xs btn-square"
                      aria-label="Arquivar"
                    >
                      <.icon name="hero-archive-box-micro" class="size-4" />
                    </button>
                    <button
                      :if={@tab == :archived}
                      type="button"
                      phx-click="unarchive"
                      phx-value-id={row.category.id}
                      class="btn btn-ghost btn-xs"
                    >
                      Reativar
                    </button>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
