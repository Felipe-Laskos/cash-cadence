defmodule CashCadenceWeb.SettingsLive do
  use CashCadenceWeb, :live_view

  alias CashCadence.{Backup, Classifier, Imports, Ledger, Settings}
  alias CashCadence.Classifier.Rule
  alias CashCadence.Ledger.BankAccount

  @sections [
    {"importacao", "Importação"},
    {"regras", "Regras"},
    {"memoria", "Memória"},
    {"conta", "Conta e acesso"},
    {"backup", "Backup"},
    {"celular", "Celular"}
  ]
  @match_kinds [
    {"contém", "contains"},
    {"começa com", "starts_with"},
    {"casa com a expressão", "regex"}
  ]
  @targets [
    {"a descrição do banco", "description"},
    {"a categoria informada pelo Itaú", "bank_hint"}
  ]
  @kind_overrides [
    {"manter o do extrato", ""},
    {"Despesa", "expense"},
    {"Receita", "income"},
    {"Transferência", "transfer"}
  ]
  @banks [{"Itaú", "itau"}, {"Nubank", "nubank"}, {"Outro", "other"}]
  @account_kinds [{"Conta", "checking"}, {"Cartão de crédito", "credit_card"}, {"Outro", "other"}]
  @competence_modes [{"data da compra", "purchase_date"}, {"mês da fatura", "statement_month"}]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Configurações",
       sections: @sections,
       match_kinds: @match_kinds,
       targets: @targets,
       kind_overrides: @kind_overrides,
       banks: @banks,
       account_kinds: @account_kinds,
       competence_modes: @competence_modes
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    rule = load_rule(params["rule"])
    account = load_account(params["account"])

    socket =
      socket
      |> assign(editing_rule: rule, editing_account: account, memory_search: params["q"] || "")
      |> assign(rule_form: rule_form(rule), account_form: account_form(account))
      |> reload()

    {:noreply, socket}
  end

  defp load_rule(nil), do: nil
  defp load_rule("new"), do: %Rule{}
  defp load_rule(id), do: Classifier.get_rule!(id)

  defp load_account(nil), do: nil
  defp load_account("new"), do: %BankAccount{}
  defp load_account(id), do: Ledger.get_bank_account!(id)

  defp rule_form(nil), do: nil

  defp rule_form(%Rule{} = rule) do
    name =
      case rule.category do
        %{name: name} -> name
        _ -> ""
      end

    to_form(Classifier.change_rule(rule, %{"category_name" => name}))
  end

  defp account_form(nil), do: nil
  defp account_form(%BankAccount{} = account), do: to_form(Ledger.change_bank_account(account))

  defp reload(socket) do
    rules = Classifier.list_rules()

    assign(socket,
      rules: rules,
      previews: Map.new(rules, &{&1.id, Classifier.preview(&1)}),
      memory: Classifier.list_memory(socket.assigns.memory_search),
      memory_count: Classifier.count_memory(),
      accounts: Ledger.list_bank_accounts(),
      last_batch: List.first(Imports.list_batches(1)),
      pending_count: Imports.count_pending(),
      suggestions: Ledger.category_suggestions(),
      auto_approve: Settings.auto_approve?(),
      backup: Backup.Scheduler.config(),
      backup_files:
        Backup.Scheduler.config() |> Keyword.fetch!(:dir) |> Backup.list_files() |> Enum.take(5)
    )
  end

  defp settings_path(overrides \\ %{}) do
    params = overrides |> Enum.reject(fn {_key, value} -> value in [nil, ""] end) |> Map.new()
    ~p"/configuracoes?#{params}"
  end

  @impl true
  def handle_event("validate_rule", %{"rule" => params}, socket) do
    changeset =
      socket.assigns.editing_rule
      |> Classifier.change_rule(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, rule_form: to_form(changeset))}
  end

  def handle_event("save_rule", %{"rule" => params}, socket) do
    result =
      case socket.assigns.editing_rule do
        %Rule{id: nil} -> Classifier.create_rule(params)
        rule -> Classifier.update_rule(rule, params)
      end

    case result do
      {:ok, _rule} ->
        {:noreply,
         socket
         |> put_flash(:info, "Regra salva. " <> reclassified())
         |> push_patch(to: settings_path())}

      {:error, changeset} ->
        {:noreply, assign(socket, rule_form: to_form(changeset))}
    end
  end

  def handle_event("delete_rule", %{"id" => id}, socket) do
    {:ok, _} = id |> Classifier.get_rule!() |> Classifier.delete_rule()
    {:noreply, socket |> put_flash(:info, "Regra excluída. " <> reclassified()) |> reload()}
  end

  def handle_event("toggle_rule", %{"id" => id}, socket) do
    {:ok, rule} = id |> Classifier.get_rule!() |> Classifier.toggle_rule()
    state = if rule.active, do: "ativada", else: "desativada"
    {:noreply, socket |> put_flash(:info, "Regra #{state}. " <> reclassified()) |> reload()}
  end

  def handle_event("move_rule", %{"id" => id, "direction" => direction}, socket) do
    {:ok, _} =
      id |> Classifier.get_rule!() |> Classifier.move_rule(String.to_existing_atom(direction))

    {:noreply, reload(socket)}
  end

  def handle_event("reclassify", _params, socket),
    do: {:noreply, socket |> put_flash(:info, reclassified()) |> reload()}

  def handle_event("toggle_auto_approve", _params, socket) do
    enabled = not socket.assigns.auto_approve
    :ok = Settings.set_auto_approve(enabled)

    message =
      if enabled,
        do: "Itens de confiança alta e sem alertas passam a ser aprovados na importação.",
        else: "Tudo que chegar vai esperar sua revisão na caixa de entrada."

    {:noreply, socket |> put_flash(:info, message) |> reload()}
  end

  def handle_event("backup_now", _params, socket) do
    {:ok, path} = Backup.Scheduler.run_now()
    {:noreply, socket |> put_flash(:info, "Backup gravado em #{path}.") |> reload()}
  end

  def handle_event("validate_account", %{"bank_account" => params}, socket) do
    changeset =
      socket.assigns.editing_account
      |> Ledger.change_bank_account(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, account_form: to_form(changeset))}
  end

  def handle_event("save_account", %{"bank_account" => params}, socket) do
    result =
      case socket.assigns.editing_account do
        %BankAccount{id: nil} -> Ledger.create_bank_account(params)
        account -> Ledger.update_bank_account(account, params)
      end

    case result do
      {:ok, account} ->
        {:noreply,
         socket
         |> put_flash(:info, "Conta “#{account.name}” salva.")
         |> push_patch(to: settings_path())}

      {:error, changeset} ->
        {:noreply, assign(socket, account_form: to_form(changeset))}
    end
  end

  def handle_event("delete_account", %{"id" => id}, socket) do
    {:ok, account} = id |> Ledger.get_bank_account!() |> Ledger.delete_bank_account()
    {:noreply, socket |> put_flash(:info, "Conta “#{account.name}” excluída.") |> reload()}
  end

  def handle_event("forget_ref", %{"id" => id}, socket) do
    {:ok, account} = id |> Ledger.get_bank_account!() |> Ledger.forget_bank_account_ref()

    {:noreply,
     socket
     |> put_flash(:info, "“#{account.name}” vai ser detectada de novo na próxima importação.")
     |> reload()}
  end

  def handle_event("search_memory", %{"q" => q}, socket),
    do: {:noreply, push_patch(socket, to: settings_path(%{"q" => q}))}

  def handle_event("forget_memory", %{"id" => id}, socket) do
    {:ok, _} = id |> Classifier.get_memory!() |> Classifier.forget()
    {:noreply, socket |> put_flash(:info, "Descrição esquecida.") |> reload()}
  end

  defp reclassified do
    case Imports.reclassify_pending() do
      0 -> "Nenhum item pendente mudou."
      1 -> "1 item pendente foi reclassificado."
      n -> "#{n} itens pendentes foram reclassificados."
    end
  end

  defp label(options, value) do
    Enum.find_value(options, to_string(value), fn {label, key} ->
      key == to_string(value) && label
    end)
  end

  defp rule_sentence(rule) do
    "se #{label(@targets, rule.target)} #{label(@match_kinds, rule.match_kind)} “#{rule.pattern}”"
  end

  defp preview_label(%{transactions: transactions, pending: pending}) do
    "#{transactions} #{if transactions == 1, do: "lançamento", else: "lançamentos"} · #{pending} #{if pending == 1, do: "pendente", else: "pendentes"}"
  end

  defp file_size(bytes) when bytes >= 1_048_576, do: "#{Float.round(bytes / 1_048_576, 1)} MB"
  defp file_size(bytes), do: "#{max(div(bytes, 1024), 1)} KB"

  defp file_date(%DateTime{} = at), do: Calendar.strftime(at, "%d/%m/%Y %H:%M")

  defp memory_date(nil), do: "—"
  defp memory_date(%DateTime{} = at), do: Calendar.strftime(at, "%d/%m/%Y")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      nav={:settings}
      inbox_count={@inbox_count}
    >
      <div>
        <h1 class="text-3xl font-bold tracking-tight">Configurações</h1>
        <p class="text-sm text-base-content/60">
          Importação e contas, regras de categoria, memória, acesso e backup
        </p>
      </div>

      <nav class="flex flex-wrap gap-1">
        <a :for={{id, label} <- @sections} href={"##{id}"} class="btn btn-sm btn-ghost">{label}</a>
      </nav>

      <datalist id="settings-category-options">
        <option :for={suggestion <- @suggestions} value={suggestion.name}></option>
      </datalist>

      <section id="importacao" class="space-y-4 scroll-mt-4">
        <.card title="Extratos e faturas" subtitle="OFX e CSV do Nubank, PDF do Itaú">
          <:actions>
            <.link navigate={~p"/importar"} class="btn btn-primary btn-sm">
              <.icon name="hero-arrow-up-tray-micro" class="size-4" /> Importar agora
            </.link>
          </:actions>
          <p class="text-sm text-base-content/80">
            Baixe o extrato ou a fatura no app do banco e solte na tela Importar. Duplicatas, lançamentos já feitos à mão e transferências entre suas contas são reconhecidos antes de você aprovar.
          </p>
          <p class="mt-2 text-sm text-base-content/60">
            <span :if={@last_batch}>
              Última importação: {full_date(DateTime.to_date(@last_batch.inserted_at))} ·
              <span class="font-mono text-xs">{@last_batch.file_name}</span>
            </span>
            <span :if={is_nil(@last_batch)}>Nenhuma importação ainda.</span>
            <span :if={@pending_count > 0}>
              ·
              <.link navigate={~p"/entrada"} class="underline">{@pending_count} {if @pending_count ==
                                                                                      1,
                                                                                    do:
                                                                                      "item aguarda",
                                                                                    else:
                                                                                      "itens aguardam"} revisão</.link>
            </span>
          </p>
          <label class="mt-4 flex items-start gap-3 text-sm">
            <input
              id="auto-approve"
              type="checkbox"
              class="toggle toggle-primary toggle-sm mt-0.5"
              checked={@auto_approve}
              phx-click="toggle_auto_approve"
            />
            <span>
              <b>Aprovar automaticamente na importação</b>
              os itens de confiança alta e sem alertas: regra ou fixa casada, ou descrição já aprovada duas vezes. Duplicatas, transferências e reembolsos prováveis continuam esperando você.
            </span>
          </label>
        </.card>

        <.card
          title="Contas bancárias"
          subtitle="Cada arquivo importado é ligado a uma conta; transferências entre elas ficam fora de receita e despesa"
        >
          <:actions>
            <.link patch={settings_path(%{"account" => "new"})} class="btn btn-sm">
              <.icon name="hero-plus-micro" class="size-4" /> Nova conta
            </.link>
          </:actions>
          <.form
            :if={@account_form}
            for={@account_form}
            id="account-form"
            phx-change="validate_account"
            phx-submit="save_account"
            class="mb-4 grid gap-3 rounded-box border border-primary/40 p-4 md:grid-cols-[1fr_9rem_11rem_11rem_auto_auto] md:items-start"
          >
            <.input
              field={@account_form[:name]}
              type="text"
              label="Nome"
              placeholder="Ex.: Itaú conta"
              required
            />
            <.input field={@account_form[:bank]} type="select" label="Banco" options={@banks} />
            <.input field={@account_form[:kind]} type="select" label="Tipo" options={@account_kinds} />
            <.input
              field={@account_form[:competence_mode]}
              type="select"
              label="Competência (cartão)"
              options={@competence_modes}
            />
            <.unlabeled_field>
              <.input field={@account_form[:own]} type="checkbox" label="É minha" />
            </.unlabeled_field>
            <.unlabeled_field>
              <div class="flex gap-1">
                <.button variant="primary" phx-disable-with="Salvando…">
                  {if @editing_account && @editing_account.id, do: "Salvar", else: "Adicionar"}
                </.button>
                <.link patch={settings_path()} class="btn">Cancelar</.link>
              </div>
            </.unlabeled_field>
          </.form>
          <.empty_state :if={@accounts == []} icon="hero-building-library">
            Nenhuma conta cadastrada. Sem contas, os arquivos importados entram sem vínculo.
          </.empty_state>
          <div :if={@accounts != []} class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Nome</th>
                  <th>Banco</th>
                  <th>Tipo</th>
                  <th>Competência</th>
                  <th>Vínculo com arquivo</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <tr :for={account <- @accounts} id={"account-#{account.id}"}>
                  <td class="font-medium">{account.name}</td>
                  <td>{label(@banks, account.bank)}</td>
                  <td>{label(@account_kinds, account.kind)}</td>
                  <td class="text-base-content/70">
                    {if account.kind == :credit_card,
                      do: label(@competence_modes, account.competence_mode),
                      else: "—"}
                  </td>
                  <td>
                    <span :if={account.external_ref} class="font-mono text-xs">{account.external_ref}</span>
                    <button
                      :if={account.external_ref}
                      type="button"
                      phx-click="forget_ref"
                      phx-value-id={account.id}
                      class="btn btn-ghost btn-xs ml-1"
                    >
                      esquecer
                    </button>
                    <span :if={is_nil(account.external_ref)} class="text-base-content/50">
                      liga no próximo arquivo desse banco
                    </span>
                  </td>
                  <td>
                    <div class="flex items-center justify-end gap-1">
                      <.link
                        patch={settings_path(%{"account" => account.id})}
                        class="btn btn-ghost btn-xs btn-square"
                        aria-label="Editar"
                      >
                        <.icon name="hero-pencil-square-micro" class="size-4" />
                      </.link>
                      <button
                        type="button"
                        phx-click="delete_account"
                        phx-value-id={account.id}
                        class="btn btn-ghost btn-xs btn-square"
                        aria-label="Excluir"
                        data-confirm={"Excluir a conta “#{account.name}”? Os lançamentos continuam, só perdem o vínculo."}
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
      </section>

      <section id="regras" class="scroll-mt-4">
        <.card
          title="Regras de categoria"
          subtitle="Valem antes da memória; a primeira que casar decide a categoria e, se quiser, o tipo"
        >
          <:actions>
            <button
              :if={@rules != [] and @pending_count > 0}
              type="button"
              phx-click="reclassify"
              class="btn btn-ghost btn-sm"
            >
              Aplicar às pendentes
            </button>
            <.link patch={settings_path(%{"rule" => "new"})} class="btn btn-primary btn-sm">
              <.icon name="hero-plus-micro" class="size-4" /> Nova regra
            </.link>
          </:actions>
          <.form
            :if={@rule_form}
            for={@rule_form}
            id="rule-form"
            phx-change="validate_rule"
            phx-submit="save_rule"
            class="mb-4 grid gap-3 rounded-box border border-primary/40 p-4 md:grid-cols-2 md:items-end lg:grid-cols-3 2xl:grid-cols-[16rem_11rem_minmax(12rem,1fr)_11rem_12rem]"
          >
            <.input field={@rule_form[:target]} type="select" label="Se" options={@targets} />
            <.input field={@rule_form[:match_kind]} type="select" label="…" options={@match_kinds} />
            <.input
              field={@rule_form[:pattern]}
              type="text"
              label="Texto"
              placeholder="Ex.: POSTO"
              class="input w-full font-mono"
              required
            />
            <.input
              field={@rule_form[:category_name]}
              type="text"
              label="Categoria"
              placeholder="Ex.: Combustível"
              list="settings-category-options"
              autocomplete="off"
            />
            <.input
              field={@rule_form[:kind_override]}
              type="select"
              label="Tipo"
              options={@kind_overrides}
            />
            <div class="flex flex-wrap items-center gap-3 md:col-span-2 lg:col-span-3 2xl:col-span-5">
              <.input field={@rule_form[:active]} type="checkbox" label="Ativa" />
              <div class="ml-auto flex gap-1">
                <.button variant="primary" phx-disable-with="Salvando…">
                  {if @editing_rule && @editing_rule.id, do: "Salvar", else: "Adicionar"}
                </.button>
                <.link patch={settings_path()} class="btn">Cancelar</.link>
              </div>
            </div>
          </.form>
          <.empty_state :if={@rules == []} icon="hero-sparkles">
            Nenhuma regra ainda. Exemplo: se a descrição contém “POSTO”, categoria Combustível.
          </.empty_state>
          <div :if={@rules != []} class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th class="w-16">Ordem</th>
                  <th>Regra</th>
                  <th>Categoria</th>
                  <th>Tipo</th>
                  <th>Casaria com</th>
                  <th class="text-right">Acertos</th>
                  <th>Ativa</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <tr :for={rule <- @rules} id={"rule-#{rule.id}"} class={!rule.active && "opacity-60"}>
                  <td>
                    <div class="flex items-center gap-0.5">
                      <button
                        type="button"
                        phx-click="move_rule"
                        phx-value-id={rule.id}
                        phx-value-direction="up"
                        class="btn btn-ghost btn-xs btn-square"
                        aria-label="Subir"
                      >
                        <.icon name="hero-chevron-up-micro" class="size-4" />
                      </button>
                      <button
                        type="button"
                        phx-click="move_rule"
                        phx-value-id={rule.id}
                        phx-value-direction="down"
                        class="btn btn-ghost btn-xs btn-square"
                        aria-label="Descer"
                      >
                        <.icon name="hero-chevron-down-micro" class="size-4" />
                      </button>
                    </div>
                  </td>
                  <td>{rule_sentence(rule)}</td>
                  <td>
                    <.category_chip :if={rule.category} category={rule.category} show_fixed={false} />
                    <span :if={is_nil(rule.category)} class="text-base-content/50">—</span>
                  </td>
                  <td class="text-base-content/70">
                    {if rule.kind_override, do: label(@kind_overrides, rule.kind_override), else: "—"}
                  </td>
                  <td class="text-base-content/70">{preview_label(@previews[rule.id])}</td>
                  <td class="tabular text-right">{rule.hits}</td>
                  <td>
                    <input
                      type="checkbox"
                      class="toggle toggle-sm toggle-primary"
                      checked={rule.active}
                      phx-click="toggle_rule"
                      phx-value-id={rule.id}
                      aria-label="Ativa"
                    />
                  </td>
                  <td>
                    <div class="flex items-center justify-end gap-1">
                      <.link
                        patch={settings_path(%{"rule" => rule.id})}
                        class="btn btn-ghost btn-xs btn-square"
                        aria-label="Editar"
                      >
                        <.icon name="hero-pencil-square-micro" class="size-4" />
                      </.link>
                      <button
                        type="button"
                        phx-click="delete_rule"
                        phx-value-id={rule.id}
                        class="btn btn-ghost btn-xs btn-square"
                        aria-label="Excluir"
                        data-confirm="Excluir esta regra?"
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
      </section>

      <section id="memoria" class="scroll-mt-4">
        <.card
          title="Memória de categorização"
          subtitle={"#{@memory_count} #{if @memory_count == 1, do: "descrição aprendida", else: "descrições aprendidas"} com as suas aprovações; duas ou mais aprovações viram confiança alta"}
        >
          <:actions>
            <form id="memory-search" phx-change="search_memory" phx-submit="search_memory">
              <input
                type="search"
                name="q"
                value={@memory_search}
                placeholder="Procurar descrição"
                class="input input-sm w-56"
                phx-debounce="300"
                autocomplete="off"
              />
            </form>
          </:actions>
          <.empty_state :if={@memory == []} icon="hero-light-bulb">
            {if @memory_search == "",
              do:
                "Nada aprendido ainda. Cada item aprovado na caixa de entrada ensina uma descrição.",
              else: "Nenhuma descrição contém “#{@memory_search}”."}
          </.empty_state>
          <div :if={@memory != []} class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Descrição do banco</th>
                  <th>Categoria</th>
                  <th class="text-right">Aprovações</th>
                  <th>Última</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <tr :for={memory <- @memory} id={"memory-#{memory.id}"}>
                  <td class="font-mono text-xs">{memory.normalized_description}</td>
                  <td><.category_chip category={memory.category} show_fixed={false} /></td>
                  <td class="tabular text-right">{memory.uses}</td>
                  <td class="font-mono text-xs text-base-content/50">
                    {memory_date(memory.last_used_at)}
                  </td>
                  <td class="text-right">
                    <button
                      type="button"
                      phx-click="forget_memory"
                      phx-value-id={memory.id}
                      class="btn btn-ghost btn-xs"
                    >
                      Esquecer
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </.card>
      </section>

      <section id="conta" class="scroll-mt-4">
        <.card
          title="Conta e acesso"
          subtitle="Um único usuário; o cadastro fechou depois do primeiro"
        >
          <:actions>
            <.link navigate={~p"/users/settings"} class="btn btn-sm">Alterar e-mail ou senha</.link>
          </:actions>
          <p class="text-sm text-base-content/80">
            Você entra como <b>{@current_scope.user.email}</b>. A sessão fica guardada neste navegador por 60 dias; para sair de todos os aparelhos, troque a senha.
          </p>
        </.card>
      </section>

      <section id="backup" class="scroll-mt-4">
        <.card title="Backup e exportação" subtitle="Os dados ficam só neste computador">
          <:actions>
            <.link href={~p"/relatorios/export.csv"} class="btn btn-sm">
              <.icon name="hero-table-cells-micro" class="size-4" /> Lançamentos (CSV)
            </.link>
            <.link href={~p"/backup.json"} class="btn btn-primary btn-sm">
              <.icon name="hero-arrow-down-tray-micro" class="size-4" /> Baixar backup completo
            </.link>
          </:actions>
          <p class="text-sm text-base-content/80">
            O backup completo é um único arquivo JSON com lançamentos, categorias, contas, despesas fixas, regras, memória e caixa de entrada. Guarde numa nuvem sua. O CSV abre em qualquer planilha.
          </p>
          <p class="mt-2 text-sm text-base-content/60">
            Para restaurar, na pasta do projeto: <code class="font-mono text-xs">mix cash.restore ARQUIVO.json --yes</code>. Isso substitui todos os dados atuais. Também dá para gerar o arquivo pelo terminal com <code class="font-mono text-xs">mix cash.backup</code>.
          </p>
          <div id="auto-backup" class="mt-4 rounded-box border border-base-300 p-4 text-sm">
            <div class="flex flex-wrap items-start justify-between gap-3">
              <div>
                <p class="font-semibold">
                  Backup automático {if @backup[:enabled], do: "ligado", else: "desligado"}
                </p>
                <p class="text-base-content/60">
                  A cada {@backup[:interval_hours]} horas, enquanto o app estiver aberto, na pasta <code class="font-mono text-xs">{@backup[:dir]}</code>; mantém os últimos {@backup[
                    :keep
                  ]} arquivos.
                  Para gravar direto numa pasta sincronizada com o seu drive, inicie o app com
                  <code class="font-mono text-xs">CASH_BACKUP_DIR</code>
                  apontando para ela.
                </p>
              </div>
              <button type="button" phx-click="backup_now" class="btn btn-sm">
                <.icon name="hero-clock-micro" class="size-4" /> Fazer backup agora
              </button>
            </div>
            <ul
              :if={@backup_files != []}
              class="mt-3 space-y-1 font-mono text-xs text-base-content/70"
            >
              <li :for={file <- @backup_files} class="flex flex-wrap justify-between gap-2">
                <span>{file.name}</span>
                <span>{file_size(file.size)} · {file_date(file.modified_at)}</span>
              </li>
            </ul>
            <p :if={@backup_files == []} class="mt-3 text-base-content/50">
              Nenhum backup automático gravado ainda.
            </p>
          </div>
        </.card>
      </section>

      <section id="celular" class="scroll-mt-4">
        <.card title="Instalar no celular" subtitle="Funciona como app, sem loja">
          <ul class="list-disc space-y-1 pl-5 text-sm text-base-content/80">
            <li>
              Abra este endereço no celular, na mesma rede Wi-Fi do computador, usando o IP da máquina e a porta 4747.
            </li>
            <li><b>Android (Chrome)</b>: menu ⋮ → Adicionar à tela inicial.</li>
            <li><b>iPhone (Safari)</b>: compartilhar → Adicionar à Tela de Início.</li>
            <li>
              O app abre em tela cheia, com a aba <b>+</b>
              para lançar em segundos e a Caixa de entrada com o contador de pendências.
            </li>
          </ul>
        </.card>
      </section>
    </Layouts.app>
    """
  end
end
