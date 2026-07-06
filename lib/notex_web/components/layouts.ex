defmodule NotexWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use NotexWeb, :html

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
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  attr :notebook, :map, default: nil, doc: "optional notebook metadata for the app header"
  attr :projects, :list, default: []
  attr :project_name_form, :map, default: nil
  attr :llm_status, :map, default: nil

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="border-b border-indigo-100 bg-white px-4 sm:px-6 lg:px-8">
      <nav class="flex min-h-12 w-full max-w-none items-center justify-between gap-4 py-1">
        <div class="flex min-w-0 flex-1 items-center gap-4">
          <a href="/" class="flex shrink-0 items-center gap-2">
            <img src={~p"/images/logo.svg"} width="36" />
            <span class="text-sm font-semibold text-zinc-950">Notex</span>
          </a>
          <div :if={@notebook} class="min-w-0 border-l border-zinc-200 pl-4">
            <div class="flex min-w-0 flex-wrap items-center gap-2">
              <.form
                :if={@project_name_form}
                for={@project_name_form}
                id="project-name-form"
                phx-submit="save_project_name"
                class="flex min-w-0 items-center gap-2"
              >
                <input
                  type="text"
                  id={@project_name_form[:name].id}
                  name={@project_name_form[:name].name}
                  value={@project_name_form[:name].value}
                  phx-blur={JS.dispatch("submit", to: "#project-name-form")}
                  class="h-7 min-w-0 max-w-56 rounded-md border border-transparent bg-transparent px-1 text-lg font-semibold text-zinc-950 outline-none transition hover:border-zinc-200 focus:border-zinc-300 focus:bg-white focus:ring-2 focus:ring-zinc-100"
                  aria-label="Project name"
                />
              </.form>
              <.form
                :if={@projects != []}
                for={%{}}
                as={:project}
                id="project-select-form"
                phx-change="select_project"
              >
                <select
                  id="project-select"
                  name="project[slug]"
                  class="h-8 max-w-44 rounded-md border border-zinc-200 bg-white px-2 text-sm font-medium text-zinc-700 outline-none transition hover:border-zinc-300 focus:border-zinc-400 focus:ring-2 focus:ring-zinc-100"
                  aria-label="Select project"
                >
                  <option
                    :for={project <- @projects}
                    value={project.slug}
                    selected={project.active?}
                  >
                    {project.name}
                  </option>
                </select>
              </.form>
              <button
                :if={@project_name_form}
                id="create-project-button"
                type="button"
                phx-click="create_project"
                class="inline-flex h-8 w-8 items-center justify-center rounded-md border border-zinc-200 text-zinc-600 transition hover:border-emerald-300 hover:bg-emerald-50 hover:text-emerald-700"
                title="Create project"
                aria-label="Create project"
              >
                <.icon name="hero-plus" class="size-4" />
              </button>
              <button
                :if={@project_name_form}
                id="delete-project-button"
                type="button"
                phx-click="delete_project"
                data-confirm="Delete this project?"
                class="inline-flex h-8 w-8 items-center justify-center rounded-md border border-zinc-200 text-zinc-600 transition hover:border-rose-300 hover:bg-rose-50 hover:text-rose-700"
                title="Delete project"
                aria-label="Delete project"
              >
                <.icon name="hero-trash" class="size-4" />
              </button>
            </div>
            <h1 :if={!@project_name_form} class="truncate text-lg font-semibold text-zinc-950">
              {@notebook.title}
            </h1>
          </div>
        </div>
        <div class="flex-none">
          <ul class="flex items-center gap-2">
            <li :if={@llm_status}>
              <div class="hidden items-center gap-2 rounded-full border border-zinc-200 bg-zinc-50 px-2 py-1 text-xs text-zinc-600 sm:inline-flex">
                <span class={[
                  "inline-flex items-center gap-1 rounded-full px-2 py-0.5 font-medium",
                  @llm_status.configured? &&
                    "bg-emerald-50 text-emerald-800 ring-1 ring-emerald-200",
                  !@llm_status.configured? && "bg-amber-50 text-amber-800 ring-1 ring-amber-200"
                ]}>
                  <.icon
                    name={
                      if(@llm_status.configured?,
                        do: "hero-bolt",
                        else: "hero-exclamation-triangle"
                      )
                    }
                    class="size-3.5"
                  />
                  {if(@llm_status.configured?, do: "GPT on", else: "Unavailable")}
                </span>
                <span class="font-mono">{@llm_status.model}</span>
                <span>effort {@llm_status.reasoning_effort}</span>
              </div>
            </li>
            <li>
              <a
                href="/mcp"
                class="hidden text-sm font-medium text-zinc-600 hover:text-zinc-950 sm:inline"
              >
                MCP
              </a>
            </li>
            <li class="flex h-8 items-center border-l border-zinc-200 pl-2">
              <.theme_toggle />
            </li>
          </ul>
        </div>
      </nav>
    </header>

    <main class="bg-indigo-50/60">
      {render_slot(@inner_block)}
    </main>

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
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
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
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
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
    <div class="inline-flex h-8 items-center gap-0.5">
      <button
        class="inline-flex size-8 cursor-pointer items-center justify-center rounded-md text-zinc-500 transition hover:bg-zinc-100 hover:text-zinc-950"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        aria-label="Use system theme"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4" />
      </button>

      <button
        class="inline-flex size-8 cursor-pointer items-center justify-center rounded-md text-zinc-500 transition hover:bg-zinc-100 hover:text-zinc-950"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        aria-label="Use light theme"
      >
        <.icon name="hero-sun-micro" class="size-4" />
      </button>

      <button
        class="inline-flex size-8 cursor-pointer items-center justify-center rounded-md text-zinc-500 transition hover:bg-zinc-100 hover:text-zinc-950"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        aria-label="Use dark theme"
      >
        <.icon name="hero-moon-micro" class="size-4" />
      </button>
    </div>
    """
  end
end
