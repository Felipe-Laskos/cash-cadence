defmodule CashCadenceWeb.UIComponents do
  @moduledoc false

  use Phoenix.Component

  import CashCadenceWeb.CoreComponents, only: [icon: 1]
  import CashCadenceWeb.Format

  alias CashCadence.Money
  alias Phoenix.LiveView.JS

  attr :label, :string, required: true
  attr :class, :string, default: nil
  slot :inner_block, required: true
  slot :footer

  def kpi(assigns) do
    ~H"""
    <div class={["card border border-base-300 bg-base-100", @class]}>
      <div class="card-body gap-2 p-5">
        <span class="text-xs font-bold uppercase tracking-wide text-base-content/60">{@label}</span>
        <div class="tabular text-3xl font-bold tracking-tight">{render_slot(@inner_block)}</div>
        <div :if={@footer != []} class="text-xs text-base-content/70">{render_slot(@footer)}</div>
      </div>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  attr :class, :string, default: nil
  slot :actions
  slot :inner_block, required: true

  def card(assigns) do
    ~H"""
    <section class={["card border border-base-300 bg-base-100", @class]}>
      <div class="card-body gap-4 p-5">
        <header class="flex flex-wrap items-start justify-between gap-3">
          <div class="min-w-0">
            <h2 class="text-sm font-bold">{@title}</h2>
            <p :if={@subtitle} class="text-xs text-base-content/60">{@subtitle}</p>
          </div>
          <div :if={@actions != []} class="flex flex-wrap items-center gap-2 text-sm">
            {render_slot(@actions)}
          </div>
        </header>
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end

  attr :kind, :atom,
    default: :neutral,
    values: [:paid, :partial, :unpaid, :neutral, :accent, :warn]

  attr :class, :string, default: nil
  slot :inner_block, required: true

  def badge(assigns) do
    ~H"""
    <span class={[
      "badge badge-soft gap-1 whitespace-nowrap font-semibold",
      badge_class(@kind),
      @class
    ]}>
      {render_slot(@inner_block)}
    </span>
    """
  end

  defp badge_class(:paid), do: "badge-success"
  defp badge_class(:partial), do: "badge-warning"
  defp badge_class(:warn), do: "badge-warning"
  defp badge_class(:unpaid), do: "badge-error"
  defp badge_class(:accent), do: "badge-info"
  defp badge_class(_), do: "badge-ghost"

  attr :category, :map, default: nil
  attr :show_fixed, :boolean, default: true

  def category_chip(assigns) do
    ~H"""
    <span :if={@category} class="badge badge-ghost gap-1 whitespace-nowrap font-medium">
      {@category.name}
      <span :if={@category.kind == :person} class="text-[10px] uppercase text-base-content/50">pessoa</span>
    </span>
    <span
      :if={@show_fixed && @category && @category.fixed}
      class="badge badge-soft badge-info badge-sm"
    >fixa</span>
    <span :if={!@category} class="badge badge-soft badge-warning gap-1 whitespace-nowrap font-medium">
      <.icon name="hero-exclamation-triangle-micro" class="size-3" /> Sem categoria
    </span>
    """
  end

  attr :value, :any, required: true
  attr :kind, :atom, default: :expense
  attr :currency, :boolean, default: false
  attr :class, :string, default: nil

  def money(assigns) do
    ~H"""
    <span class={[
      "tabular font-semibold whitespace-nowrap",
      @kind == :income && "text-income",
      @kind == :transfer && "text-base-content/60",
      @class
    ]}>
      {money_text(@value, @kind, @currency)}
    </span>
    """
  end

  defp money_text(value, :income, true), do: "+" <> brl(value)
  defp money_text(value, :income, false), do: amount(value, signed: true)
  defp money_text(value, _kind, true), do: brl(value)
  defp money_text(value, _kind, false), do: amount(value)

  attr :month, Date, required: true
  attr :base, :string, required: true
  attr :params, :map, default: %{}

  def month_nav(assigns) do
    ~H"""
    <div class="join rounded-field border border-base-300 bg-base-100">
      <.link
        patch={month_path(@base, @params, Date.shift(@month, month: -1))}
        class="btn btn-ghost btn-sm join-item"
        aria-label="Mês anterior"
      >
        <.icon name="hero-chevron-left-micro" class="size-4" />
      </.link>
      <span class="join-item flex min-w-36 items-center justify-center px-3 text-sm font-semibold">{month_label(
        @month
      )}</span>
      <.link
        patch={month_path(@base, @params, Date.shift(@month, month: 1))}
        class="btn btn-ghost btn-sm join-item"
        aria-label="Mês seguinte"
      >
        <.icon name="hero-chevron-right-micro" class="size-4" />
      </.link>
    </div>
    <.link patch={month_path(@base, @params, Date.utc_today())} class="btn btn-ghost btn-sm">Hoje</.link>
    """
  end

  def month_path(base, params, %Date{} = month) do
    query =
      params
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> Map.put("m", month_param(month))
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> URI.encode_query()

    base <> "?" <> query
  end

  attr :navigate, :string, required: true
  attr :icon, :string, required: true
  attr :active, :boolean, default: false
  slot :inner_block, required: true

  def nav_link(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class={[
        "flex items-center gap-3 rounded-field px-3 py-2 text-sm font-medium transition-colors",
        @active && "bg-secondary text-secondary-content",
        !@active && "text-base-content/70 hover:bg-base-300 hover:text-base-content"
      ]}
      aria-current={@active && "page"}
    >
      <.icon name={@icon} class="size-5" />
      {render_slot(@inner_block)}
    </.link>
    """
  end

  attr :navigate, :string, required: true
  attr :icon, :string, required: true
  attr :active, :boolean, default: false
  attr :badge, :integer, default: nil
  slot :inner_block, required: true

  def tab_link(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class={[
        "relative flex min-h-12 w-16 flex-col items-center gap-0.5 pt-1 text-[11px] font-medium",
        @active && "text-primary",
        !@active && "text-base-content/60"
      ]}
      aria-current={@active && "page"}
    >
      <.icon name={@icon} class="size-5" />
      {render_slot(@inner_block)}
      <span :if={@badge && @badge > 0} class="badge badge-primary badge-xs absolute right-1 top-0">{@badge}</span>
    </.link>
    """
  end

  attr :value, :integer, required: true
  attr :kind, :atom, default: :accent

  def progress(assigns) do
    ~H"""
    <div class="h-1.5 w-full overflow-hidden rounded-full bg-base-300">
      <div
        class={["h-full rounded-full", progress_class(@kind)]}
        style={"width: #{min(@value, 100)}%"}
      >
      </div>
    </div>
    """
  end

  defp progress_class(:paid), do: "bg-success"
  defp progress_class(:partial), do: "bg-warning"
  defp progress_class(:unpaid), do: "bg-error"
  defp progress_class(_), do: "bg-primary"

  attr :current, :any, required: true
  attr :previous, :any, required: true
  attr :label, :string, required: true
  attr :good_when, :atom, default: :up, values: [:up, :down]

  def delta(assigns) do
    change = Money.pct_change(assigns.current, assigns.previous)

    assign(assigns, change: change, up?: change && Money.positive?(change))
    |> render_delta()
  end

  defp render_delta(%{change: nil} = assigns) do
    ~H"""
    <span class="text-base-content/50">sem base de comparação</span>
    """
  end

  defp render_delta(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1 font-semibold",
      good?(@up?, @good_when) && "text-success",
      !good?(@up?, @good_when) && "text-error"
    ]}>
      <.icon
        name={if(@up?, do: "hero-chevron-up-micro", else: "hero-chevron-down-micro")}
        class="size-3"
      />
      {@change |> Decimal.abs() |> percent()}
    </span>
    <span class="text-base-content/60">{@label}</span>
    """
  end

  defp good?(up?, :up), do: up?
  defp good?(up?, :down), do: not up?

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  attr :on_cancel, JS, default: %JS{}
  attr :max_width, :string, default: "max-w-2xl"
  slot :inner_block, required: true

  def modal(assigns) do
    ~H"""
    <div
      id={@id}
      class="modal modal-open"
      role="dialog"
      aria-modal="true"
      aria-labelledby={"#{@id}-title"}
      phx-hook=".Modal"
      phx-window-keydown={@on_cancel}
      phx-key="escape"
    >
      <div class={[
        "modal-box flex max-h-[85dvh] w-full flex-col border border-base-300 p-0 shadow-2xl",
        @max_width
      ]}>
        <header class="flex items-start justify-between gap-4 border-b border-base-300 px-5 py-4">
          <div class="min-w-0">
            <h3 id={"#{@id}-title"} class="text-sm font-bold">{@title}</h3>
            <p :if={@subtitle} class="mt-1 text-xs text-base-content/60">{@subtitle}</p>
          </div>
          <button
            type="button"
            id={"#{@id}-close"}
            phx-click={@on_cancel}
            class="btn btn-ghost btn-sm btn-square -mr-2 -mt-1 shrink-0"
            aria-label="Fechar"
          >
            <.icon name="hero-x-mark-micro" class="size-4" />
          </button>
        </header>
        {render_slot(@inner_block)}
      </div>
      <button type="button" class="modal-backdrop" phx-click={@on_cancel} aria-label="Fechar"></button>
    </div>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".Modal">
      const FOCUSABLE =
        "a[href], button:not([disabled]), input:not([disabled]):not([type=hidden]), " +
        "select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex='-1'])"

      const SELECTABLE = ["text", "search", "url", "tel", "password"]

      export default {
        mounted() {
          this.restoreTo = document.activeElement
          this.onKeydown = (event) => this.trapTab(event)
          this.el.addEventListener("keydown", this.onKeydown)
          this.lock()
          this.focusFirst()
        },

        updated() {
          this.lock()
        },

        destroyed() {
          this.el.removeEventListener("keydown", this.onKeydown)
          this.unlock()
          if (this.restoreTo && document.contains(this.restoreTo)) {
            this.restoreTo.focus()
          }
        },

        lock() {
          document.documentElement.style.overflow = "hidden"
        },

        unlock() {
          document.documentElement.style.overflow = ""
        },

        focusFirst() {
          const box = this.el.querySelector(".modal-box")
          const target =
            box.querySelector("[data-autofocus]") ||
            box.querySelector("input:not([type=hidden]), select, textarea")
          if (!target) { return }
          target.focus()
          if (SELECTABLE.includes(target.type)) { target.select() }
        },

        trapTab(event) {
          if (event.key !== "Tab") { return }
          const items = Array.from(this.el.querySelectorAll(FOCUSABLE))
            .filter((el) => el.offsetParent !== null)
          if (items.length === 0) { return }
          const first = items[0]
          const last = items[items.length - 1]
          if (event.shiftKey && document.activeElement === first) {
            event.preventDefault()
            last.focus()
          } else if (!event.shiftKey && document.activeElement === last) {
            event.preventDefault()
            first.focus()
          }
        }
      }
    </script>
    """
  end

  attr :class, :any, default: nil
  slot :inner_block, required: true

  def modal_body(assigns) do
    ~H"""
    <div class={["min-h-0 flex-1 overflow-y-auto px-5 py-4", @class]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  slot :inner_block, required: true

  def modal_footer(assigns) do
    ~H"""
    <footer class="flex flex-wrap items-center justify-end gap-2 border-t border-base-300 bg-base-200/40 px-5 py-3">
      {render_slot(@inner_block)}
    </footer>
    """
  end

  attr :title, :string, required: true
  attr :hint, :string, default: nil
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def form_section(assigns) do
    ~H"""
    <div class={["mt-2 border-t border-base-300 pt-4", @class]}>
      <h4 class="text-xs font-bold uppercase tracking-wide text-base-content/60">{@title}</h4>
      <p :if={@hint} class="mt-1 text-xs text-base-content/60">{@hint}</p>
      <div class="mt-3">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  attr :icon, :string, default: "hero-inbox"
  slot :inner_block, required: true

  def empty_state(assigns) do
    ~H"""
    <div class="flex flex-col items-center gap-2 py-10 text-center text-sm text-base-content/60">
      <.icon name={@icon} class="size-8 opacity-60" />
      <div>{render_slot(@inner_block)}</div>
    </div>
    """
  end
end
