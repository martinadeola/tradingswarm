defmodule TradingSwarm.TechnicalAnalysis do
  @moduledoc """
  Technical analysis functions used by quant agents.
  All functions expect prices in chronological order (oldest first) unless noted.
  """

  # ============================================================
  # Moving Averages
  # ============================================================

  def ema(prices, n) do
    k = 2 / (n + 1)

    Enum.reduce(prices, nil, fn price, prev_ema ->
      case prev_ema do
        nil -> price
        _ -> (price * k) + (prev_ema * (1 - k))
      end
    end)
  end

  def ema_series(prices, n) do
    k = 2 / (n + 1)

    {series, _} = Enum.map_reduce(prices, nil, fn price, prev_ema ->
      new_ema = case prev_ema do
        nil -> price
        _ -> (price * k) + (prev_ema * (1 - k))
      end
      {new_ema, new_ema}
    end)
    series
  end

  def sma(prices, n) when length(prices) >= n do
    prices
    |> Enum.take(-n)
    |> then(fn window -> Enum.sum(window) / length(window) end)
  end
  def sma(prices, _n), do: Enum.sum(prices) / max(length(prices), 1)

  # ============================================================
  # MACD
  # ============================================================

  def macd(prices) do
    if length(prices) < 26 do
      {0.0, 0.0}
    else
      ema12_series = ema_series(prices, 12)
      ema26_series = ema_series(prices, 26)

      macd_series = Enum.zip(ema12_series, ema26_series) |> Enum.map(fn {e12, e26} -> e12 - e26 end)

      signal = ema(macd_series, 9)
      macd_line = List.last(macd_series)

      {macd_line, signal}
    end
  end

  @doc """
  Returns the last 3 MACD histogram values (newest first) for acceleration detection.
  Histogram = MACD line - Signal line.
  """
  def macd_histogram_trend(prices) do
    if length(prices) < 26 do
      {:flat, [0.0, 0.0, 0.0]}
    else
      ema12_series = ema_series(prices, 12)
      ema26_series = ema_series(prices, 26)

      macd_series = Enum.zip(ema12_series, ema26_series) |> Enum.map(fn {e12, e26} -> e12 - e26 end)
      signal_series = ema_series(macd_series, 9)

      histogram = Enum.zip(macd_series, signal_series) |> Enum.map(fn {m, s} -> m - s end)

      last3 = histogram |> Enum.take(-3)

      cond do
        length(last3) < 3 -> {:flat, last3}
        Enum.at(last3, 2) > Enum.at(last3, 1) and Enum.at(last3, 1) > Enum.at(last3, 0) ->
          {:accelerating_bullish, last3}
        Enum.at(last3, 2) < Enum.at(last3, 1) and Enum.at(last3, 1) < Enum.at(last3, 0) ->
          {:accelerating_bearish, last3}
        true ->
          {:flat, last3}
      end
    end
  end

  # ============================================================
  # RSI
  # ============================================================

  def rsi(prices, period \\ 14) do
    if length(prices) <= period do
      50.0
    else
      changes = Enum.chunk_every(prices, 2, 1, :discard) |> Enum.map(fn [prev, curr] -> curr - prev end)

      {initial_changes, rest_changes} = Enum.split(changes, period)

      avg_gain = (Enum.filter(initial_changes, &(&1 > 0)) |> Enum.sum()) / period
      avg_loss = abs((Enum.filter(initial_changes, &(&1 < 0)) |> Enum.sum()) / period)

      {final_gain, final_loss} = Enum.reduce(rest_changes, {avg_gain, avg_loss}, fn change, {ag, al} ->
        gain = max(change, 0)
        loss = abs(min(change, 0))

        new_ag = (ag * (period - 1) + gain) / period
        new_al = (al * (period - 1) + loss) / period
        {new_ag, new_al}
      end)

      cond do
        final_loss == 0.0 -> 100.0
        final_gain == 0.0 -> 0.0
        true ->
          rs = final_gain / final_loss
          100.0 - (100.0 / (1.0 + rs))
      end
    end
  end

  # ============================================================
  # ATR (Average True Range)
  # ============================================================

  @doc """
  Approximate ATR from close prices only (since we don't have H/L/C candles).
  Uses absolute price changes as a proxy for true range.
  """
  def atr(prices, period \\ 14) do
    if length(prices) < period + 1 do
      # Fallback: use stddev of prices as volatility proxy
      stddev(prices)
    else
      # True range approximation from closes: |close_t - close_{t-1}|
      ranges =
        prices
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [prev, curr] -> abs(curr - prev) end)

      # Use Wilder's smoothing (same as EMA with period weighting)
      {initial, rest} = Enum.split(ranges, period)
      initial_atr = Enum.sum(initial) / period

      Enum.reduce(rest, initial_atr, fn tr, prev_atr ->
        (prev_atr * (period - 1) + tr) / period
      end)
    end
  end

  # ============================================================
  # ADX (Average Directional Index) — Trend Strength
  # ============================================================

  @doc """
  Simplified ADX calculation from close prices.
  Returns a value 0-100. Above 25 = trending, below 20 = range-bound.
  Uses price momentum as a proxy for directional movement.
  """
  def adx(prices, period \\ 14) do
    if length(prices) < period * 2 + 1 do
      25.0  # Neutral default
    else
      changes =
        prices
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [prev, curr] -> curr - prev end)

      # Split into +DM and -DM approximations
      plus_dm = Enum.map(changes, fn c -> if c > 0, do: c, else: 0.0 end)
      minus_dm = Enum.map(changes, fn c -> if c < 0, do: abs(c), else: 0.0 end)

      # Smooth with Wilder's method
      atr_val = max(atr(prices, period), 0.0001)

      smooth_plus = wilder_smooth(plus_dm, period)
      smooth_minus = wilder_smooth(minus_dm, period)

      # Directional indicators
      plus_di = (smooth_plus / atr_val) * 100
      minus_di = (smooth_minus / atr_val) * 100

      # DX
      di_sum = plus_di + minus_di
      dx = if di_sum > 0, do: (abs(plus_di - minus_di) / di_sum) * 100, else: 0.0

      # ADX is a smoothed DX — for simplicity, we use DX directly
      min(dx, 100.0)
    end
  end

  # ============================================================
  # Bollinger Band Width — Volatility Regime
  # ============================================================

  @doc """
  Bollinger Band width as a percentage of SMA.
  Low values = range-bound (good for mean reversion).
  High values = trending/volatile (good for momentum).
  """
  def bb_width(prices, period \\ 20) do
    if length(prices) < period do
      0.0
    else
      window = Enum.take(prices, -period)
      mean = Enum.sum(window) / period
      std = stddev(window)

      if mean > 0 do
        (4 * std) / mean * 100  # Width as percentage
      else
        0.0
      end
    end
  end

  # ============================================================
  # Utilities
  # ============================================================

  @doc "Standard deviation of a list of numbers."
  def stddev(values) when length(values) < 2, do: 0.0
  def stddev(values) do
    n = length(values)
    mean = Enum.sum(values) / n
    variance = Enum.reduce(values, 0.0, fn v, acc -> acc + :math.pow(v - mean, 2) end) / n
    :math.sqrt(variance)
  end

  @doc "Wilder's smoothing (used in ATR and ADX calculations)."
  def wilder_smooth(values, period) when length(values) < period, do: 0.0
  def wilder_smooth(values, period) do
    {initial, rest} = Enum.split(values, period)
    initial_avg = Enum.sum(initial) / period

    Enum.reduce(rest, initial_avg, fn val, prev ->
      (prev * (period - 1) + val) / period
    end)
  end
end
