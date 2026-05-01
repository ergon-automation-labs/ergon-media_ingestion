defmodule BotArmyMediaIngestion.YouTube.Transcript do
  @moduledoc """
  Fetches YouTube transcript text and optional metadata.
  """

  @default_transcript_endpoint "https://youtubetranscript.com/?server_vid2="
  @default_oembed_endpoint "https://www.youtube.com/oembed?format=json&url="

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

      {:ok, result}
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
end
