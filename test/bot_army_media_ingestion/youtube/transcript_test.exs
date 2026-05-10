defmodule BotArmyMediaIngestion.YouTube.TranscriptTest do
  use ExUnit.Case
  @moduletag :ingestion

  alias BotArmyMediaIngestion.YouTube.Transcript

  test "rejects missing youtube_url" do
    assert {:error, "youtube_url is required"} = Transcript.fetch(%{})
  end

  test "rejects non-youtube url" do
    assert {:error, "youtube_url must be a valid YouTube watch/share URL"} =
             Transcript.fetch(%{"youtube_url" => "https://example.com/watch?v=abc"})
  end

  test "accepts valid youtube watch url and attempts fetch" do
    System.put_env("MEDIA_INGESTION_YOUTUBE_TRANSCRIPT_ENDPOINT", "http://127.0.0.1:9/?v=")
    System.put_env("MEDIA_INGESTION_YTDLP_ENABLED", "0")

    assert {:error, reason} =
             Transcript.fetch(%{"youtube_url" => "https://www.youtube.com/watch?v=dQw4w9WgXcQ"})

    assert reason =~ "transcript lookup failed:"
  after
    System.delete_env("MEDIA_INGESTION_YOUTUBE_TRANSCRIPT_ENDPOINT")
    System.delete_env("MEDIA_INGESTION_YTDLP_ENABLED")
  end

  test "accepts valid youtu.be url and attempts fetch" do
    System.put_env("MEDIA_INGESTION_YOUTUBE_TRANSCRIPT_ENDPOINT", "http://127.0.0.1:9/?v=")
    System.put_env("MEDIA_INGESTION_YTDLP_ENABLED", "0")

    assert {:error, reason} =
             Transcript.fetch(%{"youtube_url" => "https://youtu.be/dQw4w9WgXcQ"})

    assert reason =~ "transcript lookup failed:"
  after
    System.delete_env("MEDIA_INGESTION_YOUTUBE_TRANSCRIPT_ENDPOINT")
    System.delete_env("MEDIA_INGESTION_YTDLP_ENABLED")
  end

  test "parses transcript rows when HTTP 200 body is a JSON string" do
    assert {:ok, [%{"text" => "hello", "start" => 1.2}]} =
             Transcript.parse_response_body(~s([{"text":"hello","start":1.2}]))
  end

  test "parses transcript rows when HTTP 200 body is transcript XML" do
    body = ~s(<transcript><text start="0.0" dur="2.0">Hello &amp; goodbye</text></transcript>)

    assert {:ok, [%{"text" => "Hello & goodbye", "start" => "0.0"}]} =
             Transcript.parse_response_body(body)
  end

  test "reports a useful snippet for unexpected HTTP 200 body" do
    assert {:error, reason} = Transcript.parse_response_body("<html>not a transcript</html>")

    assert reason =~ "HTTP 200 unexpected body:"
    assert reason =~ "not a transcript"
  end

  test "parses yt-dlp VTT subtitle output" do
    body = """
    WEBVTT
    Kind: captions
    Language: en

    00:00:01.000 --> 00:00:03.500
    <c>Hello</c> &amp; welcome

    00:00:04.000 --> 00:00:06.000
    to the show
    """

    assert {:ok,
            [
              %{"start" => 1.0, "text" => "Hello & welcome"},
              %{"start" => 4.0, "text" => "to the show"}
            ]} = Transcript.parse_vtt_transcript(body)
  end
end
