;; market-recorder config for the compose stack: records the three simulators
;; and uploads closed minute files to MinIO through rclone (remote `minio`,
;; configured from RCLONE_CONFIG_MINIO_* in docker-compose.yml).
((data_dir /var/lib/market-recorder)
 (http_port 9100)
 (venues
  (((venue Hyperliquid)
    (symbols (BTC ETH))
    (streams (Trades Bbo L2))
    (config (Custom (base_url http://hl-sim:3000))))
   ((venue Binance)
    (symbols (BTCUSDT ETHUSDT))
    (streams (Trades Bbo L2 Funding))
    (config (Custom (base_url http://binance-sim:3300))))
   ((venue Bybit)
    (symbols (BTCUSDT ETHUSDT))
    (streams (Trades Bbo L2 Funding))
    (config (Custom (base_url http://bybit-sim:3400))))))
 (upload
  ((command (rclone copyto {file} minio:market-data/{rel}))
   (delete_after_upload false))))
