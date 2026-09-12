defmodule CashCadenceWeb.UIComponents do
  @moduledoc false

  use Phoenix.Component

  import CashCadenceWeb.CoreComponents, only: [icon: 1]
  import CashCadenceWeb.Format

  alias CashCadence.Money

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
        <header class="flex items-start justify-between gap-4">
          <div>
            <h2 class="text-sm font-bold">{@title}</h2>
            <p :if={@subtitle} class="text-xs text-base-content/60">{@subtitle}</p>
          </div>
          <div :if={@actions != []} class="flex items-center gap-2 text-sm">
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
  slot :inner_block, required: true

  def tab_link(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class={[
        "flex min-h-12 w-16 flex-col items-center gap-0.5 pt-1 text-[11px] font-medium",
        @active && "text-primary",
        !@active && "text-base-content/60"
      ]}
      aria-current={@active && "page"}
    >
      <.icon name={@icon} class="size-5" />
      {render_slot(@inner_block)}
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
