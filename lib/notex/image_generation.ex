defmodule Notex.ImageGeneration do
  @moduledoc """
  Codex app-server backed image generation for Studio image artifacts.
  """

  @default_model "gpt-5.5"
  @default_reasoning_effort "low"
  @default_timeout 240_000
  @max_json_line_length 8_388_608

  def generate(prompt, opts \\ []) when is_binary(prompt) do
    config = config(opts)

    with {:ok, image_base64, meta} <- config.app_server.(prompt, config) do
      {:ok,
       %{
         content: "data:image/png;base64,#{image_base64}",
         mime_type: "image/png",
         meta:
           Map.merge(
             %{
               "provider" => "codex_app_server",
               "model" => config.model,
               "reasoning_effort" => config.reasoning_effort
             },
             meta
           )
       }}
    end
  end

  def status do
    config = config([])

    %{
      provider: "codex_app_server",
      command: config.command,
      model: config.model,
      reasoning_effort: config.reasoning_effort,
      configured?: match?({:ok, _path}, executable(config.command))
    }
  end

  def generate_with_app_server(prompt, config) do
    with {:ok, executable} <- executable(config.command) do
      run_turn(executable, config, prompt)
    end
  end

  defp run_turn(executable, config, prompt) do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        {:args, ["app-server"]},
        {:line, @max_json_line_length}
      ])

    try do
      with :ok <- initialize(port, config.timeout),
           :ok <- ensure_image_generation_capability(port, config.timeout),
           {:ok, thread_id} <- start_thread(port, config),
           {:ok, _turn} <- start_turn(port, config, thread_id, prompt),
           {:ok, image_base64, meta} <- await_image_generation(port, config.timeout, nil) do
        {:ok, image_base64, meta}
      end
    after
      close_port(port)
    end
  end

  defp initialize(port, timeout) do
    send_message(port, %{
      method: "initialize",
      id: 0,
      params: %{
        clientInfo: %{
          name: "notex",
          title: "Notex",
          version: "0.1.0"
        }
      }
    })

    with {:ok, _result} <- await_response(port, 0, timeout) do
      send_message(port, %{method: "initialized", params: %{}})
      :ok
    end
  end

  defp ensure_image_generation_capability(port, timeout) do
    send_message(port, %{method: "modelProvider/capabilities/read", id: 1, params: %{}})

    case await_response(port, 1, timeout) do
      {:ok, %{"imageGeneration" => true}} -> :ok
      {:ok, result} -> {:error, {:image_generation_not_supported, result}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_thread(port, config) do
    send_message(port, %{
      method: "thread/start",
      id: 2,
      params: %{
        model: config.model,
        ephemeral: true,
        approvalPolicy: "never",
        developerInstructions:
          "Generate the requested image with the image generation capability. Do not run commands."
      }
    })

    case await_response(port, 2, config.timeout) do
      {:ok, %{"thread" => %{"id" => thread_id}}} -> {:ok, thread_id}
      {:ok, other} -> {:error, {:missing_thread_id, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_turn(port, config, thread_id, prompt) do
    send_message(port, %{
      method: "turn/start",
      id: 3,
      params: %{
        threadId: thread_id,
        model: config.model,
        effort: config.reasoning_effort,
        approvalPolicy: "never",
        sandboxPolicy: %{type: "readOnly", networkAccess: false},
        input: [%{type: "text", text: prompt}]
      }
    })

    await_response(port, 3, config.timeout)
  end

  defp await_response(port, id, timeout) do
    case read_message(port, timeout) do
      {:ok, %{"id" => ^id, "result" => result}} ->
        {:ok, result}

      {:ok, %{"id" => ^id, "error" => error}} ->
        {:error, {:server_error, error}}

      {:ok, _notification_or_other_response} ->
        await_response(port, id, timeout)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp await_image_generation(port, timeout, latest_meta) do
    case read_message(port, timeout) do
      {:ok,
       %{
         "method" => "item/completed",
         "params" => %{
           "item" => %{"type" => "imageGeneration", "result" => result} = item
         }
       }}
      when is_binary(result) and result != "" ->
        {:ok, result,
         %{
           "revised_prompt" => Map.get(item, "revisedPrompt"),
           "image_generation_status" => Map.get(item, "status")
         }}

      {:ok,
       %{
         "method" => "item/started",
         "params" => %{"item" => %{"type" => "imageGeneration"} = item}
       }} ->
        await_image_generation(port, timeout, %{
          "image_generation_status" => Map.get(item, "status")
        })

      {:ok, %{"method" => "turn/completed"}} ->
        {:error, {:missing_image_generation_result, latest_meta}}

      {:ok, %{"method" => "error", "params" => params}} ->
        {:error, {:server_error, params}}

      {:ok, _message} ->
        await_image_generation(port, timeout, latest_meta)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_message(port, timeout) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        decode_line(line)

      {^port, {:data, {:noeol, line}}} ->
        decode_line(line)

      {^port, {:exit_status, status}} ->
        {:error, {:exit_status, status}}
    after
      timeout -> {:error, :timeout}
    end
  end

  defp decode_line(line) do
    case Jason.decode(line) do
      {:ok, message} -> {:ok, message}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  defp send_message(port, message) do
    Port.command(port, Jason.encode!(message) <> "\n")
  end

  defp close_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp executable(command) do
    case System.find_executable(command) do
      nil -> {:error, {:missing_executable, command}}
      path -> {:ok, path}
    end
  end

  defp config(opts) do
    app_config = Application.get_env(:notex, Notex.ImageGeneration, [])
    llm_config = Application.get_env(:notex, Notex.LLM, [])

    %{
      command:
        opts[:command] ||
          System.get_env("NOTEX_CODEX_COMMAND") ||
          Keyword.get(app_config, :codex_command) ||
          Keyword.get(llm_config, :codex_command, "codex"),
      model:
        opts[:model] ||
          System.get_env("NOTEX_IMAGE_MODEL") ||
          System.get_env("NOTEX_LLM_MODEL") ||
          Keyword.get(app_config, :model, @default_model),
      reasoning_effort:
        opts[:reasoning_effort] ||
          System.get_env("NOTEX_IMAGE_REASONING_EFFORT") ||
          System.get_env("NOTEX_LLM_REASONING_EFFORT") ||
          Keyword.get(app_config, :reasoning_effort, @default_reasoning_effort),
      timeout:
        opts[:timeout] ||
          env_timeout() ||
          Keyword.get(app_config, :timeout, @default_timeout),
      app_server:
        opts[:app_server] ||
          Keyword.get(app_config, :app_server, &__MODULE__.generate_with_app_server/2)
    }
  end

  defp env_timeout do
    case System.get_env("NOTEX_IMAGE_TIMEOUT_MS") || System.get_env("NOTEX_LLM_TIMEOUT_MS") do
      nil -> nil
      value -> String.to_integer(value)
    end
  rescue
    ArgumentError -> nil
  end
end
