defmodule Electric.ShapeCache.InMemoryStorage do
  use Agent
  alias Electric.ConcurrentStream
  alias Electric.Replication.LogOffset
  alias Electric.Telemetry.OpenTelemetry

  alias __MODULE__, as: MS

  @behaviour Electric.ShapeCache.Storage

  @snapshot_offset LogOffset.first()
  @snapshot_start_index 0
  @snapshot_end_index :end
  @xmin_key :xmin

  defstruct [
    :table_base_name,
    :snapshot_table,
    :log_table,
    :chunk_checkpoint_table,
    :shape_handle,
    :stack_id
  ]

  @impl Electric.ShapeCache.Storage
  def shared_opts(opts) do
    stack_id = Access.fetch!(opts, :stack_id)
    table_base_name = Access.get(opts, :table_base_name, __MODULE__)

    %{
      table_base_name: table_base_name,
      stack_id: stack_id
    }
  end

  def name(stack_id, shape_handle) when is_binary(shape_handle) do
    Electric.ProcessRegistry.name(stack_id, __MODULE__, shape_handle)
  end

  @impl Electric.ShapeCache.Storage
  def for_shape(shape_handle, %{shape_handle: shape_handle} = opts) do
    opts
  end

  def for_shape(shape_handle, %{
        table_base_name: table_base_name,
        stack_id: stack_id
      }) do
    snapshot_table_name = :"#{table_base_name}.Snapshot_#{shape_handle}"
    log_table_name = :"#{table_base_name}.Log_#{shape_handle}"

    chunk_checkpoint_table_name =
      :"#{table_base_name}.ChunkCheckpoint_#{shape_handle}"

    %__MODULE__{
      table_base_name: table_base_name,
      shape_handle: shape_handle,
      snapshot_table: snapshot_table_name,
      log_table: log_table_name,
      chunk_checkpoint_table: chunk_checkpoint_table_name,
      stack_id: stack_id
    }
  end

  @impl Electric.ShapeCache.Storage
  def start_link(%MS{} = opts) do
    if is_nil(opts.shape_handle), do: raise("cannot start an un-attached storage instance")
    if is_nil(opts.stack_id), do: raise("stack_id cannot be nil")

    Agent.start_link(
      fn ->
        %{
          snapshot_table: storage_table(opts.snapshot_table),
          log_table: storage_table(opts.log_table),
          chunk_checkpoint_table: storage_table(opts.chunk_checkpoint_table)
        }
      end,
      name: name(opts.stack_id, opts.shape_handle)
    )
  end

  defp storage_table(name) do
    :ets.new(name, [:public, :named_table, :ordered_set])
  end

  @impl Electric.ShapeCache.Storage
  def get_current_position(%MS{} = opts) do
    {:ok, current_offset(opts), current_xmin(opts)}
  end

  defp current_xmin(opts) do
    case :ets.lookup(opts.snapshot_table, @xmin_key) do
      [] ->
        nil

      [{@xmin_key, xmin}] ->
        xmin
    end
  end

  defp current_offset(_opts) do
    LogOffset.first()
  end

  @impl Electric.ShapeCache.Storage
  def set_snapshot_xmin(xmin, %MS{} = opts) do
    :ets.insert(opts.snapshot_table, {@xmin_key, xmin})
    :ok
  end

  @impl Electric.ShapeCache.Storage
  def initialise(%MS{} = _opts), do: :ok

  @impl Electric.ShapeCache.Storage
  def set_shape_definition(_shape, %MS{} = _opts) do
    # no-op - only used to restore shapes between sessions
    :ok
  end

  @impl Electric.ShapeCache.Storage
  def get_all_stored_shapes(_opts) do
    # shapes not stored, empty map returned
    {:ok, %{}}
  end

  @impl Electric.ShapeCache.Storage
  def get_total_disk_usage(_opts) do
    0
  end

  @impl Electric.ShapeCache.Storage
  def snapshot_started?(%MS{} = opts) do
    try do
      :ets.member(opts.snapshot_table, snapshot_start())
    rescue
      ArgumentError ->
        false
    end
  end

  defp snapshot_key(index) do
    {:data, index}
  end

  defp snapshot_start, do: snapshot_key(@snapshot_start_index)
  defp snapshot_end, do: snapshot_key(@snapshot_end_index)

  @impl Electric.ShapeCache.Storage
  def get_snapshot(%MS{} = opts) do
    stream =
      ConcurrentStream.stream_to_end(
        excluded_start_key: @snapshot_start_index,
        end_marker_key: @snapshot_end_index,
        poll_time_in_ms: 10,
        stream_fun: fn excluded_start_key, included_end_key ->
          if !snapshot_started?(opts), do: raise("Snapshot no longer available")

          :ets.select(opts.snapshot_table, [
            {{snapshot_key(:"$1"), :"$2"},
             [{:andalso, {:>, :"$1", excluded_start_key}, {:"=<", :"$1", included_end_key}}],
             [{{:"$1", :"$2"}}]}
          ])
        end
      )
      |> Stream.map(fn {_, item} -> item end)

    {@snapshot_offset, stream}
  end

  defp get_offset_indexed_stream(offset, max_offset, offset_indexed_table) do
    offset = storage_offset(offset)
    max_offset = storage_offset(max_offset)

    Stream.unfold(offset, fn offset ->
      case :ets.next_lookup(offset_indexed_table, {:offset, offset}) do
        :"$end_of_table" ->
          nil

        {{:offset, position}, _} when position > max_offset ->
          nil

        {{:offset, position}, [{_, item}]} ->
          {item, position}
      end
    end)
  end

  @impl Electric.ShapeCache.Storage
  def get_log_stream(offset, max_offset, %MS{} = opts) do
    get_offset_indexed_stream(offset, max_offset, opts.log_table)
  end

  @impl Electric.ShapeCache.Storage
  def get_chunk_end_log_offset(offset, %MS{} = opts) do
    case :ets.next_lookup(opts.chunk_checkpoint_table, storage_offset(offset)) do
      :"$end_of_table" ->
        nil

      {chunk_offset, _} ->
        LogOffset.new(chunk_offset)
    end
  end

  @impl Electric.ShapeCache.Storage
  def make_new_snapshot!(data_stream, %MS{stack_id: stack_id} = opts) do
    OpenTelemetry.with_span(
      "storage.make_new_snapshot",
      [storage_impl: "in_memory", "shape.handle": opts.shape_handle],
      stack_id,
      fn ->
        table = opts.snapshot_table

        data_stream
        |> Stream.with_index(1)
        |> Stream.map(fn {log_item, index} -> {snapshot_key(index), log_item} end)
        |> Stream.chunk_every(500)
        |> Stream.each(fn chunk -> :ets.insert(table, chunk) end)
        |> Stream.run()

        :ets.insert(table, {snapshot_end(), 0})
        :ok
      end
    )
  end

  @impl Electric.ShapeCache.Storage
  def mark_snapshot_as_started(%MS{} = opts) do
    :ets.insert(opts.snapshot_table, {snapshot_start(), 0})
    :ok
  end

  @impl Electric.ShapeCache.Storage
  def append_to_log!(log_items, %MS{} = opts) do
    log_table = opts.log_table
    chunk_checkpoint_table = opts.chunk_checkpoint_table

    log_items
    |> Enum.map(fn
      {:chunk_boundary, offset} -> {storage_offset(offset), :checkpoint}
      {offset, json_log_item} -> {{:offset, storage_offset(offset)}, json_log_item}
    end)
    |> Enum.split_with(fn item -> match?({_, :checkpoint}, item) end)
    |> then(fn {checkpoints, log_items} ->
      :ets.insert(chunk_checkpoint_table, checkpoints)
      :ets.insert(log_table, log_items)
      log_items
    end)

    :ok
  end

  @impl Electric.ShapeCache.Storage
  def cleanup!(%MS{} = opts) do
    :ets.delete_all_objects(opts.snapshot_table)
    :ets.delete_all_objects(opts.log_table)
    :ets.delete_all_objects(opts.chunk_checkpoint_table)
    :ok
  end

  @impl Electric.ShapeCache.Storage
  def unsafe_cleanup!(%MS{} = opts), do: cleanup!(opts)

  # Turns a LogOffset into a tuple representation
  # for storing in the ETS table
  defp storage_offset(offset) do
    LogOffset.to_tuple(offset)
  end
end
