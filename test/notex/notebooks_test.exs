defmodule Notex.NotebooksTest do
  use Notex.DataCase

  alias Notex.Notebooks

  setup do
    old_config = Application.get_env(:notex, Notex.LLM)
    old_web_search_config = Application.get_env(:notex, Notex.WebSearch)
    old_image_config = Application.get_env(:notex, Notex.ImageGeneration)

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
    end)
  end

  test "adds sources, searches chunks, and stores cited answers" do
    notebook = Notebooks.get_default_notebook()

    assert {:ok, source} =
             Notebooks.add_source(notebook, %{
               title: "Pricing memo",
               body:
                 "Pricing risk increases when discounts expand faster than retention. Renewal notes mention pricing risk and margin pressure."
             })

    assert source.word_count > 0
    assert length(source.chunks) > 0

    assert [source_path] =
             Path.wildcard(Path.join(storage_root(), "projects/*/inputs/*.json"))

    assert source_path =~ String.pad_leading(Integer.to_string(source.id), 3, "0") <> "-"

    assert [%{source_title: "Pricing memo", excerpt: excerpt}] =
             Notebooks.search(notebook, "pricing risk")

    assert excerpt =~ "Pricing risk"

    assert {:ok, result} = Notebooks.ask_question(notebook, "What is the pricing risk?")
    assert result.answer =~ "Stubbed LLM answer"
    assert map_size(result.citations) > 0
    assert length(Notebooks.list_messages(notebook)) == 2
  end

  test "limits answers to selected source ids" do
    notebook = Notebooks.get_default_notebook()

    assert {:ok, included} =
             Notebooks.add_source(notebook, %{
               title: "Included memo",
               body: "Alpha migration risk appears in the selected source."
             })

    assert {:ok, excluded} =
             Notebooks.add_source(notebook, %{
               title: "Excluded memo",
               body: "Alpha migration risk appears in the excluded source."
             })

    included_id = included.id
    excluded_id = excluded.id

    assert [%{source_id: ^included_id}] =
             Notebooks.search(notebook, "alpha migration", source_ids: [included.id])

    refute Notebooks.search(notebook, "alpha migration", source_ids: [excluded_id]) == []

    assert {:ok, result} =
             Notebooks.ask_question(notebook, "Where is alpha migration risk?",
               source_ids: [included.id]
             )

    assert Enum.all?(result.matches, &(&1.source_id == included_id))
  end

  test "answers from selected sources when keyword search finds no exact match" do
    notebook = Notebooks.get_default_notebook()

    assert {:ok, source} =
             Notebooks.add_source(notebook, %{
               title: "Concept memo",
               body: "The document explains onboarding quality and migration readiness."
             })

    assert {:ok, result} =
             Notebooks.ask_question(notebook, "Give me a helpful overview.",
               source_ids: [source.id]
             )

    assert result.answer =~ "Stubbed LLM answer"
    assert Enum.all?(result.matches, &(&1.source_id == source.id))
    assert map_size(result.citations) > 0
  end

  test "web question context uses the shared web search and keeps up to twenty matches" do
    assert {:ok, results} = Notebooks.web_search_results("many")

    assert {:ok, %{matches: matches, citations: citations}} =
             Notebooks.web_question_context("many")

    assert Enum.map(matches, & &1.source_title) == Enum.map(results, & &1.title)
    assert length(matches) == 20
    assert map_size(citations) == 20
    assert List.first(matches).source_title == "Many result 1"
    assert List.last(matches).source_title == "Many result 20"
  end

  test "web question context keeps the same search hits when page fetch fails" do
    assert {:ok, results} = Notebooks.web_search_results("partial")

    assert {:ok, %{matches: matches}} = Notebooks.web_question_context("partial")

    assert Enum.map(matches, & &1.source_title) == Enum.map(results, & &1.title)
    assert Enum.map(matches, & &1.source_url) == Enum.map(results, & &1.url)
    assert Enum.any?(matches, &(&1.source_title == "Partial unfetched result"))

    unfetched = Enum.find(matches, &(&1.source_title == "Partial unfetched result"))
    assert unfetched.source_body =~ "Search snippet: Fallback snippet"
  end

  test "web question context can reuse source pane web results without re-searching" do
    source_pane_results = [
      %{
        id: Notex.WebSearch.result_id("https://example.com/partial/fetched"),
        title: "Source pane title",
        url: "https://example.com/partial/fetched",
        snippet: "Source pane snippet"
      }
    ]

    assert {:ok, %{matches: [match]}} =
             Notebooks.web_question_context("query without a search fixture",
               web_results: source_pane_results
             )

    assert match.source_title == "Source pane title"
    assert match.source_url == "https://example.com/partial/fetched"
  end

  test "local plus web context uses the same web search without local-only options" do
    notebook = Notebooks.get_default_notebook()

    assert {:ok, source} =
             Notebooks.add_source(notebook, %{
               title: "Local many source",
               body: "many local context"
             })

    assert {:ok, %{matches: matches}} =
             Notebooks.local_web_question_context(notebook, "many", source_ids: [source.id])

    assert Enum.any?(matches, &(&1.source_id == source.id))
    assert Enum.any?(matches, &(&1.source_title == "Many result 1"))
    assert Enum.any?(matches, &(&1.source_title == "Many result 20"))
  end

  test "deletes selected sources" do
    notebook = Notebooks.get_default_notebook()

    assert {:ok, first} =
             Notebooks.add_source(notebook, %{title: "First", body: "First body."})

    assert {:ok, _second} =
             Notebooks.add_source(notebook, %{title: "Second", body: "Second body."})

    assert {:ok, 1} = Notebooks.delete_sources(notebook, [first.id])

    titles = notebook |> Notebooks.list_sources() |> Enum.map(& &1.title)
    refute "First" in titles
    assert "Second" in titles
  end

  test "generates studio artifacts from selected sources" do
    notebook = Notebooks.get_default_notebook()

    assert {:ok, source} =
             Notebooks.add_source(notebook, %{
               title: "Studio memo",
               body: "Studio artifacts should summarize selected evidence for reuse."
             })

    assert {:ok, result} =
             Notebooks.generate_studio_artifact(notebook, "report", source_ids: [source.id])

    assert result.artifact == "Report"
    assert result.answer =~ "Stubbed LLM answer"
    assert Enum.all?(result.matches, &(&1.source_id == source.id))
    assert length(Notebooks.list_messages(notebook)) == 2

    assert [_output_path] =
             Path.wildcard(Path.join(storage_root(), "projects/*/outputs/report/*-report.json"))
  end

  test "renames project folder and keeps file-backed content under the project" do
    notebook = Notebooks.get_default_notebook()

    assert {:ok, _source} =
             Notebooks.add_source(notebook, %{
               title: "Project source",
               body: "Project scoped source body."
             })

    assert [_source_path] =
             Path.wildcard(Path.join(storage_root(), "projects/newpj/inputs/*.json"))

    assert {:ok, renamed} = Notebooks.update_project_name("Alpha Project")
    assert renamed.title == "Alpha Project"

    assert [_source_path] =
             Path.wildcard(Path.join(storage_root(), "projects/alpha-project/inputs/*.json"))

    assert [] ==
             Path.wildcard(Path.join(storage_root(), "projects/newpj/inputs/*.json"))
  end

  test "creates and selects projects with collision-safe names" do
    notebook = Notebooks.get_default_notebook()
    assert notebook.title == "NewPJ"

    assert {:ok, first} = Notebooks.create_project()
    assert first.title == "NewPJ 2"

    assert {:ok, second} = Notebooks.create_project()
    assert second.title == "NewPJ 3"

    assert Enum.map(Notebooks.list_projects(), & &1.name) == ["NewPJ", "NewPJ 2", "NewPJ 3"]

    assert {:ok, selected} = Notebooks.select_project("newpj")
    assert selected.title == "NewPJ"

    assert {:ok, renamed} = Notebooks.update_project_name("NewPJ 2")
    assert renamed.title == "NewPJ 4"
  end

  test "preserves punctuation in project display names" do
    assert {:ok, renamed} = Notebooks.update_project_name("ピーター・ティールBot")
    assert renamed.title == "ピーター・ティールBot"

    assert [%{name: "ピーター・ティールBot"}] = Notebooks.list_projects()

    selected_slug =
      Notebooks.list_projects()
      |> List.first()
      |> Map.fetch!(:slug)

    Application.delete_env(:notex, :active_project)

    assert {:ok, selected} = Notebooks.select_project(selected_slug)
    assert selected.title == "ピーター・ティールBot"
  end

  test "deletes the active project and selects a remaining project" do
    notebook = Notebooks.get_default_notebook()

    assert {:ok, _source} =
             Notebooks.add_source(notebook, %{
               title: "Project source",
               body: "Project source body."
             })

    assert {:ok, created} = Notebooks.create_project()
    assert created.title == "NewPJ 2"

    assert {:ok, selected} = Notebooks.delete_project()
    assert selected.title == "NewPJ"
    assert Enum.map(Notebooks.list_projects(), & &1.name) == ["NewPJ"]

    assert [_source_path] =
             Path.wildcard(Path.join(storage_root(), "projects/newpj/inputs/*.json"))

    assert [] == Path.wildcard(Path.join(storage_root(), "projects/newpj-2"))
  end

  test "data table studio artifacts normalize json answers to markdown" do
    old_config = Application.get_env(:notex, Notex.LLM)
    Application.put_env(:notex, Notex.LLM, Keyword.put(old_config, :provider, __MODULE__))

    notebook = Notebooks.get_default_notebook()

    assert {:ok, source} =
             Notebooks.add_source(notebook, %{
               title: "Table source",
               body: "Alpha has useful value. Beta has other useful value."
             })

    assert {:ok, result} =
             Notebooks.generate_studio_artifact(notebook, "data_table", source_ids: [source.id])

    assert result.answer =~ "| detail | item |"
    assert result.answer =~ "| Useful value [1] | Alpha |"
    refute result.answer =~ ~s("item")

    assert [_path] =
             Path.wildcard(Path.join(storage_root(), "projects/*/outputs/data-table/*.md"))

    assert [] == Path.wildcard(Path.join(storage_root(), "projects/*/outputs/data-table/*.json"))
    assert Enum.any?(Notebooks.list_messages(notebook), &(&1.content == result.answer))
  end

  test "mind map studio artifacts normalize outline answers to mermaid markdown" do
    old_config = Application.get_env(:notex, Notex.LLM)
    Application.put_env(:notex, Notex.LLM, Keyword.put(old_config, :provider, __MODULE__))

    notebook = Notebooks.get_default_notebook()

    assert {:ok, source} =
             Notebooks.add_source(notebook, %{
               title: "Map source",
               body: "Launch planning has risks, owners, and follow-up decisions."
             })

    assert {:ok, result} =
             Notebooks.generate_studio_artifact(notebook, "mind_map", source_ids: [source.id])

    assert result.answer =~ "```mermaid"
    assert result.answer =~ "mindmap"
    assert result.answer =~ "root((Launch Planning))"
    assert result.answer =~ "Risks"
    assert result.answer =~ "```"
    refute result.answer =~ "[1]"

    assert [_path] =
             Path.wildcard(Path.join(storage_root(), "projects/*/outputs/mind-map/*.md"))

    assert [] == Path.wildcard(Path.join(storage_root(), "projects/*/outputs/mind-map/*.json"))
    assert Enum.any?(Notebooks.list_messages(notebook), &(&1.content == result.answer))
  end

  test "infographic studio artifacts use Codex app-server image generation" do
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
        assert prompt =~ "Alpha has useful value"

        {:ok, image_base64, %{"revised_prompt" => "test infographic prompt"}}
      end
    )

    notebook = Notebooks.get_default_notebook()

    assert {:ok, source} =
             Notebooks.add_source(notebook, %{
               title: "Graphic source",
               body: "Alpha has useful value. Beta has other useful value."
             })

    assert {:ok, result} =
             Notebooks.generate_studio_artifact(notebook, "infographic", source_ids: [source.id])

    assert result.answer == "data:image/png;base64,#{image_base64}"
    assert result.llm["provider"] == "codex_app_server"
    assert result.llm["model"] == "gpt-5.5"
    assert result.llm["revised_prompt"] == "test infographic prompt"
  end

  test "studio artifacts require evidence" do
    notebook = Notebooks.get_default_notebook()

    assert {:error, :no_evidence} =
             Notebooks.generate_studio_artifact(notebook, "quiz", source_ids: [])
  end

  test "chat no evidence does not masquerade as an llm outage" do
    notebook = Notebooks.get_default_notebook()

    assert {:error, :no_evidence} =
             Notebooks.ask_question(notebook, "What can you summarize?", source_ids: [])
  end

  test "provider no evidence does not masquerade as an llm outage" do
    old_config = Application.get_env(:notex, Notex.LLM)

    Application.put_env(
      :notex,
      Notex.LLM,
      Keyword.put(old_config, :provider, Notex.Support.LLMNoEvidenceStub)
    )

    notebook = Notebooks.get_default_notebook()

    assert {:ok, _source} =
             Notebooks.add_source(notebook, %{
               title: "Risk memo",
               body: "Support risk is highest during migration."
             })

    assert {:error, :no_evidence} =
             Notebooks.ask_question(notebook, "Where is support risk highest?")

    assert Notebooks.list_messages(notebook) == []
  end

  test "does not create a fallback answer when the LLM is unavailable" do
    old_config = Application.get_env(:notex, Notex.LLM)
    Application.put_env(:notex, Notex.LLM, Keyword.put(old_config, :provider, Notex.LLM.Disabled))

    notebook = Notebooks.get_default_notebook()

    assert {:ok, _source} =
             Notebooks.add_source(notebook, %{
               title: "Risk memo",
               body: "Support risk is highest during migration."
             })

    assert {:error, {:llm_unavailable, :disabled}} =
             Notebooks.ask_question(notebook, "Where is support risk highest?")

    assert Notebooks.list_messages(notebook) == []
  end

  def synthesize(question, _matches, _opts) do
    content =
      cond do
        question =~ "markdown data table" ->
          ~s([{"item":"Alpha","detail":"Useful value [1]"},{"item":"Beta","detail":"Other useful value [1]"}])

        question =~ "Mermaid mind map" ->
          """
          Launch Planning [1]
            - Risks [1]
            - Owners [1]
            - Decisions [1]
          """

        true ->
          "Stubbed LLM answer from the provided evidence [1]"
      end

    {:ok, content, %{"provider" => "test", "model" => "test", "reasoning_effort" => "low"}}
  end

  def status do
    %{
      provider: "test",
      model: "test",
      reasoning_effort: "low",
      configured?: true
    }
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

  def web_requester("https://www.bing.com/search?format=rss&q=partial") do
    {:ok,
     %{
       status: 200,
       body: ~s(<?xml version="1.0" encoding="utf-8" ?><rss version="2.0"><channel>
       <item><title>Partial fetched result</title><link>https://example.com/partial/fetched</link><description>Fetched snippet</description></item>
       <item><title>Partial unfetched result</title><link>https://example.com/partial/unfetched</link><description>Fallback snippet</description></item>
       </channel></rss>)
     }}
  end

  def web_requester("https://example.com/many/" <> index) do
    {:ok,
     %{
       status: 200,
       body:
         ~s(<html><body><h1>Many page #{index}</h1><p>Shared web search body #{index}.</p></body></html>)
     }}
  end

  def web_requester("https://example.com/partial/fetched") do
    {:ok,
     %{
       status: 200,
       body: ~s(<html><body><h1>Partial fetched page</h1><p>Fetched page body.</p></body></html>)
     }}
  end
end
