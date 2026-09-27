defmodule TradingSwarm.Agents.AccountantTest do
  use ExUnit.Case

  alias TradingSwarm.KnowledgeBase
  alias TradingSwarm.Agents.Accountant

  setup do
    # Stop existing processes if running
    for name <- [TradingSwarm.KnowledgeBase, TradingSwarm.Agents.Accountant] do
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
    {:ok, _} = Accountant.start_link(%{})

    # Initialize a portfolio for strategy 1
    KnowledgeBase.assert(:portfolio_state, %{cash: 10000.0, strategy_id: 1})

    on_exit(fn ->
      for name <- [TradingSwarm.Agents.Accountant, TradingSwarm.KnowledgeBase] do
        if pid = Process.whereis(name) do
        try do GenServer.stop(pid) catch :exit, _ -> :ok end
      end
      end
      File.rm(dets_path)
    end)

    :ok
  end

  # Helper to wait for the Accountant to process the receipt
  defp assert_processed(strategy_id, timeout \\ 500) do
    # Wait for Accountant to retract the order_receipt (signals processing is done)
    Process.sleep(timeout)
    port = KnowledgeBase.get_by(:portfolio_state, %{strategy_id: strategy_id}) |> List.first()
    pos_list = KnowledgeBase.get_by(:position, %{strategy_id: strategy_id})
    {port, pos_list}
  end

  # ============================================================
  # Buy
  # ============================================================

  describe "Buy processing" do
    test "Buy decreases cash and creates position" do
      KnowledgeBase.assert(:order_receipt, %{
        symbol: "AAPL", action: :buy, quantity: 10, price: 150.0,
        time: DateTime.utc_now(), strategy_id: 1
      })

      {port, positions} = assert_processed(1)

      assert_in_delta port.cash, 10000.0 - (10 * 150.0), 0.01
      assert length(positions) == 1

      pos = hd(positions)
      assert pos.symbol == "AAPL"
      assert pos.quantity == 10
      assert_in_delta pos.avg_price, 150.0, 0.01
    end

    test "Buy into existing long position updates weighted average price" do
      # First buy
      KnowledgeBase.assert(:order_receipt, %{
        symbol: "AAPL", action: :buy, quantity: 10, price: 100.0,
        time: DateTime.utc_now(), strategy_id: 1
      })
      Process.sleep(200)

      # Second buy at different price
      KnowledgeBase.assert(:order_receipt, %{
        symbol: "AAPL", action: :buy, quantity: 10, price: 200.0,
        time: DateTime.utc_now(), strategy_id: 1
      })

      {port, positions} = assert_processed(1)

      # Weighted average: (10*100 + 10*200) / 20 = 150
      pos = Enum.find(positions, fn p -> p.symbol == "AAPL" end)
      assert pos.quantity == 20
      assert_in_delta pos.avg_price, 150.0, 0.01

      # Cash: 10000 - (10*100) - (10*200) = 7000
      assert_in_delta port.cash, 7000.0, 0.01
    end
  end

  # ============================================================
  # Sell
  # ============================================================

  describe "Sell processing" do
    test "Sell increases cash and removes position on full close" do
      # Setup: create a long position first
      KnowledgeBase.assert(:order_receipt, %{
        symbol: "AAPL", action: :buy, quantity: 10, price: 100.0,
        time: DateTime.utc_now(), strategy_id: 1
      })
      Process.sleep(200)

      # Sell all shares at a profit
      KnowledgeBase.assert(:order_receipt, %{
        symbol: "AAPL", action: :sell, quantity: 10, price: 120.0,
        time: DateTime.utc_now(), strategy_id: 1
      })

      {port, positions} = assert_processed(1)

      # Position should be fully closed
      aapl_positions = Enum.filter(positions, fn p -> p.symbol == "AAPL" end)
      assert aapl_positions == []

      # Cash: 10000 - 1000 (buy) + 1200 (sell) = 10200
      assert_in_delta port.cash, 10200.0, 0.01
    end

    test "Partial sell reduces position quantity" do
      # Setup: long 20 shares
      KnowledgeBase.assert(:order_receipt, %{
        symbol: "AAPL", action: :buy, quantity: 20, price: 100.0,
        time: DateTime.utc_now(), strategy_id: 1
      })
      Process.sleep(200)

      # Sell 10 of 20
      KnowledgeBase.assert(:order_receipt, %{
        symbol: "AAPL", action: :sell, quantity: 10, price: 110.0,
        time: DateTime.utc_now(), strategy_id: 1
      })

      {_port, positions} = assert_processed(1)

      pos = Enum.find(positions, fn p -> p.symbol == "AAPL" end)
      assert pos != nil
      assert pos.quantity == 10
    end
  end

  # ============================================================
  # Short
  # ============================================================

  describe "Short processing" do
    test "Short increases cash and creates negative position" do
      KnowledgeBase.assert(:order_receipt, %{
        symbol: "MSFT", action: :short, quantity: 10, price: 300.0,
        time: DateTime.utc_now(), strategy_id: 1
      })

      {port, positions} = assert_processed(1)

      # Cash increases from short proceeds
      assert_in_delta port.cash, 10000.0 + (10 * 300.0), 0.01

      pos = Enum.find(positions, fn p -> p.symbol == "MSFT" end)
      assert pos != nil
      assert pos.quantity == -10
      assert_in_delta pos.avg_price, 300.0, 0.01
    end
  end

  # ============================================================
  # Cover
  # ============================================================

  describe "Cover processing" do
    test "Cover decreases cash and closes short position" do
      # Setup: short first
      KnowledgeBase.assert(:order_receipt, %{
        symbol: "MSFT", action: :short, quantity: 10, price: 300.0,
        time: DateTime.utc_now(), strategy_id: 1
      })
      Process.sleep(200)

      # Cover at a profit (bought back lower)
      KnowledgeBase.assert(:order_receipt, %{
        symbol: "MSFT", action: :cover, quantity: 10, price: 280.0,
        time: DateTime.utc_now(), strategy_id: 1
      })

      {port, positions} = assert_processed(1)

      # Position should be gone
      msft_positions = Enum.filter(positions, fn p -> p.symbol == "MSFT" end)
      assert msft_positions == []

      # Cash: 10000 + 3000 (short proceeds) - 2800 (cover cost) = 10200
      assert_in_delta port.cash, 10200.0, 0.01
    end

    test "Cover is ignored when no short position exists" do
      # Try to cover without an existing short
      KnowledgeBase.assert(:order_receipt, %{
        symbol: "GOOG", action: :cover, quantity: 5, price: 100.0,
        time: DateTime.utc_now(), strategy_id: 1
      })

      {port, _positions} = assert_processed(1)

      # Cash should be unchanged
      assert_in_delta port.cash, 10000.0, 0.01
    end
  end

  # ============================================================
  # Edge Cases
  # ============================================================

  describe "edge cases" do
    test "order receipt is retracted after processing" do
      KnowledgeBase.assert(:order_receipt, %{
        symbol: "AAPL", action: :buy, quantity: 1, price: 100.0,
        time: DateTime.utc_now(), strategy_id: 1
      })

      Process.sleep(300)
      receipts = KnowledgeBase.get_by(:order_receipt)
      assert receipts == [], "Order receipt should be retracted after processing"
    end

    test "multiple strategies have independent portfolios" do
      KnowledgeBase.assert(:portfolio_state, %{cash: 5000.0, strategy_id: 2})

      KnowledgeBase.assert(:order_receipt, %{
        symbol: "AAPL", action: :buy, quantity: 10, price: 100.0,
        time: DateTime.utc_now(), strategy_id: 1
      })

      Process.sleep(300)

      port1 = KnowledgeBase.get_by(:portfolio_state, %{strategy_id: 1}) |> List.first()
      port2 = KnowledgeBase.get_by(:portfolio_state, %{strategy_id: 2}) |> List.first()

      assert_in_delta port1.cash, 9000.0, 0.01
      assert_in_delta port2.cash, 5000.0, 0.01, "Strategy 2's cash should be untouched"
    end
  end
end
