defmodule CashCadenceWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use CashCadenceWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :nav, :atom, default: nil

  slot :inner_block, required: true

  def app(%{current_scope: nil} = assigns) do
    ~H"""
    <main class="flex min-h-dvh items-center justify-center px-4 py-10">
      <div class="w-full max-w-md space-y-6">
        <p class="text-center text-2xl font-extrabold tracking-tight">
          Cash<span class="text-primary">Cadence</span>
        </p>
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  def app(assigns) do
    ~H"""
    <div class="min-h-dvh lg:flex">
      <aside class="hidden border-r border-base-300 bg-base-100 lg:fixed lg:inset-y-0 lg:flex lg:w-60 lg:flex-col lg:gap-6 lg:px-4 lg:py-6">
        <.link navigate={~p"/"} class="px-3 text-xl font-extrabold tracking-tight">
          Cash<span class="text-primary">Cadence</span>
        </.link>
        <nav class="flex flex-col gap-1">
          <.nav_link navigate={~p"/"} icon="hero-home" active={@nav == :month}>Visão do mês</.nav_link>
          <.nav_link
            navigate={~p"/lancamentos"}
            icon="hero-list-bullet"
            active={@nav == :transactions}
          >Lançamentos</.nav_link>
        </nav>
        <div class="mt-auto flex flex-col gap-3 border-t border-base-300 pt-4">
          <div class="flex items-center justify-between gap-2 px-1">
            <span class="truncate text-xs text-base-content/60" title={@current_scope.user.email}>{@current_scope.user.email}</span>
            <.theme_toggle />
          </div>
          <div class="flex items-center gap-1 px-1 text-sm">
            <.link href={~p"/users/settings"} class="btn btn-ghost btn-sm">Configurações</.link>
            <.link href={~p"/users/log-out"} method="delete" class="btn btn-ghost btn-sm">Sair</.link>
          </div>
        </div>
      </aside>

      <div class="flex-1 lg:pl-60">
        <header class="navbar gap-2 border-b border-base-300 bg-base-100 px-4 lg:hidden">
          <.link navigate={~p"/"} class="text-lg font-extrabold tracking-tight">
            Cash<span class="text-primary">Cadence</span>
          </.link>
          <nav class="ml-auto flex items-center gap-1 text-sm">
            <.link navigate={~p"/"} class={["btn btn-ghost btn-sm", @nav == :month && "btn-active"]}>Mês</.link>
            <.link
              navigate={~p"/lancamentos"}
              class={["btn btn-ghost btn-sm", @nav == :transactions && "btn-active"]}
            >Lançamentos</.link>
            <.link
              href={~p"/users/settings"}
              class="btn btn-ghost btn-sm btn-square"
              aria-label="Configurações"
            >
              <.icon name="hero-cog-6-tooth" class="size-5" />
            </.link>
          </nav>
        </header>

        <main class="px-4 py-6 sm:px-6 lg:px-10 lg:py-8">
          <div class="mx-auto max-w-7xl space-y-6">
            {render_slot(@inner_block)}
          </div>
        </main>
      </div>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
