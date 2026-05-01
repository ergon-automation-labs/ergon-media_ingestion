defmodule BotArmyMediaIngestion.YouTube.Transcript do
  @moduledoc """
  Fetches YouTube transcript text and optional metadata.
  """

  require Logger

  @default_transcript_endpoint "https://youtubetranscript.com/?server_vid2="
  @default_oembed_endpoint "https://www.youtube.com/oembed?format=json&url="
  @default_store_mode "markdown"
  @default_include_full_text true

  @spec fetch(map()) :: {:ok, map()} | {:error, String.t()}
  def fetch(params) when is_map(params) do
    with {:ok, youtube_url} <- validate_youtube_url(params),
         {:ok, video_id} <- extract_video_id(youtube_url),
         {:ok, transcript_rows} <- fetch_transcript_rows(video_id),
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

  defp fetch_transcript_rows(video_id) do
    endpoint =
      System.get_env("MEDIA_INGESTION_YOUTUBE_TRANSCRIPT_ENDPOINT", @default_transcript_endpoint)

    url = endpoint <> URI.encode(video_id)

    case http_get_json(url) do
      {:ok, rows} when is_list(rows) and rows != [] ->
        {:ok, rows}

      {:ok, []} ->
        {:error, "transcript unavailable for this video"}

      {:ok, _} ->
        {:error, "unexpected transcript response shape"}

      {:error, reason} ->
        {:error, "transcript lookup failed: #{reason}"}
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

  defp normalize_max_chars(nil), do: nil
  defp normalize_max_chars(value) when is_integer(value) and value > 0, do: value
  defp normalize_max_chars(_), do: nil

  defp truncate_text(text, nil), do: text

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

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
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
        nil -> nil
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
        true -> truncate_text(transcript_text, 5_000)
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
