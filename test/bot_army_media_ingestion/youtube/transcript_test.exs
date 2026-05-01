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

    assert {:error, reason} =
             Transcript.fetch(%{"youtube_url" => "https://www.youtube.com/watch?v=dQw4w9WgXcQ"})

    assert reason =~ "transcript lookup failed:"
  after
    System.delete_env("MEDIA_INGESTION_YOUTUBE_TRANSCRIPT_ENDPOINT")
  end

  test "accepts valid youtu.be url and attempts fetch" do
    System.put_env("MEDIA_INGESTION_YOUTUBE_TRANSCRIPT_ENDPOINT", "http://127.0.0.1:9/?v=")

    assert {:error, reason} =
             Transcript.fetch(%{"youtube_url" => "https://youtu.be/dQw4w9WgXcQ"})

    assert reason =~ "transcript lookup failed:"
  after
    System.delete_env("MEDIA_INGESTION_YOUTUBE_TRANSCRIPT_ENDPOINT")
  end
end
