;; market-recorder config for the `testnet` profile (`make up-testnet`): records
;; the anchored hl-sim of the box. No upload: the files stay on the
;; testnet-recorder-data volume (`docker compose cp` them out).
((data_dir /var/lib/market-recorder)
 (http_port 9100)
 (venues
  (((venue Hyperliquid)
    (symbols (BTC ETH SOL))
    (streams (Trades Bbo L2))
    (config (Custom (base_url http://testnet-sim:3000)))))))
