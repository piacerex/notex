defmodule Notex.WebSearchTest do
  use ExUnit.Case, async: true

  alias Notex.WebSearch

  test "parses search results from Bing RSS" do
    xml = """
    <?xml version="1.0" encoding="utf-8" ?>
    <rss version="2.0">
      <channel>
        <item>
          <title>Alpha &amp; Beta ...</title>
          <link>https://example.com/alpha</link>
          <description>A useful source about alpha.</description>
        </item>
        <item>
          <title>Gamma</title>
          <link>https://example.com/gamma</link>
          <description>Another useful source.</description>
        </item>
      </channel>
    </rss>
    """

    assert [
             %{
               id: id,
               title: "Alpha & Beta",
               url: "https://example.com/alpha",
               snippet: "A useful source about alpha."
             },
             %{title: "Gamma", url: "https://example.com/gamma"}
           ] = WebSearch.parse_results(xml)

    assert id == WebSearch.result_id("https://example.com/alpha")
  end

  test "parses search results from Bing HTML and decodes redirect URLs" do
    encoded_url = "https://example.com/strategy" |> Base.url_encode64(padding: false)

    html = """
    <ol>
      <li class="b_algo">
        <h2>
          <a href="https://www.bing.com/ck/a?u=a1#{encoded_url}&amp;ntb=1">
            <strong>ピーター・ティール</strong>の戦略
          </a>
        </h2>
        <div class="b_caption">
          <p>意思決定と戦略に関する検索結果。</p>
        </div>
      </li>
    </ol>
    """

    assert [
             %{
               title: "ピーター・ティール の戦略",
               url: "https://example.com/strategy",
               snippet: "意思決定と戦略に関する検索結果。"
             }
           ] = WebSearch.parse_html_results(html)
  end

  test "searches and fetches a selected result through an injected requester" do
    requester = fn
      "https://www.bing.com/search?format=rss&q=alpha" ->
        {:ok,
         %{
           status: 200,
           body:
             ~s(<?xml version="1.0" encoding="utf-8" ?><rss version="2.0"><channel><item><title>Alpha ...</title><link>https://example.com/alpha</link><description>Snippet</description></item></channel></rss>)
         }}

      "https://example.com/alpha" ->
        {:ok,
         %{
           status: 200,
           body: ~S"""
           <html><head><title>Alpha Complete Title</title><style>.x{}</style></head><body><h1>Alpha Complete Title</h1><p>Fetched page text.</p><script>nope()</script></body></html>
           """
         }}
    end

    assert {:ok, [result]} = WebSearch.search("alpha", requester: requester)

    assert {:ok, %{title: "Alpha", body: body}} =
             WebSearch.fetch_result(result, requester: requester)

    assert body =~ "URL: https://example.com/alpha"
    assert body =~ "Search snippet: Snippet"
    assert body =~ "Fetched page text."
    refute body =~ "nope()"
  end

  test "reranks provider results by query term relevance" do
    requester = fn
      "https://www.bing.com/search?format=rss&q=alpha+metrics" ->
        {:ok,
         %{
           status: 200,
           body: ~s(<?xml version="1.0" encoding="utf-8" ?><rss version="2.0"><channel>
             <item><title>Beta market report</title><link>https://example.com/beta</link><description>Market metrics overview.</description></item>
             <item><title>Random page</title><link>https://example.com/other</link><description>Irrelevant content with no matching terms.</description></item>
             <item><title>Alpha alpha deep dive</title><link>https://example.com/alpha</link><description>Contains alpha metrics trend</description></item>
             </channel></rss>)
         }}
    end

    assert {:ok, [first, second | _rest]} =
             WebSearch.search("alpha metrics", requester: requester)

    assert first.url == "https://example.com/alpha"
    assert second.url == "https://example.com/beta"
  end

  test "prefers reputable sources when relevance is otherwise similar" do
    requester = fn
      "https://www.bing.com/search?format=rss&q=alpha+profile" ->
        {:ok,
         %{
           status: 200,
           body: ~s(<?xml version="1.0" encoding="utf-8" ?><rss version="2.0"><channel>
             <item><title>Alpha profile blog</title><link>https://random.example/alpha</link><description>Alpha profile.</description></item>
             <item><title>Alpha profile - Wikipedia</title><link>https://en.wikipedia.org/wiki/Alpha</link><description>Alpha profile.</description></item>
             </channel></rss>)
         }}
    end

    assert {:ok, [first | _rest]} = WebSearch.search("alpha profile", requester: requester)
    assert first.url == "https://en.wikipedia.org/wiki/Alpha"
  end

  test "returns up to twenty web search results" do
    requester = fn
      "https://www.bing.com/search?format=rss&q=many" ->
        items =
          1..25
          |> Enum.map_join(fn index ->
            ~s(<item><title>Result #{index}</title><link>https://example.com/#{index}</link><description>Snippet #{index}</description></item>)
          end)

        {:ok,
         %{
           status: 200,
           body:
             ~s(<?xml version="1.0" encoding="utf-8" ?><rss version="2.0"><channel>#{items}</channel></rss>)
         }}
    end

    assert {:ok, results} = WebSearch.search("many", requester: requester)
    assert length(results) == 20
    assert List.first(results).title == "Result 1"
    assert List.last(results).title == "Result 20"
  end

  test "treats middle-dot phrases as connected search terms without hard-coded proper nouns" do
    requester = fn url ->
      parsed_query = URI.parse(url).query || ""
      query = URI.decode_query(parsed_query)["q"] || ""
      send(self(), {:requested_query, query})

      {:ok,
       %{
         status: 200,
         body: ~s(<?xml version="1.0" encoding="utf-8" ?><rss version="2.0"><channel>
           <item><title>ピーターの出演作</title><link>https://example.com/actor</link><description>ピーターの人物情報。</description></item>
           <item><title>Search result</title><link>https://example.com/result</link><description>Returned by provider.</description></item>
           <item><title>ピーター・ティールの意思決定</title><link>https://example.com/thiel</link><description>戦略と投資判断。</description></item>
         </channel></rss>)
       }}
    end

    assert {:ok, [first | _rest]} =
             WebSearch.search("ピーター・ティール 意思決定 戦略", requester: requester)

    assert first.url == "https://example.com/thiel"
    assert_received {:requested_query, "ピーター ティール 意思決定 戦略"}
    assert_received {:requested_query, "ピーターティール 意思決定 戦略"}
    assert_received {:requested_query, "ティール ピーター 意思決定 戦略"}
    assert_received {:requested_query, "ピーター ティール 意思決定"}
    assert_received {:requested_query, "ピーターティール 意思決定"}
    assert_received {:requested_query, "ティール ピーター 意思決定"}
    assert_received {:requested_query, "ピーター ティール 戦略"}
    assert_received {:requested_query, "ピーターティール 戦略"}
    assert_received {:requested_query, "ティール ピーター 戦略"}
    assert_received {:requested_query, "ピーターティール"}
    assert_received {:requested_query, "ティール ピーター"}
  end

  test "falls back to entity-only middle-dot queries when modifiers break provider matching" do
    requester = fn url ->
      parsed_query = URI.parse(url).query || ""
      query = URI.decode_query(parsed_query)["q"] || ""

      body =
        case query do
          "ティール ピーター" ->
            ~s(<?xml version="1.0" encoding="utf-8" ?><rss version="2.0"><channel>
              <item><title>ピーター・ティール - Wikipedia</title><link>https://example.com/wiki</link><description>投資家ピーター・ティール。</description></item>
              <item><title>ピーター・ティールの戦略</title><link>https://example.com/strategy</link><description>意思決定と戦略。</description></item>
            </channel></rss>)

          _other ->
            ~s(<?xml version="1.0" encoding="utf-8" ?><rss version="2.0"><channel>
              <item><title>ピーターの出演作</title><link>https://example.com/actor</link><description>ピーターの人物情報。</description></item>
            </channel></rss>)
        end

      {:ok, %{status: 200, body: body}}
    end

    assert {:ok, results} =
             WebSearch.search("ピーター・ティール 意思決定 戦略", requester: requester)

    assert Enum.map(results, & &1.url) == [
             "https://example.com/strategy",
             "https://example.com/wiki"
           ]
  end

  test "keeps entity-only matches when one modifier query also matches" do
    requester = fn url ->
      parsed_query = URI.parse(url).query || ""
      query = URI.decode_query(parsed_query)["q"] || ""

      body =
        case query do
          "ピーターティール 意思決定 戦略" ->
            ~s(<?xml version="1.0" encoding="utf-8" ?><rss version="2.0"><channel>
              <item><title>ピーター・ティールの意思決定</title><link>https://example.com/decision</link><description>意思決定と戦略。</description></item>
            </channel></rss>)

          "ピーターティール" ->
            ~s(<?xml version="1.0" encoding="utf-8" ?><rss version="2.0"><channel>
              <item><title>ピーター・ティール - Wikipedia</title><link>https://example.com/wiki</link><description>投資家ピーター・ティール。</description></item>
              <item><title>ピーター・ティール思想の整理</title><link>https://example.com/thought</link><description>ピーター・ティールの思想。</description></item>
            </channel></rss>)

          _other ->
            ~s(<?xml version="1.0" encoding="utf-8" ?><rss version="2.0"><channel>
              <item><title>ピーターの出演作</title><link>https://example.com/actor</link><description>ピーターの人物情報。</description></item>
            </channel></rss>)
        end

      {:ok, %{status: 200, body: body}}
    end

    assert {:ok, results} =
             WebSearch.search("ピーター・ティール 意思決定 戦略", requester: requester)

    assert Enum.map(results, & &1.url) == [
             "https://example.com/decision",
             "https://example.com/wiki",
             "https://example.com/thought"
           ]
  end

  test "expands middle-dot searches with latin aliases found in results" do
    requester = fn url ->
      parsed = URI.parse(url)
      params = URI.decode_query(parsed.query || "")
      query = params["q"] || ""
      send(self(), {:requested_query, query, params["mkt"]})

      body =
        case {query, params["mkt"]} do
          {"ピーターティール", _market} ->
            ~s(<?xml version="1.0" encoding="utf-8" ?><rss version="2.0"><channel>
              <item><title>ピーター・ティール / Peter Thielに関する最新記事</title><link>https://example.com/ja</link><description>ピーター・ティールの記事。</description></item>
            </channel></rss>)

          {"Peter Thiel", "en-US"} ->
            ~s(<?xml version="1.0" encoding="utf-8" ?><rss version="2.0"><channel>
              <item><title>Peter Thiel - Forbes</title><link>https://example.com/en</link><description>English profile.</description></item>
            </channel></rss>)

          _other ->
            ~s(<?xml version="1.0" encoding="utf-8" ?><rss version="2.0"><channel></channel></rss>)
        end

      {:ok, %{status: 200, body: body}}
    end

    assert {:ok, results} = WebSearch.search("ピーター・ティール", requester: requester)

    assert Enum.map(results, & &1.url) == ["https://example.com/ja", "https://example.com/en"]
    assert_received {:requested_query, "Peter Thiel", "en-US"}
  end

  test "does not expand latin aliases without matching source context" do
    requester = fn url ->
      parsed = URI.parse(url)
      params = URI.decode_query(parsed.query || "")
      query = params["q"] || ""
      send(self(), {:requested_query, query, params["mkt"]})

      body =
        case query do
          "ピーターティール" ->
            ~s(<?xml version="1.0" encoding="utf-8" ?><rss version="2.0"><channel>
              <item><title>ピーター・ティールの思想</title><link>https://example.com/thiel</link><description>PayPal Mafia and Zero To One are mentioned elsewhere.</description></item>
            </channel></rss>)

          _other ->
            ~s(<?xml version="1.0" encoding="utf-8" ?><rss version="2.0"><channel></channel></rss>)
        end

      {:ok, %{status: 200, body: body}}
    end

    assert {:ok, [%{url: "https://example.com/thiel"}]} =
             WebSearch.search("ピーター・ティール", requester: requester)

    refute_received {:requested_query, "Zero To One", "en-US"}
    refute_received {:requested_query, "PayPal Mafia", "en-US"}
  end

  test "filters to modifier matches when there are enough relevant phrase results" do
    requester = fn url ->
      parsed_query = URI.parse(url).query || ""
      query = URI.decode_query(parsed_query)["q"] || ""

      items =
        case query do
          "ピーターティール" ->
            [
              {"ピーター・ティール - Wikipedia", "https://example.com/wiki", "投資家ピーター・ティール。"},
              {"ピーター・ティール思想の整理", "https://example.com/thought", "ピーター・ティールの思想。"},
              {"ピーター・ティールの投資判断", "https://example.com/decision", "意思決定と戦略。"},
              {"ピーター・ティールと独占", "https://example.com/strategy", "競争戦略。"},
              {"ピーター・ティールの講義", "https://example.com/lecture", "意思決定の講義。"}
            ]

          _other ->
            []
        end

      body =
        items
        |> Enum.map_join(fn {title, link, description} ->
          ~s(<item><title>#{title}</title><link>#{link}</link><description>#{description}</description></item>)
        end)
        |> then(
          &~s(<?xml version="1.0" encoding="utf-8" ?><rss version="2.0"><channel>#{&1}</channel></rss>)
        )

      {:ok, %{status: 200, body: body}}
    end

    assert {:ok, results} =
             WebSearch.search("ピーター・ティール 意思決定 戦略", requester: requester)

    assert Enum.map(results, & &1.url) == [
             "https://example.com/decision",
             "https://example.com/strategy",
             "https://example.com/lecture"
           ]
  end

  test "filters by fetched page body when snippets do not expose modifier matches" do
    requester = fn
      "https://www.bing.com/search?format=rss&q=" <> encoded_query ->
        query = URI.decode_www_form(encoded_query)

        items =
          case query do
            "ピーターティール" ->
              [
                {"ピーター・ティール - Wikipedia", "https://example.com/wiki", "投資家ピーター・ティール。"},
                {"ピーター・ティールの哲学", "https://example.com/philosophy", "ピーター・ティールの思想。"},
                {"ピーター・ティールの近況", "https://example.com/news", "ピーター・ティールの人物情報。"}
              ]

            _other ->
              []
          end

        body =
          items
          |> Enum.map_join(fn {title, link, description} ->
            ~s(<item><title>#{title}</title><link>#{link}</link><description>#{description}</description></item>)
          end)
          |> then(
            &~s(<?xml version="1.0" encoding="utf-8" ?><rss version="2.0"><channel>#{&1}</channel></rss>)
          )

        {:ok, %{status: 200, body: body}}

      "https://example.com/wiki" ->
        {:ok, %{status: 200, body: "<html><body>ピーター・ティールの戦略。</body></html>"}}

      "https://example.com/philosophy" ->
        {:ok, %{status: 200, body: "<html><body>ピーター・ティールの意思決定。</body></html>"}}

      "https://example.com/news" ->
        {:ok, %{status: 200, body: "<html><body>ピーター・ティールの近況。</body></html>"}}
    end

    assert {:ok, results} =
             WebSearch.search("ピーター・ティール 意思決定 戦略", requester: requester)

    assert Enum.map(results, & &1.url) == [
             "https://example.com/wiki",
             "https://example.com/philosophy"
           ]
  end

  test "normalizes katakana proper names embedded in Japanese questions" do
    requester = fn url ->
      parsed_query = URI.parse(url).query || ""
      query = URI.decode_query(parsed_query)["q"] || ""
      send(self(), {:requested_query, query})

      body =
        case query do
          query when query in ["ティール ピーター", "ティール ピーター 何者"] ->
            ~s(<?xml version="1.0" encoding="utf-8" ?><rss version="2.0"><channel>
              <item><title>ピーター・ティール profile</title><link>https://example.com/thiel</link><description>投資家ピーター・ティールの人物情報。</description></item>
            </channel></rss>)

          _other ->
            ~s(<?xml version="1.0" encoding="utf-8" ?><rss version="2.0"><channel>
              <item><title>ピーターの出演作</title><link>https://example.com/actor</link><description>ピーターの人物情報。</description></item>
            </channel></rss>)
        end

      {:ok, %{status: 200, body: body}}
    end

    assert {:ok, [%{url: "https://example.com/thiel"}]} =
             WebSearch.search("ピーター・ティールは何者？", requester: requester)

    assert_received {:requested_query, "ピーター ティール"}
    assert_received {:requested_query, "ティール ピーター"}

    assert {:ok, [%{url: "https://example.com/thiel"}]} =
             WebSearch.search("ピーターティールは何者？", requester: requester)

    assert_received {:requested_query, "ピーターティール"}
    assert_received {:requested_query, "ティール ピーター"}
  end

  test "prioritizes both sides of a middle-dot phrase even when it is the whole query" do
    requester = fn _url ->
      {:ok,
       %{
         status: 200,
         body: ~s(<?xml version="1.0" encoding="utf-8" ?><rss version="2.0"><channel>
           <item><title>ピーターの出演作</title><link>https://example.com/actor</link><description>ピーターの人物情報。</description></item>
           <item><title>ピーター・ティール profile</title><link>https://example.com/thiel</link><description>投資家ピーター・ティールの人物情報。</description></item>
         </channel></rss>)
       }}
    end

    assert {:ok, [%{url: "https://example.com/thiel"}]} =
             WebSearch.search("ピーター・ティール", requester: requester)
  end

  test "keeps provider results when middle-dot phrase matching finds no exact Japanese result" do
    requester = fn _url ->
      {:ok,
       %{
         status: 200,
         body: ~s(<?xml version="1.0" encoding="utf-8" ?><rss version="2.0"><channel>
           <item><title>Peter Thiel profile</title><link>https://example.com/thiel</link><description>English result for the person.</description></item>
         </channel></rss>)
       }}
    end

    assert {:ok, [%{url: "https://example.com/thiel"}]} =
             WebSearch.search("ピーター・ティール", requester: requester)
  end

  test "adds technical fallback queries for short English technology terms" do
    requester = fn url ->
      parsed_query = URI.parse(url).query || ""
      query = URI.decode_query(parsed_query)["q"] || ""
      send(self(), {:requested_query, query})

      body =
        case query do
          "Angular web framework" ->
            ~s(<?xml version="1.0" encoding="utf-8" ?><rss version="2.0"><channel>
              <item><title>Home • Angular</title><link>https://angular.dev/</link><description>The web development framework for building modern apps.</description></item>
            </channel></rss>)

          _other ->
            ~s(<?xml version="1.0" encoding="utf-8" ?><rss version="2.0"><channel>
              <item><title>Unrelated result</title><link>https://example.com/unrelated</link><description>Provider returned an unrelated page.</description></item>
            </channel></rss>)
        end

      {:ok, %{status: 200, body: body}}
    end

    assert {:ok, [%{url: "https://angular.dev/"} | _rest]} =
             WebSearch.search("Angular", requester: requester)

    assert_received {:requested_query, "Angular"}
    assert_received {:requested_query, "Angular web framework"}
    assert_received {:requested_query, "Angular software development"}
  end

  test "skips technical fallback queries when the initial English result is relevant" do
    requester = fn url ->
      parsed_query = URI.parse(url).query || ""
      query = URI.decode_query(parsed_query)["q"] || ""
      send(self(), {:requested_query, query})

      {:ok,
       %{
         status: 200,
         body: ~s(<?xml version="1.0" encoding="utf-8" ?><rss version="2.0"><channel>
           <item><title>React</title><link>https://react.dev/</link><description>The library for web and native user interfaces.</description></item>
         </channel></rss>)
       }}
    end

    assert {:ok, [%{url: "https://react.dev/"}]} = WebSearch.search("React", requester: requester)

    assert_received {:requested_query, "React"}
    refute_received {:requested_query, "React web framework"}
    refute_received {:requested_query, "React software development"}
  end

  test "adds conservative fallback queries for low-quality two-term English searches" do
    requester = fn url ->
      parsed_query = URI.parse(url).query || ""
      query = URI.decode_query(parsed_query)["q"] || ""
      send(self(), {:requested_query, query})

      body =
        case query do
          "Phoenix LiveView documentation" ->
            ~s(<?xml version="1.0" encoding="utf-8" ?><rss version="2.0"><channel>
              <item><title>Phoenix LiveView documentation</title><link>https://hexdocs.pm/phoenix_live_view/</link><description>Phoenix LiveView official docs.</description></item>
            </channel></rss>)

          _other ->
            ~s(<?xml version="1.0" encoding="utf-8" ?><rss version="2.0"><channel>
              <item><title>Unrelated result</title><link>https://example.com/unrelated</link><description>Provider returned unrelated content.</description></item>
            </channel></rss>)
        end

      {:ok, %{status: 200, body: body}}
    end

    assert {:ok, [%{url: "https://hexdocs.pm/phoenix_live_view/"} | _rest]} =
             WebSearch.search("Phoenix LiveView", requester: requester)

    assert_received {:requested_query, "Phoenix LiveView"}
    assert_received {:requested_query, "Phoenix LiveView documentation"}
    assert_received {:requested_query, "Phoenix LiveView official"}
  end

  test "skips two-term fallback queries when the initial result includes both terms" do
    requester = fn url ->
      parsed_query = URI.parse(url).query || ""
      query = URI.decode_query(parsed_query)["q"] || ""
      send(self(), {:requested_query, query})

      {:ok,
       %{
         status: 200,
         body: ~s(<?xml version="1.0" encoding="utf-8" ?><rss version="2.0"><channel>
           <item><title>Phoenix LiveView guides</title><link>https://hexdocs.pm/phoenix_live_view/</link><description>Build real-time UI with Phoenix LiveView.</description></item>
         </channel></rss>)
       }}
    end

    assert {:ok, [%{url: "https://hexdocs.pm/phoenix_live_view/"}]} =
             WebSearch.search("Phoenix LiveView", requester: requester)

    assert_received {:requested_query, "Phoenix LiveView"}
    refute_received {:requested_query, "Phoenix LiveView documentation"}
    refute_received {:requested_query, "Phoenix LiveView official"}
  end

  test "searches connected katakana tokens with split fallback queries" do
    requester = fn url ->
      parsed_query = URI.parse(url).query || ""
      query = URI.decode_query(parsed_query)["q"] || ""
      send(self(), {:requested_query, query})

      body =
        case query do
          "ティール ピーター" ->
            ~s(<?xml version="1.0" encoding="utf-8" ?><rss version="2.0"><channel>
              <item><title>ピーター・ティール profile</title><link>https://example.com/thiel</link><description>投資家ピーター・ティールの人物情報。</description></item>
            </channel></rss>)

          _other ->
            ~s(<?xml version="1.0" encoding="utf-8" ?><rss version="2.0"><channel>
              <item><title>ピーターの出演作</title><link>https://example.com/actor</link><description>ピーターの人物情報。</description></item>
            </channel></rss>)
        end

      {:ok, %{status: 200, body: body}}
    end

    assert {:ok, [%{url: "https://example.com/thiel"}]} =
             WebSearch.search("ピーターティール", requester: requester)

    assert_received {:requested_query, "ピーターティール"}
    assert_received {:requested_query, "ティール ピーター"}
  end
end
