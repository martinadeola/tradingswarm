File.mkdir_p!("data")
IO.puts("Generating realistic synthetic backtest data with market regimes...")

start_time = DateTime.utc_now() |> DateTime.add(-60, :day)

initial_state = %{
  "AAPL" => 150.0,
  "MSFT" => 300.0,
  "GOOG" => 2800.0
}

# Market regime definitions
# Each regime has a drift (bias), volatility, and duration range
regimes = [
  %{name: "bull_trend", drift: 0.0008, volatility: 0.003, duration: 200..500},
  %{name: "bear_trend", drift: -0.0006, volatility: 0.004, duration: 200..400},
  %{name: "range_bound", drift: 0.0, volatility: 0.002, duration: 300..600},
  %{name: "high_volatility", drift: 0.0001, volatility: 0.008, duration: 100..300},
  %{name: "low_volatility", drift: 0.0002, volatility: 0.001, duration: 300..500}
]

# Pre-generate regime schedule for 10,000 ticks
{regime_schedule, _} =
  Enum.reduce_while(1..100, {[], 0}, fn _i, {schedule, total_ticks} ->
    regime = Enum.random(regimes)
    duration = Enum.random(regime.duration)
    remaining = 10_000 - total_ticks
    actual_duration = min(duration, remaining)

    new_schedule = schedule ++ List.duplicate(regime, actual_duration)
    new_total = total_ticks + actual_duration

    if new_total >= 10_000 do
      {:halt, {Enum.take(new_schedule, 10_000), new_total}}
    else
      {:cont, {new_schedule, new_total}}
    end
  end)

IO.puts("Generated regime schedule: #{length(regime_schedule)} ticks across multiple regimes")

file = File.open!("data/historical.csv", [:write])
IO.write(file, "symbol,price,volume,timestamp\n")

# Intraday volume pattern (U-shaped: high at open/close, low midday)
# Simulates 6.5-hour trading day (13:30-20:00 UTC = 390 minutes)
volume_curve = fn minute_of_day ->
  # Normalize to 0-1 range within trading day
  t = minute_of_day / 390.0
  # U-shaped curve: high at 0 and 1, low at 0.5
  base = 1.0 + 2.0 * :math.pow(2.0 * t - 1.0, 2)
  base
end

# Correlation matrix: MSFT and GOOG partially follow AAPL's moves
# This makes pairs trading viable
correlation_factor = 0.6

Enum.reduce(1..10_000, initial_state, fn i, state ->
  time = DateTime.add(start_time, i * 60, :second) |> DateTime.to_iso8601()
  regime = Enum.at(regime_schedule, i - 1, Enum.random(regimes))

  # Generate AAPL's move first (leader)
  aapl_change = regime.drift + (:rand.normal() * regime.volatility)

  Enum.reduce(["AAPL", "MSFT", "GOOG"], state, fn sym, acc_state ->
    current_price = acc_state[sym]

    # Correlated moves: other stocks partially follow AAPL
    idiosyncratic_change = regime.drift + (:rand.normal() * regime.volatility)

    change_pct =
      if sym == "AAPL" do
        aapl_change
      else
        # Blend AAPL's move with idiosyncratic move
        correlation_factor * aapl_change + (1 - correlation_factor) * idiosyncratic_change
      end

    new_price = current_price * (1.0 + change_pct)
    new_price = max(new_price, 1.0)  # Floor at $1

    # U-shaped intraday volume
    minute_of_day = rem(i, 390)
    vol_multiplier = volume_curve.(minute_of_day)
    base_vol = Enum.random(5000..30000)
    vol = trunc(base_vol * vol_multiplier)

    # Extra volume during high-volatility regime
    vol = if regime.name == "high_volatility", do: trunc(vol * 1.8), else: vol

    IO.write(file, "#{sym},#{Float.round(new_price, 2)},#{vol},#{time}\n")
    Map.put(acc_state, sym, new_price)
  end)
end)

File.close(file)
IO.puts("Generated data/historical.csv with 30,000 rows (10,000 ticks × 3 symbols)")
IO.puts("Regimes included: bull_trend, bear_trend, range_bound, high_volatility, low_volatility")
IO.puts("Features: correlated moves (AAPL leads), U-shaped intraday volume, regime-specific volatility")
