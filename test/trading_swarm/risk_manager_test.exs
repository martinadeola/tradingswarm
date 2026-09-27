defmodule TradingSwarm.Agents.RiskManagerTest do
  use ExUnit.Case

  alias TradingSwarm.KnowledgeBase
  alias TradingSwarm.Agents.{RiskManager, CircuitBreaker}

  @strategy_id 1

  setup do
    # Stop existing processes
    for name <- [TradingSwarm.KnowledgeBase, TradingSwarm.Agents.CircuitBreaker] do
      if pid = Process.whereis(name) do
        try do GenServer.stop(pid) catch :exit, _ -> :ok end
      end
    end

    # Kill any existing risk manager instances (they're not named)
    dets_path = Application.get_env(:trading_swarm, :dets_path, "data/test_kb.dets")
    File.rm(dets_path)

    unless Process.whereis(TradingSwarm.PubSub) do
      {:ok, _} = Registry.start_link(keys: :duplicate, name: TradingSwarm.PubSub)
    end

    {:ok, _} = KnowledgeBase.start_link(%{})
    {:ok, _} = CircuitBreaker.start_link(%{})

    # Initialize portfolio with $100,000 for easier math
    KnowledgeBase.assert(:portfolio_state, %{cash: 100_000.0, strategy_id: @strategy_id})

    # Start a risk manager for our test strategy
    {:ok, rm_pid} = RiskManager.start_link(%{strategy_id: @strategy_id})

    on_exit(fn ->
      if Process.alive?(rm_pid) do
        try do GenServer.stop(rm_pid) catch :exit, _ -> :ok end
      end
      for name <- [TradingSwarm.Agents.CircuitBreaker, TradingSwarm.KnowledgeBase] do
        if pid = Process.whereis(name) do
        try do GenServer.stop(pid) catch :exit, _ -> :ok end
      end
      end
      File.rm(dets_path)
    end)

    %{rm_pid: rm_pid}
  end

  # ============================================================
  # Exit trades always approved
  # ============================================================

  describe "exit trades" do
    test "Sell signal is always approved when position exists" do
      # Create an existing long position
      KnowledgeBase.assert(:position, %{symbol: "AAPL", quantity: 100, avg_price: 150.0, strategy_id: @strategy_id})

      # Subscribe to approved orders
      KnowledgeBase.subscribe(:approved_order)

      # Send sell signal
      KnowledgeBase.assert(:trade_signal, %{symbol: "AAPL", action: :sell, price: 160.0, strategy_id: @strategy_id})

      assert_receive {:fact_asserted, :approved_order, order}, 1000
      assert order.action == :sell
      assert order.symbol == "AAPL"
      assert order.quantity == 100
    end

    test "Cover signal is always approved when short position exists" do
      # Create an existing short position (negative quantity)
      KnowledgeBase.assert(:position, %{symbol: "MSFT", quantity: -50, avg_price: 300.0, strategy_id: @strategy_id})

      KnowledgeBase.subscribe(:approved_order)

      KnowledgeBase.assert(:trade_signal, %{symbol: "MSFT", action: :cover, price: 280.0, strategy_id: @strategy_id})

      assert_receive {:fact_asserted, :approved_order, order}, 1000
      assert order.action == :cover
      assert order.quantity == 50
    end
  end

  # ============================================================
  # Entry trade gating
  # ============================================================

  describe "entry trade risk checks" do
    test "Buy signal is approved when all risk limits are satisfied" do
      # Publish ATR so position sizing works
      KnowledgeBase.assert(:indicator, %{symbol: "AAPL", name: "atr", value: 2.0})

      KnowledgeBase.subscribe(:approved_order)

      KnowledgeBase.assert(:trade_signal, %{symbol: "AAPL", action: :buy, price: 150.0, strategy_id: @strategy_id})

      assert_receive {:fact_asserted, :approved_order, order}, 1000
      assert order.action == :buy
      assert order.quantity > 0
    end

    test "Buy signal is blocked when total exposure exceeds 30%" do
      # Fill up exposure to 30% of equity ($100k * 0.30 = $30k)
      # Create a position worth $35k (exceeds 30%)
      KnowledgeBase.update(:portfolio_state, %{strategy_id: @strategy_id}, %{cash: 65_000.0})
      KnowledgeBase.assert(:position, %{symbol: "GOOG", quantity: 250, avg_price: 140.0, strategy_id: @strategy_id})

      KnowledgeBase.subscribe(:approved_order)

      KnowledgeBase.assert(:trade_signal, %{symbol: "AAPL", action: :buy, price: 150.0, strategy_id: @strategy_id})

      # Should NOT receive an approved order
      refute_receive {:fact_asserted, :approved_order, _}, 500
    end

    test "Buy signal is blocked when single-symbol concentration exceeds 15%" do
      # Create existing position in AAPL worth > 15% of equity ($100k * 0.15 = $15k)
      KnowledgeBase.update(:portfolio_state, %{strategy_id: @strategy_id}, %{cash: 83_500.0})
      KnowledgeBase.assert(:position, %{symbol: "AAPL", quantity: 110, avg_price: 150.0, strategy_id: @strategy_id})

      KnowledgeBase.subscribe(:approved_order)

      KnowledgeBase.assert(:trade_signal, %{symbol: "AAPL", action: :buy, price: 150.0, strategy_id: @strategy_id})

      refute_receive {:fact_asserted, :approved_order, _}, 500
    end

    test "Buy signal is blocked when insufficient cash" do
      # Drain cash
      KnowledgeBase.update(:portfolio_state, %{strategy_id: @strategy_id}, %{cash: 1.0})

      KnowledgeBase.subscribe(:approved_order)

      KnowledgeBase.assert(:trade_signal, %{symbol: "AAPL", action: :buy, price: 150.0, strategy_id: @strategy_id})

      refute_receive {:fact_asserted, :approved_order, _}, 500
    end
  end

  # ============================================================
  # Position sizing
  # ============================================================

  describe "position sizing" do
    test "position size is based on ATR and 2% risk" do
      # ATR of $5 means stop distance = $5
      # 2% of $100k equity = $2,000 risk
      # Expected quantity = $2,000 / $5 = 400 shares
      KnowledgeBase.assert(:indicator, %{symbol: "AAPL", name: "atr", value: 5.0})

      KnowledgeBase.subscribe(:approved_order)

      KnowledgeBase.assert(:trade_signal, %{symbol: "AAPL", action: :buy, price: 150.0, strategy_id: @strategy_id})

      assert_receive {:fact_asserted, :approved_order, order}, 1000
      # Quantity should be capped by exposure limits, but the ATR-based sizing should be ≤ 400
      assert order.quantity > 0
      assert order.quantity <= 400
    end
  end

  # ============================================================
  # Signal cleanup
  # ============================================================

  describe "signal lifecycle" do
    test "trade signal is retracted after processing" do
      KnowledgeBase.assert(:indicator, %{symbol: "AAPL", name: "atr", value: 2.0})

      KnowledgeBase.assert(:trade_signal, %{symbol: "AAPL", action: :buy, price: 150.0, strategy_id: @strategy_id})

      Process.sleep(500)
      signals = KnowledgeBase.get_by(:trade_signal, %{strategy_id: @strategy_id})
      assert signals == [], "Trade signal should be retracted after processing"
    end
  end
end
