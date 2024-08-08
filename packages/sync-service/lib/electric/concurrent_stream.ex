defmodule Electric.ConcurrentStream do
  @default_poll_time 10

  def stream_to_end(opts) do
    excluded_start_key = Keyword.fetch!(opts, :excluded_start_key)
    end_marker_key = Keyword.fetch!(opts, :end_marker_key)
    stream_fun = Keyword.fetch!(opts, :stream_fun)

    stream_fun.(excluded_start_key, end_marker_key)
    |> continue_if_not_ended(excluded_start_key, opts)
  end

  defp continue_if_not_ended(stream, latest_key, opts) do
    end_marker_key = Keyword.fetch!(opts, :end_marker_key)
    stream_fun = Keyword.fetch!(opts, :stream_fun)
    poll_time_in_ms = Keyword.get(opts, :poll_time_in_ms, @default_poll_time)

    [stream, [:premature_end]]
    |> Stream.concat()
    |> Stream.transform(latest_key, fn
      :premature_end, latest_key ->
        # Wait for more items to be added
        Process.sleep(poll_time_in_ms)

        # Continue from the latest_key
        stream =
          stream_fun.(latest_key, end_marker_key)
          |> continue_if_not_ended(latest_key, opts)

        {stream, latest_key}

      {^end_marker_key, _}, _latest_key ->
        {:halt, :end_marker_seen}

      {key, _value} = item, _latest_key ->
        {[item], key}
    end)
  end
end