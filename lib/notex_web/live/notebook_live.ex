defmodule NotexWeb.NotebookLive do
  use NotexWeb, :live_view

  alias Notex.{Notebooks, WebSearch}
  alias Notex.MCP.Server, as: MCPServer
  alias Notex.Notebooks.Message

  @impl true
  def mount(_params, _session, socket) do
    notebook = Notebooks.get_default_notebook()
    sources = Notebooks.list_sources(notebook)
    messages = Notebooks.list_messages(notebook)
    chat_messages = chat_messages(messages)

    socket =
      socket
      |> assign(:notebook, notebook)
      |> assign(:projects, Notebooks.list_projects())
      |> assign(:project_name_form, to_form(%{"name" => notebook.title}, as: :project))
      |> assign(:sources, sources)
      |> assign(:source_count, length(sources))
      |> assign(:word_count, Enum.sum(Enum.map(sources, & &1.word_count)))
      |> assign(:selected_source_ids, Enum.map(sources, & &1.id))
      |> assign(:llm_status, Notebooks.llm_status())
      |> assign(:mcp_form, to_form(default_mcp_form(), as: :mcp))
      |> assign(:mcp_running, false)
      |> assign(:show_source_form, false)
      |> assign(:active_source, nil)
      |> assign(:source_form, to_form(Notebooks.change_source()))
      |> assign(:web_search_form, to_form(%{"query" => ""}, as: :web_search))
      |> assign(:web_import_form, to_form(%{}, as: :web_import))
      |> assign(:web_results, [])
      |> assign(:web_query, "")
      |> assign(:web_search_cache, %{})
      |> assign(:web_searching, false)
      |> assign(:importing_web_result_ids, MapSet.new())
      |> assign(:chat_mode, "local")
      |> assign(:chat_message_count, length(chat_messages))
      |> assign(:question_form, to_form(%{"question" => ""}, as: :question))
      |> assign(:asking, false)
      |> assign(:studio_outputs, studio_outputs(messages))
      |> assign(:active_studio_output, nil)
      |> assign(:active_source_position, nil)
      |> assign(:generating_studio_artifacts, MapSet.new())
      |> assign(:streaming_assistant_content, %{})
      |> stream_configure(:messages, dom_id: &message_dom_id/1)
      |> stream_messages(chat_messages, reset: true)

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle_source_form", _params, socket) do
    {:noreply, update(socket, :show_source_form, &(!&1))}
  end

  def handle_event("save_project_name", %{"project" => %{"name" => name}}, socket) do
    {:ok, notebook} = Notebooks.update_project_name(name)
    socket = socket |> load_project(notebook) |> put_flash(:info, "Project renamed.")

    {:noreply, socket}
  end

  def handle_event("create_project", _params, socket) do
    {:ok, notebook} = Notebooks.create_project()
    socket = socket |> load_project(notebook) |> put_flash(:info, "Project created.")
    {:noreply, socket}
  end

  def handle_event("delete_project", _params, socket) do
    {:ok, notebook} = Notebooks.delete_project()
    socket = socket |> load_project(notebook) |> put_flash(:info, "Project deleted.")
    {:noreply, socket}
  end

  def handle_event("select_project", %{"project" => %{"slug" => slug}}, socket) do
    case Notebooks.select_project(slug) do
      {:ok, notebook} ->
        socket = socket |> load_project(notebook) |> put_flash(:info, "Project selected.")
        {:noreply, socket}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Project not found.")}
    end
  end

  def handle_event("open_source", %{"id" => id}, socket) do
    source = Enum.find(socket.assigns.sources, &(to_string(&1.id) == id))
    {:noreply, socket |> assign(:active_source, source) |> assign(:active_source_position, nil)}
  end

  def handle_event(
        "open_citation_source",
        %{"source-id" => source_id, "position" => position},
        socket
      ) do
    source = Enum.find(socket.assigns.sources, &(to_string(&1.id) == source_id))

    position =
      case Integer.parse(position) do
        {integer, ""} -> integer
        _other -> nil
      end

    {:noreply,
     socket
     |> assign(:active_source, source)
     |> assign(:active_source_position, position)}
  end

  def handle_event("close_source", _params, socket) do
    {:noreply, socket |> assign(:active_source, nil) |> assign(:active_source_position, nil)}
  end

  def handle_event("source_refs_changed", params, socket) do
    selected_ids =
      params
      |> get_in(["source_refs", "source_ids"])
      |> normalize_source_ids()

    {:noreply, assign(socket, :selected_source_ids, selected_ids)}
  end

  def handle_event("set_all_source_refs", %{"checked" => "true"}, socket) do
    {:noreply, assign(socket, :selected_source_ids, Enum.map(socket.assigns.sources, & &1.id))}
  end

  def handle_event("set_all_source_refs", _params, socket) do
    {:noreply, assign(socket, :selected_source_ids, [])}
  end

  def handle_event("delete_selected_sources", _params, socket) do
    if socket.assigns.selected_source_ids == [] do
      {:noreply, put_flash(socket, :error, "Select a source.")}
    else
      {:ok, count} =
        Notebooks.delete_sources(socket.assigns.notebook, socket.assigns.selected_source_ids)

      socket =
        socket
        |> refresh_sources()
        |> assign(:selected_source_ids, [])
        |> put_flash(:info, "Deleted #{count} source(s).")

      {:noreply, socket}
    end
  end

  def handle_event("delete_source", %{"id" => id}, socket) do
    case normalize_source_ids([id]) do
      [source_id] ->
        {:ok, count} = Notebooks.delete_sources(socket.assigns.notebook, [source_id])

        socket =
          socket
          |> refresh_sources()
          |> assign(
            :selected_source_ids,
            List.delete(socket.assigns.selected_source_ids, source_id)
          )
          |> put_flash(:info, "Deleted #{count} source(s).")

        {:noreply, socket}

      [] ->
        {:noreply, put_flash(socket, :error, "Source not found.")}
    end
  end

  def handle_event("delete_chat_history", _params, socket) do
    {:ok, count} = Notebooks.delete_chat_messages(socket.assigns.notebook)

    socket =
      socket
      |> assign(:chat_message_count, 0)
      |> assign(:streaming_assistant_content, %{})
      |> stream_messages([], reset: true)
      |> put_flash(:info, "Deleted #{count} chat message(s).")

    {:noreply, socket}
  end

  def handle_event("archive_chat_history", _params, socket) do
    {:ok, %{count: count}} = Notebooks.archive_chat_messages(socket.assigns.notebook)

    socket =
      socket
      |> assign(:chat_message_count, 0)
      |> assign(:streaming_assistant_content, %{})
      |> stream_messages([], reset: true)
      |> put_flash(:info, "Archived #{count} chat message(s).")

    {:noreply, socket}
  end

  def handle_event("add_source", %{"source" => source_params}, socket) do
    case Notebooks.add_source(socket.assigns.notebook, source_params) do
      {:ok, _source} ->
        socket =
          socket
          |> put_flash(:info, "Source added to the notebook.")
          |> refresh_sources()
          |> assign(:show_source_form, false)
          |> assign(:source_form, to_form(Notebooks.change_source()))

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, :source_form, to_form(changeset, action: :insert))}
    end
  end

  def handle_event("web_search", %{"web_search" => %{"query" => query}}, socket) do
    query = String.trim(query)
    parent = self()

    Task.start(fn ->
      send(
        parent,
        {:web_search_completed, query, cached_web_search(socket.assigns.web_search_cache, query)}
      )
    end)

    socket =
      socket
      |> assign(:web_searching, true)
      |> assign(:web_search_form, to_form(%{"query" => query}, as: :web_search))

    {:noreply, socket}
  end

  def handle_event("set_all_web_results", %{"checked" => "true"}, socket) do
    selected_ids =
      socket.assigns.web_results
      |> Enum.map(& &1.id)

    {:noreply,
     assign(
       socket,
       :web_import_form,
       to_form(%{"result_ids" => selected_ids}, as: :web_import)
     )}
  end

  def handle_event("set_all_web_results", _params, socket) do
    {:noreply, assign(socket, :web_import_form, to_form(%{"result_ids" => []}, as: :web_import))}
  end

  def handle_event("toggle_web_import_result", %{"result-id" => result_id}, socket) do
    selected_ids = web_import_result_ids(socket.assigns.web_import_form)

    {:noreply,
     assign(
       socket,
       :web_import_form,
       to_form(
         %{
           "result_ids" =>
             if(result_id in selected_ids,
               do: List.delete(selected_ids, result_id),
               else: [result_id | selected_ids]
             )
         },
         as: :web_import
       )
     )}
  end

  def handle_event("cancel_web_results", _params, socket) do
    socket =
      socket
      |> assign(:web_results, [])
      |> assign(:web_import_form, to_form(%{"result_ids" => []}, as: :web_import))

    {:noreply, socket}
  end

  def handle_event("set_chat_mode", %{"mode" => mode}, socket)
      when mode in ["local", "local_web", "web"] do
    {:noreply, assign(socket, :chat_mode, mode)}
  end

  def handle_event("question_changed", %{"question" => params}, socket) do
    {:noreply, assign(socket, :question_form, to_form(params, as: :question))}
  end

  def handle_event("add_web_citation_source", %{"url" => url}, socket) do
    case find_web_citation(socket.assigns.notebook, url) do
      nil ->
        {:noreply, put_flash(socket, :error, "Web source not found.")}

      citation ->
        case Notebooks.add_source(socket.assigns.notebook, %{
               title: citation["source_title"],
               body: citation["source_body"]
             }) do
          {:ok, _source} ->
            socket =
              socket
              |> refresh_sources()
              |> put_flash(:info, "Web source added.")

            {:noreply, socket}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Could not add web source.")}
        end
    end
  end

  def handle_event("add_web_sources", params, socket) do
    selected_ids = params |> get_in(["web_import", "result_ids"]) |> List.wrap()
    selected = Enum.filter(socket.assigns.web_results, &(&1.id in selected_ids))

    if selected == [] do
      {:noreply, put_flash(socket, :error, "Select at least one web result.")}
    else
      parent = self()
      notebook = socket.assigns.notebook

      Task.start(fn ->
        Enum.each(selected, fn result ->
          send(parent, {:web_import_completed, result.id, import_web_result(notebook, result)})
        end)
      end)

      socket =
        socket
        |> assign(
          :importing_web_result_ids,
          MapSet.union(socket.assigns.importing_web_result_ids, MapSet.new(selected_ids))
        )

      {:noreply, socket}
    end
  end

  def handle_event("execute_mcp", %{"mcp" => params}, socket) do
    if socket.assigns.mcp_running do
      {:noreply, socket}
    else
      execute_mcp(socket, params)
    end
  end

  def handle_event("ask", %{"question" => %{"question" => question}}, socket) do
    if socket.assigns.asking do
      {:noreply, socket}
    else
      ask(socket, question)
    end
  end

  def handle_event("generate_studio", %{"artifact" => artifact}, socket) do
    if socket.assigns.selected_source_ids == [] do
      {:noreply, put_flash(socket, :error, "Select a source.")}
    else
      parent = self()
      notebook = socket.assigns.notebook
      source_ids = socket.assigns.selected_source_ids

      Task.start(fn ->
        result = Notebooks.generate_studio_artifact(notebook, artifact, source_ids: source_ids)
        send(parent, {:studio_generation_completed, artifact, result})
      end)

      {:noreply,
       assign(
         socket,
         :generating_studio_artifacts,
         MapSet.put(socket.assigns.generating_studio_artifacts, artifact)
       )}
    end
  end

  def handle_event("open_studio_output", %{"id" => id}, socket) do
    output = Enum.find(socket.assigns.studio_outputs, &(to_string(&1.id) == id))
    {:noreply, assign(socket, :active_studio_output, output)}
  end

  def handle_event("close_studio_output", _params, socket) do
    {:noreply, assign(socket, :active_studio_output, nil)}
  end

  def handle_event("delete_studio_output", %{"id" => id}, socket) do
    case Notebooks.delete_studio_output(socket.assigns.notebook, id) do
      {:ok, _count} ->
        messages = Notebooks.list_messages(socket.assigns.notebook)
        studio_outputs = studio_outputs(messages)

        active_studio_output =
          if socket.assigns.active_studio_output &&
               to_string(socket.assigns.active_studio_output.id) == id do
            nil
          else
            socket.assigns.active_studio_output
          end

        socket =
          socket
          |> assign(:studio_outputs, studio_outputs)
          |> assign(:active_studio_output, active_studio_output)
          |> put_flash(:info, "Studio output deleted.")

        {:noreply, socket}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Studio output not found.")}
    end
  end

  defp ask(socket, question) do
    if ask_disabled?(socket.assigns.chat_mode, socket.assigns.selected_source_ids) do
      {:noreply, put_flash(socket, :error, "Select a source.")}
    else
      question = String.trim(question)

      with {:ok, socket, web_results} <- prepare_chat_web_results(socket, question),
           {:ok, result} <- Notebooks.begin_question(socket.assigns.notebook, question) do
        parent = self()
        notebook = socket.assigns.notebook
        mode = socket.assigns.chat_mode
        selected_source_ids = socket.assigns.selected_source_ids
        assistant_id = result.assistant_id

        Task.start(fn ->
          with {:ok, %{matches: matches, citations: citations}} <-
                 chat_question_context(
                   notebook,
                   question,
                   mode,
                   selected_source_ids,
                   web_results
                 ) do
            send(parent, {:chat_status, assistant_id, "Writing answer..."})

            outcome =
              Notebooks.synthesize_question(question, matches,
                on_delta: fn delta -> send(parent, {:chat_delta, assistant_id, delta}) end
              )

            send(parent, {:chat_completed, notebook, assistant_id, citations, outcome})
          else
            {:error, reason} ->
              send(parent, {:chat_completed, notebook, assistant_id, %{}, {:error, reason}})
          end
        end)

        assistant_message =
          transient_message(
            assistant_id,
            notebook.id,
            "assistant",
            chat_search_status(socket.assigns.chat_mode),
            %{},
            result.user_message.inserted_at
          )

        socket =
          socket
          |> assign(:question_form, to_form(%{"question" => ""}, as: :question))
          |> assign(:asking, true)
          |> update(:chat_message_count, &(&1 + 1))
          |> assign(
            :streaming_assistant_content,
            Map.put(socket.assigns.streaming_assistant_content, assistant_id, "")
          )
          |> stream_message(result.user_message)
          |> stream_message(assistant_message)

        {:noreply, socket}
      else
        {:error, :empty_question} ->
          {:noreply,
           socket |> assign(:asking, false) |> put_flash(:error, "Ask a question before sending.")}

        {:error, _changeset} ->
          {:noreply,
           socket |> assign(:asking, false) |> put_flash(:error, "Could not save the answer.")}

        {:web_search_error, reason} ->
          {:noreply,
           socket
           |> assign(:asking, false)
           |> put_flash(:error, "Web search failed: #{inspect(reason)}")}
      end
    end
  end

  defp execute_mcp(socket, params) do
    case build_mcp_request(params, socket.assigns.notebook) do
      {:ok, user_query, request} ->
        parent = self()
        notebook = socket.assigns.notebook

        Task.start(fn ->
          response = MCPServer.handle(request)
          result = Jason.encode!(response, pretty: true)
          outcome = Notebooks.record_tool_exchange(notebook, user_query, result)

          send(parent, {:mcp_completed, params, outcome})
        end)

        socket =
          socket
          |> assign(:mcp_form, to_form(params, as: :mcp))
          |> assign(:mcp_running, true)

        {:noreply, socket}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  @impl true
  def handle_info({:web_search_completed, query, result}, socket) do
    complete_web_search(socket, query, result)
  end

  def handle_info({:web_import_completed, result_id, result}, socket) do
    importing_ids = MapSet.delete(socket.assigns.importing_web_result_ids, result_id)
    selected_ids = List.delete(web_import_result_ids(socket.assigns.web_import_form), result_id)

    socket =
      socket
      |> assign(:importing_web_result_ids, importing_ids)
      |> assign(:web_import_form, to_form(%{"result_ids" => selected_ids}, as: :web_import))
      |> refresh_sources()

    socket =
      case result do
        {:ok, _source} ->
          socket

        {:error, _changeset} ->
          put_flash(socket, :error, "Could not add web source.")
      end

    {:noreply, socket}
  end

  def handle_info(
        {:mcp_completed, params,
         {:ok, %{user_message: user_message, assistant_message: assistant_message}}},
        socket
      ) do
    socket =
      socket
      |> assign(:mcp_running, false)
      |> assign(:mcp_form, to_form(params, as: :mcp))
      |> update(:chat_message_count, &(&1 + 2))
      |> stream_message(user_message)
      |> stream_message(assistant_message)

    {:noreply, socket}
  end

  def handle_info({:mcp_completed, _params, {:error, _reason}}, socket) do
    {:noreply,
     socket
     |> assign(:mcp_running, false)
     |> put_flash(:error, "MCP result was empty.")}
  end

  def handle_info({:studio_generation_completed, artifact, result}, socket) do
    socket =
      assign(
        socket,
        :generating_studio_artifacts,
        MapSet.delete(socket.assigns.generating_studio_artifacts, artifact)
      )

    case result do
      {:ok, _result} ->
        messages = Notebooks.list_messages(socket.assigns.notebook)
        studio_outputs = studio_outputs(messages)

        socket =
          socket
          |> assign(:studio_outputs, studio_outputs)
          |> assign(:active_studio_output, nil)
          |> put_flash(:info, "Studio generated #{studio_label(artifact)}.")

        {:noreply, socket}

      {:error, :no_evidence} ->
        {:noreply, put_flash(socket, :error, "Select a source.")}

      {:error, {:llm_unavailable, _reason}} ->
        {:noreply, put_flash(socket, :error, "Studio unavailable.")}

      {:error, {:image_unavailable, reason}} ->
        {:noreply,
         put_flash(socket, :error, "Image generation failed: #{format_image_reason(reason)}")}

      {:error, :unknown_studio_artifact} ->
        {:noreply, put_flash(socket, :error, "Unknown Studio action.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Studio failed.")}
    end
  end

  def handle_info({:chat_delta, assistant_id, delta}, socket) do
    content = Map.get(socket.assigns.streaming_assistant_content, assistant_id, "") <> delta

    socket =
      socket
      |> assign(
        :streaming_assistant_content,
        Map.put(socket.assigns.streaming_assistant_content, assistant_id, content)
      )
      |> stream_message(
        transient_message(
          assistant_id,
          socket.assigns.notebook.id,
          "assistant",
          content,
          %{},
          DateTime.utc_now()
        )
      )

    {:noreply, socket}
  end

  def handle_info({:chat_status, assistant_id, status}, socket) do
    socket =
      stream_message(
        socket,
        transient_message(
          assistant_id,
          socket.assigns.notebook.id,
          "assistant",
          status,
          %{},
          DateTime.utc_now()
        )
      )

    {:noreply, socket}
  end

  def handle_info(
        {:chat_completed, notebook, assistant_id, citations, {:ok, answer, _llm_meta}},
        socket
      ) do
    {:ok, assistant_message} =
      Notebooks.save_assistant_message(notebook, assistant_id, answer, citations)

    socket =
      socket
      |> assign(:asking, false)
      |> assign(
        :streaming_assistant_content,
        Map.delete(socket.assigns.streaming_assistant_content, assistant_id)
      )
      |> update(:chat_message_count, &(&1 + 1))
      |> stream_message(assistant_message)

    {:noreply, socket}
  end

  def handle_info(
        {:chat_completed, _notebook, assistant_id, _citations, {:error, reason}},
        socket
      ) do
    content = "Chat failed: #{format_llm_reason(reason)}"

    socket =
      socket
      |> assign(:asking, false)
      |> assign(
        :streaming_assistant_content,
        Map.delete(socket.assigns.streaming_assistant_content, assistant_id)
      )
      |> stream_message(
        transient_message(
          assistant_id,
          socket.assigns.notebook.id,
          "assistant",
          content,
          %{},
          DateTime.utc_now()
        )
      )

    {:noreply, socket}
  end

  defp ordered_citations(message) do
    message.citations
    |> Enum.sort_by(fn {key, _value} -> String.to_integer(key) end)
    |> Enum.map(fn {key, value} -> {key, value} end)
  end

  defp markdown_html(markdown) when is_binary(markdown) do
    markdown
    |> MDEx.to_html!(extension: [table: true, strikethrough: true, tasklist: true])
    |> HtmlSanitizeEx.markdown_html()
    |> Phoenix.HTML.raw()
  end

  defp markdown_html(_markdown), do: Phoenix.HTML.raw("")

  defp chat_question_context(_notebook, question, "web", _selected_source_ids, web_results) do
    Notebooks.web_question_context(question, web_results: web_results)
  end

  defp chat_question_context(notebook, question, "local_web", selected_source_ids, web_results) do
    Notebooks.local_web_question_context(notebook, question,
      source_ids: selected_source_ids,
      web_results: web_results
    )
  end

  defp chat_question_context(notebook, question, _mode, selected_source_ids, _web_results) do
    Notebooks.local_question_context(notebook, question, source_ids: selected_source_ids)
  end

  defp prepare_chat_web_results(socket, question) do
    case socket.assigns.chat_mode do
      mode when mode in ["web", "local_web"] ->
        if question == "" do
          {:ok, socket, nil}
        else
          case cached_web_search(socket.assigns.web_search_cache, question) do
            {:ok, results} ->
              socket =
                socket
                |> assign(
                  :web_search_cache,
                  cache_web_results(socket.assigns.web_search_cache, question, results)
                )

              {:ok, socket, results}

            {:error, reason} ->
              {:web_search_error, reason}
          end
        end

      _mode ->
        {:ok, socket, nil}
    end
  end

  defp chat_search_status("web"), do: "Searching the web..."
  defp chat_search_status("local_web"), do: "Searching local sources and web..."
  defp chat_search_status(_mode), do: "Searching local sources..."

  defp ask_disabled?(mode, selected_source_ids) do
    mode in ["local", "local_web"] and selected_source_ids == []
  end

  defp stream_messages(socket, messages, opts) do
    stream(socket, :messages, messages, opts)
  end

  defp stream_message(socket, message) do
    stream_insert(socket, :messages, message)
  end

  defp message_dom_id(%{id: id}), do: "messages-#{id}"

  defp find_web_citation(notebook, url) do
    notebook
    |> Notebooks.list_messages()
    |> Enum.flat_map(&Map.values(&1.citations || %{}))
    |> Enum.find(&(&1["source_url"] == url && is_binary(&1["source_body"])))
  end

  defp studio_generating?(generating_artifacts, artifact) do
    MapSet.member?(generating_artifacts, artifact)
  end

  defp transient_message(id, notebook_id, role, content, citations, inserted_at) do
    %Message{
      id: id,
      notebook_id: notebook_id,
      role: role,
      content: content,
      citations: citations,
      inserted_at: inserted_at,
      updated_at: inserted_at
    }
  end

  defp studio_outputs(messages) do
    messages
    |> studio_entries()
    |> Enum.reverse()
  end

  defp studio_entries(messages) do
    messages
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn
      [
        %{role: "user", content: request},
        %{role: "assistant", id: id, content: content, inserted_at: inserted_at}
      ]
      when is_binary(request) ->
        case studio_request_meta(request) do
          nil ->
            []

          meta ->
            [
              Map.merge(meta, %{
                id: id,
                content: content,
                inserted_at: inserted_at,
                title: studio_output_title(content, meta.label)
              })
            ]
        end

      _other ->
        []
    end)
  end

  defp studio_request_meta("Create an audio overview" <> _rest),
    do: %{
      type: "audio",
      label: "Audio",
      icon: "hero-sparkles",
      tone: "bg-indigo-50 text-indigo-950"
    }

  defp studio_request_meta("Create a report" <> _rest),
    do: %{
      type: "document",
      label: "Report",
      icon: "hero-document-text",
      tone: "bg-amber-50 text-amber-950"
    }

  defp studio_request_meta("Create a quiz" <> _rest),
    do: %{
      type: "document",
      label: "Quiz",
      icon: "hero-question-mark-circle",
      tone: "bg-cyan-50 text-cyan-950"
    }

  defp studio_request_meta("Create flashcards" <> _rest),
    do: %{
      type: "cards",
      label: "Cards",
      icon: "hero-rectangle-stack",
      tone: "bg-rose-50 text-rose-950"
    }

  defp studio_request_meta("Create a data table" <> _rest),
    do: %{
      type: "table",
      label: "Data Table",
      icon: "hero-table-cells",
      tone: "bg-violet-50 text-violet-950"
    }

  defp studio_request_meta("Create a mind map" <> _rest),
    do: %{
      type: "map",
      label: "Mind Map",
      icon: "hero-share",
      tone: "bg-fuchsia-50 text-fuchsia-950"
    }

  defp studio_request_meta("Create an infographic" <> _rest),
    do: %{
      type: "image",
      label: "InfoGraphic",
      icon: "hero-photo",
      tone: "bg-emerald-50 text-emerald-950"
    }

  defp studio_request_meta(_request), do: nil

  defp studio_output_title("data:image/" <> _rest, fallback), do: fallback
  defp studio_output_title("```mermaid" <> _rest, fallback), do: fallback

  defp studio_output_title(content, fallback) when is_binary(content) do
    lines = String.split(content, "\n")

    lines
    |> Enum.map(&clean_studio_title_line/1)
    |> Enum.find(&studio_title_line?/1)
    |> case do
      nil -> fallback_studio_title(lines, fallback)
      title -> String.slice(title, 0, 80)
    end
  end

  defp studio_output_title(_content, fallback), do: fallback

  defp fallback_studio_title(lines, "Data Table") do
    lines
    |> markdown_table_rows()
    |> table_summary_title()
    |> case do
      nil -> "Data Table"
      title -> String.slice(title, 0, 80)
    end
  end

  defp fallback_studio_title(_lines, fallback), do: fallback

  defp markdown_table_rows(lines) do
    lines
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&(String.starts_with?(&1, "|") and String.ends_with?(&1, "|")))
    |> Enum.reject(&markdown_table_separator?/1)
    |> Enum.map(&markdown_table_cells/1)
    |> Enum.reject(&(&1 == []))
  end

  defp markdown_table_separator?(line) do
    line
    |> String.trim("|")
    |> String.replace(~r/[\s:\-|\+]/, "")
    |> Kernel.==("")
  end

  defp markdown_table_cells(line) do
    line
    |> String.trim("|")
    |> String.split("|")
    |> Enum.map(&clean_studio_title_line/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp table_summary_title([headers | rows]) do
    subjects =
      rows
      |> Enum.map(&List.first/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.take(3)

    descriptor =
      headers
      |> Enum.at(1)
      |> case do
        nil -> "一覧"
        header when header in ["種別", "種類", "Type", "Category"] -> "整理表"
        header -> "#{header}一覧"
      end

    case subjects do
      [] -> nil
      [subject] -> "#{subject}の#{descriptor}"
      subjects -> "#{Enum.join(subjects, "・")}の#{descriptor}"
    end
  end

  defp table_summary_title(_rows), do: nil

  defp clean_studio_title_line(line) do
    line
    |> String.trim()
    |> String.trim_leading("#")
    |> String.trim_leading("-")
    |> String.trim_leading("*")
    |> String.trim()
    |> String.trim("*")
    |> String.trim("_")
    |> String.trim()
    |> String.replace(~r/^(Speaker\s+[A-Z]|Front|Back|Question|Answer|Q|A)\s*[:：]\s*/iu, "")
    |> String.replace(~r/\s*\[[^\]]+\]/, "")
    |> String.replace(~r/^\d+[\).\s-]+/, "")
    |> String.replace(~r/^\|+|\|+$/, "")
    |> String.trim()
  end

  defp studio_title_line?(""), do: false

  defp studio_title_line?(line) do
    normalized =
      line
      |> String.trim()
      |> String.downcase()

    not (normalized in ["summary", "key findings", "evidence", "open questions"] or
           String.starts_with?(normalized, ["---", ":---"]) or
           String.contains?(normalized, "|") or
           String.contains?(normalized, "---|"))
  end

  defp chat_messages(messages) do
    studio_ids =
      messages
      |> studio_entries()
      |> MapSet.new(& &1.id)

    studio_request_contents =
      messages
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.flat_map(fn
        [%{role: "user", content: request}, %{role: "assistant", id: assistant_id}]
        when is_binary(request) ->
          if MapSet.member?(studio_ids, assistant_id), do: [request], else: []

        _other ->
          []
      end)
      |> MapSet.new()

    Enum.reject(messages, fn message ->
      MapSet.member?(studio_ids, message.id) or
        (message.role == "user" and MapSet.member?(studio_request_contents, message.content))
    end)
  end

  defp web_result_checked?(form, result) do
    web_import_result_ids(form) |> Enum.member?(result.id)
  end

  defp all_web_results_selected?([], _form), do: false

  defp all_web_results_selected?(web_results, form) do
    selected_result_ids = web_import_result_ids(form)
    web_result_ids = Enum.map(web_results, & &1.id)

    Enum.all?(web_result_ids, &(&1 in selected_result_ids))
  end

  defp web_import_result_ids(form) do
    form.params
    |> Map.get("result_ids", [])
    |> List.wrap()
    |> Enum.uniq()
  end

  defp source_ref_checked?(selected_source_ids, source) do
    source.id in selected_source_ids
  end

  defp all_source_refs_selected?([], _selected_source_ids), do: false

  defp all_source_refs_selected?(sources, selected_source_ids) do
    source_ids = Enum.map(sources, & &1.id)
    Enum.all?(source_ids, &(&1 in selected_source_ids))
  end

  defp import_web_result(notebook, result) do
    with {:ok, attrs} <- WebSearch.fetch_result(result),
         {:ok, source} <- Notebooks.add_source(notebook, attrs) do
      {:ok, source}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp default_mcp_form do
    %{
      "operation" => "tool",
      "tool" => "notex.search",
      "method" => "tools/call",
      "query" => "",
      "arguments" => "{}",
      "resource_uri" => ""
    }
  end

  defp build_mcp_request(params, notebook) do
    id = System.unique_integer([:positive])

    case Map.get(params, "operation", "tool") do
      "resource_list" ->
        request = %{"jsonrpc" => "2.0", "id" => id, "method" => "resources/list", "params" => %{}}
        {:ok, "MCP resources/list", request}

      "resource_read" ->
        uri = params |> Map.get("resource_uri", "") |> String.trim()

        if uri == "" do
          {:error, "Enter a resource URI."}
        else
          request = %{
            "jsonrpc" => "2.0",
            "id" => id,
            "method" => "resources/read",
            "params" => %{"uri" => uri}
          }

          {:ok, "MCP resources/read #{uri}", request}
        end

      _tool ->
        build_mcp_tool_request(params, notebook, id)
    end
  end

  defp build_mcp_tool_request(params, notebook, id) do
    tool = Map.get(params, "tool", "notex.search")

    with {:ok, arguments} <- mcp_arguments(params, notebook) do
      request = %{
        "jsonrpc" => "2.0",
        "id" => id,
        "method" => "tools/call",
        "params" => %{"name" => tool, "arguments" => arguments}
      }

      {:ok, mcp_user_query(tool, arguments), request}
    end
  end

  defp mcp_arguments(%{"tool" => "notex.search"} = params, notebook) do
    query = params |> Map.get("query", "") |> String.trim()

    if query == "" do
      {:error, "Enter a search query."}
    else
      {:ok, %{"query" => query, "notebook_id" => notebook.id, "record_chat" => false}}
    end
  end

  defp mcp_arguments(%{"tool" => "notex.answer"} = params, notebook) do
    query = params |> Map.get("query", "") |> String.trim()

    if query == "" do
      {:error, "Enter a question."}
    else
      {:ok, %{"question" => query, "notebook_id" => notebook.id, "record_chat" => false}}
    end
  end

  defp mcp_arguments(%{"tool" => "notex.add_source"} = params, notebook) do
    with {:ok, arguments} <- decode_mcp_arguments(params) do
      {:ok, Map.merge(arguments, %{"notebook_id" => notebook.id})}
    end
  end

  defp mcp_arguments(params, notebook) do
    with {:ok, arguments} <- decode_mcp_arguments(params) do
      {:ok, Map.put_new(arguments, "notebook_id", notebook.id)}
    end
  end

  defp decode_mcp_arguments(params) do
    text = params |> Map.get("arguments", "{}") |> String.trim()
    text = if text == "", do: "{}", else: text

    case Jason.decode(text) do
      {:ok, arguments} when is_map(arguments) -> {:ok, arguments}
      {:ok, _other} -> {:error, "Arguments must be a JSON object."}
      {:error, _reason} -> {:error, "Arguments must be valid JSON."}
    end
  end

  defp mcp_user_query("notex.search", %{"query" => query}), do: "MCP notex.search: #{query}"

  defp mcp_user_query("notex.answer", %{"question" => question}),
    do: "MCP notex.answer: #{question}"

  defp mcp_user_query(tool, arguments), do: "MCP #{tool}: #{Jason.encode!(arguments)}"

  defp load_project(socket, notebook) do
    sources = Notebooks.list_sources(notebook)
    messages = Notebooks.list_messages(notebook)
    chat_messages = chat_messages(messages)

    socket
    |> assign(:notebook, notebook)
    |> assign(:projects, Notebooks.list_projects())
    |> assign(:project_name_form, to_form(%{"name" => notebook.title}, as: :project))
    |> assign(:sources, sources)
    |> assign(:source_count, length(sources))
    |> assign(:word_count, Enum.sum(Enum.map(sources, & &1.word_count)))
    |> assign(:selected_source_ids, Enum.map(sources, & &1.id))
    |> assign(:source_form, to_form(Notebooks.change_source()))
    |> assign(:web_search_form, to_form(%{"query" => ""}, as: :web_search))
    |> assign(:web_import_form, to_form(%{}, as: :web_import))
    |> assign(:web_results, [])
    |> assign(:web_query, "")
    |> assign(:web_search_cache, %{})
    |> assign(:question_form, to_form(%{"question" => ""}, as: :question))
    |> assign(:mcp_form, to_form(default_mcp_form(), as: :mcp))
    |> assign(:studio_outputs, studio_outputs(messages))
    |> assign(:active_studio_output, nil)
    |> assign(:active_source, nil)
    |> assign(:active_source_position, nil)
    |> assign(:show_source_form, false)
    |> assign(:chat_message_count, length(chat_messages))
    |> assign(:streaming_assistant_content, %{})
    |> stream_messages(chat_messages, reset: true)
  end

  defp refresh_sources(socket) do
    sources = Notebooks.list_sources(socket.assigns.notebook)

    socket
    |> assign(:sources, sources)
    |> assign(:source_count, length(sources))
    |> assign(:word_count, Enum.sum(Enum.map(sources, & &1.word_count)))
    |> assign(:selected_source_ids, Enum.map(sources, & &1.id))
    |> assign(:active_source, nil)
    |> assign(:active_source_position, nil)
  end

  defp complete_web_search(socket, query, result) do
    case result do
      {:ok, []} ->
        socket =
          socket
          |> assign(:web_searching, false)
          |> assign(:web_results, [])
          |> assign(:web_query, query)
          |> put_flash(:error, "No web results found.")

        {:noreply, socket}

      {:ok, results} ->
        selected_ids = Enum.map(results, & &1.id)

        socket =
          socket
          |> assign(:web_searching, false)
          |> assign(:web_results, results)
          |> assign(:web_query, query)
          |> assign(
            :web_search_cache,
            cache_web_results(socket.assigns.web_search_cache, query, results)
          )
          |> assign(
            :web_import_form,
            to_form(%{"result_ids" => selected_ids}, as: :web_import)
          )

        {:noreply, socket}

      {:error, :empty_query} ->
        {:noreply,
         socket
         |> assign(:web_searching, false)
         |> put_flash(:error, "Enter a web search query.")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:web_searching, false)
         |> put_flash(:error, "Web search failed: #{inspect(reason)}")}
    end
  end

  defp cached_web_search(cache, query) do
    cache_key = normalized_web_query(query)

    case Map.fetch(cache, cache_key) do
      {:ok, results} -> {:ok, results}
      :error -> Notebooks.web_search_results(query)
    end
  end

  defp cache_web_results(cache, query, results) do
    Map.put(cache, normalized_web_query(query), results)
  end

  defp normalized_web_query(query) do
    query
    |> to_string()
    |> String.trim()
  end

  defp normalize_source_ids(source_ids) do
    source_ids
    |> List.wrap()
    |> Enum.flat_map(fn
      id when is_integer(id) ->
        [id]

      id when is_binary(id) ->
        case Integer.parse(id) do
          {integer, ""} -> [integer]
          _other -> []
        end

      _other ->
        []
    end)
    |> Enum.uniq()
  end

  defp studio_label("audio_overview"), do: "Audio"
  defp studio_label("report"), do: "Report"
  defp studio_label("quiz"), do: "Quiz"
  defp studio_label("flashcards"), do: "Flashcards"
  defp studio_label("data_table"), do: "Data Table"
  defp studio_label("mind_map"), do: "Mind Map"
  defp studio_label("infographic"), do: "InfoGraphic"
  defp studio_label(_artifact), do: "artifact"

  defp message_tone("user"), do: "border-zinc-200 bg-zinc-100 text-zinc-950"
  defp message_tone("assistant"), do: "border-zinc-200 bg-white text-zinc-950"
  defp message_tone(_role), do: "border-zinc-200 bg-zinc-50 text-zinc-950"

  defp message_alignment("user"), do: "ml-auto"
  defp message_alignment("assistant"), do: "mr-auto"
  defp message_alignment(_role), do: "mr-auto"

  defp format_llm_reason(reason), do: inspect(reason)

  defp format_image_reason({:missing_executable, command}) do
    "Codex command #{inspect(command)} was not found."
  end

  defp format_image_reason({:image_generation_not_supported, _capabilities}) do
    "Codex app-server does not advertise image generation."
  end

  defp format_image_reason({:missing_image_generation_result, _meta}) do
    "Codex app-server completed without an image result."
  end

  defp format_image_reason(:timeout), do: "Codex app-server timed out."
  defp format_image_reason(reason), do: inspect(reason)
end
