defmodule Notex.WebSearch do
  @moduledoc """
  Web search and page extraction for source ingestion.
  """

  @search_url "https://www.bing.com/search"
  @user_agent "Notex/0.1 (+https://localhost/notex)"
  @max_results 20

  def search(query, opts \\ []) when is_binary(query) do
    query = String.trim(query)

    if query == "" do
      {:error, :empty_query}
    else
      case search_results(query, opts) do
        {:ok, results} -> {:ok, rank_phrase_matches(results, query)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def fetch_result(%{url: url, title: title} = result, opts \\ []) do
    with {:ok, body} <- request_body(url, opts),
         text when text != "" <- html_to_text(body) do
      title = clean_result_title(title)

      source_body =
        [
          "URL: #{url}",
          result[:snippet] && "Search snippet: #{result.snippet}",
          "",
          text
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n")

      {:ok, %{title: title, body: source_body}}
    else
      "" -> {:error, :empty_page}
      {:error, reason} -> {:error, reason}
    end
  end

  def result_id(url) when is_binary(url) do
    :sha256
    |> :crypto.hash(url)
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 12)
  end

  def parse_results(xml) when is_binary(xml) do
    ~r/<item\b[^>]*>(?<item>.*?)<\/item>/isu
    |> Regex.scan(xml, capture: :all_names)
    |> Enum.map(fn [item] ->
      url = item |> tag_text("link") |> normalize_result_url()
      title = tag_text(item, "title")

      %{
        id: result_id(url),
        title: clean_result_title(html_to_text(title)),
        url: url,
        snippet: item |> tag_text("description") |> html_to_text()
      }
    end)
    |> Enum.reject(&(&1.url == ""))
    |> Enum.uniq_by(& &1.url)
    |> Enum.take(@max_results)
  end

  def parse_html_results(html) when is_binary(html) do
    ~r/<li\b[^>]*class="[^"]*\bb_algo\b[^"]*"[^>]*>(?<item>.*?)<\/li>/isu
    |> Regex.scan(html, capture: :all_names)
    |> Enum.flat_map(fn [item] ->
      case Regex.named_captures(
             ~r/<h2[^>]*>.*?<a[^>]+href="(?<url>[^"]+)"[^>]*>(?<title>.*?)<\/a>/isu,
             item
           ) do
        %{"url" => url, "title" => title} ->
          url = normalize_result_url(url)
          snippet = item |> html_snippet() |> html_to_text()

          [
            %{
              id: result_id(url),
              title: clean_result_title(html_to_text(title)),
              url: url,
              snippet: snippet
            }
          ]

        _none ->
          []
      end
    end)
    |> Enum.reject(&(&1.url == "" or &1.title == ""))
    |> Enum.uniq_by(& &1.url)
    |> Enum.take(@max_results)
  end

  defp search_request_url(query) do
    @search_url <> "?" <> URI.encode_query(%{format: "rss", q: query})
  end

  defp html_search_request_url(query) do
    @search_url <> "?" <> URI.encode_query(%{q: query})
  end

  defp search_results(query, opts) do
    query
    |> search_queries()
    |> Enum.reduce({[], []}, fn search_query, {results, errors} ->
      rss_results =
        request_search_results(search_request_url(search_query.query), search_query, opts, :rss)

      html_results =
        request_search_results(
          html_search_request_url(search_query.query),
          search_query,
          opts,
          :html
        )

      case {rss_results, html_results} do
        {{:error, rss_reason}, {:error, html_reason}} ->
          {results, [html_reason, rss_reason | errors]}

        _other ->
          parsed_results =
            [rss_results, html_results]
            |> Enum.flat_map(fn
              {:ok, parsed_results} -> parsed_results
              {:error, _reason} -> []
            end)

          {results ++ parsed_results, errors}
      end
    end)
    |> case do
      {[], [reason | _errors]} ->
        {:error, reason}

      {results, _errors} ->
        results =
          results
          |> merge_duplicate_results()
          |> prefer_phrase_matches(query)
          |> Enum.take(result_limit(opts))
          |> Enum.map(&strip_search_metadata/1)

        {:ok, results}
    end
  end

  defp request_search_results(url, search_query, opts, parser) do
    case request_body(url, opts) do
      {:ok, body} ->
        parsed_results =
          body
          |> parse_search_body(parser)
          |> Enum.map(&Map.put(&1, :search_weight, search_query.weight))

        {:ok, parsed_results}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_search_body(body, :rss), do: parse_results(body)
  defp parse_search_body(body, :html), do: parse_html_results(body)

  defp search_queries(query) do
    tokens = query_tokens(query)
    middle_dot_queries = middle_dot_search_queries(tokens, 3)
    modifier_queries = modifier_search_queries(tokens)
    entity_queries = entity_search_queries(tokens)
    compact_split_queries = compact_katakana_split_queries(tokens, 3)

    [
      weighted_query(plain_search_query(tokens), 3)
      | middle_dot_queries ++ modifier_queries ++ entity_queries ++ compact_split_queries
    ]
    |> Enum.map(fn query -> %{query | query: String.trim(query.query)} end)
    |> Enum.reject(&(&1.query == ""))
    |> Enum.reduce([], fn query, queries ->
      if Enum.any?(queries, &(&1.query == query.query)) do
        queries
      else
        queries ++ [query]
      end
    end)
  end

  defp query_tokens(query) do
    query
    |> String.split(~r/[\s　]+/u, trim: true)
    |> Enum.flat_map(&query_token_terms/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp query_token_terms(token) do
    token = clean_query_token(token)

    case katakana_entity_with_suffix(token) do
      {entity, suffix} -> [entity | suffix_query_tokens(suffix)]
      :none -> [token]
    end
  end

  defp clean_query_token(token) do
    token
    |> String.trim()
    |> String.replace(~r/^[^\p{L}\p{N}ー・･]+|[^\p{L}\p{N}ー・･]+$/u, "")
  end

  defp katakana_entity_with_suffix(token) do
    cond do
      captures =
          Regex.named_captures(
            ~r/^(?<entity>[\p{Katakana}ー]+[・･][\p{Katakana}ー]+)(?<suffix>.*)$/u,
            token
          ) ->
        {captures["entity"], captures["suffix"]}

      captures =
          Regex.named_captures(
            ~r/^(?<entity>[\p{Katakana}ー]{6,})(?<suffix>[^\p{Katakana}ー].*)$/u,
            token
          ) ->
        {captures["entity"], captures["suffix"]}

      true ->
        :none
    end
  end

  defp suffix_query_tokens(suffix) do
    suffix
    |> String.replace(~r/^(?:について|とは|とか|って|は|が|を|に|へ|で|と|も|や|の)+/u, "")
    |> String.split(~r/[^\p{L}\p{N}ー・･]+/u, trim: true)
    |> Enum.map(&clean_query_token/1)
    |> Enum.reject(&stopword_query_token?/1)
  end

  defp stopword_query_token?(token) do
    token in [
      "",
      "について",
      "とは",
      "とか",
      "って",
      "は",
      "が",
      "を",
      "に",
      "へ",
      "で",
      "と",
      "も",
      "や",
      "の",
      "何",
      "なに",
      "何者",
      "誰"
    ]
  end

  defp plain_search_query(tokens) do
    tokens
    |> Enum.map(&String.replace(&1, ~r/[・･]/u, " "))
    |> Enum.join(" ")
  end

  defp weighted_query(query, weight), do: %{query: query, weight: weight}

  defp middle_dot_search_queries(tokens, weight) do
    tokens
    |> Enum.with_index()
    |> Enum.filter(fn {token, _index} -> String.match?(token, ~r/[・･]/u) end)
    |> Enum.flat_map(fn {token, index} ->
      parts = middle_dot_parts(token)
      compact = Enum.join(parts, "")
      reversed = parts |> Enum.reverse() |> Enum.join(" ")

      [
        weighted_query(replace_token_query(tokens, index, compact), weight),
        weighted_query(replace_token_query(tokens, index, reversed), weight)
      ]
    end)
  end

  defp modifier_search_queries(tokens) do
    middle_dot_modifier_queries(tokens) ++ compact_katakana_modifier_queries(tokens)
  end

  defp middle_dot_modifier_queries(tokens) do
    tokens
    |> Enum.with_index()
    |> Enum.filter(fn {token, _index} -> String.match?(token, ~r/[・･]/u) end)
    |> Enum.flat_map(fn {token, index} ->
      modifiers = modifier_tokens(tokens, index)
      parts = middle_dot_parts(token)
      compact = Enum.join(parts, "")
      spaced = Enum.join(parts, " ")
      reversed = parts |> Enum.reverse() |> Enum.join(" ")

      for modifier <- modifiers,
          replacement <- [spaced, compact, reversed] do
        weighted_query(plain_search_query([replacement, modifier]), 2)
      end
    end)
  end

  defp compact_katakana_modifier_queries(tokens) do
    tokens
    |> Enum.with_index()
    |> Enum.filter(fn {token, _index} -> connected_katakana_token?(token) end)
    |> Enum.flat_map(fn {token, index} ->
      modifiers = modifier_tokens(tokens, index)

      token
      |> katakana_split_pairs()
      |> Enum.flat_map(fn {left, right} ->
        reversed = Enum.join([right, left], " ")

        for modifier <- modifiers,
            replacement <- [token, reversed] do
          weighted_query(plain_search_query([replacement, modifier]), 2)
        end
      end)
    end)
  end

  defp entity_search_queries(tokens) do
    middle_dot_entity_queries(tokens) ++ compact_katakana_entity_queries(tokens)
  end

  defp middle_dot_entity_queries(tokens) do
    tokens
    |> Enum.filter(&String.match?(&1, ~r/[・･]/u))
    |> Enum.flat_map(fn token ->
      parts = middle_dot_parts(token)

      [
        weighted_query(Enum.join(parts, ""), 1),
        weighted_query(parts |> Enum.reverse() |> Enum.join(" "), 1)
      ]
    end)
  end

  defp compact_katakana_entity_queries(tokens) do
    tokens
    |> Enum.filter(&connected_katakana_token?/1)
    |> Enum.flat_map(fn token ->
      token
      |> katakana_split_pairs()
      |> Enum.map(fn {left, right} -> weighted_query(Enum.join([right, left], " "), 1) end)
    end)
  end

  defp compact_katakana_split_queries(tokens, weight) do
    tokens
    |> Enum.with_index()
    |> Enum.filter(fn {token, _index} -> connected_katakana_token?(token) end)
    |> Enum.flat_map(fn {token, index} ->
      token
      |> katakana_split_pairs()
      |> Enum.flat_map(fn {left, right} ->
        reversed = Enum.join([right, left], " ")

        [
          weighted_query(replace_token_query(tokens, index, reversed), weight)
        ]
      end)
    end)
  end

  defp modifier_tokens(tokens, entity_index) do
    tokens
    |> List.delete_at(entity_index)
    |> Enum.reject(&(&1 == ""))
  end

  defp replace_token_query(tokens, index, replacement) do
    tokens
    |> List.replace_at(index, replacement)
    |> plain_search_query()
  end

  defp middle_dot_parts(token) do
    token
    |> String.split(~r/[・･]/u, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp connected_katakana_token?(token) do
    String.length(token) >= 6 and Regex.match?(~r/^[\p{Katakana}ー]+$/u, token) and
      not String.match?(token, ~r/[・･]/u)
  end

  defp katakana_split_pairs(token) do
    graphemes = String.graphemes(token)
    length = length(graphemes)

    3..(length - 3)//1
    |> Enum.map(fn index -> Enum.split(graphemes, index) end)
    |> Enum.map(fn {left, right} -> {Enum.join(left), Enum.join(right)} end)
    |> Enum.reject(fn {_left, right} -> invalid_katakana_split_start?(right) end)
  end

  defp invalid_katakana_split_start?(<<first::utf8, _rest::binary>>) do
    <<first::utf8>> in ["ー", "ァ", "ィ", "ゥ", "ェ", "ォ", "ャ", "ュ", "ョ", "ッ"]
  end

  defp rank_phrase_matches(results, query) do
    phrases = connected_phrases(query)

    if phrases == [] do
      results
    else
      Enum.sort_by(results, &phrase_match_score(&1, phrases), :desc)
    end
  end

  defp prefer_phrase_matches(results, query) do
    phrases = connected_phrases(query)

    if phrases == [] do
      results
    else
      matching_results = Enum.filter(results, &phrase_match?(&1, phrases))

      results =
        if matching_results == [] do
          results
        else
          modifier_results = modifier_matching_results(matching_results, query)
          if modifier_results == [], do: matching_results, else: modifier_results
        end

      rank_search_results(results, query)
    end
  end

  defp modifier_matching_results(results, query) do
    modifiers = modifier_terms(query)

    if modifiers == [] do
      results
    else
      high_weight_results = Enum.filter(results, &(Map.get(&1, :search_weight, 0) >= 2))
      if high_weight_results == [], do: results, else: high_weight_results
    end
  end

  defp rank_search_results(results, query) do
    modifiers = modifier_terms(query)

    Enum.sort_by(
      results,
      fn result ->
        {
          modifier_match_count(result, modifiers),
          Map.get(result, :search_weight, 0),
          -Map.get(result, :search_index, 0)
        }
      end,
      :desc
    )
  end

  defp modifier_terms(query) do
    query
    |> query_tokens()
    |> Enum.reject(&(String.match?(&1, ~r/[・･]/u) or connected_katakana_token?(&1)))
    |> Enum.map(&normalize_search_text/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp middle_dot_phrases(query) do
    query
    |> query_tokens()
    |> Enum.filter(&String.match?(&1, ~r/[・･]/u))
  end

  defp connected_phrases(query) do
    middle_dot_variants =
      query
      |> middle_dot_phrases()
      |> Enum.flat_map(fn phrase -> [phrase, String.replace(phrase, ~r/[・･]/u, "")] end)

    katakana_phrases =
      query
      |> query_tokens()
      |> Enum.filter(&connected_katakana_token?/1)

    (middle_dot_variants ++ katakana_phrases)
    |> Enum.uniq()
  end

  defp phrase_match?(result, phrases) do
    text = searchable_result_text(result)

    Enum.any?(phrases, fn phrase ->
      normalized_phrase = normalize_search_text(phrase)

      parts =
        phrase
        |> String.split(~r/[・･]/u, trim: true)
        |> Enum.map(&normalize_search_text/1)

      String.contains?(text, normalized_phrase) or Enum.all?(parts, &String.contains?(text, &1))
    end)
  end

  defp phrase_match_score(result, phrases) do
    if phrase_match?(result, phrases), do: 1, else: 0
  end

  defp modifier_match_count(_result, []), do: 0

  defp modifier_match_count(result, modifiers) do
    text = searchable_result_text(result)
    Enum.count(modifiers, &String.contains?(text, &1))
  end

  defp merge_duplicate_results(results) do
    results
    |> Enum.with_index()
    |> Enum.group_by(fn {result, _index} -> result.url end)
    |> Enum.map(fn {_url, entries} ->
      {first, first_index} = Enum.min_by(entries, fn {_result, index} -> index end)

      max_weight =
        entries
        |> Enum.map(fn {result, _index} -> Map.get(result, :search_weight, 0) end)
        |> Enum.max()

      first
      |> Map.put(:search_index, first_index)
      |> Map.put(:search_weight, max_weight)
    end)
    |> Enum.sort_by(& &1.search_index)
  end

  defp strip_search_metadata(result) do
    Map.drop(result, [:search_index, :search_weight])
  end

  defp searchable_result_text(result) do
    [result.title, result.snippet, result.url]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> normalize_search_text()
  end

  defp normalize_search_text(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[・･]/u, "")
    |> String.replace(~r/\s+/u, "")
  end

  def html_to_text(html) when is_binary(html) do
    html
    |> String.replace(~r/<script\b[^>]*>.*?<\/script>/isu, " ")
    |> String.replace(~r/<style\b[^>]*>.*?<\/style>/isu, " ")
    |> String.replace(~r/<noscript\b[^>]*>.*?<\/noscript>/isu, " ")
    |> String.replace(~r/<(br|p|div|li|h[1-6])\b[^>]*>/iu, "\n")
    |> String.replace(~r/<[^>]+>/u, " ")
    |> decode_entities()
    |> String.replace(~r/[ \t]+/u, " ")
    |> String.replace(~r/\n[ \t]+/u, "\n")
    |> String.replace(~r/\n{3,}/u, "\n\n")
    |> String.trim()
  end

  defp clean_result_title(title) when is_binary(title) do
    title
    |> String.trim()
    |> String.replace(~r/\s*(?:\.{3}|…)\s*$/u, "")
    |> String.trim()
  end

  defp tag_text(xml, tag) do
    pattern = Regex.compile!("<#{tag}\\b[^>]*>(?<text>.*?)</#{tag}>", "isu")

    case Regex.named_captures(pattern, xml) do
      %{"text" => text} -> text
      _none -> ""
    end
  end

  defp normalize_result_url("//" <> rest), do: normalize_result_url("https://" <> rest)

  defp normalize_result_url(url) do
    url = decode_entities(url)

    case URI.parse(url) do
      %URI{host: host, path: "/ck/a", query: query}
      when host in ["www.bing.com", "bing.com"] and is_binary(query) ->
        query
        |> URI.decode_query()
        |> Map.get("u", "")
        |> decode_bing_redirect_url()
        |> normalize_result_url()

      %URI{host: "duckduckgo.com", query: query} when is_binary(query) ->
        query
        |> URI.decode_query()
        |> Map.get("uddg", "")

      %URI{scheme: scheme} when scheme in ["http", "https"] ->
        url

      _other ->
        ""
    end
  end

  defp html_snippet(item) do
    case Regex.run(
           ~r/<div[^>]*class="[^"]*\bb_caption\b[^"]*"[^>]*>(?<caption>.*?)<\/div>/isu,
           item,
           capture: :all_names
         ) do
      [caption] -> caption
      _none -> ""
    end
  end

  defp decode_bing_redirect_url("a1" <> encoded_url) do
    encoded_url
    |> Base.url_decode64(padding: false)
    |> case do
      {:ok, url} -> url
      :error -> ""
    end
  end

  defp decode_bing_redirect_url(url), do: url

  defp request_body(url, opts) do
    response =
      try do
        requester(opts).(url)
      rescue
        FunctionClauseError -> {:error, :unhandled_request}
      end

    case response do
      {:ok, %{status: status, body: body}} when status in 200..299 and is_binary(body) ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp requester(opts) do
    app_config = Application.get_env(:notex, __MODULE__, [])
    opts[:requester] || Keyword.get(app_config, :requester, &default_requester/1)
  end

  defp result_limit(opts) do
    opts
    |> Keyword.get(:limit, @max_results)
    |> case do
      limit when is_integer(limit) -> limit
      _other -> @max_results
    end
    |> max(1)
    |> min(@max_results)
  end

  defp default_requester(url) do
    Req.get(url,
      headers: [{"user-agent", @user_agent}],
      receive_timeout: 20_000,
      redirect: true
    )
  end

  defp decode_entities(text) do
    text
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&apos;", "'")
    |> then(fn text ->
      Regex.replace(~r/&#x([0-9a-f]+);/iu, text, fn _, hex ->
        hex |> String.to_integer(16) |> List.wrap() |> List.to_string()
      end)
    end)
    |> then(fn text ->
      Regex.replace(~r/&#(\d+);/u, text, fn _, int ->
        int |> String.to_integer() |> List.wrap() |> List.to_string()
      end)
    end)
  end
end
