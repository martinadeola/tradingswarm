defmodule TradingSwarm.Agents.ScannerAgent do
  use GenServer
  alias TradingSwarm.KnowledgeBase
  require Logger

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(_args) do
    KnowledgeBase.subscribe(:market_data)
    {:ok, %{history: %{}, in_play_cache: %{}}}
  end

  @impl true
  def handle_info({:fact_asserted, :market_data, md}, state) do
    sym = md.symbol
    p = md.price
    
    # Fast path: if already in play, do nothing
    if Map.has_key?(state.in_play_cache, sym) do
      {:noreply, state}
    else
      # Update history (keep last 20 prices)
      history = Map.update(state.history, sym, [p], fn list -> [p | Enum.take(list, 19)] end)
      prices = Map.get(history, sym)
      
      new_in_play_cache =
        if length(prices) == 20 do
          min_p = Enum.min(prices)
          max_p = Enum.max(prices)
          ratio = max_p / min_p
          
          # Debug log for a specific symbol to see what ratios we are getting
          if sym == "AAPL" and :rand.uniform(1000) == 1 do
             Logger.info("[Scanner Debug] AAPL max/min ratio: #{ratio}")
          end
          
          # Lowered to 0.1% for testing
          if ratio > 1.001 do
            KnowledgeBase.assert(:in_play, %{symbol: sym})
            # Logger.info("[Scanner] 🚨 ALERT: #{sym} is IN PLAY! (Ratio: #{ratio})")
            Map.put(state.in_play_cache, sym, true)
          else
            state.in_play_cache
          end
        else
          state.in_play_cache
        end
      
      {:noreply, %{state | history: history, in_play_cache: new_in_play_cache}}
    end
  end
end
