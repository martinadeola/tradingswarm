import Config

config :trading_swarm, :universe, [
  "AAPL", "MSFT",   
  "JPM",  "GS",    
  "XOM",  "CVX",   
  "AMZN", "WMT",  
  "JNJ",  "UNH",  
  "CAT",  "DE"      
]

config :trading_swarm, :pairs, [
  {"AAPL", "MSFT"},
  {"JPM",  "GS"},
  {"XOM",  "CVX"},
  {"AMZN", "WMT"},
  {"JNJ",  "UNH"},
  {"CAT",  "DE"}
]

config :trading_swarm, :dets_path, "data/kb.dets"
