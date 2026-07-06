defmodule Notex.Notebooks do
  @moduledoc """
  File-backed notebook storage, source ingestion, retrieval, and cited draft answers.
  """

  alias Notex.{ImageGeneration, LLM, WebSearch}
  alias Notex.Notebooks.{Message, Notebook, Source, SourceChunk, Text}

  @default_title "NewPJ"
  @default_description "Local source-grounded notes"
  @chat_messages_file "chat-messages.jsonl"
  @project_metadata_file "project.json"
  @active_project_key :active_project

  def project_name do
    project_metadata().name
  end

  def list_projects do
    current = project_metadata()

    projects =
      projects_dir()
      |> Path.join("*")
      |> Path.wildcard()
      |> Enum.filter(&File.dir?/1)
      |> Enum.map(fn path ->
        slug = Path.basename(path)

        %{
          name: project_name_for_slug(slug),
          slug: slug,
          active?: slug == current.slug
        }
      end)

    projects =
      if Enum.any?(projects, &(&1.slug == current.slug)) do
        projects
      else
        [%{name: current.name, slug: current.slug, active?: true} | projects]
      end

    Enum.sort_by(projects, &String.downcase(&1.name))
  end

  def update_project_name(name) when is_binary(name) do
    old = project_metadata()
    new_name = unique_project_name(name, old.slug)
    new = %{name: new_name, slug: slug(new_name)}

    ensure_project_dir_moved(old.slug, new.slug)
    set_active_project_metadata(new)
    write_project_metadata(new)
    {:ok, get_default_notebook()}
  end

  def create_project do
    ensure_storage!()
    name = unique_project_name(@default_title)
    metadata = set_active_project_metadata(%{name: name, slug: slug(name)})
    File.mkdir_p!(project_dir(metadata.slug))
    File.mkdir_p!(inputs_dir(metadata.slug))
    File.mkdir_p!(outputs_dir(metadata.slug))
    write_project_metadata(metadata)
    {:ok, get_default_notebook()}
  end

  def delete_project do
    ensure_storage!()
    current = project_metadata()
    current_path = project_dir(current.slug)

    if File.dir?(current_path) do
      File.rm_rf!(current_path)
    end

    next_slug =
      existing_project_slugs()
      |> Enum.to_list()
      |> Enum.sort()
      |> List.first()

    case next_slug do
      nil -> create_project()
      slug -> select_project(slug)
    end
  end

  def select_project(slug) when is_binary(slug) do
    slug = normalize_project_slug(slug, @default_title)

    if File.dir?(Path.join(projects_dir(), slug)) or slug == project_metadata().slug do
      set_active_project_metadata(%{name: project_name_for_slug(slug), slug: slug})
      ensure_storage!()
      {:ok, get_default_notebook()}
    else
      {:error, :not_found}
    end
  end

  def list_notebooks do
    [get_default_notebook()]
  end

  def get_notebook!("1"), do: get_default_notebook()
  def get_notebook!(1), do: get_default_notebook()

  def get_default_notebook do
    now = now()

    %Notebook{
      id: 1,
      title: project_name(),
      description: @default_description,
      inserted_at: now,
      updated_at: now
    }
  end

  def create_notebook!(attrs) do
    %Notebook{
      id: 1,
      title: Map.get(attrs, :title) || Map.get(attrs, "title") || @default_title,
      description: Map.get(attrs, :description) || Map.get(attrs, "description") || "",
      inserted_at: now(),
      updated_at: now()
    }
  end

  def list_sources(%Notebook{id: notebook_id}) do
    ensure_storage!()

    inputs_dir()
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.map(&read_source_file(&1, notebook_id))
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&sort_key/1, :desc)
  end

  def change_source(attrs \\ %{}) do
    %{
      "title" => Map.get(attrs, :title) || Map.get(attrs, "title") || "",
      "body" => Map.get(attrs, :body) || Map.get(attrs, "body") || ""
    }
  end

  def add_source(%Notebook{} = notebook, attrs) do
    title = attrs |> get_attr(:title) |> to_string() |> String.trim()
    body = attrs |> get_attr(:body) |> to_string() |> String.trim()

    cond do
      title == "" ->
        {:error, change_source(%{body: body})}

      body == "" ->
        {:error, change_source(%{title: title})}

      true ->
        ensure_storage!()
        now = now()
        id = next_id(source_ids())

        source = %Source{
          id: id,
          notebook_id: notebook.id,
          title: title,
          body: body,
          word_count: Text.word_count(body),
          inserted_at: now,
          updated_at: now
        }

        chunks = chunks_for(source)
        source = %{source | chunks: chunks}
        File.write!(source_path(source), Jason.encode!(source_to_json(source), pretty: true))
        {:ok, source}
    end
  end

  def delete_sources(%Notebook{} = notebook, source_ids) do
    source_ids = normalize_source_ids(source_ids)

    count =
      notebook
      |> list_sources()
      |> Enum.filter(&(&1.id in source_ids))
      |> Enum.reduce(0, fn source, count ->
        source
        |> source_path()
        |> File.rm()

        count + 1
      end)

    {:ok, count}
  end

  def delete_studio_output(%Notebook{}, output_id) do
    output_id = normalize_id(output_id)

    deleted? =
      studio_output_paths()
      |> Enum.find_value(false, fn path ->
        id = studio_output_id_from_path(path)

        if id == output_id do
          File.rm(path) == :ok
        else
          false
        end
      end)

    if deleted?, do: {:ok, 1}, else: {:error, :not_found}
  end

  def delete_chat_messages(%Notebook{} = notebook) do
    ensure_storage!()

    count =
      notebook.id
      |> read_chat_messages()
      |> length()

    File.write!(chat_messages_path(), "")
    {:ok, count}
  end

  def archive_chat_messages(%Notebook{} = notebook) do
    ensure_storage!()

    count =
      notebook.id
      |> read_chat_messages()
      |> length()

    if count == 0 do
      {:ok, %{count: 0, path: nil}}
    else
      archive_path = chat_archive_path()
      File.mkdir_p!(Path.dirname(archive_path))
      File.rename!(chat_messages_path(), archive_path)
      File.write!(chat_messages_path(), "")
      {:ok, %{count: count, path: archive_path}}
    end
  end

  def list_messages(%Notebook{id: notebook_id}) do
    ensure_storage!()

    (read_chat_messages(notebook_id) ++ read_studio_messages(notebook_id))
    |> Enum.sort_by(&sort_key/1, :asc)
  end

  def record_tool_exchange(%Notebook{} = notebook, query, result) do
    query = query |> to_string() |> String.trim()
    result = result |> to_string() |> String.trim()

    if query == "" or result == "" do
      {:error, :empty_tool_exchange}
    else
      now = now()
      user_message = message_struct(next_message_id(), notebook.id, "user", query, %{}, now)

      assistant_message =
        message_struct(
          next_message_id([user_message.id]),
          notebook.id,
          "assistant",
          result,
          %{},
          now
        )

      append_chat_message(user_message)
      append_chat_message(assistant_message)

      {:ok, %{user_message: user_message, assistant_message: assistant_message}}
    end
  end

  def ask_question(%Notebook{} = notebook, question, opts \\ []) when is_binary(question) do
    question = String.trim(question)

    if question == "" do
      {:error, :empty_question}
    else
      matches = question_matches(notebook, question, opts)

      if matches == [] do
        {:error, :no_evidence}
      else
        with {:ok, answer, llm_meta} <- synthesize_answer(question, matches) do
          citations = citations_for(matches)
          now = now()

          user_message =
            message_struct(next_message_id(), notebook.id, "user", question, %{}, now)

          assistant_message =
            message_struct(
              next_message_id([user_message.id]),
              notebook.id,
              "assistant",
              answer,
              citations,
              now
            )

          append_chat_message(user_message)
          append_chat_message(assistant_message)

          {:ok,
           %{
             message: assistant_message,
             answer: answer,
             citations: citations,
             matches: matches,
             llm: llm_meta
           }}
        end
      end
    end
  end

  def start_question(%Notebook{} = notebook, question, opts \\ []) when is_binary(question) do
    with {:ok, result} <- begin_question(notebook, question),
         {:ok, context} <- local_question_context(notebook, question, opts) do
      {:ok, Map.merge(result, context)}
    end
  end

  def start_web_question(%Notebook{} = notebook, question, opts \\ []) when is_binary(question) do
    with {:ok, result} <- begin_question(notebook, question),
         {:ok, context} <- web_question_context(question, opts) do
      {:ok, Map.merge(result, context)}
    end
  end

  def start_local_web_question(%Notebook{} = notebook, question, opts \\ [])
      when is_binary(question) do
    with {:ok, result} <- begin_question(notebook, question),
         {:ok, context} <- local_web_question_context(notebook, question, opts) do
      {:ok, Map.merge(result, context)}
    end
  end

  def begin_question(%Notebook{} = notebook, question) when is_binary(question) do
    question = String.trim(question)

    if question == "" do
      {:error, :empty_question}
    else
      now = now()
      user_message = message_struct(next_message_id(), notebook.id, "user", question, %{}, now)
      assistant_id = next_message_id([user_message.id])

      append_chat_message(user_message)

      {:ok, %{user_message: user_message, assistant_id: assistant_id}}
    end
  end

  def local_question_context(%Notebook{} = notebook, question, opts \\ [])
      when is_binary(question) do
    notebook
    |> question_matches(question, opts)
    |> context_from_matches()
  end

  def web_question_context(question, opts \\ []) when is_binary(question) do
    with {:ok, matches} <- web_matches(question, opts), do: context_from_matches(matches)
  end

  def web_search_results(question, opts \\ []) when is_binary(question) do
    limit = opts |> Keyword.get(:limit, 20) |> clamp_limit()
    WebSearch.search(question, web_search_opts(opts, limit))
  end

  def local_web_question_context(%Notebook{} = notebook, question, opts \\ [])
      when is_binary(question) do
    local_matches = question_matches(notebook, question, opts)

    with {:ok, web_matches} <- web_matches(question, opts) do
      context_from_matches(local_matches ++ web_matches)
    end
  end

  defp context_from_matches([]), do: {:error, :no_evidence}

  defp context_from_matches(matches) do
    {:ok, %{matches: matches, citations: citations_for(matches)}}
  end

  def synthesize_question(question, matches, opts \\ []) when is_binary(question) do
    synthesize_answer(question, matches, opts)
  end

  def save_assistant_message(%Notebook{} = notebook, id, answer, citations) do
    now = now()
    message = message_struct(id, notebook.id, "assistant", answer, citations, now)
    append_chat_message(message)
    {:ok, message}
  end

  def generate_studio_artifact(%Notebook{} = notebook, artifact_type, opts \\ []) do
    with {:ok, spec} <- studio_spec(artifact_type),
         matches when matches != [] <- studio_matches(notebook, opts),
         {:ok, answer, studio_meta} <- generate_studio_content(spec, matches) do
      answer = normalize_studio_answer(spec.type, answer)
      citations = citations_for(matches)
      now = now()

      user_message =
        message_struct(next_message_id(), notebook.id, "user", spec.request, %{}, now)

      assistant_message =
        message_struct(
          next_message_id([user_message.id]),
          notebook.id,
          "assistant",
          answer,
          citations,
          now
        )

      write_studio_output(%{
        id: assistant_message.id,
        type: spec.type,
        request: spec.request,
        content: answer,
        citations: citations,
        inserted_at: now,
        updated_at: now
      })

      {:ok,
       %{
         message: assistant_message,
         answer: answer,
         citations: citations,
         matches: matches,
         llm: studio_meta,
         artifact: spec.title
       }}
    else
      [] -> {:error, :no_evidence}
      {:error, reason} -> {:error, reason}
    end
  end

  defp generate_studio_content(%{generator: :image} = spec, matches) do
    spec
    |> image_prompt(matches)
    |> ImageGeneration.generate()
    |> case do
      {:ok, %{content: content, meta: meta}} -> {:ok, content, meta}
      {:error, reason} -> {:error, {:image_unavailable, reason}}
    end
  end

  defp generate_studio_content(spec, matches), do: synthesize_answer(spec.prompt, matches)

  defp image_prompt(spec, matches) do
    evidence =
      matches
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {match, index} ->
        """
        [#{index}] #{match.source_title}
        #{match.excerpt}
        """
      end)

    """
    #{spec.prompt}

    Evidence:
    #{evidence}
    """
  end

  defp normalize_studio_answer("data-table", answer) when is_binary(answer) do
    trimmed = String.trim(answer)

    cond do
      markdown_table?(trimmed) ->
        answer

      true ->
        case Jason.decode(trimmed) do
          {:ok, decoded} -> decoded_to_markdown_table(decoded, answer)
          {:error, _reason} -> answer
        end
    end
  end

  defp normalize_studio_answer("mind-map", answer) when is_binary(answer) do
    trimmed = String.trim(answer)

    cond do
      String.contains?(trimmed, "```mermaid") ->
        trimmed
        |> mermaid_fence_content()
        |> normalize_mermaid_mindmap()
        |> mermaid_markdown()

      String.starts_with?(trimmed, "mindmap") ->
        trimmed
        |> normalize_mermaid_mindmap()
        |> mermaid_markdown()

      true ->
        answer
        |> outline_to_mermaid_mindmap()
        |> mermaid_markdown()
    end
  end

  defp normalize_studio_answer(_type, answer), do: answer

  defp mermaid_markdown(content), do: "```mermaid\n#{String.trim(content)}\n```"

  defp mermaid_fence_content(markdown) do
    case Regex.run(~r/```mermaid\s*(.*?)```/s, markdown, capture: :all_but_first) do
      [content] -> content
      _other -> markdown
    end
  end

  defp normalize_mermaid_mindmap(content) do
    content
    |> String.split("\n")
    |> Enum.map(&normalize_mermaid_mindmap_line/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> "mindmap\n  root((Mind Map))"
      ["mindmap" | _rest] = lines -> Enum.join(lines, "\n")
      lines -> Enum.join(["mindmap" | lines], "\n")
    end
  end

  defp normalize_mermaid_mindmap_line(line) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" ->
        ""

      trimmed == "mindmap" ->
        "mindmap"

      String.starts_with?(trimmed, "root((") ->
        root =
          trimmed
          |> String.replace_prefix("root((", "")
          |> String.replace_suffix("))", "")
          |> mermaid_node_text()

        "  root((#{root}))"

      true ->
        leading_spaces =
          line
          |> String.length()
          |> Kernel.-(String.length(String.trim_leading(line)))

        level = max(div(leading_spaces, 2), 2)
        String.duplicate("  ", level) <> mermaid_node_text(trimmed)
    end
  end

  defp outline_to_mermaid_mindmap(answer) do
    nodes =
      answer
      |> String.split("\n")
      |> Enum.map(&outline_line/1)
      |> Enum.reject(&is_nil/1)

    case nodes do
      [] ->
        "mindmap\n  root((Mind Map))"

      [{_level, root} | children] ->
        root = mermaid_node_text(root)

        child_lines =
          children
          |> Enum.map(fn {level, text} ->
            indent = String.duplicate("  ", max(level + 2, 2))
            indent <> mermaid_node_text(text)
          end)

        ["mindmap", "  root((#{root}))" | child_lines]
        |> Enum.join("\n")
    end
  end

  defp outline_line(line) do
    trimmed = String.trim(line)

    if trimmed == "" do
      nil
    else
      leading_spaces =
        line |> String.length() |> Kernel.-(String.length(String.trim_leading(line)))

      level = div(leading_spaces, 2)

      text =
        trimmed
        |> String.trim_leading("#")
        |> String.replace(~r/^[-*]\s+/, "")
        |> String.replace(~r/^\d+[\).\s-]+/, "")
        |> String.trim()

      if text == "", do: nil, else: {level, text}
    end
  end

  defp mermaid_node_text(text) do
    text
    |> String.replace(~r/\s*\[[^\]]+\]/, "")
    |> String.replace(~r/[(){}\[\]]/, "")
    |> String.replace(~r/[<>|`]/, "")
    |> String.replace("\"", "'")
    |> String.trim()
  end

  defp markdown_table?(answer) do
    answer
    |> String.split("\n")
    |> Enum.any?(
      &(String.starts_with?(String.trim(&1), "|") and String.ends_with?(String.trim(&1), "|"))
    )
  end

  defp decoded_to_markdown_table(rows, fallback) when is_list(rows) do
    rows
    |> Enum.filter(&is_map/1)
    |> rows_to_markdown_table(fallback)
  end

  defp decoded_to_markdown_table(%{"rows" => rows}, fallback) when is_list(rows) do
    decoded_to_markdown_table(rows, fallback)
  end

  defp decoded_to_markdown_table(%{"data" => rows}, fallback) when is_list(rows) do
    decoded_to_markdown_table(rows, fallback)
  end

  defp decoded_to_markdown_table(map, fallback) when is_map(map) do
    rows_to_markdown_table([map], fallback)
  end

  defp decoded_to_markdown_table(_decoded, fallback), do: fallback

  defp rows_to_markdown_table([], fallback), do: fallback

  defp rows_to_markdown_table(rows, _fallback) do
    headers =
      rows
      |> Enum.flat_map(&Map.keys/1)
      |> Enum.uniq()
      |> Enum.sort()

    separator = Enum.map(headers, fn _header -> "---" end)

    body =
      Enum.map(rows, fn row ->
        Enum.map(headers, fn header ->
          row
          |> Map.get(header, "")
          |> markdown_table_value()
        end)
      end)

    [headers, separator | body]
    |> Enum.map_join("\n", fn cells -> "| " <> Enum.join(cells, " | ") <> " |" end)
  end

  defp markdown_table_value(value) when is_binary(value) do
    value
    |> String.replace("\n", " ")
    |> String.replace("|", "\\|")
  end

  defp markdown_table_value(value) when is_number(value) or is_boolean(value),
    do: to_string(value)

  defp markdown_table_value(nil), do: ""
  defp markdown_table_value(value), do: value |> Jason.encode!() |> String.replace("|", "\\|")

  def search(%Notebook{id: notebook_id} = notebook, query, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 6) |> clamp_limit()

    source_ids_filter =
      if Keyword.has_key?(opts, :source_ids) do
        {:only, opts |> Keyword.get(:source_ids) |> normalize_source_ids()}
      else
        :all
      end

    terms = query |> Text.terms() |> Enum.uniq()

    if terms == [] do
      []
    else
      notebook
      |> source_chunks()
      |> Enum.filter(&(&1.notebook_id == notebook_id))
      |> maybe_filter_source_ids(source_ids_filter)
      |> Enum.map(&score_match(&1, terms))
      |> Enum.filter(&(&1.score > 0))
      |> Enum.sort_by(&{-&1.score, &1.source_title, &1.position})
      |> Enum.take(limit)
    end
  end

  def list_resources do
    notebooks =
      list_notebooks()
      |> Enum.map(fn notebook ->
        %{
          uri: "notex://notebooks/#{notebook.id}",
          name: notebook.title,
          title: notebook.title,
          description: notebook.description,
          mimeType: "text/markdown"
        }
      end)

    sources =
      get_default_notebook()
      |> list_sources()
      |> Enum.map(fn source ->
        %{
          uri: "notex://sources/#{source.id}",
          name: source.title,
          title: source.title,
          description: "Source in priv/inputs",
          mimeType: "text/plain"
        }
      end)

    notebooks ++ sources
  end

  def read_resource("notex://notebooks/" <> id) do
    notebook = get_notebook!(id)
    sources = list_sources(notebook)

    body =
      [
        "# #{notebook.title}",
        notebook.description,
        "",
        "## Sources",
        Enum.map_join(sources, "\n", &"- #{&1.title} (#{&1.word_count} words)")
      ]
      |> Enum.join("\n")

    {:ok, %{uri: "notex://notebooks/#{notebook.id}", mimeType: "text/markdown", text: body}}
  end

  def read_resource("notex://sources/" <> id) do
    source =
      get_default_notebook()
      |> list_sources()
      |> Enum.find(&(to_string(&1.id) == id))

    if source do
      {:ok, %{uri: "notex://sources/#{source.id}", mimeType: "text/plain", text: source.body}}
    else
      {:error, :not_found}
    end
  end

  def read_resource(_uri), do: {:error, :not_found}

  def llm_status, do: LLM.status()

  defp question_matches(notebook, question, opts) do
    search_matches = search(notebook, question, Keyword.merge([limit: 5], opts))

    if search_matches == [] do
      notebook
      |> studio_matches(Keyword.merge([limit: 5], opts))
      |> Enum.take(5)
    else
      search_matches
    end
  end

  defp web_matches(question, opts) do
    limit = opts |> Keyword.get(:limit, 20) |> clamp_limit()

    with {:ok, results} <- web_match_results(question, opts, limit) do
      matches =
        results
        |> Enum.take(limit)
        |> Task.async_stream(&web_result_match/1, timeout: :infinity)
        |> Enum.flat_map(fn
          {:ok, {:ok, match}} -> [match]
          _other -> []
        end)

      {:ok, matches}
    end
  end

  defp web_match_results(question, opts, limit) do
    case Keyword.get(opts, :web_results) do
      results when is_list(results) ->
        {:ok, Enum.take(results, limit)}

      _other ->
        web_search_results(question, Keyword.put(opts, :limit, limit))
    end
  end

  defp web_search_opts(opts, limit) do
    opts
    |> Keyword.take([:requester])
    |> Keyword.put(:limit, limit)
  end

  defp web_result_match(result) do
    attrs = web_result_attrs(result)

    {:ok,
     %{
       id: WebSearch.result_id(result.url),
       source_id: nil,
       source_title: attrs.title,
       source_url: result.url,
       source_body: attrs.body,
       chunk_id: WebSearch.result_id(result.url),
       position: 0,
       content: attrs.body,
       excerpt: Text.excerpt(attrs.body, Text.terms(attrs.body), 600),
       score: 1
     }}
  end

  defp web_result_attrs(result) do
    case WebSearch.fetch_result(result) do
      {:ok, attrs} ->
        attrs

      {:error, _reason} ->
        %{
          title: result.title,
          body:
            [
              "URL: #{result.url}",
              result[:snippet] && "Search snippet: #{result.snippet}"
            ]
            |> Enum.reject(&is_nil/1)
            |> Enum.join("\n")
        }
    end
  end

  defp studio_spec("audio_overview") do
    {:ok,
     %{
       type: "audio",
       title: "Audio overview",
       request: "Create an audio overview from the checked sources.",
       prompt: """
       Create a concise two-speaker audio overview script from the evidence.
       Requirements:
       - Format the output as Markdown.
       - Use Speaker A and Speaker B labels.
       - Open with the main topic and why it matters.
       - Include 4-6 short exchanges.
       - Cite factual claims with bracket citations.
       - Use only the evidence.
       """
     }}
  end

  defp studio_spec("report") do
    {:ok,
     %{
       type: "report",
       title: "Report",
       request: "Create a report from the checked sources.",
       prompt: """
       Create a structured report from the evidence.
       Requirements:
       - Format the output as Markdown.
       - Use sections: Summary, Key Findings, Evidence, Open Questions.
       - Keep it concise and decision-oriented.
       - Cite factual claims with bracket citations.
       - Use only the evidence.
       """
     }}
  end

  defp studio_spec("quiz") do
    {:ok,
     %{
       type: "quiz",
       title: "Quiz",
       request: "Create a quiz from the checked sources.",
       prompt: """
       Create a quiz from the evidence.
       Requirements:
       - Format the output as Markdown.
       - Write 5 questions.
       - Include multiple-choice options A-D.
       - Mark the correct answer and add a one-sentence explanation.
       - Cite the evidence for each explanation.
       - Use only the evidence.
       """
     }}
  end

  defp studio_spec("flashcards") do
    {:ok,
     %{
       type: "flashcards",
       title: "Flashcards",
       request: "Create flashcards from the checked sources.",
       prompt: """
       Create flashcards from the evidence.
       Requirements:
       - Format the output as Markdown.
       - Write 8 compact Q/A cards.
       - Format each card as Front and Back.
       - Focus on facts, definitions, risks, and relationships.
       - Cite the back of each card.
       - Use only the evidence.
       """
     }}
  end

  defp studio_spec("data_table") do
    {:ok,
     %{
       type: "data-table",
       title: "Data Table",
       request: "Create a data table from the checked sources.",
       prompt: """
       Create a markdown data table from the evidence.
       Requirements:
       - Format the output as Markdown.
       - Start with one concise markdown heading that summarizes the table's overall subject.
       - Choose useful columns based on the evidence.
       - Include one row per distinct item, claim, risk, entity, or comparison.
       - Keep cell text short.
       - Add citations inside cells where facts appear.
       - Use only the evidence.
       """
     }}
  end

  defp studio_spec("mind_map") do
    {:ok,
     %{
       type: "mind-map",
       title: "Mind map",
       request: "Create a mind map from the checked sources.",
       prompt: """
       Create a Mermaid mind map from the evidence.
       Requirements:
       - Format the output as Markdown with a single ```mermaid fenced code block.
       - Use Mermaid mindmap syntax.
       - Start with one central topic.
       - Add 3-5 major branches with concise child nodes.
       - Cite factual nodes with bracket citations.
       - Use only the evidence.
       """
     }}
  end

  defp studio_spec("infographic") do
    {:ok,
     %{
       type: "infographic",
       title: "InfoGraphic",
       request: "Create an infographic from the checked sources.",
       generator: :image,
       prompt: """
       Create a polished editorial infographic from the evidence.
       Requirements:
       - Use a horizontal landscape canvas, preferably 16:9 or similarly wide.
       - Arrange content left-to-right or in a wide dashboard layout; do not make a vertical poster.
       - Use a clean information-design layout, not a decorative poster.
       - Include one clear title, 3-5 concise visual sections, and source-grounded labels.
       - Prioritize legible typography, simple charts, callouts, and visual hierarchy.
       - Do not invent facts beyond the evidence.
       - Avoid tiny dense text; keep wording short and readable.
       """
     }}
  end

  defp studio_spec(_artifact_type), do: {:error, :unknown_studio_artifact}

  defp source_chunks(notebook) do
    notebook
    |> list_sources()
    |> Enum.flat_map(&chunks_for/1)
  end

  defp chunks_for(%Source{} = source) do
    source.body
    |> Text.chunks()
    |> Enum.map(fn chunk ->
      %SourceChunk{
        id: source.id * 1_000 + chunk.position,
        notebook_id: source.notebook_id,
        source_id: source.id,
        position: chunk.position,
        content: chunk.content,
        word_count: chunk.word_count,
        inserted_at: source.inserted_at,
        updated_at: source.updated_at
      }
      |> Map.merge(%{source_title: source.title})
    end)
  end

  defp studio_matches(%Notebook{} = notebook, opts) do
    source_ids_filter =
      if Keyword.has_key?(opts, :source_ids) do
        {:only, opts |> Keyword.get(:source_ids) |> normalize_source_ids()}
      else
        :all
      end

    limit = opts |> Keyword.get(:limit, 10) |> clamp_limit()

    notebook
    |> source_chunks()
    |> maybe_filter_source_ids(source_ids_filter)
    |> Enum.sort_by(&{datetime_sort_value(&1.inserted_at), &1.source_id, &1.position}, :asc)
    |> Enum.take(limit)
    |> Enum.map(&Map.merge(&1, %{excerpt: &1.content, score: 1, chunk_id: &1.id}))
  end

  defp maybe_filter_source_ids(chunks, :all), do: chunks

  defp maybe_filter_source_ids(chunks, {:only, source_ids}) do
    Enum.filter(chunks, &(&1.source_id in source_ids))
  end

  defp score_match(match, terms) do
    chunk_terms = Text.terms(match.content)
    counts = Enum.frequencies(chunk_terms)

    score =
      terms
      |> Enum.map(fn term -> Map.get(counts, term, 0) end)
      |> Enum.sum()

    Map.merge(match, %{
      chunk_id: match.id,
      score: score,
      excerpt: Text.excerpt(match.content, terms)
    })
  end

  defp synthesize_answer(question, matches, opts \\ []) do
    synthesize =
      if Keyword.has_key?(opts, :on_delta) do
        &LLM.synthesize_stream/3
      else
        &LLM.synthesize/3
      end

    case synthesize.(question, matches, opts) do
      {:ok, answer, meta} -> {:ok, answer, meta}
      {:error, :no_evidence} -> {:error, :no_evidence}
      {:error, reason} -> {:error, {:llm_unavailable, reason}}
    end
  end

  defp citations_for(matches) do
    matches
    |> Enum.with_index(1)
    |> Map.new(fn {match, index} ->
      {Integer.to_string(index),
       %{
         "source_id" => match.source_id,
         "source_title" => match.source_title,
         "source_url" => Map.get(match, :source_url),
         "source_body" => Map.get(match, :source_body),
         "chunk_id" => match.chunk_id,
         "position" => match.position
       }}
    end)
  end

  defp read_source_file(path, notebook_id) do
    with {:ok, data} <- read_json_file(path) do
      source = %Source{
        id: data |> Map.get("id") |> normalize_id(),
        notebook_id: Map.get(data, "notebook_id", notebook_id),
        title: Map.get(data, "title", Path.basename(path, ".json")),
        body: Map.get(data, "body", ""),
        word_count: Map.get(data, "word_count") || Text.word_count(Map.get(data, "body", "")),
        inserted_at: parse_datetime(Map.get(data, "inserted_at")),
        updated_at: parse_datetime(Map.get(data, "updated_at"))
      }

      %{source | chunks: chunks_for(source)}
    end
  end

  defp read_chat_messages(notebook_id) do
    chat_messages_path()
    |> read_jsonl_file()
    |> Enum.map(&message_from_json(&1, notebook_id))
  end

  defp read_studio_messages(notebook_id) do
    studio_output_paths()
    |> Enum.reject(&(Path.basename(&1) == @chat_messages_file))
    |> Enum.flat_map(fn path ->
      case read_studio_output(path) do
        {:ok, data} ->
          id = data |> Map.get("id") |> normalize_id()
          inserted_at = parse_datetime(Map.get(data, "inserted_at"))
          request = Map.get(data, "request", "Create a Studio output from the checked sources.")

          [
            message_struct(id - 1, notebook_id, "user", request, %{}, inserted_at),
            message_struct(
              id,
              notebook_id,
              "assistant",
              Map.get(data, "content", ""),
              Map.get(data, "citations", %{}),
              inserted_at
            )
          ]

        _error ->
          []
      end
    end)
  end

  defp append_chat_message(%Message{} = message) do
    ensure_storage!()
    File.write!(chat_messages_path(), Jason.encode!(message_to_json(message)) <> "\n", [:append])
  end

  defp write_studio_output(data) do
    ensure_storage!()
    type_dir = Path.join(outputs_dir(), data.type)
    File.mkdir_p!(type_dir)

    path =
      Path.join(
        type_dir,
        "#{format_id(data.id)}-#{data.type}.#{studio_output_extension(data.type)}"
      )

    if studio_output_markdown?(data.type) do
      File.write!(path, studio_output_markdown(data))
    else
      File.write!(path, Jason.encode!(data_to_json(data), pretty: true))
    end
  end

  defp read_studio_output(path) do
    case Path.extname(path) do
      ".md" -> read_studio_markdown_file(path)
      _ext -> read_json_file(path)
    end
  end

  defp read_studio_markdown_file(path) do
    with {:ok, body} <- File.read(path),
         [metadata_json, content] <-
           Regex.run(~r/\A<!--\s*notex-studio:\s*(.*?)\s*-->\s*(.*)\z/s, body,
             capture: :all_but_first
           ),
         {:ok, metadata} <- Jason.decode(metadata_json) do
      content = normalize_studio_answer(Map.get(metadata, "type"), content)
      {:ok, Map.put(metadata, "content", content)}
    else
      _error -> {:error, :invalid_markdown_studio_output}
    end
  end

  defp studio_output_markdown?(type), do: type in ["data-table", "mind-map"]

  defp studio_output_extension(type),
    do: if(studio_output_markdown?(type), do: "md", else: "json")

  defp studio_output_markdown(data) do
    metadata =
      data
      |> data_to_json()
      |> Map.delete(:content)
      |> Map.delete("content")

    "<!-- notex-studio: #{Jason.encode!(metadata)} -->\n#{data.content}"
  end

  defp source_to_json(%Source{} = source) do
    %{
      id: source.id,
      notebook_id: source.notebook_id,
      title: source.title,
      body: source.body,
      word_count: source.word_count,
      inserted_at: source.inserted_at,
      updated_at: source.updated_at
    }
  end

  defp message_to_json(%Message{} = message) do
    %{
      id: message.id,
      notebook_id: message.notebook_id,
      role: message.role,
      content: message.content,
      citations: message.citations,
      inserted_at: message.inserted_at,
      updated_at: message.updated_at
    }
  end

  defp data_to_json(data) do
    data
    |> Map.update!(:inserted_at, &DateTime.to_iso8601/1)
    |> Map.update!(:updated_at, &DateTime.to_iso8601/1)
  end

  defp message_from_json(data, notebook_id) do
    message_struct(
      normalize_id(Map.get(data, "id")),
      Map.get(data, "notebook_id", notebook_id),
      Map.get(data, "role"),
      Map.get(data, "content", ""),
      Map.get(data, "citations", %{}),
      parse_datetime(Map.get(data, "inserted_at"))
    )
  end

  defp message_struct(id, notebook_id, role, content, citations, inserted_at) do
    %Message{
      id: id,
      notebook_id: notebook_id,
      role: role,
      content: content,
      citations: citations || %{},
      inserted_at: inserted_at,
      updated_at: inserted_at
    }
  end

  defp source_path(%Source{} = source) do
    Path.join(inputs_dir(), "#{format_id(source.id)}-#{slug(source.title)}.json")
  end

  defp source_ids do
    inputs_dir()
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.map(fn path ->
      path
      |> Path.basename(".json")
      |> String.split("-", parts: 2)
      |> List.first()
      |> normalize_id()
    end)
  end

  defp message_ids do
    chat_ids =
      chat_messages_path()
      |> read_jsonl_file()
      |> Enum.map(&(Map.get(&1, "id") |> normalize_id()))

    studio_ids =
      studio_output_paths()
      |> Enum.map(&studio_output_id_from_path/1)

    chat_ids ++ studio_ids
  end

  defp studio_output_paths do
    ["*.json", "*.md"]
    |> Enum.flat_map(fn pattern ->
      outputs_dir()
      |> Path.join("*/#{pattern}")
      |> Path.wildcard()
    end)
  end

  defp studio_output_id_from_path(path) do
    path
    |> Path.basename(Path.extname(path))
    |> String.split("-", parts: 2)
    |> List.first()
    |> normalize_id()
  end

  defp next_message_id(extra_ids \\ []) do
    next_id(message_ids() ++ extra_ids)
  end

  defp next_id([]), do: 1
  defp next_id(ids), do: Enum.max(ids) + 1

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

  defp normalize_id(id) when is_integer(id), do: id

  defp normalize_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {integer, _rest} -> integer
      :error -> 0
    end
  end

  defp normalize_id(_id), do: 0

  defp get_attr(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end

  defp slug(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^[:alnum:]]+/u, "-")
    |> String.trim("-")
    |> String.slice(0, 60)
  end

  defp format_id(id) when is_integer(id),
    do: id |> Integer.to_string() |> String.pad_leading(3, "0")

  defp format_id(id), do: id |> normalize_id() |> format_id()

  defp read_json_file(path) do
    with {:ok, body} <- File.read(path),
         {:ok, data} <- Jason.decode(body) do
      {:ok, data}
    end
  end

  defp read_jsonl_file(path) do
    if File.exists?(path) do
      path
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
      |> Enum.flat_map(fn line ->
        case Jason.decode(line) do
          {:ok, data} -> [data]
          _error -> []
        end
      end)
    else
      []
    end
  end

  defp parse_datetime(%DateTime{} = value), do: value

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _error -> now()
    end
  end

  defp parse_datetime(_value), do: now()

  defp now, do: DateTime.utc_now()

  defp sort_key(%{inserted_at: inserted_at, id: id}) do
    {datetime_sort_value(inserted_at), id || 0}
  end

  defp datetime_sort_value(%DateTime{} = datetime), do: DateTime.to_unix(datetime)
  defp datetime_sort_value(_datetime), do: 0

  defp ensure_storage! do
    File.mkdir_p!(projects_dir())
    active_slug = project_metadata().slug
    File.mkdir_p!(project_dir(active_slug))
    File.mkdir_p!(inputs_dir(active_slug))
    File.mkdir_p!(outputs_dir(active_slug))
    File.mkdir_p!(Path.join(outputs_dir(), "chat"))
  end

  defp inputs_dir, do: inputs_dir(project_metadata().slug)
  defp outputs_dir, do: outputs_dir(project_metadata().slug)
  defp inputs_dir(slug), do: Path.join(project_dir(slug), "inputs")
  defp outputs_dir(slug), do: Path.join(project_dir(slug), "outputs")
  defp chat_messages_path, do: Path.join([outputs_dir(), "chat", @chat_messages_file])

  defp chat_archive_path do
    timestamp =
      DateTime.utc_now()
      |> DateTime.to_iso8601(:basic)
      |> String.replace(~r/[^0-9A-Z]/, "")

    Path.join([outputs_dir(), "chat", "archives", "chat-messages-#{timestamp}.jsonl"])
  end

  defp project_dir(slug), do: Path.join(projects_dir(), slug)
  defp project_metadata_path(slug), do: Path.join(project_dir(slug), @project_metadata_file)

  defp project_metadata do
    case Application.get_env(:notex, @active_project_key) do
      %{name: name, slug: slug} when is_binary(name) and is_binary(slug) ->
        candidate = %{
          name: normalize_project_name(name),
          slug: normalize_project_slug(slug, name)
        }

        if File.dir?(project_dir(candidate.slug)) do
          candidate
        else
          fallback_project_metadata()
        end

      _ ->
        fallback_project_metadata()
    end
  end

  defp fallback_project_metadata do
    fallback =
      existing_project_slugs()
      |> Enum.to_list()
      |> Enum.sort()
      |> case do
        [] ->
          %{name: @default_title, slug: slug(@default_title)}

        [slug | _] ->
          %{name: project_name_for_slug(slug), slug: slug}
      end

    set_active_project_metadata(fallback)
  end

  defp set_active_project_metadata(%{name: name, slug: slug}) do
    metadata = %{name: normalize_project_name(name), slug: normalize_project_slug(slug, name)}
    Application.put_env(:notex, @active_project_key, metadata)
    metadata
  end

  defp project_name_for_slug(project_slug, preferred_name \\ nil) do
    cond do
      is_binary(preferred_name) and String.trim(preferred_name) != "" ->
        normalize_project_name(preferred_name)

      is_binary(project_name_from_metadata(project_slug)) ->
        project_name_from_metadata(project_slug)

      project_slug == "" ->
        @default_title

      true ->
        project_slug
        |> String.replace("-", " ")
        |> String.split(" ", trim: true)
        |> Enum.map_join(" ", fn
          "newpj" -> "NewPJ"
          word -> String.capitalize(word)
        end)
        |> normalize_project_name()
    end
  end

  defp project_name_from_metadata(project_slug) do
    with {:ok, data} <- read_json_file(project_metadata_path(project_slug)),
         name when is_binary(name) and name != "" <- Map.get(data, "name") do
      normalize_project_name(name)
    else
      _error -> nil
    end
  end

  defp write_project_metadata(%{name: name, slug: slug}) do
    File.mkdir_p!(project_dir(slug))

    File.write!(
      project_metadata_path(slug),
      Jason.encode!(%{"name" => normalize_project_name(name), "slug" => slug}, pretty: true)
    )
  end

  defp unique_project_name(base_name, allowed_slug \\ nil) do
    requested_name = normalize_project_name(base_name)
    base_name = String.replace(requested_name, ~r/\s+\d+$/, "")
    existing_slugs = existing_project_slugs() |> MapSet.delete(allowed_slug)

    Stream.iterate(1, &(&1 + 1))
    |> Enum.find_value(fn
      1 ->
        if slug(requested_name) in existing_slugs, do: nil, else: requested_name

      index ->
        candidate = "#{base_name} #{index}"
        if slug(candidate) in existing_slugs, do: nil, else: candidate
    end)
  end

  defp existing_project_slugs do
    projects_dir()
    |> Path.join("*")
    |> Path.wildcard()
    |> Enum.filter(&File.dir?/1)
    |> Enum.map(&Path.basename/1)
    |> MapSet.new()
  end

  defp ensure_project_dir_moved(old_slug, new_slug) when old_slug == new_slug, do: :ok

  defp ensure_project_dir_moved(old_slug, new_slug) do
    old_path = Path.join(projects_dir(), old_slug)
    new_path = Path.join(projects_dir(), new_slug)

    cond do
      !File.dir?(old_path) ->
        File.mkdir_p!(new_path)

      File.exists?(new_path) ->
        :ok

      true ->
        File.rename!(old_path, new_path)
    end
  end

  defp normalize_project_name(name) do
    name
    |> String.trim()
    |> case do
      "" -> @default_title
      value -> value
    end
  end

  defp normalize_project_slug(project_slug, name) do
    project_slug = project_slug |> to_string() |> String.trim()
    if project_slug == "", do: slug(name), else: project_slug
  end

  defp storage_root do
    Application.get_env(:notex, :storage_root, priv_dir())
  end

  defp projects_dir, do: Path.join(storage_root(), "projects")

  defp priv_dir do
    :notex
    |> :code.priv_dir()
    |> to_string()
  end

  defp clamp_limit(limit) when is_integer(limit), do: min(max(limit, 1), 20)
  defp clamp_limit(_), do: 6
end
