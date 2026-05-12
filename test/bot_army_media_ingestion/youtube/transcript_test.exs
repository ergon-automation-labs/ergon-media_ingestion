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

  test "collapses rolling auto-caption VTT cues into readable transcript text" do
    body = """
    WEBVTT
    Kind: captions
    Language: en

    00:00:00.080 --> 00:00:02.310 align:start position:0%

    A<00:00:00.320><c> few</c><00:00:00.480><c> weeks</c><00:00:00.640><c> ago,</c><00:00:01.199><c> I</c><00:00:01.439><c> caught</c><00:00:01.680><c> myself</c><00:00:02.080><c> doing</c>

    00:00:02.310 --> 00:00:02.320 align:start position:0%
    A few weeks ago, I caught myself doing

    00:00:02.320 --> 00:00:05.030 align:start position:0%
    A few weeks ago, I caught myself doing
    something<00:00:02.960><c> weird.</c><00:00:03.760><c> It</c><00:00:03.919><c> was</c><00:00:04.000><c> Sunday</c><00:00:04.319><c> night,</c><00:00:04.799><c> my</c>

    00:00:05.030 --> 00:00:05.040 align:start position:0%
    something weird. It was Sunday night, my

    00:00:05.040 --> 00:00:06.789 align:start position:0%
    something weird. It was Sunday night, my
    laptop<00:00:05.359><c> was</c><00:00:05.600><c> open,</c><00:00:05.920><c> and</c><00:00:06.160><c> Claude</c><00:00:06.560><c> was</c>
    """

    assert {:ok, rows} = Transcript.parse_vtt_transcript(body)

    assert {:ok, text} =
             Transcript.build_transcript_text_for_test(rows, %{"include_timestamps" => false})

    assert text ==
             "A few weeks ago, I caught myself doing something weird. It was Sunday night, my laptop was open, and Claude was"
  end
end
