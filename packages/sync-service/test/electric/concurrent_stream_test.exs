defmodule Electric.ConcurrentStreamTest do
  use ExUnit.Case, async: true
  alias Electric.ConcurrentStream

  describe "stream_to_end/2" do
    @tag :tmp_dir
    test "returns complete stream from CubDB when it's being written to concurrently", ctx do
      item_count = 10
      end_marker_key = item_count + 1
      db = :"cubdb_#{ctx.test}"
      CubDB.start_link(data_dir: ctx.tmp_dir, name: db)

      stream =
        ConcurrentStream.stream_to_end(
          excluded_start_key: 0,
          end_marker_key: end_marker_key,
          stream_fun: fn excluded_start_key, included_end_key ->
            CubDB.select(db,
              min_key: excluded_start_key,
              end_key: included_end_key,
              min_key_inclusive: false
            )
          end
        )

      read_task =
        Task.async(fn ->
          items = Enum.to_list(stream)

          assert Enum.count(items) == item_count

          for i <- 1..item_count do
            assert Enum.at(items, i - 1) == {i, "item_#{i}"}
          end
        end)

      # Write the stream concurrently
      for i <- 1..item_count do
        CubDB.put(db, i, "item_#{i}")
        # Sleep to give the read process time to run
        Process.sleep(1)
      end

      # Write the end marker to let the read process that the stream has ended
      CubDB.put(db, end_marker_key, "ended")

      Task.await(read_task)
    end
  end
end
