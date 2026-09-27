defmodule TradingSwarm.KnowledgeBaseTest do
  use ExUnit.Case

  alias TradingSwarm.KnowledgeBase

  # Each test gets a fresh KB + DETS setup
  setup do
    # Stop existing KB if running
    if Process.whereis(TradingSwarm.KnowledgeBase) do
      if pid = Process.whereis(TradingSwarm.KnowledgeBase) do
        try do GenServer.stop(pid) catch :exit, _ -> :ok end
      end
    end

    # Clean up DETS file
    dets_path = Application.get_env(:trading_swarm, :dets_path, "data/test_kb.dets")
    File.rm(dets_path)

    # Ensure PubSub registry exists
    unless Process.whereis(TradingSwarm.PubSub) do
      {:ok, _} = Registry.start_link(keys: :duplicate, name: TradingSwarm.PubSub)
    end

    {:ok, _pid} = KnowledgeBase.start_link(%{})

    on_exit(fn ->
      if Process.whereis(TradingSwarm.KnowledgeBase) do
        if pid = Process.whereis(TradingSwarm.KnowledgeBase) do
        try do GenServer.stop(pid) catch :exit, _ -> :ok end
      end
      end
      File.rm(dets_path)
    end)

    :ok
  end

  # ============================================================
  # Basic CRUD
  # ============================================================

  describe "assert/get_by/retract cycle" do
    test "asserts and retrieves a fact" do
      KnowledgeBase.assert(:portfolio_state, %{cash: 10000.0, strategy_id: 1})
      results = KnowledgeBase.get_by(:portfolio_state, %{strategy_id: 1})
      assert length(results) == 1
      assert hd(results).cash == 10000.0
    end

    test "get_by with no conditions returns all facts of that type" do
      KnowledgeBase.assert(:portfolio_state, %{cash: 10000.0, strategy_id: 1})
      KnowledgeBase.assert(:portfolio_state, %{cash: 20000.0, strategy_id: 2})
      results = KnowledgeBase.get_by(:portfolio_state)
      assert length(results) == 2
    end

    test "get_by filters by conditions" do
      KnowledgeBase.assert(:position, %{symbol: "AAPL", quantity: 100, strategy_id: 1})
      KnowledgeBase.assert(:position, %{symbol: "MSFT", quantity: 50, strategy_id: 1})
      KnowledgeBase.assert(:position, %{symbol: "AAPL", quantity: 200, strategy_id: 2})

      results = KnowledgeBase.get_by(:position, %{symbol: "AAPL"})
      assert length(results) == 2

      results = KnowledgeBase.get_by(:position, %{symbol: "AAPL", strategy_id: 1})
      assert length(results) == 1
      assert hd(results).quantity == 100
    end

    test "retract removes a specific fact" do
      fact = %{cash: 10000.0, strategy_id: 1}
      KnowledgeBase.assert(:portfolio_state, fact)
      KnowledgeBase.retract(:portfolio_state, fact)
      assert KnowledgeBase.get_by(:portfolio_state, %{strategy_id: 1}) == []
    end

    test "retract does not affect other facts" do
      fact1 = %{cash: 10000.0, strategy_id: 1}
      fact2 = %{cash: 20000.0, strategy_id: 2}
      KnowledgeBase.assert(:portfolio_state, fact1)
      KnowledgeBase.assert(:portfolio_state, fact2)

      KnowledgeBase.retract(:portfolio_state, fact1)
      remaining = KnowledgeBase.get_by(:portfolio_state)
      assert length(remaining) == 1
      assert hd(remaining).strategy_id == 2
    end
  end

  # ============================================================
  # Update
  # ============================================================

  describe "update/3" do
    test "updates matching facts" do
      KnowledgeBase.assert(:portfolio_state, %{cash: 10000.0, strategy_id: 1})
      KnowledgeBase.update(:portfolio_state, %{strategy_id: 1}, %{cash: 9500.0})

      result = KnowledgeBase.get_by(:portfolio_state, %{strategy_id: 1}) |> List.first()
      assert result.cash == 9500.0
    end

    test "update only affects matching facts" do
      KnowledgeBase.assert(:portfolio_state, %{cash: 10000.0, strategy_id: 1})
      KnowledgeBase.assert(:portfolio_state, %{cash: 20000.0, strategy_id: 2})

      KnowledgeBase.update(:portfolio_state, %{strategy_id: 1}, %{cash: 5000.0})

      s1 = KnowledgeBase.get_by(:portfolio_state, %{strategy_id: 1}) |> List.first()
      s2 = KnowledgeBase.get_by(:portfolio_state, %{strategy_id: 2}) |> List.first()
      assert s1.cash == 5000.0
      assert s2.cash == 20000.0
    end
  end

  # ============================================================
  # has_facts?
  # ============================================================

  describe "has_facts?/1" do
    test "returns false for empty KB" do
      refute KnowledgeBase.has_facts?(:portfolio_state)
    end

    test "returns true after asserting a fact" do
      KnowledgeBase.assert(:portfolio_state, %{cash: 10000.0, strategy_id: 0})
      assert KnowledgeBase.has_facts?(:portfolio_state)
    end
  end

  # ============================================================
  # DETS Persistence
  # ============================================================

  describe "DETS persistence" do
    test "persisted types survive KB restart" do
      KnowledgeBase.assert(:portfolio_state, %{cash: 7777.0, strategy_id: 1})
      KnowledgeBase.assert(:position, %{symbol: "AAPL", quantity: 50, avg_price: 150.0, strategy_id: 1})

      # Stop and restart the KB
      if pid = Process.whereis(TradingSwarm.KnowledgeBase) do
        try do GenServer.stop(pid) catch :exit, _ -> :ok end
      end
      {:ok, _pid} = KnowledgeBase.start_link(%{})

      # Facts should be restored
      port = KnowledgeBase.get_by(:portfolio_state, %{strategy_id: 1}) |> List.first()
      assert port != nil
      assert port.cash == 7777.0

      pos = KnowledgeBase.get_by(:position, %{symbol: "AAPL", strategy_id: 1}) |> List.first()
      assert pos != nil
      assert pos.quantity == 50
    end

    test "ephemeral types do NOT survive restart" do
      KnowledgeBase.assert(:pending_order, %{symbol: "AAPL", action: :buy, quantity: 10, limit_price: 150.0, strategy_id: 1})

      if pid = Process.whereis(TradingSwarm.KnowledgeBase) do
        try do GenServer.stop(pid) catch :exit, _ -> :ok end
      end
      {:ok, _pid} = KnowledgeBase.start_link(%{})

      # Ephemeral facts should be gone
      assert KnowledgeBase.get_by(:pending_order) == []
    end

    test "updates to persisted types are durable" do
      KnowledgeBase.assert(:portfolio_state, %{cash: 10000.0, strategy_id: 1})
      KnowledgeBase.update(:portfolio_state, %{strategy_id: 1}, %{cash: 8500.0})

      if pid = Process.whereis(TradingSwarm.KnowledgeBase) do
        try do GenServer.stop(pid) catch :exit, _ -> :ok end
      end
      {:ok, _pid} = KnowledgeBase.start_link(%{})

      port = KnowledgeBase.get_by(:portfolio_state, %{strategy_id: 1}) |> List.first()
      assert port.cash == 8500.0
    end

    test "retracting a persisted type removes it from DETS" do
      fact = %{cash: 10000.0, strategy_id: 99}
      KnowledgeBase.assert(:portfolio_state, fact)
      KnowledgeBase.retract(:portfolio_state, fact)

      if pid = Process.whereis(TradingSwarm.KnowledgeBase) do
        try do GenServer.stop(pid) catch :exit, _ -> :ok end
      end
      {:ok, _pid} = KnowledgeBase.start_link(%{})

      assert KnowledgeBase.get_by(:portfolio_state, %{strategy_id: 99}) == []
    end
  end

  # ============================================================
  # PubSub
  # ============================================================

  describe "pub/sub" do
    test "subscribers receive :fact_asserted messages" do
      KnowledgeBase.subscribe(:trade_signal)
      KnowledgeBase.assert(:trade_signal, %{symbol: "AAPL", action: :buy, price: 150.0, strategy_id: 1})

      assert_receive {:fact_asserted, :trade_signal, %{symbol: "AAPL"}}, 1000
    end

    test "subscribers receive :fact_updated messages on update" do
      KnowledgeBase.subscribe(:portfolio_state)
      KnowledgeBase.assert(:portfolio_state, %{cash: 10000.0, strategy_id: 1})

      # Drain the :fact_asserted message
      assert_receive {:fact_asserted, :portfolio_state, _}, 1000

      KnowledgeBase.update(:portfolio_state, %{strategy_id: 1}, %{cash: 9000.0})
      assert_receive {:fact_updated, :portfolio_state, %{cash: 9000.0}}, 1000
    end

    test "non-subscribers do NOT receive messages" do
      KnowledgeBase.assert(:trade_signal, %{symbol: "AAPL", action: :buy, price: 150.0, strategy_id: 1})
      refute_receive {:fact_asserted, _, _}, 100
    end
  end
end
