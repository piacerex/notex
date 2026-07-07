defmodule NotexWeb.NotebookLiveTest do
  use NotexWeb.ConnCase

  import Phoenix.LiveViewTest

  setup do
    old_config = Application.get_env(:notex, Notex.LLM)
    old_web_search_config = Application.get_env(:notex, Notex.WebSearch)
    old_image_config = Application.get_env(:notex, Notex.ImageGeneration)
    old_video_config = Application.get_env(:notex, Notex.VideoGeneration)

    Application.put_env(
      :notex,
      Notex.LLM,
      Keyword.put(old_config, :provider, Notex.Support.LLMStub)
    )

    Application.put_env(:notex, Notex.WebSearch, requester: &__MODULE__.web_requester/1)

    on_exit(fn ->
      Application.put_env(:notex, Notex.LLM, old_config)

      if old_web_search_config do
        Application.put_env(:notex, Notex.WebSearch, old_web_search_config)
      else
        Application.delete_env(:notex, Notex.WebSearch)
      end

      if old_image_config do
        Application.put_env(:notex, Notex.ImageGeneration, old_image_config)
      else
        Application.delete_env(:notex, Notex.ImageGeneration)
      end

      if old_video_config do
        Application.put_env(:notex, Notex.VideoGeneration, old_video_config)
      else
        Application.delete_env(:notex, Notex.VideoGeneration)
      end
    end)
  end

  test "adds a source and asks a cited question", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#source-form")
    assert has_element?(view, "#question-form")
    assert has_element?(view, "h2", "Chat & MCP result")
    assert has_element?(view, "#mcp-panel")
    assert has_element?(view, "header", "GPT on")
    assert has_element?(view, "header", "stub")
    assert has_element?(view, "#mcp-panel", "POST /mcp")
    refute has_element?(view, "#mcp-panel", "Endpoint")

    view
    |> element("#source-form")
    |> render_submit(%{
      source: %{
        title: "Launch notes",
        body:
          "The launch depends on onboarding quality. Support risk is highest during migration."
      }
    })

    assert has_element?(view, "#sources-list article")

    [source] = Notex.Notebooks.list_sources(Notex.Notebooks.get_default_notebook())
    assert has_element?(view, "#source-refs-select-all[checked]")
    assert has_element?(view, "#source-ref-checkbox-#{source.id}[checked]")
    refute has_element?(view, "#source-#{source.id} p")

    view
    |> element("#question-form")
    |> render_submit(%{question: %{question: "Where is support risk highest?"}})

    assert has_element?(view, "#messages article")
  end

  test "runs an embedded MCP tool and mirrors the exchange into chat", %{conn: conn} do
    notebook = Notex.Notebooks.get_default_notebook()

    {:ok, _source} =
      Notex.Notebooks.add_source(notebook, %{
        title: "MCP source",
        body: "Embedded MCP can search notebook evidence from the UI."
      })

    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#mcp-execute-form")
    |> render_submit(%{
      mcp: %{
        operation: "tool",
        tool: "notex.search",
        query: "notebook evidence",
        arguments: "{}",
        resource_uri: ""
      }
    })

    assert render_until(view, "MCP notex.search: notebook evidence")
    assert render(view) =~ "MCP notex.search: notebook evidence"
    assert render(view) =~ "structuredContent"

    [user_message, assistant_message] = wait_for_message_count(notebook, 2)
    assert user_message.role == "user"
    assert user_message.content == "MCP notex.search: notebook evidence"
    assert assistant_message.role == "assistant"
    assert assistant_message.content =~ "MCP source"
  end

  test "shows the user chat message immediately and streams the assistant answer", %{conn: conn} do
    old_config = Application.get_env(:notex, Notex.LLM)
    Application.put_env(:notex, Notex.LLM, Keyword.put(old_config, :provider, __MODULE__))

    notebook = Notex.Notebooks.get_default_notebook()

    {:ok, _source} =
      Notex.Notebooks.add_source(notebook, %{
        title: "Streaming source",
        body: "Streaming source content supports immediate chat answers."
      })

    {:ok, view, _html} = live(conn, ~p"/")

    html =
      view
      |> element("#question-form")
      |> render_submit(%{question: %{question: "What streams?"}})

    assert html =~ "What streams?"
    assert html =~ "Searching local sources..."
    assert render_until(view, "Streaming answer from chunks")

    [_user_message, assistant_message] = wait_for_message_count(notebook, 2)
    assert assistant_message.content == "Streaming answer from chunks"
    assert render(view) =~ "Streaming answer from chunks"
    refute render(view) =~ "Searching local sources..."
  end

  test "deletes chat history", %{conn: conn} do
    notebook = Notex.Notebooks.get_default_notebook()

    {:ok, _source} =
      Notex.Notebooks.add_source(notebook, %{
        title: "Delete chat source",
        body: "Delete chat source content supports a removable chat answer."
      })

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#delete-chat-history-button[disabled]")

    view
    |> element("#question-form")
    |> render_submit(%{question: %{question: "What can be deleted?"}})

    assert render_until(view, "Stubbed LLM answer")
    refute has_element?(view, "#delete-chat-history-button[disabled]")

    view
    |> element("#delete-chat-history-button")
    |> render_click()

    refute has_element?(view, "#messages article")
    assert Notex.Notebooks.list_messages(notebook) == []
    assert has_element?(view, "#delete-chat-history-button[disabled]")
  end

  test "archives chat history", %{conn: conn} do
    notebook = Notex.Notebooks.get_default_notebook()

    {:ok, _source} =
      Notex.Notebooks.add_source(notebook, %{
        title: "Archive chat source",
        body: "Archive chat source content supports a restorable record."
      })

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#archive-chat-history-button[disabled]")

    view
    |> element("#question-form")
    |> render_submit(%{question: %{question: "What can be archived?"}})

    assert render_until(view, "Stubbed LLM answer")
    refute has_element?(view, "#archive-chat-history-button[disabled]")

    view
    |> element("#archive-chat-history-button")
    |> render_click()

    refute has_element?(view, "#messages article")
    assert Notex.Notebooks.list_messages(notebook) == []
    assert has_element?(view, "#archive-chat-history-button[disabled]")
  end

  test "answers chat questions from web search mode", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#ask-button[disabled]")
    assert has_element?(view, "#chat-mode-local")
    assert has_element?(view, "#chat-mode-local-web")
    assert has_element?(view, "#chat-mode-web", "web ONLY")

    view
    |> element("#chat-mode-web")
    |> render_click()

    refute has_element?(view, "#ask-button[disabled]")

    html =
      view
      |> element("#question-form")
      |> render_submit(%{question: %{question: "alpha"}})

    assert html =~ "Searching the web..."
    assert render_until(view, "Stubbed LLM answer")
    assert has_element?(view, "[phx-click='add_web_citation_source']", "web")
    assert has_element?(view, "[phx-click='add_web_citation_source']", "Alpha result")
    refute has_element?(view, "[phx-click='open_citation_source']")

    view
    |> element("[phx-click='add_web_citation_source']")
    |> render_click()

    [source] = Notex.Notebooks.list_sources(Notex.Notebooks.get_default_notebook())
    assert source.title == "Alpha result"
    assert source.body =~ "Imported web source body."
  end

  test "keeps draft question text when switching chat modes", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#question-form")
    |> render_change(%{question: %{question: "Do not clear this draft"}})

    for button <- ["#chat-mode-local-web", "#chat-mode-web", "#chat-mode-local"] do
      view
      |> element(button)
      |> render_click()

      assert has_element?(
               view,
               "#question-form input[value='Do not clear this draft']"
             )
    end
  end

  test "reuses source pane web search results for the same chat web query", %{conn: conn} do
    {:ok, search_count} = Agent.start_link(fn -> 0 end)

    Application.put_env(:notex, Notex.WebSearch,
      requester: fn
        "https://www.bing.com/search?format=rss&q=volatile" ->
          count = Agent.get_and_update(search_count, &{&1, &1 + 1})
          title = if count == 0, do: "First volatile result", else: "Second volatile result"

          url =
            if count == 0,
              do: "https://example.com/volatile/first",
              else: "https://example.com/volatile/second"

          {:ok,
           %{
             status: 200,
             body:
               ~s(<?xml version="1.0" encoding="utf-8" ?><rss version="2.0"><channel><item><title>#{title}</title><link>#{url}</link><description>Volatile snippet.</description></item></channel></rss>)
           }}

        "https://www.bing.com/search?q=volatile" ->
          {:error, :html_unavailable}

        "https://example.com/volatile/first" ->
          {:ok,
           %{
             status: 200,
             body: ~s(<html><body><h1>First page</h1><p>First volatile body.</p></body></html>)
           }}

        "https://example.com/volatile/second" ->
          {:ok,
           %{
             status: 200,
             body: ~s(<html><body><h1>Second page</h1><p>Second volatile body.</p></body></html>)
           }}
      end
    )

    notebook = Notex.Notebooks.get_default_notebook()
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#web-search-form")
    |> render_submit(%{web_search: %{query: "volatile"}})

    assert render_until(view, "First volatile result")

    first_id = Notex.WebSearch.result_id("https://example.com/volatile/first")
    assert has_element?(view, "#web-result-#{first_id}", "First volatile result")

    view
    |> element("#cancel-web-results-button")
    |> render_click()

    view
    |> element("#chat-mode-web")
    |> render_click()

    view
    |> element("#question-form")
    |> render_submit(%{question: %{question: "volatile"}})

    assert render_until(view, "Stubbed LLM answer")

    [_user_message, assistant_message] = wait_for_message_count(notebook, 2)

    citation_titles =
      assistant_message.citations |> Map.values() |> Enum.map(& &1["source_title"])

    assert citation_titles == ["First volatile result"]
    refute "Second volatile result" in citation_titles
    assert Agent.get(search_count, & &1) == 1
  end

  test "chat web search does not populate the source pane with chat-only results",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#chat-mode-web")
    |> render_click()

    view
    |> element("#question-form")
    |> render_submit(%{question: %{question: "ピーターティールは何者？"}})

    thiel_id = Notex.WebSearch.result_id("https://example.com/thiel")
    actor_id = Notex.WebSearch.result_id("https://example.com/actor")

    refute has_element?(view, "#web-result-#{thiel_id}")
    refute has_element?(view, "#web-result-#{actor_id}")

    assert render_until(view, "Stubbed LLM answer")

    [_user_message, assistant_message] =
      wait_for_message_count(Notex.Notebooks.get_default_notebook(), 2)

    citation_titles =
      assistant_message.citations |> Map.values() |> Enum.map(& &1["source_title"])

    assert citation_titles == ["ピーター・ティール profile"]
  end

  test "edits project name from the top bar", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#project-name-form")
    assert has_element?(view, "#create-project-button")
    assert has_element?(view, "#delete-project-button")
    assert has_element?(view, "#project-select")

    view
    |> element("#project-name-form")
    |> render_submit(%{project: %{name: "Inline Project"}})

    assert has_element?(view, "#project-name-form input[value='Inline Project']")
    assert Notex.Notebooks.project_name() == "Inline Project"
  end

  test "creates and selects projects from the top bar", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#project-name-form input[value='NewPJ']")

    view
    |> element("#create-project-button")
    |> render_click()

    assert has_element?(view, "#project-name-form input[value='NewPJ 2']")
    assert has_element?(view, "#project-select option", "NewPJ")
    assert has_element?(view, "#project-select option", "NewPJ 2")

    view
    |> element("#project-select-form")
    |> render_change(%{project: %{slug: "NewPJ"}})

    assert has_element?(view, "#project-name-form input[value='NewPJ']")
  end

  test "deletes the active project from the top bar", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#create-project-button")
    |> render_click()

    assert has_element?(view, "#project-name-form input[value='NewPJ 2']")

    view
    |> element("#delete-project-button")
    |> render_click()

    assert has_element?(view, "#project-name-form input[value='NewPJ']")
    refute has_element?(view, "#project-select option", "NewPJ 2")
  end

  test "searches the web and imports checked results", %{conn: conn} do
    notebook = Notex.Notebooks.get_default_notebook()

    {:ok, _existing_source} =
      Notex.Notebooks.add_source(notebook, %{
        title: "Existing source",
        body: "Existing source body."
      })

    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#web-search-form")
    |> render_submit(%{web_search: %{query: "alpha"}})

    assert render_until(view, "Alpha result")

    result_id = Notex.WebSearch.result_id("https://example.com/alpha")
    assert has_element?(view, "#web-result-checkbox-#{result_id}")
    assert has_element?(view, "#web-result-checkbox-#{result_id}[checked]")

    view
    |> element("#web-import-form")
    |> render_submit(%{web_import: %{result_ids: [result_id]}})

    assert wait_for_source_count(notebook, 2)
    assert has_element?(view, "#sources-list article")
    assert has_element?(view, "#sources-list article", "Alpha result")
    refute has_element?(view, "#sources-list article", "Fetched Alpha Page Title")

    html = render(view)

    source_positions =
      notebook
      |> Notex.Notebooks.list_sources()
      |> Enum.map(fn source ->
        {position, _length} = :binary.match(html, "source-#{source.id}")
        position
      end)

    assert source_positions == Enum.sort(source_positions)
    refute has_element?(view, "#web-result-select-all[checked]")

    view
    |> element("#web-result-select-all")
    |> render_click()

    assert has_element?(view, "#web-result-select-all[checked]")
    assert has_element?(view, "#web-result-checkbox-#{result_id}[checked]")
  end

  test "toggles a web search result checkbox", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#web-search-form")
    |> render_submit(%{web_search: %{query: "alpha"}})

    assert render_until(view, "Alpha result")

    result_id = Notex.WebSearch.result_id("https://example.com/alpha")

    assert has_element?(view, "#web-result-checkbox-#{result_id}[checked]")

    view
    |> element("#web-result-checkbox-#{result_id}")
    |> render_click()

    refute has_element?(view, "#web-result-checkbox-#{result_id}[checked]")

    view
    |> element("#web-result-checkbox-#{result_id}")
    |> render_click()

    assert has_element?(view, "#web-result-checkbox-#{result_id}[checked]")
  end

  test "shows web results in an eight-row scrollable list", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#web-search-form")
    |> render_submit(%{web_search: %{query: "many"}})

    assert render_until(view, "Many result 1")

    for index <- 1..20 do
      result_id = Notex.WebSearch.result_id("https://example.com/many/#{index}")
      assert has_element?(view, "#web-result-#{result_id}")
    end

    html = render(view)

    assert html =~
             ~s(id="web-results" class="max-h-[29.75rem] min-h-0 flex-none space-y-1 overflow-y-auto pr-1")

    assert html =~ ~s(id="sources-list" class="min-h-0 flex-1 space-y-1 overflow-y-auto pr-1")
    assert html =~ "overflow-y-auto"
  end

  test "searches the web while add source accordion is open", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#toggle-source-form-button")
    |> render_click()

    assert has_element?(view, "#source-form")

    view
    |> element("#web-search-form")
    |> render_submit(%{web_search: %{query: "alpha"}})

    assert render_until(view, "Alpha result")

    result_id = Notex.WebSearch.result_id("https://example.com/alpha")
    assert has_element?(view, "#web-result-checkbox-#{result_id}[checked]")
  end

  test "toggles source checkboxes", %{conn: conn} do
    notebook = Notex.Notebooks.get_default_notebook()

    {:ok, source} =
      Notex.Notebooks.add_source(notebook, %{
        title: "Checkbox source",
        body: "Checkbox source body."
      })

    {:ok, other_source} =
      Notex.Notebooks.add_source(notebook, %{
        title: "Other checkbox source",
        body: "Other source body."
      })

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#source-ref-checkbox-#{source.id}[checked]")
    assert has_element?(view, "#source-ref-checkbox-#{other_source.id}[checked]")

    view
    |> element("#source-refs-form")
    |> render_change(%{source_refs: %{source_ids: [to_string(other_source.id)]}})

    refute has_element?(view, "#source-ref-checkbox-#{source.id}[checked]")
    assert has_element?(view, "#source-ref-checkbox-#{other_source.id}[checked]")

    view
    |> element("#source-refs-form")
    |> render_change(%{
      source_refs: %{source_ids: [to_string(source.id), to_string(other_source.id)]}
    })

    assert has_element?(view, "#source-ref-checkbox-#{source.id}[checked]")
  end

  test "cancels web search candidates", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#web-search-form")
    |> render_submit(%{web_search: %{query: "alpha"}})

    assert render_until(view, "Alpha result")

    result_id = Notex.WebSearch.result_id("https://example.com/alpha")
    assert has_element?(view, "#web-result-checkbox-#{result_id}")

    view
    |> element("#cancel-web-results-button")
    |> render_click()

    refute has_element?(view, "#web-import-form")
    refute has_element?(view, "#web-result-checkbox-#{result_id}")
  end

  test "uses only checked sources as chat RAG context", %{conn: conn} do
    notebook = Notex.Notebooks.get_default_notebook()

    {:ok, selected_source} =
      Notex.Notebooks.add_source(notebook, %{
        title: "Selected source",
        body: "Sharedneedle context belongs to the selected source."
      })

    {:ok, ignored_source} =
      Notex.Notebooks.add_source(notebook, %{
        title: "Ignored source",
        body: "Sharedneedle context belongs to the ignored source."
      })

    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#source-refs-form")
    |> render_change(%{source_refs: %{source_ids: [selected_source.id]}})

    assert has_element?(view, "#source-ref-checkbox-#{selected_source.id}[checked]")
    refute has_element?(view, "#source-ref-checkbox-#{ignored_source.id}[checked]")

    view
    |> element("#question-form")
    |> render_submit(%{question: %{question: "Where is sharedneedle context?"}})

    assert render_until(view, "Stubbed LLM answer")

    [_user_message, assistant_message] = wait_for_message_count(notebook, 2)
    citations = Map.values(assistant_message.citations)

    assert Enum.any?(citations, &(&1["source_title"] == "Selected source"))
    refute Enum.any?(citations, &(&1["source_title"] == "Ignored source"))

    view
    |> element("[phx-click='open_citation_source']")
    |> render_click()

    assert has_element?(view, "[phx-click='open_citation_source']", "local")
    assert has_element?(view, "#source-detail-view")
    assert has_element?(view, "#source-detail-title", "Selected source")
    assert has_element?(view, "#source-detail-body", "Sharedneedle context")
    refute has_element?(view, "[id^='source-chunk-']")
  end

  test "shows a short error when chat has no checked source context", %{conn: conn} do
    notebook = Notex.Notebooks.get_default_notebook()

    {:ok, _source} =
      Notex.Notebooks.add_source(notebook, %{
        title: "Unchecked source",
        body: "Unchecked source body."
      })

    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#source-refs-select-all")
    |> render_click()

    assert has_element?(view, "#ask-button[disabled]")

    view
    |> element("#chat-mode-local-web")
    |> render_click()

    assert has_element?(view, "#ask-button[disabled]")

    html =
      view
      |> element("#question-form")
      |> render_submit(%{question: %{question: "What is this about?"}})

    refute html =~ "no_evidence"
  end

  test "source select all follows checked state", %{conn: conn} do
    notebook = Notex.Notebooks.get_default_notebook()

    {:ok, first_source} =
      Notex.Notebooks.add_source(notebook, %{
        title: "First source",
        body: "First source body."
      })

    {:ok, second_source} =
      Notex.Notebooks.add_source(notebook, %{
        title: "Second source",
        body: "Second source body."
      })

    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#source-refs-select-all")
    |> render_click()

    refute has_element?(view, "#source-refs-select-all[checked]")
    refute has_element?(view, "#source-ref-checkbox-#{first_source.id}[checked]")
    refute has_element?(view, "#source-ref-checkbox-#{second_source.id}[checked]")

    view
    |> element("#source-refs-select-all")
    |> render_click()

    assert has_element?(view, "#source-refs-select-all[checked]")
    assert has_element?(view, "#source-ref-checkbox-#{first_source.id}[checked]")
    assert has_element?(view, "#source-ref-checkbox-#{second_source.id}[checked]")
  end

  test "deletes checked sources from the Sources pane", %{conn: conn} do
    notebook = Notex.Notebooks.get_default_notebook()

    {:ok, deleted_source} =
      Notex.Notebooks.add_source(notebook, %{
        title: "Delete me",
        body: "Delete me body."
      })

    {:ok, kept_source} =
      Notex.Notebooks.add_source(notebook, %{
        title: "Keep me",
        body: "Keep me body."
      })

    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#source-refs-form")
    |> render_change(%{"source_refs" => %{"source_ids" => [deleted_source.id]}})

    view
    |> element("#delete-selected-sources-button")
    |> render_click()

    refute has_element?(view, "#source-#{deleted_source.id}")
    assert has_element?(view, "#source-#{kept_source.id}")
    refute has_element?(view, "#source-refs-select-all[checked]")
    refute has_element?(view, "#source-ref-checkbox-#{kept_source.id}[checked]")
  end

  test "deletes a single source from the Sources list", %{conn: conn} do
    notebook = Notex.Notebooks.get_default_notebook()

    {:ok, deleted_source} =
      Notex.Notebooks.add_source(notebook, %{
        title: "Delete single",
        body: "Delete single body."
      })

    {:ok, kept_source} =
      Notex.Notebooks.add_source(notebook, %{
        title: "Keep single",
        body: "Keep single body."
      })

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#delete-source-#{deleted_source.id}")

    view
    |> element("#delete-source-#{deleted_source.id}")
    |> render_click()

    refute has_element?(view, "#source-#{deleted_source.id}")
    assert has_element?(view, "#source-#{kept_source.id}")
  end

  test "opens and closes a full source detail view in the Sources pane", %{conn: conn} do
    notebook = Notex.Notebooks.get_default_notebook()

    long_title =
      "Readable source with a deliberately long complete title that should remain visible in the source detail view"

    {:ok, source} =
      Notex.Notebooks.add_source(notebook, %{
        title: long_title,
        body: "This is the full source body.\nIt should replace the Sources pane content."
      })

    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#open-source-#{source.id}")
    |> render_click()

    assert has_element?(view, "#source-detail-view")
    assert has_element?(view, "#source-detail-title", long_title)
    assert has_element?(view, "#source-detail-body", "This is the full source body.")
    refute has_element?(view, "[id^='source-chunk-']")
    refute has_element?(view, "#web-search-form")

    view
    |> element("#close-source-detail-button")
    |> render_click()

    refute has_element?(view, "#source-detail-view")
    assert has_element?(view, "#web-search-form")
    assert has_element?(view, "#sources-list")
  end

  test "studio buttons generate content-titled media artifacts", %{conn: conn} do
    notebook = Notex.Notebooks.get_default_notebook()

    {:ok, source} =
      Notex.Notebooks.add_source(notebook, %{
        title: "Studio source",
        body: "Studio source content can become reports, quizzes, cards, tables, and maps."
      })

    {:ok, view, _html} = live(conn, ~p"/")

    assert render(view) =~ "sm:grid-cols-3"
    assert has_element?(view, "#studio-action-data-table", "DataTable")
    assert has_element?(view, "#studio-action-mind-map", "MindMap")
    assert has_element?(view, "#studio-action-infographic", "Infographic")
    assert has_element?(view, "#studio-action-slides", "Slides")
    refute has_element?(view, "#studio-action-video-explainer", "Video")
    assert has_element?(view, "#studio-action-slides-settings")

    view
    |> element("#studio-action-slides-settings")
    |> render_click()

    assert has_element?(view, "#studio-settings-modal", "Slides")

    view
    |> element("#close-studio-settings-button")
    |> render_click()

    view
    |> element("#studio-action-flashcards")
    |> render_click()

    assert render_until(view, "Stubbed LLM answer")
    assert has_element?(view, "#studio-output-list [id^='studio-output-']")
    assert has_element?(view, "#studio-output-list [id^='studio-output-']", "Stubbed LLM answer")
    refute has_element?(view, "#studio-output-modal")
    refute has_element?(view, "#messages article")

    [_user_message, assistant_message] = Notex.Notebooks.list_messages(notebook)
    citations = Map.values(assistant_message.citations)
    assert Enum.any?(citations, &(&1["source_title"] == source.title))

    for index <- 1..6 do
      view
      |> element("#studio-action-flashcards")
      |> render_click()

      wait_for_message_count(notebook, 2 + index * 2)
    end

    assert length(Notex.Notebooks.list_messages(notebook)) == 14
    assert render(element(view, "#studio-output-list")) |> output_count() == 7
  end

  test "studio output opens in a modal for playback", %{conn: conn} do
    notebook = Notex.Notebooks.get_default_notebook()

    {:ok, _source} =
      Notex.Notebooks.add_source(notebook, %{
        title: "Audio source",
        body: "Audio source content can become a spoken overview."
      })

    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#studio-action-audio-overview")
    |> render_click()

    assert render_until(view, "Stubbed LLM answer")
    refute has_element?(view, "#studio-output-modal")

    view
    |> element("#studio-output-list [phx-click='open_studio_output']")
    |> render_click()

    assert has_element?(view, "#studio-output-modal")
    assert has_element?(view, "#studio-player", "Stubbed LLM answer")
    assert has_element?(view, "#studio-player .studio-markdown")
    assert has_element?(view, "#studio-player [phx-hook='MermaidRenderer'][phx-update='ignore']")
    refute has_element?(view, "#studio-player pre")
    assert has_element?(view, "[id^='play-studio-output-']")
    assert has_element?(view, "[id^='delete-active-studio-output-']")
    assert render(view) =~ "max-w-[96rem]"

    [_user_message, assistant_message] = Notex.Notebooks.list_messages(notebook)
    assert render(view) =~ Calendar.strftime(assistant_message.inserted_at, "%Y-%m-%d %H:%M")

    view
    |> element("#close-studio-output-button")
    |> render_click()

    refute has_element?(view, "#studio-output-modal")
  end

  test "infographic studio output opens as an image", %{conn: conn} do
    image_base64 = Base.encode64("fake png")

    Application.put_env(:notex, Notex.ImageGeneration,
      model: "gpt-5.5",
      reasoning_effort: "low",
      app_server: fn prompt, config ->
        assert config.model == "gpt-5.5"
        assert config.reasoning_effort == "low"
        assert prompt =~ "Create a polished editorial infographic"
        assert prompt =~ "horizontal landscape canvas"
        assert prompt =~ "do not make a vertical poster"

        {:ok, image_base64, %{"revised_prompt" => "test infographic prompt"}}
      end
    )

    notebook = Notex.Notebooks.get_default_notebook()

    {:ok, _source} =
      Notex.Notebooks.add_source(notebook, %{
        title: "Graphic source",
        body: "Graphic source content can become an infographic."
      })

    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#studio-action-infographic")
    |> render_click()

    wait_for_message_count(notebook, 2)
    assert render(view) =~ "Infographic"

    view
    |> element("#studio-output-list [phx-click='open_studio_output']")
    |> render_click()

    assert has_element?(view, "#studio-output-modal")

    assert has_element?(
             view,
             "[id^='studio-image-'][src='data:image/png;base64,#{image_base64}']"
           )

    refute has_element?(view, "#studio-player .studio-markdown")
  end

  test "slides outputs open as slide media", %{conn: conn} do
    notebook = Notex.Notebooks.get_default_notebook()

    {:ok, _source} =
      Notex.Notebooks.add_source(notebook, %{
        title: "Presentation source",
        body: "Presentation source content can become slides and a video explainer."
      })

    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#studio-action-slides")
    |> render_click()

    assert render_until(view, "Stubbed LLM answer")
    assert has_element?(view, "#studio-output-list [id^='studio-output-']", "Slides")

    view
    |> element("#studio-output-list [phx-click='open_studio_output'][phx-value-id='2']")
    |> render_click()

    assert has_element?(view, "#studio-output-modal")
    assert has_element?(view, "[id^='studio-slides-']")
    assert has_element?(view, ".studio-slide")
    assert has_element?(view, "img.studio-slide-image[src^='data:image/svg+xml;base64,']")
    refute has_element?(view, "#studio-player .studio-markdown > h1")
    refute has_element?(view, "#studio-action-video-explainer")
  end

  test "studio output list omits time and can delete media", %{conn: conn} do
    notebook = Notex.Notebooks.get_default_notebook()

    {:ok, _source} =
      Notex.Notebooks.add_source(notebook, %{
        title: "Delete media source",
        body: "Delete media source content can become a report."
      })

    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#studio-action-report")
    |> render_click()

    assert render_until(view, "Stubbed LLM answer")
    [_user_message, output] = Notex.Notebooks.list_messages(notebook)
    list_html = render(element(view, "#studio-output-list"))

    refute list_html =~ Calendar.strftime(output.inserted_at, "%H:%M")
    assert has_element?(view, "#delete-studio-output-#{output.id}")

    view
    |> element("#delete-studio-output-#{output.id}")
    |> render_click()

    refute has_element?(view, "#studio-output-#{output.id}")
    assert Notex.Notebooks.list_messages(notebook) == []
  end

  test "studio output titles skip structural media prefixes", %{conn: conn} do
    old_config = Application.get_env(:notex, Notex.LLM)
    Application.put_env(:notex, Notex.LLM, Keyword.put(old_config, :provider, __MODULE__))

    notebook = Notex.Notebooks.get_default_notebook()

    {:ok, _source} =
      Notex.Notebooks.add_source(notebook, %{
        title: "Title source",
        body: "Title source content can become audio, reports, flashcards, and data tables."
      })

    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#studio-action-audio-overview")
    |> render_click()

    assert render_until(view, "A natural audio title")

    assert has_element?(
             view,
             "#studio-output-list [id^='studio-output-']",
             "A natural audio title"
           )

    refute has_element?(view, "#studio-output-list [id^='studio-output-']", "Speaker A:")

    view
    |> element("#studio-action-report")
    |> render_click()

    assert render_until(view, "Report body title")
    assert has_element?(view, "#studio-output-list [id^='studio-output-']", "Report body title")
    refute has_element?(view, "#studio-output-list [id^='studio-output-']", "Summary")

    view
    |> element("#studio-action-flashcards")
    |> render_click()

    assert render_until(view, "What should become the card title?")

    assert has_element?(
             view,
             "#studio-output-list [id^='studio-output-']",
             "What should become the card title?"
           )

    refute has_element?(view, "#studio-output-list [id^='studio-output-']", "Front:")

    view
    |> element(
      "#studio-output-list [phx-click='open_studio_output']",
      "What should become the card title?"
    )
    |> render_click()

    assert has_element?(view, "#studio-output-modal")
    assert has_element?(view, ".flashcard-face", "What should become the card title?")
    assert has_element?(view, ".flashcard-count", "1/2")

    assert render(view) =~
             ~s(<div class="flashcard-text">What should become the card title?</div>)

    refute render(view) =~ "Slide 1"

    view
    |> element(".flashcard-face")
    |> render_click()

    assert has_element?(view, ".flashcard-face", "The answer.")

    view
    |> element(".flashcard-nav.is-next")
    |> render_click()

    assert has_element?(view, ".flashcard-face", "What is the second card?")
    assert has_element?(view, ".flashcard-count", "2/2")
    refute has_element?(view, ".studio-slide-image")
    refute has_element?(view, "[id^='studio-markdown-']")

    view
    |> element("#close-studio-output-button")
    |> render_click()

    view
    |> element("#studio-action-data-table")
    |> render_click()

    assert render_until(view, "Alpha・BetaのDetail一覧")
    assert has_element?(view, "#studio-output-list [id^='studio-output-']", "Alpha・BetaのDetail一覧")
    refute has_element?(view, "#studio-output-list [id^='studio-output-']", "Column")
  end

  def web_requester("https://www.bing.com/search?format=rss&q=alpha") do
    {:ok,
     %{
       status: 200,
       body:
         ~s(<?xml version="1.0" encoding="utf-8" ?><rss version="2.0"><channel><item><title>Alpha result</title><link>https://example.com/alpha</link><description>A source from search.</description></item></channel></rss>)
     }}
  end

  def web_requester("https://www.bing.com/search?format=rss&q=many") do
    items =
      1..25
      |> Enum.map_join(fn index ->
        ~s(<item><title>Many result #{index}</title><link>https://example.com/many/#{index}</link><description>Many snippet #{index}</description></item>)
      end)

    {:ok,
     %{
       status: 200,
       body:
         ~s(<?xml version="1.0" encoding="utf-8" ?><rss version="2.0"><channel>#{items}</channel></rss>)
     }}
  end

  def web_requester("https://www.bing.com/search?format=rss&q=" <> encoded_query) do
    case URI.decode_www_form(encoded_query) do
      query when query in ["ピーター ティール", "ピーターティール"] ->
        {:ok,
         %{
           status: 200,
           body: ~s(<?xml version="1.0" encoding="utf-8" ?><rss version="2.0"><channel>
           <item><title>ピーターの出演作</title><link>https://example.com/actor</link><description>俳優ピーターの情報。</description></item>
           </channel></rss>)
         }}

      "ティール ピーター" ->
        {:ok,
         %{
           status: 200,
           body: ~s(<?xml version="1.0" encoding="utf-8" ?><rss version="2.0"><channel>
           <item><title>ピーター・ティール profile</title><link>https://example.com/thiel</link><description>投資家ピーター・ティールの情報。</description></item>
           </channel></rss>)
         }}

      _other ->
        {:error, :unhandled_request}
    end
  end

  def web_requester("https://example.com/thiel") do
    {:ok,
     %{
       status: 200,
       body:
         ~s(<html><body><h1>Peter Thiel</h1><p>Investor Peter Thiel profile.</p></body></html>)
     }}
  end

  def web_requester("https://example.com/alpha") do
    {:ok,
     %{
       status: 200,
       body:
         ~s(<html><body><h1>Fetched Alpha Page Title</h1><p>Imported web source body.</p></body></html>)
     }}
  end

  defp render_until(view, text, attempts \\ 20)
  defp render_until(_view, _text, 0), do: false

  defp render_until(view, text, attempts) do
    if render(view) =~ text do
      true
    else
      Process.sleep(10)
      render_until(view, text, attempts - 1)
    end
  end

  defp wait_for_message_count(notebook, count, attempts \\ 20)
  defp wait_for_message_count(notebook, _count, 0), do: Notex.Notebooks.list_messages(notebook)

  defp wait_for_message_count(notebook, count, attempts) do
    messages = Notex.Notebooks.list_messages(notebook)

    if length(messages) >= count do
      messages
    else
      Process.sleep(10)
      wait_for_message_count(notebook, count, attempts - 1)
    end
  end

  defp wait_for_source_count(notebook, count, attempts \\ 20)
  defp wait_for_source_count(_notebook, _count, 0), do: false

  defp wait_for_source_count(notebook, count, attempts) do
    if length(Notex.Notebooks.list_sources(notebook)) >= count do
      true
    else
      Process.sleep(10)
      wait_for_source_count(notebook, count, attempts - 1)
    end
  end

  defp output_count(html) do
    html
    |> String.split("phx-click=\"open_studio_output\"")
    |> length()
    |> Kernel.-(1)
  end

  def synthesize(question, _matches, _opts) do
    content =
      cond do
        question =~ "audio overview script" ->
          "Speaker A: A natural audio title from the generated script [1]\n\nSpeaker B: More context."

        question =~ "structured report" ->
          "**Summary**\n\nReport body title from the first real paragraph [1]"

        question =~ "flashcards" ->
          "Front: What should become the card title? [1]\nBack: The answer.\n\nFront: What is the second card? [1]\nBack: Another answer."

        question =~ "markdown data table" ->
          "| Column | Detail |\n|---|---|\n| Alpha | Useful value [1] |\n| Beta | Other useful value [1] |"

        question =~ "slide deck" ->
          "# Slides title\n\n---\n\n## Slide one\n- Useful point [1]"

        question =~ "narrated video package" ->
          "# Video title\n\n## Useful scene\n- Useful scene [1]\n\nNarration:\nNarration text."

        true ->
          "Stubbed LLM answer from the provided evidence [1]"
      end

    {:ok, content, %{"provider" => "test", "model" => "test", "reasoning_effort" => "low"}}
  end

  def synthesize_stream("What streams?", _matches, opts) do
    on_delta = Keyword.fetch!(opts, :on_delta)
    on_delta.("Streaming answer ")
    on_delta.("from chunks")
    {:ok, "Streaming answer from chunks", %{"provider" => "test", "model" => "test"}}
  end

  def synthesize_stream(question, matches, opts), do: synthesize(question, matches, opts)

  def status do
    %{provider: "test", model: "test", reasoning_effort: "low", configured?: true}
  end
end
