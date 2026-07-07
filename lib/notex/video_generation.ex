defmodule Notex.VideoGeneration do
  @moduledoc """
  ffmpeg-backed narrated MP4 generation for Studio video explainer artifacts.
  """

  @default_slide_duration 7
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
    File.write!(subtitle_path, ass_subtitle(slides, config))

    with {:ok, tts_executable} <- tts_executable(config),
         :ok <- write_narration(tts_executable, narration_text(slides), audio_path) do
      duration = length(slides) * config.slide_duration

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
    |> Enum.map(&slide_from_section(&1, title))
    |> Enum.reject(&is_nil/1)
    |> Enum.take(6)
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

  defp slide_from_section(section, fallback_title) do
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
        |> Enum.take(4)

      narration =
        narration_lines
        |> Enum.reverse()
        |> Enum.map(&clean_text/1)
        |> Enum.join(" ")
        |> blank_to(Enum.join([clean_text(heading) | bullets], ". "))

      %{
        title: clean_text(heading) |> blank_to(fallback_title),
        bullets: bullets,
        narration: narration
      }
    else
      _other -> nil
    end
  end

  defp fallback_slides(markdown, title) do
    lines =
      markdown
      |> String.split("\n")
      |> Enum.map(&clean_text/1)
      |> Enum.reject(&(&1 == "" or &1 == "---" or String.starts_with?(&1, "#")))
      |> Enum.map(&String.replace(&1, ~r/^\s*[-*]\s+/, ""))
      |> Enum.take(12)

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

  defp narration_text(slides) do
    slides
    |> Enum.map(& &1.narration)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp write_narration(tts_executable, text, audio_path) do
    args = ["-w", audio_path, text]

    case System.cmd(tts_executable, args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:tts_failed, status, error_snippet(output)}}
    end
  end

  defp subtitle_filter(subtitle_path), do: "subtitles='#{escape_filter_value(subtitle_path)}'"

  defp escape_filter_value(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace(":", "\\:")
    |> String.replace("'", "\\'")
  end

  defp ass_subtitle(slides, config) do
    events =
      slides
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {slide, index} ->
        start_time = index * config.slide_duration
        end_time = start_time + config.slide_duration
        variant = rem(index, 3)
        text = slide_ass_text(slide, variant)

        "Dialogue: 0,#{ass_timestamp(start_time)},#{ass_timestamp(end_time)},Slide,,0,0,0,,#{text}"
      end)

    """
    [Script Info]
    ScriptType: v4.00+
    PlayResX: 1280
    PlayResY: 720
    WrapStyle: 2

    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
    Style: Slide,#{ass_font_name(config.fontfile)},44,&H0018181B,&H0018181B,&H00FFFFFF,&HCCFFFFFF,0,0,0,0,100,100,0,0,4,0,0,7,88,88,70,1

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

  defp ass_font_name(fontfile) when is_binary(fontfile) do
    fontfile
    |> Path.basename()
    |> Path.rootname()
    |> String.replace("-", " ")
  end

  defp ass_font_name(_fontfile), do: "DejaVu Sans"

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
      tts_command:
        opts[:tts_command] ||
          System.get_env("NOTEX_TTS_COMMAND") ||
          Keyword.get(app_config, :tts_command) ||
          default_tts_command(),
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

  defp error_snippet(output) when byte_size(output) <= 1_500, do: output

  defp error_snippet(output) do
    "...#{String.slice(output, -1_500, 1_500)}"
  end

  defp default_fontfile do
    [
      "/usr/share/fonts/truetype/ubuntu/Ubuntu-R.ttf",
      "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
    ]
    |> Enum.find(&File.exists?/1)
  end

  defp default_tts_command do
    Enum.find(["espeak-ng", "espeak"], &System.find_executable/1)
  end
end
