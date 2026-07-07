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
      |> assign(:active_studio_settings_artifact, nil)
      |> assign(:active_flashcard_index, 0)
      |> assign(:active_flashcard_answer?, false)
      |> assign(:active_source_position, nil)
      |> assign(:generating_studio_artifacts, MapSet.new())
      |> assign(:studio_generation_tasks, %{})
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
    cond do
      Map.has_key?(socket.assigns.studio_generation_tasks, artifact) ->
        {:noreply, stop_studio_generation(socket, artifact)}

      socket.assigns.selected_source_ids == [] ->
        {:noreply, put_flash(socket, :error, "Select a source.")}

      true ->
        parent = self()
        notebook = socket.assigns.notebook
        source_ids = socket.assigns.selected_source_ids

        {:ok, pid} =
          Task.start(fn ->
            result =
              Notebooks.generate_studio_artifact(notebook, artifact, source_ids: source_ids)

            send(parent, {:studio_generation_completed, notebook, artifact, result})
          end)

        {:noreply,
         socket
         |> assign(
           :generating_studio_artifacts,
           MapSet.put(socket.assigns.generating_studio_artifacts, artifact)
         )
         |> assign(
           :studio_generation_tasks,
           Map.put(socket.assigns.studio_generation_tasks, artifact, pid)
         )}
    end
  end

  def handle_event("open_studio_settings", %{"artifact" => artifact}, socket) do
    {:noreply, assign(socket, :active_studio_settings_artifact, artifact)}
  end

  def handle_event("close_studio_settings", _params, socket) do
    {:noreply, assign(socket, :active_studio_settings_artifact, nil)}
  end

  def handle_event("generate_studio_from_settings", %{"artifact" => artifact}, socket) do
    socket = assign(socket, :active_studio_settings_artifact, nil)
    handle_event("generate_studio", %{"artifact" => artifact}, socket)
  end

  def handle_event("open_studio_output", %{"id" => id}, socket) do
    output = Enum.find(socket.assigns.studio_outputs, &(to_string(&1.id) == id))

    {:noreply,
     socket
     |> assign(:active_studio_output, output)
     |> assign(:active_flashcard_index, 0)
     |> assign(:active_flashcard_answer?, false)}
  end

  def handle_event("close_studio_output", _params, socket) do
    {:noreply, assign(socket, :active_studio_output, nil)}
  end

  def handle_event("show_flashcard_answer", _params, socket) do
    {:noreply, assign(socket, :active_flashcard_answer?, true)}
  end

  def handle_event("previous_flashcard", _params, socket) do
    count = flashcard_count(socket.assigns.active_studio_output)

    index =
      if count > 0 do
        rem(socket.assigns.active_flashcard_index - 1 + count, count)
      else
        0
      end

    {:noreply,
     socket
     |> assign(:active_flashcard_index, index)
     |> assign(:active_flashcard_answer?, false)}
  end

  def handle_event("next_flashcard", _params, socket) do
    count = flashcard_count(socket.assigns.active_studio_output)

    index =
      if count > 0 do
        rem(socket.assigns.active_flashcard_index + 1, count)
      else
        0
      end

    {:noreply,
     socket
     |> assign(:active_flashcard_index, index)
     |> assign(:active_flashcard_answer?, false)}
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

  defp stop_studio_generation(socket, artifact) do
    case Map.fetch(socket.assigns.studio_generation_tasks, artifact) do
      {:ok, pid} -> Process.exit(pid, :kill)
      :error -> :ok
    end

    socket
    |> assign(
      :generating_studio_artifacts,
      MapSet.delete(socket.assigns.generating_studio_artifacts, artifact)
    )
    |> assign(
      :studio_generation_tasks,
      Map.delete(socket.assigns.studio_generation_tasks, artifact)
    )
    |> put_flash(:info, "#{studio_label(artifact)} generation stopped.")
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

  def handle_info({:studio_generation_completed, notebook, artifact, result}, socket) do
    if not Map.has_key?(socket.assigns.studio_generation_tasks, artifact) do
      {:noreply, socket}
    else
      handle_studio_generation_completed(socket, notebook, artifact, result)
    end
  end

  def handle_info({:studio_generation_completed, artifact, result}, socket) do
    handle_info({:studio_generation_completed, socket.assigns.notebook, artifact, result}, socket)
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

  defp handle_studio_generation_completed(socket, notebook, artifact, result) do
    socket =
      socket
      |> assign(
        :generating_studio_artifacts,
        MapSet.delete(socket.assigns.generating_studio_artifacts, artifact)
      )
      |> assign(
        :studio_generation_tasks,
        Map.delete(socket.assigns.studio_generation_tasks, artifact)
      )

    case result do
      {:ok, result} ->
        studio_outputs =
          socket.assigns.notebook
          |> refresh_studio_outputs(result, artifact, notebook)
          |> ensure_generated_studio_output(socket.assigns.notebook, notebook, artifact, result)

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

      {:error, {:video_unavailable, reason}} ->
        {:noreply,
         put_flash(socket, :error, "Video generation failed: #{format_video_reason(reason)}")}

      {:error, :unknown_studio_artifact} ->
        {:noreply, put_flash(socket, :error, "Unknown Studio action.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Studio failed.")}
    end
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

  defp favicon_src(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        "https://www.google.com/s2/favicons?domain=#{URI.encode(host)}&sz=64"

      _ ->
        nil
    end
  end

  defp favicon_src(_url), do: nil

  defp source_favicon_src(%{body: body}) when is_binary(body) do
    body
    |> source_url()
    |> favicon_src()
  end

  defp source_favicon_src(_source), do: nil

  defp source_url(body) do
    case Regex.run(~r/https?:\/\/[^\s<>)"']+/, body) do
      [url | _] -> String.trim_trailing(url, ".,;")
      _ -> nil
    end
  end

  defp slides_from_markdown(markdown) when is_binary(markdown) do
    markdown
    |> String.split(~r/^\s*---\s*$/m)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> [markdown]
      slides -> slides
    end
  end

  defp slides_from_markdown(_markdown), do: []

  defp studio_slides(%{type: "cards", content: content}), do: cards_from_markdown(content)
  defp studio_slides(%{content: content}), do: slides_from_markdown(content)
  defp studio_slides(_output), do: []

  defp slide_image_src(slide, index) do
    variant = slide_variant_for_slide(slide, index)

    encoded =
      slide
      |> slide_svg(index, variant)
      |> Base.encode64()

    "data:image/svg+xml;base64,#{encoded}"
  end

  defp slide_svg(slide, index, variant) do
    lines = slide_lines(slide)
    title = slide_title(lines, index)
    body = slide_body(lines)

    body_nodes = slide_body_nodes(body, variant)

    escaped_title = Phoenix.HTML.html_escape(title) |> Phoenix.HTML.safe_to_string()
    decoration = slide_decoration(variant)
    content = slide_content_panel(variant, escaped_title, body_nodes)

    """
    <svg xmlns="http://www.w3.org/2000/svg" width="1280" height="720" viewBox="0 0 1280 720">
      <defs>
        <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0%" stop-color="#{variant.bg_a}"/>
          <stop offset="56%" stop-color="#{variant.bg_b}"/>
          <stop offset="100%" stop-color="#{variant.bg_c}"/>
        </linearGradient>
        <filter id="shadow" x="-20%" y="-20%" width="140%" height="140%">
          <feDropShadow dx="0" dy="18" stdDeviation="18" flood-color="#0f172a" flood-opacity="0.15"/>
        </filter>
        <filter id="softShadow" x="-20%" y="-30%" width="140%" height="160%">
          <feDropShadow dx="0" dy="8" stdDeviation="8" flood-color="#0f172a" flood-opacity="0.10"/>
        </filter>
        <style>
          .eyebrow { font: 700 20px sans-serif; letter-spacing: 8px; fill: #64748b; }
          .title { font: 800 54px sans-serif; fill: #2c2c36; }
          .body { font: 600 24px sans-serif; fill: #27272a; }
          .small { font: 700 18px sans-serif; fill: #475569; }
          .metric { font: 900 44px sans-serif; fill: #2c2c36; }
          .rail { font: 800 20px sans-serif; letter-spacing: 5px; fill: #ffffff; }
        </style>
      </defs>
      <rect width="1280" height="720" rx="28" fill="url(#bg)"/>
      <path d="M0 0h118v720H0z" fill="#{variant.rail}"/>
      <text x="-650" y="72" transform="rotate(-90)" class="rail">SLIDE #{index}</text>
      #{decoration}
      #{content}
    </svg>
    """
  end

  defp slide_content_panel(
         %{layout: :timeline, accent: accent, progress_width: progress},
         title,
         body_nodes
       ) do
    """
    <path d="M172 96c0-18 14-32 32-32h824c18 0 32 14 32 32v520c0 18-14 32-32 32H204c-18 0-32-14-32-32z" fill="#ffffff" opacity="0.74" filter="url(#shadow)"/>
    <rect x="204" y="104" width="118" height="12" rx="6" fill="#{accent}"/>
    <text x="204" y="154" class="eyebrow">TIMELINE</text>
    <text x="204" y="220" class="title">#{title}</text>
    <path d="M224 260v328" stroke="#{accent}" stroke-width="12" stroke-linecap="round" opacity="0.14"/>
    #{body_nodes}
    <rect x="204" y="622" width="#{progress}" height="14" rx="7" fill="#{accent}"/>
    """
  end

  defp slide_content_panel(
         %{layout: :cards, accent: accent, progress_width: progress},
         title,
         body_nodes
       ) do
    """
    <rect x="174" y="72" width="392" height="156" rx="34" fill="#ffffff" opacity="0.82" filter="url(#shadow)"/>
    <rect x="596" y="72" width="460" height="156" rx="34" fill="#ffffff" opacity="0.52"/>
    <text x="206" y="126" class="eyebrow">KEY CARDS</text>
    <text x="206" y="190" class="title">#{title}</text>
    <path d="M612 168h296" stroke="#{accent}" stroke-width="18" stroke-linecap="round" opacity="0.28"/>
    <path d="M612 204h182" stroke="#2c2c36" stroke-width="10" stroke-linecap="round" opacity="0.10"/>
    <rect x="176" y="244" width="842" height="360" rx="38" fill="#ffffff" opacity="0.42"/>
    #{body_nodes}
    <rect x="206" y="622" width="#{progress}" height="14" rx="7" fill="#{accent}"/>
    """
  end

  defp slide_content_panel(
         %{layout: :metrics, accent: accent, progress_width: progress},
         title,
         body_nodes
       ) do
    """
    <rect x="172" y="78" width="312" height="548" rx="36" fill="#ffffff" opacity="0.80" filter="url(#shadow)"/>
    <rect x="520" y="106" width="540" height="492" rx="42" fill="#ffffff" opacity="0.58"/>
    <text x="212" y="148" class="eyebrow">DASHBOARD</text>
    <text x="212" y="222" class="title">#{title}</text>
    <circle cx="338" cy="420" r="86" fill="none" stroke="#{accent}" stroke-width="28" opacity="0.28"/>
    <circle cx="338" cy="420" r="48" fill="#{accent}" opacity="0.16"/>
    #{body_nodes}
    <rect x="212" y="566" width="#{progress}" height="14" rx="7" fill="#{accent}"/>
    """
  end

  defp slide_content_panel(
         %{layout: :network, accent: accent, progress_width: progress},
         title,
         body_nodes
       ) do
    """
    <path d="M176 134c88-72 214-74 302-4s190 72 300 10 224-42 286 40v410H176z" fill="#ffffff" opacity="0.60" filter="url(#shadow)"/>
    <rect x="198" y="92" width="604" height="128" rx="34" fill="#ffffff" opacity="0.84"/>
    <text x="230" y="142" class="eyebrow">RELATION MAP</text>
    <text x="230" y="202" class="title">#{title}</text>
    <circle cx="930" cy="158" r="56" fill="#{accent}" opacity="0.22"/>
    <circle cx="1006" cy="218" r="30" fill="#2c2c36" opacity="0.08"/>
    #{body_nodes}
    <rect x="230" y="622" width="#{progress}" height="14" rx="7" fill="#{accent}"/>
    """
  end

  defp slide_variant(index) do
    variants = [
      %{
        bg_a: "#ffffff",
        bg_b: "#f8fafc",
        bg_c: "#ecfdf5",
        rail: "#2c2c36",
        accent: "#10b981",
        progress_width: 196,
        decoration: :rings,
        layout: :timeline
      },
      %{
        bg_a: "#f8fafc",
        bg_b: "#eef2ff",
        bg_c: "#f0fdfa",
        rail: "#0f766e",
        accent: "#0ea5e9",
        progress_width: 300,
        decoration: :steps,
        layout: :cards
      },
      %{
        bg_a: "#fff7ed",
        bg_b: "#ffffff",
        bg_c: "#fefce8",
        rail: "#7c2d12",
        accent: "#f97316",
        progress_width: 260,
        decoration: :bars,
        layout: :metrics
      },
      %{
        bg_a: "#fdf2f8",
        bg_b: "#ffffff",
        bg_c: "#eef2ff",
        rail: "#581c87",
        accent: "#a855f7",
        progress_width: 340,
        decoration: :nodes,
        layout: :network
      }
    ]

    Enum.at(variants, rem(index - 1, length(variants)))
  end

  defp slide_variant_for_slide(slide, index) do
    chapter = slide_chapter_key(slide)
    variant_index = :erlang.phash2(chapter, 4) + 1
    slide_variant(variant_index || index)
  end

  defp slide_chapter_key(slide) do
    slide
    |> slide_lines()
    |> slide_title(1)
    |> String.downcase()
    |> String.replace(~r/^\s*(?:chapter|section|part|第)?\s*\d+\s*[:：.\-]?\s*/u, "")
    |> String.split(~r/[：:｜|\-—–]/u, parts: 2)
    |> List.first()
    |> to_string()
    |> String.trim()
    |> case do
      "" -> "default"
      key -> key
    end
  end

  defp slide_decoration(%{decoration: :rings, accent: accent}) do
    """
    <circle cx="1110" cy="138" r="92" fill="#{accent}" opacity="0.18"/>
    <circle cx="1180" cy="226" r="44" fill="#0ea5e9" opacity="0.16"/>
    <circle cx="1074" cy="612" r="110" fill="none" stroke="#{accent}" stroke-width="24" opacity="0.10"/>
    """
  end

  defp slide_decoration(%{decoration: :steps, accent: accent}) do
    """
    <rect x="1040" y="96" width="140" height="62" rx="22" fill="#{accent}" opacity="0.20"/>
    <rect x="990" y="178" width="190" height="62" rx="22" fill="#{accent}" opacity="0.14"/>
    <rect x="940" y="260" width="240" height="62" rx="22" fill="#{accent}" opacity="0.10"/>
    <path d="M1018 574c58-72 128-72 210 0" fill="none" stroke="#{accent}" stroke-width="18" stroke-linecap="round" opacity="0.18"/>
    """
  end

  defp slide_decoration(%{decoration: :bars, accent: accent}) do
    """
    <rect x="1044" y="110" width="38" height="360" rx="19" fill="#{accent}" opacity="0.16"/>
    <rect x="1110" y="184" width="38" height="286" rx="19" fill="#{accent}" opacity="0.24"/>
    <rect x="1176" y="252" width="38" height="218" rx="19" fill="#{accent}" opacity="0.14"/>
    <circle cx="1130" cy="592" r="84" fill="#2c2c36" opacity="0.07"/>
    """
  end

  defp slide_decoration(%{decoration: :nodes, accent: accent}) do
    """
    <path d="M1010 178 L1144 112 L1192 250 L1078 326 Z" fill="none" stroke="#{accent}" stroke-width="12" opacity="0.20"/>
    <circle cx="1010" cy="178" r="28" fill="#{accent}" opacity="0.24"/>
    <circle cx="1144" cy="112" r="22" fill="#{accent}" opacity="0.18"/>
    <circle cx="1192" cy="250" r="34" fill="#{accent}" opacity="0.20"/>
    <circle cx="1078" cy="326" r="24" fill="#{accent}" opacity="0.16"/>
    <rect x="1008" y="536" width="180" height="52" rx="26" fill="#{accent}" opacity="0.16"/>
    """
  end

  defp slide_body_nodes(body, %{layout: :timeline, accent: accent}) do
    body
    |> Enum.take(6)
    |> Enum.with_index()
    |> Enum.map_join("\n", fn {line, index} ->
      y = 292 + index * 52
      escaped = slide_label(line)

      """
      <g>
        <line x1="232" y1="#{y - 34}" x2="232" y2="#{y + 22}" stroke="#{accent}" stroke-width="5" opacity="0.28"/>
        <circle cx="232" cy="#{y - 6}" r="18" fill="#{accent}"/>
        <text x="226" y="#{y}" class="small" fill="#ffffff">#{index + 1}</text>
        <rect x="274" y="#{y - 34}" width="684" height="46" rx="18" fill="#ffffff" opacity="0.86" filter="url(#softShadow)"/>
        <text x="300" y="#{y}" class="body">#{escaped}</text>
      </g>
      """
    end)
  end

  defp slide_body_nodes(body, %{layout: :cards, accent: accent}) do
    body
    |> Enum.take(6)
    |> Enum.with_index()
    |> Enum.map_join("\n", fn {line, index} ->
      x = 206 + rem(index, 2) * 396
      y = 284 + div(index, 2) * 106
      escaped = slide_label(line)

      """
      <g filter="url(#softShadow)">
        <rect x="#{x}" y="#{y - 42}" width="348" height="78" rx="24" fill="#ffffff" opacity="0.88"/>
        <path d="M#{x + 24} #{y + 36}h92" stroke="#{accent}" stroke-width="8" stroke-linecap="round"/>
        <circle cx="#{x + 304}" cy="#{y - 4}" r="26" fill="#{accent}" opacity="0.18"/>
        <text x="#{x + 26}" y="#{y}" class="body">#{escaped}</text>
      </g>
      """
    end)
  end

  defp slide_body_nodes(body, %{layout: :metrics, accent: accent}) do
    body
    |> Enum.take(4)
    |> Enum.with_index()
    |> Enum.map_join("\n", fn {line, index} ->
      x = 550 + rem(index, 2) * 250
      y = 310 + div(index, 2) * 150
      escaped = slide_label(line)
      metric = String.pad_leading(Integer.to_string(index + 1), 2, "0")

      """
      <g filter="url(#softShadow)">
        <rect x="#{x}" y="#{y - 76}" width="220" height="116" rx="30" fill="#ffffff" opacity="0.88"/>
        <text x="#{x + 26}" y="#{y - 20}" class="metric">#{metric}</text>
        <rect x="#{x + 26}" y="#{y + 8}" width="118" height="10" rx="5" fill="#{accent}"/>
        <text x="#{x + 26}" y="#{y + 36}" class="small">#{escaped}</text>
      </g>
      """
    end)
  end

  defp slide_body_nodes(body, %{layout: :network, accent: accent}) do
    nodes =
      [
        {270, 322},
        {478, 270},
        {712, 332},
        {366, 488},
        {650, 500}
      ]

    lines =
      body
      |> Enum.take(length(nodes))
      |> Enum.with_index()

    connectors =
      """
      <path d="M270 322 L478 270 L712 332 L650 500 L366 488 Z" fill="none" stroke="#{accent}" stroke-width="8" opacity="0.18"/>
      <path d="M478 270 L366 488 M712 332 L366 488" stroke="#{accent}" stroke-width="5" opacity="0.14"/>
      """

    node_markup =
      Enum.map_join(lines, "\n", fn {line, index} ->
        {x, y} = Enum.at(nodes, index)
        escaped = slide_label(line, 18)

        """
        <g filter="url(#softShadow)">
          <circle cx="#{x}" cy="#{y}" r="64" fill="#ffffff" opacity="0.90"/>
          <circle cx="#{x}" cy="#{y - 24}" r="12" fill="#{accent}"/>
          <text x="#{x - 46}" y="#{y + 14}" class="small">#{escaped}</text>
        </g>
        """
      end)

    connectors <> node_markup
  end

  defp slide_label(text, limit \\ 38) do
    text
    |> String.graphemes()
    |> Enum.take(limit)
    |> Enum.join()
    |> then(fn label ->
      if String.length(text) > limit, do: label <> "...", else: label
    end)
    |> svg_escape()
  end

  defp svg_escape(text) do
    text
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end

  defp slide_lines(slide) do
    slide
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or &1 == "---" or &1 == "Notes:"))
    |> Enum.map(&String.replace(&1, ~r/\s*\[[^\]]+\]/, ""))
  end

  defp slide_title([], index), do: "Slide #{index}"

  defp slide_title([line | _lines], _index) do
    line
    |> String.trim_leading("#")
    |> String.replace(~r/^\s*[-*]\s+/, "")
    |> String.trim()
  end

  defp slide_body([_title | lines]) do
    lines
    |> Enum.map(&String.replace(&1, ~r/^\s*[-*]\s+/, ""))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp slide_body([]), do: []

  defp cards_from_markdown(markdown) when is_binary(markdown) do
    markdown
    |> String.trim()
    |> String.split(~r/(?=^\s*(?:[-*]\s*)?(?:\*\*)?Front\s*:)/im, trim: true)
    |> Enum.map(&format_card_slide/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> slides_from_markdown(markdown)
      cards -> cards
    end
  end

  defp cards_from_markdown(_markdown), do: []

  defp studio_flashcards(%{type: "cards", content: content}) when is_binary(content) do
    content
    |> String.trim()
    |> String.split(~r/(?=^\s*(?:[-*]\s*)?(?:\*\*)?Front\s*:)/im, trim: true)
    |> Enum.map(&flashcard_from_markdown/1)
    |> Enum.reject(&is_nil/1)
  end

  defp studio_flashcards(_output), do: []

  defp flashcard_count(output), do: length(studio_flashcards(output))

  defp active_flashcard(output, index) do
    output
    |> studio_flashcards()
    |> Enum.at(index)
  end

  defp flashcard_from_markdown(card) do
    normalized =
      card
      |> String.trim()
      |> String.replace(~r/^\s*[-*]\s*/, "")

    with [front, back] <-
           Regex.split(~r/(?:\*\*)?Back(?:\*\*)?\s*:/i, normalized, parts: 2),
         front <- String.replace(front, ~r/(?:\*\*)?Front(?:\*\*)?\s*:/i, ""),
         front <- clean_flashcard_text(front),
         back <- clean_flashcard_text(back),
         false <- front == "",
         false <- back == "" do
      %{front: front, back: back}
    else
      _ -> nil
    end
  end

  defp clean_flashcard_text(text) do
    text
    |> String.replace(~r/^\s*#+\s*/m, "")
    |> String.replace(~r/\s*\[[^\]]+\]/, "")
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.join("\n")
    |> String.trim()
  end

  defp flashcard_text_html(text) do
    {:safe, ["<div class=\"flashcard-text\">", Phoenix.HTML.Engine.html_escape(text), "</div>"]}
  end

  defp format_card_slide(card) do
    card
    |> String.trim()
    |> String.replace(~r/^\s*[-*]\s*/, "")
    |> String.replace(~r/(?:\*\*)?Front(?:\*\*)?\s*:/i, "## ")
    |> String.replace(~r/(?:\*\*)?Back(?:\*\*)?\s*:/i, "\n\n")
    |> String.trim()
  end

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

  defp active_studio_settings(nil), do: nil

  defp active_studio_settings(artifact) do
    Enum.find(studio_actions(), &(&1.artifact == artifact))
  end

  defp studio_actions do
    [
      studio_action("infographic", "studio-action-infographic", "Infographic", "hero-photo",
        bg: "bg-emerald-50",
        hover: "hover:bg-emerald-100",
        text: "text-emerald-950",
        ring: "phx-click-loading:ring-emerald-300"
      ),
      studio_action("data_table", "studio-action-data-table", "DataTable", "hero-table-cells",
        bg: "bg-[#f7f0ff]",
        hover: "hover:bg-violet-100",
        text: "text-violet-950",
        ring: "phx-click-loading:ring-violet-300"
      ),
      studio_action("slides", "studio-action-slides", "Slides", "hero-presentation-chart-bar",
        bg: "bg-sky-100",
        hover: "hover:bg-sky-200",
        text: "text-sky-950",
        ring: "phx-click-loading:ring-sky-300"
      ),
      studio_action("audio_overview", "studio-action-audio-overview", "Audio", "hero-sparkles",
        bg: "bg-indigo-50",
        hover: "hover:bg-indigo-100",
        text: "text-indigo-950",
        ring: "phx-click-loading:ring-indigo-300"
      ),
      studio_action("mind_map", "studio-action-mind-map", "MindMap", "hero-share",
        bg: "bg-[#fdf0fd]",
        hover: "hover:bg-fuchsia-100",
        text: "text-fuchsia-950",
        ring: "phx-click-loading:ring-fuchsia-300"
      ),
      studio_action("flashcards", "studio-action-flashcards", "Cards", "hero-rectangle-stack",
        bg: "bg-[#dcf8fb]",
        hover: "hover:bg-cyan-100",
        text: "text-cyan-950",
        ring: "phx-click-loading:ring-cyan-300"
      ),
      studio_action("report", "studio-action-report", "Report", "hero-document-text",
        bg: "bg-[#fffaf0]",
        hover: "hover:bg-amber-100",
        text: "text-amber-950",
        ring: "phx-click-loading:ring-amber-300"
      )
    ]
  end

  defp studio_action(artifact, id, label, icon, opts) do
    %{
      artifact: artifact,
      id: id,
      settings_id: "#{id}-settings",
      label: label,
      icon: icon,
      bg: opts[:bg],
      hover: opts[:hover],
      text: opts[:text],
      ring: opts[:ring]
    }
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
    |> Enum.reject(&(&1.label == "Quiz"))
    |> Enum.reverse()
  end

  defp refresh_studio_outputs(notebook, result, artifact, generated_notebook) do
    notebook
    |> Notebooks.list_messages()
    |> studio_outputs()
    |> maybe_prepend_generated_studio_output(notebook, generated_notebook, artifact, result)
    |> Enum.uniq_by(& &1.id)
  end

  defp maybe_prepend_generated_studio_output(
         studio_outputs,
         _current_notebook,
         _generated_notebook,
         "quiz",
         _result
       ),
       do: studio_outputs

  defp maybe_prepend_generated_studio_output(
         studio_outputs,
         current_notebook,
         generated_notebook,
         artifact,
         result
       ) do
    if same_notebook?(current_notebook, generated_notebook) do
      [studio_output_from_result(artifact, result) | studio_outputs]
    else
      studio_outputs
    end
  end

  defp ensure_generated_studio_output(
         studio_outputs,
         current_notebook,
         generated_notebook,
         artifact,
         result
       ) do
    cond do
      not same_notebook?(current_notebook, generated_notebook) ->
        studio_outputs

      Enum.any?(studio_outputs, &(&1.id == result.message.id)) ->
        studio_outputs

      true ->
        [studio_output_from_result(artifact, result) | studio_outputs]
    end
  end

  defp studio_output_from_result(artifact, result) do
    artifact
    |> studio_artifact_meta()
    |> Map.merge(%{
      id: result.message.id,
      content: result.answer,
      inserted_at: result.message.inserted_at,
      title: studio_output_title(result.answer, studio_label(artifact))
    })
  end

  defp same_notebook?(%{id: current_id}, %{id: generated_id}), do: current_id == generated_id
  defp same_notebook?(_current_notebook, _generated_notebook), do: false

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
    do: studio_artifact_meta("audio_overview")

  defp studio_request_meta("Create a report" <> _rest),
    do: studio_artifact_meta("report")

  defp studio_request_meta("Create a quiz" <> _rest),
    do: studio_artifact_meta("quiz")

  defp studio_request_meta("Create flashcards" <> _rest),
    do: studio_artifact_meta("flashcards")

  defp studio_request_meta("Create a data table" <> _rest),
    do: studio_artifact_meta("data_table")

  defp studio_request_meta("Create a mind map" <> _rest),
    do: studio_artifact_meta("mind_map")

  defp studio_request_meta("Create an infographic" <> _rest),
    do: studio_artifact_meta("infographic")

  defp studio_request_meta("Create slide materials" <> _rest),
    do: studio_artifact_meta("slides")

  defp studio_request_meta("Create a video explainer" <> _rest),
    do: studio_artifact_meta("video_explainer")

  defp studio_request_meta(_request), do: nil

  defp studio_artifact_meta("audio_overview"),
    do: %{
      type: "audio",
      label: "Audio",
      icon: "hero-sparkles",
      tone: "bg-indigo-50 text-indigo-950"
    }

  defp studio_artifact_meta("report"),
    do: %{
      type: "document",
      label: "Report",
      icon: "hero-document-text",
      tone: "bg-[#fffaf0] text-amber-950"
    }

  defp studio_artifact_meta("quiz"),
    do: %{
      type: "document",
      label: "Quiz",
      icon: "hero-question-mark-circle",
      tone: "bg-rose-50 text-rose-950"
    }

  defp studio_artifact_meta("flashcards"),
    do: %{
      type: "cards",
      label: "Cards",
      icon: "hero-rectangle-stack",
      tone: "bg-[#dcf8fb] text-cyan-950"
    }

  defp studio_artifact_meta("data_table"),
    do: %{
      type: "table",
      label: "DataTable",
      icon: "hero-table-cells",
      tone: "bg-[#f7f0ff] text-violet-950"
    }

  defp studio_artifact_meta("mind_map"),
    do: %{
      type: "map",
      label: "MindMap",
      icon: "hero-share",
      tone: "bg-[#fdf0fd] text-fuchsia-950"
    }

  defp studio_artifact_meta("infographic"),
    do: %{
      type: "image",
      label: "Infographic",
      icon: "hero-photo",
      tone: "bg-emerald-50 text-emerald-950"
    }

  defp studio_artifact_meta("slides"),
    do: %{
      type: "slides",
      label: "Slides",
      icon: "hero-presentation-chart-bar",
      tone: "bg-sky-100 text-sky-950"
    }

  defp studio_artifact_meta("video_explainer"),
    do: %{
      type: "video",
      label: "Video",
      icon: "hero-video-camera",
      tone: "bg-[#f4fbdc] text-lime-950"
    }

  defp studio_artifact_meta(_artifact),
    do: %{
      type: "document",
      label: "Studio",
      icon: "hero-document-text",
      tone: "bg-zinc-50 text-zinc-950"
    }

  defp studio_output_title("data:image/" <> _rest, fallback), do: fallback
  defp studio_output_title("data:video/" <> _rest, fallback), do: fallback
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

  defp fallback_studio_title(lines, fallback) when fallback in ["Data Table", "DataTable"] do
    lines
    |> markdown_table_rows()
    |> table_summary_title()
    |> case do
      nil -> fallback
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
  defp studio_label("flashcards"), do: "Cards"
  defp studio_label("data_table"), do: "DataTable"
  defp studio_label("mind_map"), do: "MindMap"
  defp studio_label("infographic"), do: "Infographic"
  defp studio_label("slides"), do: "Slides"
  defp studio_label("video_explainer"), do: "Video"
  defp studio_label(_artifact), do: "artifact"

  defp message_tone("user"), do: "chat-user-message border-zinc-200 text-zinc-950"
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

  defp format_video_reason({:missing_executable, command}) do
    "ffmpeg command #{inspect(command)} was not found."
  end

  defp format_video_reason({:ffmpeg_failed, status, output}) do
    "ffmpeg exited with status #{status}: #{output}"
  end

  defp format_video_reason(reason), do: inspect(reason)
end
