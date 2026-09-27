csv_files = Path.wildcard("data/1m/*.csv") |> Enum.take(100)
symbols = Enum.map(csv_files, &Path.basename(&1, ".csv"))

IO.puts("Merging Kaggle Minute Data for: #{inspect(symbols)}")

all_rows = 
  Enum.flat_map(symbols, fn sym ->
    file_path = "data/1m/#{sym}.csv"
    
    if File.exists?(file_path) do
      File.read!(file_path)
      |> String.split("\n", trim: true)
      |> Enum.drop(1)
      |> Enum.take(2000)
      |> Enum.map(fn line ->
        parts = String.split(line, ",")
        if length(parts) >= 6 do
          time_str = Enum.at(parts, 0)
          time_str = String.replace(time_str, " ", "T")
          
          close_price = Enum.at(parts, 4)
          volume = Enum.at(parts, 5)
          
          {time_str, sym, close_price, volume}
        else
          nil
        end
      end)
      |> Enum.reject(&is_nil/1)
    else
      IO.puts("Warning: #{file_path} not found.")
      []
    end
  end)

IO.puts("Total rows extracted: #{length(all_rows)}")
IO.puts("Sorting by timestamp (chronological order)...")

sorted_rows = Enum.sort_by(all_rows, fn {time_str, _sym, _p, _v} -> time_str end)

out_file = File.open!("data/historical.csv", [:write])
IO.write(out_file, "symbol,price,volume,timestamp\n")

Enum.each(sorted_rows, fn {time_str, sym, p, v} ->
  IO.write(out_file, "#{sym},#{p},#{v},#{time_str}\n")
end)

File.close(out_file)
IO.puts("Successfully merged and sorted data to data/historical.csv!")
