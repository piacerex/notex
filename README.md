# Notex

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

## Local media dependencies

Video generation uses `ffmpeg` for MP4 rendering and a local TTS command for narration. Install these before using the Video media action:

```bash
sudo apt-get update
sudo apt-get install -y ffmpeg open-jtalk open-jtalk-mecab-naist-jdic hts-voice-nitech-jp-atr503-m001 fonts-noto-cjk
```

Japanese narration uses Open JTalk when it is installed. You can tune its rate with:

```bash
export NOTEX_OPEN_JTALK_RATE="1.0"
```

If Open JTalk is not installed, Notex falls back to `espeak-ng`/`espeak` when available. That fallback is mainly for basic narration and is not recommended for Japanese.

```bash
sudo apt-get install -y espeak-ng
```

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://hexdocs.pm/phoenix/overview.html
* Docs: https://hexdocs.pm/phoenix
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix

## LLM synthesis

Notex uses local retrieval first, then can synthesize cited answers with Codex app-server using GPT-5.5 low reasoning. This is the default provider when the `codex` command is available:

```bash
export NOTEX_LLM_PROVIDER="codex_app_server"
export NOTEX_LLM_MODEL="gpt-5.5"
export NOTEX_LLM_REASONING_EFFORT="low"
```

You can also use the OpenAI Responses API-compatible provider:

```bash
export NOTEX_LLM_PROVIDER="openai"
export OPENAI_API_KEY="..."
export NOTEX_LLM_MODEL="gpt-5.5"
export NOTEX_LLM_REASONING_EFFORT="low"
export NOTEX_LLM_BASE_URL="https://api.openai.com/v1"
```

If Codex app-server or API credentials are unavailable, Notex returns an explicit LLM error instead of generating a deterministic fallback answer.
