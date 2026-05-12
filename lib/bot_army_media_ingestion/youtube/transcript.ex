defmodule BotArmyMediaIngestion.YouTube.Transcript do
  @moduledoc """
  Fetches YouTube transcript text and optional metadata.
  """

  require Logger

  @default_transcript_endpoint "https://youtubetranscript.com/?server_vid2="
  @default_oembed_endpoint "https://www.youtube.com/oembed?format=json&url="
  @default_store_mode "markdown"
  @default_include_full_text true
  @default_max_chars 200_000

  @spec fetch(map()) :: {:ok, map()} | {:error, String.t()}
  def fetch(params) when is_map(params) do
    with {:ok, youtube_url} <- validate_youtube_url(params),
         {:ok, video_id} <- extract_video_id(youtube_url),
         {:ok, transcript_rows} <- fetch_transcript_rows(video_id, youtube_url),
         {:ok, transcript_text} <- build_transcript_text(transcript_rows, params) do
      result = %{
        "youtube_url" => youtube_url,
        "video_id" => video_id,
        "transcript_text" => transcript_text,
        "transcript_length_chars" => String.length(transcript_text)
      }

      result =
        if include_video_metadata?(params) do
          case fetch_video_metadata(youtube_url) do
            {:ok, metadata} -> Map.put(result, "video_metadata", metadata)
            _ -> result
          end
        else
          result
        end

      maybe_persist(result, params)
    end
  end

  def fetch(_), do: {:error, "invalid request"}

  defp validate_youtube_url(params) do
    case Map.get(params, "youtube_url") do
      url when is_binary(url) ->
        trimmed = String.trim(url)
        if trimmed == "", do: {:error, "youtube_url is required"}, else: {:ok, trimmed}

      _ ->
        {:error, "youtube_url is required"}
    end
  end

  defp include_video_metadata?(params),
    do: Map.get(params, "include_video_metadata", true) != false

  defp extract_video_id(url) do
    with %URI{} = uri <- URI.parse(url),
         true <- youtube_host?(uri.host),
         {:ok, id} <- extract_video_id_from_uri(uri),
         true <- String.length(id) >= 6 do
      {:ok, id}
    else
      _ -> {:error, "youtube_url must be a valid YouTube watch/share URL"}
    end
  end

  defp youtube_host?(nil), do: false

  defp youtube_host?(host) do
    normalized = String.downcase(host)
    normalized in ["youtube.com", "www.youtube.com", "youtu.be"]
  end

  defp extract_video_id_from_uri(%URI{host: host, query: query, path: path}) do
    normalized_host = String.downcase(host || "")
    normalized_path = path || ""

    cond do
      normalized_host == "youtu.be" ->
        id =
          normalized_path
          |> String.trim_leading("/")
          |> String.split("/", parts: 2)
          |> List.first()

        if is_binary(id) and id != "", do: {:ok, id}, else: {:error, :missing_video_id}

      String.starts_with?(normalized_path, "/watch") ->
        case URI.decode_query(query || "") do
          %{"v" => id} when is_binary(id) and id != "" -> {:ok, id}
          _ -> {:error, :missing_video_id}
        end

      String.starts_with?(normalized_path, "/shorts/") ->
        id =
          normalized_path
          |> String.trim_leading("/shorts/")
          |> String.split("/", parts: 2)
          |> List.first()

        if is_binary(id) and id != "", do: {:ok, id}, else: {:error, :missing_video_id}

      true ->
        {:error, :unsupported_youtube_path}
    end
  end

  defp fetch_transcript_rows(video_id, youtube_url) do
    endpoint =
      System.get_env("MEDIA_INGESTION_YOUTUBE_TRANSCRIPT_ENDPOINT", @default_transcript_endpoint)

    url = endpoint <> URI.encode(video_id)

    case http_get_json(url) do
      {:ok, rows} when is_list(rows) and rows != [] ->
        if provider_blocked_rows?(rows) do
          Logger.info(
            "[MediaIngestion.YouTube] transcript endpoint blocked; falling back to yt-dlp"
          )

          fetch_transcript_rows_with_ytdlp(youtube_url)
        else
          {:ok, rows}
        end

      {:ok, []} ->
        fetch_transcript_rows_with_ytdlp(youtube_url)

      {:ok, _} ->
        fetch_transcript_rows_with_ytdlp(youtube_url)

      {:error, reason} ->
        case fetch_transcript_rows_with_ytdlp(youtube_url) do
          {:ok, rows} -> {:ok, rows}
          {:error, fallback_reason} -> transcript_lookup_error(reason, fallback_reason)
        end
    end
  end

  defp transcript_lookup_error(reason, fallback_reason) do
    {:error, "transcript lookup failed: #{reason}; yt-dlp fallback failed: #{fallback_reason}"}
  end

  defp provider_blocked_rows?(rows) do
    rows
    |> Enum.map(&Map.get(&1, "text", ""))
    |> Enum.any?(fn text ->
      normalized = String.downcase(to_string(text))

      String.contains?(normalized, "youtube is currently blocking") or
        String.contains?(normalized, "blocking us from fetching subtitles")
    end)
  end

  defp fetch_transcript_rows_with_ytdlp(youtube_url) do
    if env_bool("MEDIA_INGESTION_YTDLP_ENABLED", true) do
      do_fetch_transcript_rows_with_ytdlp(youtube_url)
    else
      {:error, "yt-dlp fallback disabled"}
    end
  end

  defp do_fetch_transcript_rows_with_ytdlp(youtube_url) do
    bin = System.get_env("MEDIA_INGESTION_YTDLP_BIN", "yt-dlp")

    tmp_dir =
      Path.join(System.tmp_dir!(), "media_ingestion_ytdlp_#{System.unique_integer([:positive])}")

    try do
      with :ok <- File.mkdir_p(tmp_dir),
           {output, status} <- run_ytdlp(bin, youtube_url, tmp_dir),
           {:ok, rows} <- read_ytdlp_subtitle_rows(tmp_dir, output, status) do
        {:ok, rows}
      else
        {:error, reason} ->
          {:error, reason}
      end
    after
      File.rm_rf(tmp_dir)
    end
  rescue
    e in ErlangError ->
      {:error, "yt-dlp execution failed: #{inspect(e.original)}"}
  end

  defp run_ytdlp(bin, youtube_url, tmp_dir) do
    args = [
      "--skip-download",
      "--write-subs",
      "--write-auto-subs",
      "--sub-langs",
      System.get_env("MEDIA_INGESTION_YTDLP_SUB_LANGS", "en"),
      "--sub-format",
      "vtt",
      "--output",
      "%(id)s.%(ext)s",
      youtube_url
    ]

    System.cmd(bin, args, cd: tmp_dir, stderr_to_stdout: true)
  end

  defp read_ytdlp_subtitle_rows(tmp_dir, output, status) do
    tmp_dir
    |> Path.join("*.vtt")
    |> Path.wildcard()
    |> Enum.sort()
    |> case do
      [] ->
        reason =
          if status == 0 do
            "yt-dlp produced no VTT subtitles"
          else
            "yt-dlp exited #{status} and produced no VTT subtitles"
          end

        {:error, "#{reason}: #{body_snippet(output)}"}

      paths ->
        paths
        |> Enum.map(&File.read!/1)
        |> Enum.reduce_while([], fn body, acc ->
          case parse_vtt_transcript(body) do
            {:ok, rows} -> {:halt, rows}
            {:error, _reason} -> {:cont, acc}
          end
        end)
        |> case do
          [] -> {:error, "yt-dlp subtitles had no text rows"}
          rows -> {:ok, rows}
        end
    end
  end

  defp fetch_video_metadata(youtube_url) do
    endpoint = System.get_env("MEDIA_INGESTION_YOUTUBE_OEMBED_ENDPOINT", @default_oembed_endpoint)
    url = endpoint <> URI.encode(youtube_url)

    case http_get_json(url) do
      {:ok, %{} = metadata} ->
        {:ok,
         %{
           "title" => Map.get(metadata, "title"),
           "channel" => Map.get(metadata, "author_name"),
           "provider" => Map.get(metadata, "provider_name")
         }}

      _ ->
        {:error, :metadata_unavailable}
    end
  end

  defp build_transcript_text(rows, params) do
    include_timestamps = Map.get(params, "include_timestamps", false) == true
    max_chars = normalize_max_chars(Map.get(params, "max_chars"))

    lines =
      rows
      |> Enum.map(&normalize_row_text(&1, include_timestamps))
      |> Enum.reject(&(&1 == ""))

    text = Enum.join(lines, "\n")
    {:ok, truncate_text(text, max_chars)}
  end

  defp normalize_row_text(%{"text" => text} = row, include_timestamps) when is_binary(text) do
    cleaned =
      text
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    if cleaned == "" do
      ""
    else
      maybe_prefix_timestamp(cleaned, row, include_timestamps)
    end
  end

  defp normalize_row_text(_, _), do: ""

  defp maybe_prefix_timestamp(text, _row, false), do: text

  defp maybe_prefix_timestamp(text, row, true) do
    case parse_seconds(Map.get(row, "start")) do
      {:ok, seconds} -> "[#{format_timestamp(seconds)}] #{text}"
      :error -> text
    end
  end

  defp parse_seconds(value) when is_number(value), do: {:ok, trunc(value)}

  defp parse_seconds(value) when is_binary(value) do
    case Float.parse(value) do
      {seconds, _} -> {:ok, trunc(seconds)}
      :error -> :error
    end
  end

  defp parse_seconds(_), do: :error

  defp format_timestamp(total_seconds) when total_seconds >= 0 do
    hours = div(total_seconds, 3600)
    minutes = div(rem(total_seconds, 3600), 60)
    seconds = rem(total_seconds, 60)

    if hours > 0 do
      :io_lib.format("~2..0B:~2..0B:~2..0B", [hours, minutes, seconds]) |> to_string()
    else
      :io_lib.format("~2..0B:~2..0B", [minutes, seconds]) |> to_string()
    end
  end

  defp normalize_max_chars(nil), do: @default_max_chars
  defp normalize_max_chars(value) when is_integer(value) and value > 0, do: value
  defp normalize_max_chars(_), do: @default_max_chars

  defp truncate_text(text, max_chars) do
    if String.length(text) <= max_chars do
      text
    else
      String.slice(text, 0, max_chars) <> "...[truncated]"
    end
  end

  defp http_get_json(url) do
    case Req.get(url) do
      {:ok, %{status: 200, body: body}} when is_map(body) or is_list(body) ->
        {:ok, body}

      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        parse_response_body(body)

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  @doc false
  def parse_response_body(body) when is_binary(body) do
    trimmed = String.trim(body)

    cond do
      trimmed == "" ->
        {:error, "HTTP 200 empty body"}

      String.starts_with?(trimmed, ["[", "{"]) ->
        case Jason.decode(trimmed) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, _} -> {:error, "HTTP 200 invalid JSON body: #{body_snippet(trimmed)}"}
        end

      String.contains?(trimmed, "<text") ->
        parse_transcript_xml(trimmed)

      true ->
        {:error, "HTTP 200 unexpected body: #{body_snippet(trimmed)}"}
    end
  end

  def parse_response_body(body), do: {:error, "unexpected response body: #{inspect(body)}"}

  @doc false
  def parse_vtt_transcript(body) when is_binary(body) do
    rows =
      body
      |> String.replace("\r\n", "\n")
      |> String.replace("\r", "\n")
      |> String.split(~r/\n\s*\n/)
      |> Enum.flat_map(&parse_vtt_cue/1)

    if rows == [] do
      {:error, "VTT had no text rows"}
    else
      {:ok, rows}
    end
  end

  def parse_vtt_transcript(body), do: {:error, "unexpected VTT body: #{inspect(body)}"}

  defp parse_vtt_cue(cue) do
    lines =
      cue
      |> String.split(["\n", "\r\n"], trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    timestamp_index = Enum.find_index(lines, &String.contains?(&1, "-->"))

    if is_integer(timestamp_index) do
      timestamp_line = Enum.at(lines, timestamp_index)
      text = lines |> Enum.drop(timestamp_index + 1) |> clean_vtt_text()

      case text do
        "" -> []
        value -> [%{"start" => vtt_start(timestamp_line), "text" => value}]
      end
    else
      []
    end
  end

  defp clean_vtt_text(lines) do
    lines
    |> Enum.reject(&vtt_metadata_line?/1)
    |> Enum.map(&strip_xml_tags/1)
    |> Enum.map(&decode_xml_entities/1)
    |> Enum.join(" ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp vtt_metadata_line?("WEBVTT" <> _), do: true
  defp vtt_metadata_line?("Kind:" <> _), do: true
  defp vtt_metadata_line?("Language:" <> _), do: true
  defp vtt_metadata_line?("NOTE" <> _), do: true
  defp vtt_metadata_line?("STYLE" <> _), do: true
  defp vtt_metadata_line?(_), do: false

  defp vtt_start(timestamp_line) do
    timestamp_line
    |> String.split("-->", parts: 2)
    |> List.first()
    |> to_string()
    |> String.trim()
    |> vtt_timestamp_seconds()
  end

  defp vtt_timestamp_seconds(timestamp) do
    parts = String.split(timestamp, ":")

    parts
    |> Enum.reverse()
    |> Enum.with_index()
    |> Enum.reduce(0.0, fn {part, index}, acc ->
      case Float.parse(part) do
        {value, _} -> acc + value * :math.pow(60, index)
        :error -> acc
      end
    end)
  end

  defp parse_transcript_xml(body) do
    rows =
      ~r/<text\b([^>]*)>(.*?)<\/text>/s
      |> Regex.scan(body)
      |> Enum.map(fn [_match, attrs, text] ->
        %{
          "start" => xml_attr(attrs, "start"),
          "text" => text |> strip_xml_tags() |> decode_xml_entities() |> String.trim()
        }
      end)
      |> Enum.reject(&(Map.get(&1, "text") == ""))

    if rows == [] do
      {:error, "HTTP 200 transcript XML had no text rows"}
    else
      {:ok, rows}
    end
  end

  defp xml_attr(attrs, name) do
    case Regex.run(~r/#{Regex.escape(name)}="([^"]*)"/, attrs) do
      [_match, value] -> value
      _ -> nil
    end
  end

  defp strip_xml_tags(text), do: Regex.replace(~r/<[^>]+>/, text, "")

  defp decode_xml_entities(text) do
    text
    |> String.replace("&amp;", "&")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&apos;", "'")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
  end

  defp body_snippet(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.slice(0, 160)
  end

  defp maybe_persist(result, params) do
    if should_persist?(params) do
      case persist_transcript_markdown(result, params) do
        {:ok, metadata} ->
          {:ok, Map.merge(result, metadata)}

        {:error, reason} ->
          Logger.warning("[MediaIngestion.YouTube] transcript persistence failed: #{reason}")
          {:error, "transcript persistence failed: #{reason}"}
      end
    else
      {:ok, Map.put(result, "stored", false)}
    end
  end

  defp should_persist?(params) do
    case Map.get(params, "persist") do
      true -> true
      false -> false
      _ -> env_enabled?("MEDIA_INGESTION_TRANSCRIPT_STORE_ENABLED")
    end
  end

  defp persist_transcript_markdown(result, params) do
    root = System.get_env("MEDIA_INGESTION_TRANSCRIPT_STORE_ROOT", "")
    mode = System.get_env("MEDIA_INGESTION_TRANSCRIPT_STORE_MODE", @default_store_mode)

    include_full_text =
      env_bool("MEDIA_INGESTION_TRANSCRIPT_INCLUDE_FULL_TEXT", @default_include_full_text)

    max_chars =
      case System.get_env("MEDIA_INGESTION_TRANSCRIPT_MAX_CHARS") do
        nil -> @default_max_chars
        raw -> normalize_max_chars(parse_int(raw))
      end

    cond do
      String.trim(root) == "" ->
        {:error, "MEDIA_INGESTION_TRANSCRIPT_STORE_ROOT not configured"}

      mode != "markdown" ->
        {:error, "unsupported store mode: #{mode}"}

      true ->
        filename = build_filename(result)
        path = Path.join(root, filename)
        body = build_markdown_body(result, params, include_full_text, max_chars)

        with :ok <- File.mkdir_p(root),
             :ok <- File.write(path, body) do
          {:ok,
           %{
             "stored" => true,
             "stored_path" => path,
             "stored_bytes" => byte_size(body)
           }}
        end
    end
  end

  defp build_filename(result) do
    video_id = Map.get(result, "video_id", "unknown")
    timestamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    "#{timestamp}_#{video_id}.md"
  end

  defp build_markdown_body(result, params, include_full_text, max_chars) do
    metadata = Map.get(result, "video_metadata", %{})
    transcript_text = Map.get(result, "transcript_text", "")

    transcript_text =
      cond do
        include_full_text and is_integer(max_chars) -> truncate_text(transcript_text, max_chars)
        include_full_text -> transcript_text
        is_integer(max_chars) -> truncate_text(transcript_text, max_chars)
        true -> truncate_text(transcript_text, @default_max_chars)
      end

    summary =
      if transcript_text == "" do
        "(empty transcript)"
      else
        truncate_text(String.replace(transcript_text, "\n", " "), 400)
      end

    """
    ---
    source_url: #{Map.get(result, "youtube_url", "")}
    video_id: #{Map.get(result, "video_id", "")}
    title: #{Map.get(metadata, "title", "")}
    channel: #{Map.get(metadata, "channel", "")}
    provider: #{Map.get(metadata, "provider", "")}
    fetched_at: #{DateTime.utc_now() |> DateTime.to_iso8601()}
    language: #{Map.get(params, "language", "unknown")}
    transcript_length_chars: #{Map.get(result, "transcript_length_chars", 0)}
    tags: [youtube, transcript, media]
    ---

    ## Summary

    #{summary}

    ## Transcript

    #{transcript_text}
    """
  end

  defp env_enabled?(name), do: env_bool(name, false)

  defp env_bool(name, default) do
    case System.get_env(name) do
      nil -> default
      raw -> String.downcase(String.trim(raw)) in ["1", "true", "yes", "on"]
    end
  end

  defp parse_int(raw) when is_binary(raw) do
    case Integer.parse(String.trim(raw)) do
      {value, _} -> value
      :error -> nil
    end
  end
end
