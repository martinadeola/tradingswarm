defmodule TradingSwarm.PipelineTest do
  @moduledoc """
  Integration test: exercises the full signal → risk → broker → exchange → accountant pipeline.

  Verifies that asserting a trade_signal eventually results in a portfolio state change,
  passing through every agent in the chain.
  """
  use ExUnit.Case

  alias TradingSwarm.KnowledgeBase
  alias TradingSwarm.Agents.{RiskManager, Broker, ExchangeMatcher, Accountant, CircuitBreaker}

  @strategy_id 1

  setup do
    # Stop any existing processes
    for name <- [
      TradingSwarm.KnowledgeBase,
      TradingSwarm.Agents.Broker,
      TradingSwarm.Agents.ExchangeMatcher,
      TradingSwarm.Agents.Accountant,
      TradingSwarm.Agents.CircuitBreaker
    ] do
      if pid = Process.whereis(name) do
        try do GenServer.stop(pid) catch :exit, _ -> :ok end
      end
    end

    dets_path = Application.get_env(:trading_swarm, :dets_path, "data/test_kb.dets")
    File.rm(dets_path)

    unless Process.whereis(TradingSwarm.PubSub) do
      {:ok, _} = Registry.start_link(keys: :duplicate, name: TradingSwarm.PubSub)
    end

    {:ok, _} = KnowledgeBase.start_link(%{})
    {:ok, _} = CircuitBreaker.start_link(%{})
    {:ok, rm_pid} = RiskManager.start_link(%{strategy_id: @strategy_id})
    {:ok, _} = Broker.start_link(%{})
    {:ok, _} = ExchangeMatcher.start_link(%{})
    {:ok, _} = Accountant.start_link(%{})

    # Initialize portfolio
    KnowledgeBase.assert(:portfolio_state, %{cash: 50_000.0, strategy_id: @strategy_id})

    # Publish ATR so risk manager can size positions
    KnowledgeBase.assert(:indicator, %{symbol: "AAPL", name: "atr", value: 2.0})

    on_exit(fn ->
      if Process.alive?(rm_pid) do
        try do GenServer.stop(rm_pid) catch :exit, _ -> :ok end
      end
      for name <- [
        TradingSwarm.Agents.Accountant,
        TradingSwarm.Agents.ExchangeMatcher,
        TradingSwarm.Agents.Broker,
        TradingSwarm.Agents.CircuitBreaker,
        TradingSwarm.KnowledgeBase
      ] do
        if pid = Process.whereis(name) do
        try do GenServer.stop(pid) catch :exit, _ -> :ok end
      end
      end
      File.rm(dets_path)
    end)

    %{rm_pid: rm_pid}
  end

  describe "full pipeline: signal → fill → accounting" do
    test "Buy signal flows through entire pipeline and updates portfolio" do
      initial_port = KnowledgeBase.get_by(:portfolio_state, %{strategy_id: @strategy_id}) |> List.first()
      initial_cash = initial_port.cash

      # Step 1: Assert a trade signal (this triggers the Risk Manager)
      KnowledgeBase.assert(:trade_signal, %{
        symbol: "AAPL", action: :buy, price: 150.0, strategy_id: @strategy_id
      })

      # Give Risk Manager time to process → creates approved_order
      Process.sleep(200)

      # Step 2: Verify Broker created a pending order
      pending = KnowledgeBase.get_by(:pending_order, %{symbol: "AAPL", strategy_id: @strategy_id})
      assert length(pending) > 0, "Broker should have created a pending order"

      # Step 3: Assert market data to trigger the ExchangeMatcher
      KnowledgeBase.assert(:market_data, %{
        symbol: "AAPL",
        price: 150.0,
        volume: 20000,
        time: DateTime.utc_now()
      })

      # First tick registers the order (fill latency = 1 tick delay)
      Process.sleep(100)

      # Second tick should actually fill the order
      KnowledgeBase.assert(:market_data, %{
        symbol: "AAPL",
        price: 149.0, # Lower price to guarantee limit buy fills
        volume: 20000,
        time: DateTime.utc_now()
      })

      # Give the full pipeline time to settle
      Process.sleep(500)

      # Step 4: Verify Accountant updated the portfolio
      final_port = KnowledgeBase.get_by(:portfolio_state, %{strategy_id: @strategy_id}) |> List.first()
      assert final_port.cash < initial_cash, "Cash should have decreased after a Buy"

      # Step 5: Verify position was created
      positions = KnowledgeBase.get_by(:position, %{symbol: "AAPL", strategy_id: @strategy_id})
      assert length(positions) == 1, "Should have an AAPL position"
      pos = hd(positions)
      assert pos.quantity > 0, "Position should be long"

      # Step 6: Verify no orphaned intermediate state
      signals = KnowledgeBase.get_by(:trade_signal, %{strategy_id: @strategy_id})
      assert signals == [], "Trade signal should be cleaned up"

      approved = KnowledgeBase.get_by(:approved_order, %{strategy_id: @strategy_id})
      assert approved == [], "Approved order should be cleaned up"

      receipts = KnowledgeBase.get_by(:order_receipt, %{strategy_id: @strategy_id})
      assert receipts == [], "Order receipt should be cleaned up"
    end

    test "Sell signal closes position and returns cash" do
      # Setup: manually create a position (simulating a completed buy)
      KnowledgeBase.assert(:position, %{
        symbol: "AAPL", quantity: 100, avg_price: 140.0, strategy_id: @strategy_id
      })

      initial_port = KnowledgeBase.get_by(:portfolio_state, %{strategy_id: @strategy_id}) |> List.first()
      initial_cash = initial_port.cash

      # Send sell signal
      KnowledgeBase.assert(:trade_signal, %{
        symbol: "AAPL", action: :sell, price: 155.0, strategy_id: @strategy_id
      })

      Process.sleep(200)

      # Trigger exchange matching
      KnowledgeBase.assert(:market_data, %{
        symbol: "AAPL", price: 156.0, volume: 20000, time: DateTime.utc_now()
      })
      Process.sleep(100)
      KnowledgeBase.assert(:market_data, %{
        symbol: "AAPL", price: 156.0, volume: 20000, time: DateTime.utc_now()
      })

      Process.sleep(500)

      # Cash should have increased
      final_port = KnowledgeBase.get_by(:portfolio_state, %{strategy_id: @strategy_id}) |> List.first()
      assert final_port.cash > initial_cash, "Cash should increase after selling"

      # Position should be closed
      positions = KnowledgeBase.get_by(:position, %{symbol: "AAPL", strategy_id: @strategy_id})
      assert positions == [], "Position should be fully closed after sell"
    end
  end
end
