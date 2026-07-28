defmodule Ourocode.Terminal.TuiLogin do
  @moduledoc false

  alias Ourocode.Provider.{Anthropic, Codex}
  alias Ourocode.Terminal.{KeyReader, TuiEnvironment, TuiState}

  @max_login_polls 80

  @doc """
  Starts login for the chosen backend. Codex uses the device-code flow with
  a live card; Claude (Anthropic) opens the browser authorization URL and
  arms a paste-the-code step handled by the next submitted line.
  """
  @spec start(atom(), map(), pid(), pid(), pos_integer(), pos_integer(), function()) :: :ok
  def start(provider, result, output, state, cols, rows, redraw),
    do: start(provider, result, output, state, cols, rows, redraw, [])

  @doc false
  @spec start(atom(), map(), pid(), pid(), pos_integer(), pos_integer(), function(), keyword()) ::
          :ok
  def start(provider, result, output, state, cols, rows, redraw, opts)

  def start(:claude_api, result, output, state, cols, rows, redraw, opts)
      when is_function(redraw, 6) do
    if Anthropic.signed_in?() do
      TuiState.put_model_id(state, :claude_api)
      log(output, "Already signed in. model: claude (Claude Pro/Max).")
      redraw.(result, output, state, "", cols, rows)
    else
      pkce = Anthropic.generate_pkce()
      login_state = pkce.verifier

      redirect_uri = Anthropic.redirect_uri()
      url = Anthropic.authorize_url(pkce.challenge, login_state, redirect_uri)

      TuiState.put_pending_login(state, %{
        provider: :claude_api,
        verifier: pkce.verifier,
        state: login_state,
        redirect_uri: redirect_uri
      })

      case assist_browser(output, url, "sign-in link", url, opts) do
        {true, true} ->
          log(output, "Approve Claude access in the opened browser.")

        {true, false} ->
          log(output, "Approve Claude access in the opened browser. Clipboard copy failed.")

        {false, true} ->
          log(output, "Could not open the browser. The Claude sign-in link was copied.")

        {false, false} ->
          log(
            output,
            "Could not open the browser or copy the Claude sign-in link. Open this URL:"
          )

          log(output, url)
      end

      log(output, "(paste the authorization code or final redirect URL and press Enter)")
      redraw.(result, output, state, "", cols, rows)
    end
  end

  def start(_codex, result, output, state, cols, rows, redraw, opts)
      when is_function(redraw, 6) do
    if Codex.signed_in?() do
      TuiState.put_model_id(state, :codex)
      log(output, "Already signed in. model: codex (ChatGPT).")
      redraw.(result, output, state, "", cols, rows)
    else
      case Codex.start_device_login() do
        {:ok, dev} ->
          entry_code = codex_entry_code(dev.user_code)
          TuiState.put_login(state, %{code: entry_code, url: dev.verification_uri})

          assist_browser(
            output,
            dev.verification_uri,
            "9-character device code",
            entry_code,
            opts
          )

          redraw.(result, output, state, "", cols, rows)
          poll(dev, 0, result, output, state, cols, rows, redraw)

        {:error, reason} ->
          log(output, "Login could not start: #{inspect(reason)}")
          redraw.(result, output, state, "", cols, rows)
      end
    end
  end

  defp poll(_dev, polls, result, output, state, cols, rows, redraw)
       when polls >= @max_login_polls do
    TuiState.put_login(state, nil)
    log(output, "Login timed out. Run /login to try again.")
    redraw.(result, output, state, "", cols, rows)
  end

  defp poll(dev, polls, result, output, state, cols, rows, redraw) do
    deadline = System.monotonic_time(:millisecond) + dev.interval_ms

    case wait_or_cancel(state, deadline) do
      :cancel ->
        TuiState.put_login(state, nil)
        log(output, "Login cancelled.")
        redraw.(result, output, state, "", cols, rows)

      :timeout ->
        case Codex.poll_device_login(dev) do
          {:ok, tokens} ->
            TuiState.put_login(state, nil)
            TuiState.put_model_id(state, :codex)
            who = tokens.email || tokens.account_id || "your ChatGPT account"
            log(output, "Signed in as #{who}. model: codex (ChatGPT) - ask anything.")
            redraw.(result, output, state, "", cols, rows)

          :pending ->
            redraw.(result, output, state, "", cols, rows)
            poll(dev, polls + 1, result, output, state, cols, rows, redraw)

          {:error, reason} ->
            if transient_poll_error?(reason) do
              redraw.(result, output, state, "", cols, rows)
              poll(dev, polls + 1, result, output, state, cols, rows, redraw)
            else
              TuiState.put_login(state, nil)
              log(output, "Login failed: #{inspect(reason)}")
              redraw.(result, output, state, "", cols, rows)
            end
        end
    end
  end

  # One blip while the user is still typing the code must not abort the
  # login: transport errors and retryable statuses (408/429/5xx) keep polling
  # inside the @max_login_polls budget; only a definitive 4xx aborts.
  @doc false
  @spec transient_poll_error?(term()) :: boolean()
  def transient_poll_error?({:device_poll_failed, status, _body}) when is_integer(status),
    do: status in [408, 429] or status >= 500

  def transient_poll_error?(_transport_error), do: true

  @doc """
  Completes a pending paste-based login with the code the user submitted.
  Returns `:handled` (login attempt consumed the line) or `:not_pending`.
  """
  @spec complete_paste(String.t(), pid(), pid()) :: :handled | :not_pending
  def complete_paste(line, output, state) do
    case TuiState.pending_login(state) do
      %{provider: :claude_api, verifier: verifier, state: login_state} = pending ->
        TuiState.put_pending_login(state, nil)
        code = line |> String.trim() |> strip_url_to_code()
        redirect_uri = Map.get(pending, :redirect_uri, Anthropic.redirect_uri())

        case Anthropic.exchange(code, verifier, login_state, redirect_uri) do
          {:ok, tokens} ->
            TuiState.put_model_id(state, :claude_api)
            who = tokens.email || tokens.account_id || "your Claude account"
            log(output, "Signed in as #{who}. model: claude (Claude Pro/Max).")

          {:error, reason} ->
            log(output, "Claude login failed: #{inspect(reason)}")
        end

        :handled

      _none ->
        :not_pending
    end
  end

  @doc false
  @spec codex_entry_code(String.t()) :: String.t()
  def codex_entry_code(code) when is_binary(code) do
    code
    |> String.replace(~r/[^A-Za-z0-9]/, "")
    |> String.upcase()
  end

  @doc false
  def login_input_cancel_action(data, pending \\ <<>>)

  def login_input_cancel_action(<<>>, <<27>>), do: {:cancel, <<>>}

  def login_input_cancel_action(data, pending) when is_binary(data) and is_binary(pending) do
    {events, rest} = KeyReader.decode(pending <> data)

    if Enum.any?(events, &match?(%{type: :key, key: key} when key in [:ctrl_c, :escape], &1)),
      do: {:cancel, rest},
      else: {:continue, rest}
  end

  # Accept either a bare code or the full redirect URL the browser landed on.
  defp strip_url_to_code(text) do
    case URI.parse(text) do
      %URI{query: query} when is_binary(query) ->
        case URI.decode_query(query) do
          %{"code" => code} = params ->
            case params["state"] do
              s when is_binary(s) and s != "" -> code <> "#" <> s
              _none -> code
            end

          _no_code ->
            text
        end

      _not_a_url ->
        text
    end
  end

  defp wait_or_cancel(state, deadline, pending \\ <<>>) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      :timeout
    else
      port = TuiState.port(state)
      wait_ms = if pending == <<27>>, do: min(remaining, 25), else: remaining

      receive do
        {^port, {:data, data}} ->
          case login_input_cancel_action(data, pending) do
            {:cancel, _rest} -> :cancel
            {:continue, rest} -> wait_or_cancel(state, deadline, rest)
          end

        {^port, {:exit_status, _}} ->
          :cancel
      after
        wait_ms ->
          if match?({:cancel, _rest}, login_input_cancel_action(<<>>, pending)),
            do: :cancel,
            else: :timeout
      end
    end
  end

  defp assist_browser(output, url, clipboard_label, clipboard_text, opts) do
    open_url = Keyword.get(opts, :open_url, &default_open_url/1)
    copy_to_clipboard = Keyword.get(opts, :copy_to_clipboard, &default_copy_to_clipboard/1)

    opened? = open_url.(url) == :ok
    copied? = copy_to_clipboard.(clipboard_text) == :ok

    status = {opened?, copied?}

    case status do
      {true, true} ->
        log(output, "Opened browser and copied the #{clipboard_label} to clipboard.")

      {true, false} ->
        log(output, "Opened browser for sign-in.")

      {false, true} ->
        log(output, "Could not open browser; #{clipboard_label} copied to clipboard.")

      {false, false} ->
        :ok
    end

    status
  end

  defp default_open_url(url) do
    if TuiEnvironment.test_run?() do
      {:error, :test_run}
    else
      case open_url_command(url, :os.type(), &System.find_executable/1) do
        nil -> {:error, :not_found}
        {command, args} -> system_ok(command, args)
      end
    end
  rescue
    exception -> {:error, exception}
  end

  defp default_copy_to_clipboard(text) do
    if TuiEnvironment.test_run?() do
      {:error, :test_run}
    else
      case windows_clipboard_command(text, :os.type(), &System.find_executable/1) do
        {command, args, env} ->
          system_ok(command, args, env: env)

        nil ->
          copy_to_unix_clipboard(text)
      end
    end
  rescue
    exception -> {:error, exception}
  end

  defp copy_to_unix_clipboard(text) do
    case clipboard_command() do
      nil -> {:error, :not_found}
      command -> copy_with_stdin(command, text)
    end
  end

  @doc false
  @spec open_url_command(String.t(), tuple(), (String.t() -> String.t() | nil)) ::
          {String.t(), [String.t()]} | nil
  def open_url_command(url, {:win32, _}, _find_executable) do
    {"rundll32.exe", ["url.dll,FileProtocolHandler", url]}
  end

  def open_url_command(url, _os_type, find_executable) do
    case find_executable.("open") || find_executable.("xdg-open") do
      nil -> nil
      command -> {command, [url]}
    end
  end

  @doc false
  @spec windows_clipboard_command(String.t(), tuple(), (String.t() -> String.t() | nil)) ::
          {String.t(), [String.t()], [{String.t(), String.t()}]} | nil
  def windows_clipboard_command(text, {:win32, _}, find_executable) do
    command = find_executable.("powershell.exe") || "powershell.exe"
    args = ["-NoProfile", "-Command", "Set-Clipboard -Value $env:OUROCODE_CLIPBOARD_TEXT"]

    {command, args, [{"OUROCODE_CLIPBOARD_TEXT", text}]}
  end

  def windows_clipboard_command(_text, _os_type, _find_executable), do: nil

  defp clipboard_command do
    System.find_executable("pbcopy") ||
      if(File.exists?("/usr/bin/pbcopy"), do: "/usr/bin/pbcopy")
  end

  defp copy_with_stdin(command, text) do
    system_ok("/bin/sh", ["-c", "printf %s \"$1\" | \"$2\"", "ourocode-copy", text, command])
  end

  defp system_ok(command, args, opts \\ []) do
    case System.cmd(command, args, Keyword.put(opts, :stderr_to_stdout, true)) do
      {_out, 0} -> :ok
      {out, status} -> {:error, {status, out}}
    end
  end

  defp log(output, text), do: IO.puts(output, text)
end
