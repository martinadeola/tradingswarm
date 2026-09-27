defmodule TradingSwarm.TechnicalAnalysisTest do
  use ExUnit.Case, async: true

  alias TradingSwarm.TechnicalAnalysis, as: TA

  # ============================================================
  # EMA
  # ============================================================

  describe "ema/2" do
    test "returns the single value for a one-element list" do
      assert TA.ema([100.0], 10) == 100.0
    end

    test "EMA of flat prices equals that price" do
      flat = List.duplicate(50.0, 30)
      assert_in_delta TA.ema(flat, 10), 50.0, 0.001
    end

    test "EMA of rising prices is above the SMA" do
      prices = Enum.map(1..30, fn i -> 100.0 + i * 1.0 end)
      ema_val = TA.ema(prices, 10)
      sma_val = Enum.sum(Enum.take(prices, -10)) / 10
      # EMA weights recent prices more, so for a rising series it should be >= SMA
      assert ema_val >= sma_val
    end
  end

  # ============================================================
  # SMA
  # ============================================================

  describe "sma/2" do
    test "SMA of known values" do
      prices = [10.0, 20.0, 30.0, 40.0, 50.0]
      assert_in_delta TA.sma(prices, 5), 30.0, 0.001
    end

    test "SMA only uses last N values" do
      prices = [1.0, 2.0, 3.0, 4.0, 5.0, 100.0, 100.0, 100.0]
      assert_in_delta TA.sma(prices, 3), 100.0, 0.001
    end
  end

  # ============================================================
  # RSI
  # ============================================================

  describe "rsi/2" do
    test "RSI of steadily rising prices is overbought (>70)" do
      prices = Enum.map(1..50, fn i -> 100.0 + i * 0.5 end)
      rsi_val = TA.rsi(prices)
      assert rsi_val > 70.0, "Expected RSI > 70 for rising prices, got #{rsi_val}"
    end

    test "RSI of steadily falling prices is oversold (<30)" do
      prices = Enum.map(1..50, fn i -> 200.0 - i * 0.5 end)
      rsi_val = TA.rsi(prices)
      assert rsi_val < 30.0, "Expected RSI < 30 for falling prices, got #{rsi_val}"
    end

    test "RSI of flat prices returns 100 (no losses)" do
      # When all price changes are zero, avg_loss = 0, which means RS = infinity → RSI = 100
      prices = List.duplicate(100.0, 50)
      rsi_val = TA.rsi(prices)
      assert_in_delta rsi_val, 100.0, 1.0
    end

    test "RSI is bounded between 0 and 100" do
      prices = Enum.map(1..50, fn i -> 100.0 + :math.sin(i / 3.0) * 10 end)
      rsi_val = TA.rsi(prices)
      assert rsi_val >= 0.0
      assert rsi_val <= 100.0
    end
  end

  # ============================================================
  # ATR
  # ============================================================

  describe "atr/2" do
    test "ATR is positive for volatile prices" do
      prices = Enum.map(1..50, fn i -> 100.0 + :math.sin(i / 2.0) * 5 end)
      atr_val = TA.atr(prices)
      assert atr_val > 0.0, "Expected positive ATR for volatile prices, got #{atr_val}"
    end

    test "ATR is near zero for flat prices" do
      prices = List.duplicate(100.0, 50)
      atr_val = TA.atr(prices)
      assert_in_delta atr_val, 0.0, 0.01
    end

    test "ATR increases with higher volatility" do
      low_vol = Enum.map(1..50, fn i -> 100.0 + :math.sin(i / 2.0) * 1 end)
      high_vol = Enum.map(1..50, fn i -> 100.0 + :math.sin(i / 2.0) * 10 end)
      assert TA.atr(high_vol) > TA.atr(low_vol)
    end
  end

  # ============================================================
  # MACD
  # ============================================================

  describe "macd/1" do
    test "returns {0.0, 0.0} for insufficient data" do
      assert TA.macd(Enum.to_list(1..10)) == {0.0, 0.0}
    end

    test "MACD line is positive for uptrending prices" do
      prices = Enum.map(1..50, fn i -> 100.0 + i * 1.0 end)
      {macd_line, _signal} = TA.macd(prices)
      assert macd_line > 0, "Expected positive MACD for uptrend, got #{macd_line}"
    end

    test "MACD line is negative for downtrending prices" do
      prices = Enum.map(1..50, fn i -> 200.0 - i * 1.0 end)
      {macd_line, _signal} = TA.macd(prices)
      assert macd_line < 0, "Expected negative MACD for downtrend, got #{macd_line}"
    end
  end

  describe "macd_histogram_trend/1" do
    test "returns :flat for insufficient data" do
      {trend, _} = TA.macd_histogram_trend(Enum.to_list(1..10))
      assert trend == :flat
    end

    test "detects accelerating bullish trend" do
      # Strongly accelerating uptrend
      prices = Enum.map(1..50, fn i -> 100.0 + :math.pow(i / 10.0, 2) end)
      {trend, _vals} = TA.macd_histogram_trend(prices)
      assert trend in [:accelerating_bullish, :flat]
    end
  end

  # ============================================================
  # ADX
  # ============================================================

  describe "adx/2" do
    test "ADX is high for strongly trending data" do
      prices = Enum.map(1..50, fn i -> 100.0 + i * 2.0 end)
      adx_val = TA.adx(prices)
      assert adx_val > 25.0, "Expected ADX > 25 for trending data, got #{adx_val}"
    end

    test "ADX is bounded between 0 and 100" do
      prices = Enum.map(1..50, fn i -> 100.0 + :math.sin(i / 3.0) * 5 end)
      adx_val = TA.adx(prices)
      assert adx_val >= 0.0
      assert adx_val <= 100.0
    end
  end

  # ============================================================
  # Bollinger Band Width
  # ============================================================

  describe "bb_width/2" do
    test "BB width is zero for flat prices" do
      prices = List.duplicate(100.0, 30)
      assert_in_delta TA.bb_width(prices), 0.0, 0.01
    end

    test "BB width increases with volatility" do
      low_vol = Enum.map(1..30, fn i -> 100.0 + :math.sin(i) * 1 end)
      high_vol = Enum.map(1..30, fn i -> 100.0 + :math.sin(i) * 10 end)
      assert TA.bb_width(high_vol) > TA.bb_width(low_vol)
    end
  end

  # ============================================================
  # Utilities
  # ============================================================

  describe "stddev/1" do
    test "stddev of identical values is zero" do
      assert_in_delta TA.stddev(List.duplicate(42.0, 10)), 0.0, 0.001
    end

    test "stddev of known values" do
      # stddev of [2, 4, 4, 4, 5, 5, 7, 9] = 2.0
      values = [2.0, 4.0, 4.0, 4.0, 5.0, 5.0, 7.0, 9.0]
      assert_in_delta TA.stddev(values), 2.0, 0.01
    end

    test "returns 0.0 for single element" do
      assert TA.stddev([5.0]) == 0.0
    end
  end
end
