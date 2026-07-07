defmodule Notex.VideoGeneration do
  @moduledoc """
  ffmpeg-backed narrated MP4 generation for Studio video explainer artifacts.
  """

  @default_slide_duration 7
  @max_slides 12
  @default_size "1280x720"

  def generate(markdown, opts \\ []) when is_binary(markdown) do
    config = config(opts)

    with {:ok, executable} <- executable(config.command),
         {:ok, path} <- config.runner.(executable, markdown, config),
         {:ok, bytes} <- File.read(path) do
      {:ok,
       %{
         content: "data:video/mp4;base64,#{Base.encode64(bytes)}",
         mime_type: "video/mp4",
         meta: %{
           "provider" => "ffmpeg",
           "command" => config.command,
           "slide_duration" => config.slide_duration,
           "size" => config.size
         }
       }}
    end
  end

  def generate_with_ffmpeg(executable, markdown, config) do
    temp_dir = Path.join(System.tmp_dir!(), "notex-video-#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)
    output_path = Path.join(temp_dir, "explainer.mp4")
    subtitle_path = Path.join(temp_dir, "explainer.ass")
    audio_path = Path.join(temp_dir, "narration.wav")
    slides = video_slides(markdown)

    with {:ok, tts_executable} <- tts_executable(config),
         {:ok, slide_audio_paths} <-
           write_slide_narrations(tts_executable, slides, temp_dir, config),
         :ok <- concat_audio(executable, slide_audio_paths, audio_path, temp_dir),
         {:ok, slide_durations} <- audio_durations(executable, slide_audio_paths) do
      File.write!(subtitle_path, ass_subtitle(slides, config, slide_durations))
      duration = total_slide_duration(slides, config, slide_durations)

      args = [
        "-y",
        "-f",
        "lavfi",
        "-i",
        "color=c=0xf8fafc:s=#{config.size}:d=#{duration}",
        "-i",
        audio_path,
        "-vf",
        subtitle_filter(subtitle_path),
        "-c:v",
        "libx264",
        "-c:a",
        "aac",
        "-b:a",
        "128k",
        "-pix_fmt",
        "yuv420p",
        "-shortest",
        "-movflags",
        "+faststart",
        output_path
      ]

      case System.cmd(executable, args, stderr_to_stdout: true) do
        {_output, 0} -> {:ok, output_path}
        {output, status} -> {:error, {:ffmpeg_failed, status, error_snippet(output)}}
      end
    end
  end

  defp video_slides(markdown) do
    title = video_title(markdown)

    markdown
    |> String.split(~r/^\s*##\s+/m, trim: true)
    |> Enum.reject(&String.starts_with?(&1, "#"))
    |> Enum.flat_map(&slides_from_section(&1, title))
    |> Enum.take(@max_slides)
    |> case do
      [] -> fallback_slides(markdown, title)
      lines -> lines
    end
  end

  defp video_title(markdown) do
    case Regex.run(~r/^\s*#\s+(.+)$/m, markdown, capture: :all_but_first) do
      [title] -> clean_text(title)
      _other -> "Notex Video Explainer"
    end
  end

  defp slides_from_section(section, fallback_title) do
    lines =
      section
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    with [heading | rest] <- lines do
      {narration_lines, visual_lines} =
        rest
        |> Enum.reduce({[], []}, fn line, {narration, visual} ->
          cond do
            String.match?(line, ~r/^Narration\s*:/i) ->
              {[String.replace(line, ~r/^Narration\s*:\s*/i, "") | narration], visual}

            narration != [] and not String.starts_with?(line, ["-", "*"]) ->
              {[line | narration], visual}

            true ->
              {narration, [line | visual]}
          end
        end)

      bullets =
        visual_lines
        |> Enum.reverse()
        |> Enum.map(&String.replace(&1, ~r/^\s*[-*]\s+/, ""))
        |> Enum.map(&clean_text/1)
        |> Enum.reject(&(&1 == "" or String.match?(&1, ~r/^Narration\s*:/i)))

      narration =
        narration_lines
        |> Enum.reverse()
        |> Enum.map(&clean_text/1)
        |> Enum.join(" ")
        |> blank_to(Enum.join([clean_text(heading) | bullets], ". "))

      heading = clean_text(heading) |> blank_to(fallback_title)
      slide_chunks = if bullets == [], do: [[heading]], else: Enum.chunk_every(bullets, 4)

      slide_chunks
      |> Enum.with_index(1)
      |> Enum.map(fn {chunk, index} ->
        %{
          title: section_slide_title(heading, index, length(slide_chunks)),
          bullets: chunk,
          narration: section_slide_narration(narration, chunk)
        }
      end)
    else
      _other -> []
    end
  end

  defp section_slide_title(heading, _index, 1), do: heading
  defp section_slide_title(heading, index, _count), do: "#{heading} #{index}"

  defp section_slide_narration(narration, bullets) do
    bullets_text = Enum.join(bullets, "。")

    cond do
      narration == "" -> bullets_text
      bullets_text == "" -> narration
      String.contains?(narration, bullets_text) -> narration
      true -> "#{bullets_text}。#{narration}"
    end
  end

  defp fallback_slides(markdown, title) do
    lines =
      markdown
      |> String.split("\n")
      |> Enum.map(&clean_text/1)
      |> Enum.reject(&(&1 == "" or &1 == "---" or String.starts_with?(&1, "#")))
      |> Enum.map(&String.replace(&1, ~r/^\s*[-*]\s+/, ""))
      |> Enum.take(@max_slides * 3)

    lines
    |> Enum.chunk_every(3)
    |> Enum.with_index(1)
    |> Enum.map(fn {bullets, index} ->
      %{
        title: if(index == 1, do: title, else: "Part #{index}"),
        bullets: bullets,
        narration: Enum.join(bullets, ". ")
      }
    end)
  end

  defp tts_narration_for_slide(slide) do
    [slide.title | slide.bullets]
    |> Kernel.++([slide.narration])
    |> Enum.map(&clean_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.join("。")
    |> normalize_tts_text()
  end

  defp normalize_tts_text(text) do
    text
    |> String.replace(~r/\bPayPal\b/i, "ペイパル")
    |> String.replace(~r/\beBay\b/i, "イーベイ")
    |> String.replace(~r/\bOpenAI\b/i, "オープンエーアイ")
    |> String.replace(~r/\bPalantir\b/i, "パランティア")
    |> String.replace(~r/\bFacebook\b/i, "フェイスブック")
    |> String.replace(~r/\bYouTube\b/i, "ユーチューブ")
    |> String.replace(~r/\bLinkedIn\b/i, "リンクトイン")
    |> String.replace(~r/\bIPO\b/i, "アイピーオー")
    |> String.replace(~r/\bAI\b/i, "エーアイ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp write_slide_narrations(tts_executable, slides, temp_dir, config) do
    slides
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {slide, index}, {:ok, paths} ->
      audio_path = Path.join(temp_dir, "narration-#{format_file_index(index)}.wav")
      text = tts_narration_for_slide(slide)

      case write_narration(tts_executable, text, audio_path, config) do
        :ok -> {:cont, {:ok, [audio_path | paths]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, paths} -> {:ok, Enum.reverse(paths)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_narration(tts_executable, text, audio_path, config) do
    case Path.basename(tts_executable) do
      "open_jtalk" -> write_open_jtalk_narration(tts_executable, text, audio_path, config)
      _other -> write_espeak_narration(tts_executable, text, audio_path, config)
    end
  end

  defp concat_audio(_executable, [audio_path], output_path, _temp_dir) do
    File.cp!(audio_path, output_path)
    :ok
  end

  defp concat_audio(executable, audio_paths, output_path, temp_dir) do
    list_path = Path.join(temp_dir, "narration-list.txt")

    list_body =
      audio_paths
      |> Enum.map_join("\n", fn path -> "file '#{escape_concat_path(path)}'" end)

    File.write!(list_path, list_body)

    args = [
      "-y",
      "-f",
      "concat",
      "-safe",
      "0",
      "-i",
      list_path,
      "-acodec",
      "pcm_s16le",
      output_path
    ]

    case System.cmd(executable, args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:ffmpeg_failed, status, error_snippet(output)}}
    end
  end

  defp escape_concat_path(path), do: String.replace(path, "'", "'\\''")

  defp audio_durations(executable, audio_paths) do
    audio_paths
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, durations} ->
      case wav_duration(executable, path) do
        {:ok, duration} -> {:cont, {:ok, [duration | durations]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, durations} -> {:ok, Enum.reverse(durations)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp wav_duration(executable, path) do
    args = [
      "-i",
      path,
      "-f",
      "null",
      "-"
    ]

    case System.cmd(executable, args, stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, duration_from_ffmpeg_output(output) || @default_slide_duration}

      {output, status} ->
        {:error, {:ffmpeg_failed, status, error_snippet(output)}}
    end
  end

  defp duration_from_ffmpeg_output(output) do
    case Regex.run(~r/Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)/, output, capture: :all_but_first) do
      [hours, minutes, seconds] ->
        String.to_integer(hours) * 3_600 + String.to_integer(minutes) * 60 +
          ceil(String.to_float(seconds)) + 1

      _other ->
        nil
    end
  end

  defp write_espeak_narration(tts_executable, text, audio_path, config) do
    args =
      []
      |> append_tts_option("-v", config.tts_voice)
      |> append_tts_option("-s", config.tts_speed)
      |> Kernel.++(["-w", audio_path, text])

    case System.cmd(tts_executable, args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:tts_failed, status, error_snippet(output)}}
    end
  end

  defp write_open_jtalk_narration(tts_executable, text, audio_path, config) do
    with {:ok, dictionary_path} <-
           existing_tts_path(config.open_jtalk_dictionary, "Open JTalk dictionary"),
         {:ok, voice_path} <- existing_tts_path(config.open_jtalk_voice, "Open JTalk voice") do
      text_path = Path.rootname(audio_path) <> ".txt"
      File.write!(text_path, text)

      args =
        [
          "-x",
          dictionary_path,
          "-m",
          voice_path,
          "-r",
          to_string(config.open_jtalk_rate),
          "-ow",
          audio_path,
          text_path
        ]

      case System.cmd(tts_executable, args, stderr_to_stdout: true) do
        {_output, 0} -> :ok
        {output, status} -> {:error, {:tts_failed, status, error_snippet(output)}}
      end
    end
  end

  defp existing_tts_path(nil, label), do: {:error, {:missing_tts_resource, label}}

  defp existing_tts_path(path, label) do
    if File.exists?(path) do
      {:ok, path}
    else
      {:error, {:missing_tts_resource, "#{label}: #{path}"}}
    end
  end

  defp append_tts_option(args, _option, nil), do: args
  defp append_tts_option(args, option, value), do: args ++ [option, to_string(value)]

  defp subtitle_filter(subtitle_path), do: "subtitles='#{escape_filter_value(subtitle_path)}'"

  defp escape_filter_value(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace(":", "\\:")
    |> String.replace("'", "\\'")
  end

  defp ass_subtitle(slides, config, slide_durations) do
    events =
      slides
      |> Enum.with_index()
      |> Enum.reduce({0, []}, fn {slide, index}, {start_time, events} ->
        slide_duration =
          slide_durations
          |> duration_at(index)
          |> Kernel.||(slide_duration(slide, config))

        end_time = start_time + slide_duration
        variant = rem(index, 3)
        text = slide_ass_text(slide, variant)

        event =
          "Dialogue: 0,#{ass_timestamp(start_time)},#{ass_timestamp(end_time)},Slide,,0,0,0,,#{text}"

        {end_time, [event | events]}
      end)
      |> elem(1)
      |> Enum.reverse()
      |> Enum.join("\n")

    """
    [Script Info]
    ScriptType: v4.00+
    PlayResX: 1280
    PlayResY: 720
    WrapStyle: 2

    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
    Style: Slide,#{config.font_name},44,&H0018181B,&H0018181B,&H00FFFFFF,&HCCFFFFFF,0,0,0,0,100,100,0,0,4,0,0,7,88,88,70,1

    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    #{events}
    """
  end

  defp slide_ass_text(slide, variant) do
    accent =
      case variant do
        0 -> "{\\c&H1D4F91&}■{\\c&H18181B&}"
        1 -> "{\\c&H2F7D52&}●{\\c&H18181B&}"
        _other -> "{\\c&H7A4A9E&}◆{\\c&H18181B&}"
      end

    bullets =
      slide.bullets
      |> Enum.flat_map(&wrap_line/1)
      |> Enum.take(8)
      |> Enum.map_join("\\N", &"  #{escape_ass_text(&1)}")

    title =
      slide.title
      |> clean_text()
      |> wrap_line(24)
      |> Enum.take(2)
      |> Enum.join("\\N")
      |> escape_ass_text()

    [accent, "{\\fs56\\b1}#{title}{\\b0\\fs44}", bullets]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\\N\\N")
  end

  defp wrap_line(line, width \\ 32) do
    line
    |> String.graphemes()
    |> Enum.chunk_every(width)
    |> Enum.map(&Enum.join/1)
  end

  defp clean_text(text) do
    text
    |> String.replace(~r/\s*\[[^\]]+\]/, "")
    |> String.replace(~r/^\s*#+\s*/, "")
    |> String.trim()
  end

  defp blank_to("", fallback), do: fallback
  defp blank_to(value, _fallback), do: value

  defp duration_at(nil, _index), do: nil
  defp duration_at(durations, index), do: Enum.at(durations, index)

  defp total_slide_duration(slides, config, slide_durations) do
    slides
    |> Enum.with_index()
    |> Enum.map(fn {slide, index} ->
      duration_at(slide_durations, index) || slide_duration(slide, config)
    end)
    |> Enum.sum()
  end

  defp slide_duration(slide, config) do
    max(config.slide_duration, estimated_narration_seconds(tts_narration_for_slide(slide)))
  end

  defp estimated_narration_seconds(text) do
    grapheme_count = text |> String.graphemes() |> length()
    max(4, ceil(grapheme_count / 5) + 2)
  end

  defp format_file_index(index) do
    index
    |> Integer.to_string()
    |> String.pad_leading(3, "0")
  end

  defp escape_ass_text(text) do
    text
    |> String.replace("\\", "\\\\")
    |> String.replace("{", "\\{")
    |> String.replace("}", "\\}")
  end

  defp ass_timestamp(duration) do
    duration = max(duration, 1)
    seconds = rem(duration, 60)
    minutes = div(duration, 60) |> rem(60)
    hours = div(duration, 3_600)
    "#{hours}:#{pad2(minutes)}:#{pad2(seconds)}.00"
  end

  defp pad2(number) when number < 10, do: "0#{number}"
  defp pad2(number), do: Integer.to_string(number)

  defp executable(command) do
    case System.find_executable(command) do
      nil -> {:error, {:missing_executable, command}}
      path -> {:ok, path}
    end
  end

  defp tts_executable(%{tts_command: nil}), do: {:error, :missing_tts_command}
  defp tts_executable(%{tts_command: command}), do: executable(command)

  defp config(opts) do
    app_config = Application.get_env(:notex, Notex.VideoGeneration, [])

    %{
      command:
        opts[:command] ||
          System.get_env("NOTEX_FFMPEG_COMMAND") ||
          Keyword.get(app_config, :ffmpeg_command, "ffmpeg"),
      slide_duration:
        opts[:slide_duration] ||
          env_integer("NOTEX_VIDEO_SLIDE_SECONDS") ||
          Keyword.get(app_config, :slide_duration, @default_slide_duration),
      size:
        opts[:size] ||
          System.get_env("NOTEX_VIDEO_SIZE") ||
          Keyword.get(app_config, :size, @default_size),
      fontfile:
        opts[:fontfile] ||
          System.get_env("NOTEX_VIDEO_FONTFILE") ||
          Keyword.get(app_config, :fontfile, default_fontfile()),
      font_name:
        opts[:font_name] ||
          System.get_env("NOTEX_VIDEO_FONT_NAME") ||
          Keyword.get(app_config, :font_name, default_font_name()),
      tts_command:
        opts[:tts_command] ||
          System.get_env("NOTEX_TTS_COMMAND") ||
          Keyword.get(app_config, :tts_command) ||
          default_tts_command(),
      tts_voice:
        opts[:tts_voice] ||
          System.get_env("NOTEX_TTS_VOICE") ||
          Keyword.get(app_config, :tts_voice, "ja"),
      tts_speed:
        opts[:tts_speed] ||
          env_integer("NOTEX_TTS_SPEED") ||
          Keyword.get(app_config, :tts_speed, 135),
      open_jtalk_dictionary:
        opts[:open_jtalk_dictionary] ||
          System.get_env("NOTEX_OPEN_JTALK_DICTIONARY") ||
          Keyword.get(app_config, :open_jtalk_dictionary, default_open_jtalk_dictionary()),
      open_jtalk_voice:
        opts[:open_jtalk_voice] ||
          System.get_env("NOTEX_OPEN_JTALK_VOICE") ||
          Keyword.get(app_config, :open_jtalk_voice, default_open_jtalk_voice()),
      open_jtalk_rate:
        opts[:open_jtalk_rate] ||
          env_number("NOTEX_OPEN_JTALK_RATE") ||
          Keyword.get(app_config, :open_jtalk_rate, 1.0),
      runner:
        opts[:runner] ||
          Keyword.get(app_config, :runner, &__MODULE__.generate_with_ffmpeg/3)
    }
  end

  defp env_integer(name) do
    case System.get_env(name) do
      nil -> nil
      value -> String.to_integer(value)
    end
  rescue
    ArgumentError -> nil
  end

  defp env_number(name) do
    case System.get_env(name) do
      nil ->
        nil

      value ->
        case Float.parse(value) do
          {number, ""} -> number
          _other -> nil
        end
    end
  end

  defp error_snippet(output) when byte_size(output) <= 1_500, do: output

  defp error_snippet(output) do
    "...#{String.slice(output, -1_500, 1_500)}"
  end

  defp default_fontfile do
    [
      "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
      "/usr/share/fonts/opentype/noto/NotoSansCJKjp-Regular.otf",
      "/usr/share/fonts/truetype/noto/NotoSansJP-Regular.ttf",
      "/usr/share/fonts/truetype/fonts-japanese-gothic.ttf",
      "/usr/share/fonts/truetype/ubuntu/Ubuntu-R.ttf",
      "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
    ]
    |> Enum.find(&File.exists?/1)
  end

  defp default_font_name do
    [
      "Noto Sans CJK JP",
      "Noto Sans JP",
      "IPAexGothic",
      "TakaoGothic",
      "DejaVu Sans"
    ]
    |> Enum.find("DejaVu Sans", &font_available?/1)
  end

  defp font_available?(font_name) do
    case System.cmd("fc-match", [font_name], stderr_to_stdout: true) do
      {match, 0} -> String.contains?(String.downcase(match), String.downcase(font_name))
      _other -> false
    end
  rescue
    ErlangError -> false
  end

  defp default_tts_command do
    Enum.find(["open_jtalk", "espeak-ng", "espeak"], &System.find_executable/1)
  end

  defp default_open_jtalk_dictionary do
    [
      "/var/lib/mecab/dic/open-jtalk/naist-jdic",
      "/usr/share/open_jtalk/open_jtalk_dic_utf_8-1.11",
      "/usr/share/open_jtalk/open_jtalk_dic_utf_8"
    ]
    |> Enum.find(&File.exists?/1)
  end

  defp default_open_jtalk_voice do
    [
      "/usr/share/hts-voice/nitech-jp-atr503-m001/nitech_jp_atr503_m001.htsvoice",
      "/usr/share/hts-voice/mei/mei_normal.htsvoice"
    ]
    |> Enum.find(&File.exists?/1)
  end
end
