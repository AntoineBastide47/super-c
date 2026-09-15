# Build matrix report

build f5f587a17ef8, 14 cores, 5 reps per case, 1-minute load 10.35 at start, dev profile unless noted; global object cache and ccache off throughout.

| case | workers | runs | transpile ms med / p95 | compile ms med / p95 | link ms med / p95 | total ms med / p95 | units stale | cc span ms | cc overlap ms | lto |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| body | 1 | 5 | 615.7 / 623.5 | 733.5 / 745.2 | 71.1 / 72.9 | 1452.5 / 1460.5 | 1/151 | 797.7 | 35.1 | flags |
| body | 14 | 5 | 324.5 / 375.1 | 760.9 / 832.4 | 73.4 / 78.5 | 1184.1 / 1316.6 | 1/151 | 824.3 | 33.2 | flags |
| clean | 1 | 5 | 631.1 / 646.2 | 56359.9 / 57321.6 | 71.2 / 76.9 | 57105.7 / 58063.2 | 151/151 | 56720.5 | 332.3 | flags |
| clean | 14 | 5 | 384.0 / 406.1 | 8259.6 / 8455.4 | 72.4 / 77.1 | 8748.4 / 8961.8 | 151/151 | 8524.6 | 238.7 | flags |
| layout | 1 | 5 | 591.7 / 618.5 | 50753.8 / 51869.4 | 72.3 / 73.7 | 51447.0 / 52596.6 | 92/151 | 50827.3 | 50.0 | flags |
| layout | 14 | 5 | 356.4 / 384.4 | 7659.7 / 8124.6 | 73.1 / 76.1 | 8147.8 / 8593.3 | 91/151 | 7803.1 | 107.3 | flags |
| release_nocache | 1 | 5 | 622.7 / 649.6 | 138.0 / 147.5 | 2825.8 / 3001.7 | 3623.0 / 3775.3 | 1/151 | 205.7 | 36.3 | thin |
| release_nocache | 14 | 5 | 309.7 / 317.4 | 149.8 / 159.0 | 2853.1 / 2982.1 | 3335.4 / 3476.9 | 1/151 | 206.8 | 32.5 | thin |
| release_relink | 1 | 5 | 611.0 / 650.5 | 166.3 / 172.5 | 18231.6 / 18509.1 | 19080.1 / 19309.0 | 1/151 | 233.0 | 35.3 | auto |
| release_relink | 14 | 5 | 303.5 / 312.7 | 170.0 / 174.0 | 18315.4 / 18592.5 | 18816.5 / 19085.2 | 1/151 | 230.5 | 33.5 | auto |
| release_thin | 1 | 5 | 621.4 / 628.4 | 139.8 / 144.6 | 138.2 / 1253.8 | 933.7 / 2044.5 | 1/151 | 204.1 | 35.4 | thin+cache |
| release_thin | 14 | 5 | 315.9 / 323.4 | 142.1 / 149.4 | 138.8 / 140.4 | 624.8 / 638.4 | 1/151 | 198.0 | 32.1 | thin+cache |
| signature | 1 | 5 | 625.3 / 782.4 | 33463.0 / 34739.1 | 71.7 / 73.2 | 34194.0 / 35622.5 | 40/151 | 33543.1 | 51.3 | flags |
| signature | 14 | 5 | 371.5 / 386.2 | 3785.2 / 3879.1 | 73.6 / 74.1 | 4272.2 / 4371.4 | 39/151 | 3939.2 | 112.8 | flags |
| tucache_off | 14 | 5 | 288.5 / 310.1 | 763.7 / 823.9 | 71.9 / 73.4 | 1172.7 / 1209.9 | 1/151 | 819.8 | 32.0 | flags |
| tucache_on | 14 | 5 | 314.5 / 320.9 | 766.6 / 781.1 | 72.9 / 74.8 | 1178.5 / 1192.6 | 1/151 | 823.2 | 33.2 | flags |
| unchanged | 1 | 5 | 2.6 / 2.9 | 21.3 / 23.5 | 0.2 / 0.2 | 24.1 / 26.7 | 0/151 | 0.0 | 0.0 | flags |
| unchanged | 14 | 5 | 2.6 / 3.0 | 20.3 / 23.2 | 0.2 / 0.4 | 23.1 / 26.4 | 0/151 | 0.0 | 0.0 | flags |

## Memory (one tracked run each, every core)

| case | boundary | peak RSS MiB | alloc calls | requested MiB | live MiB | survivors from earlier phases |
|---|---|---:|---:|---:|---:|---|
| body_j14 | frontend | 90.0 | 44588 | 135.5 | 96.9 | - |
| body_j14 | borrowck | 194.0 | 202121 | 336.4 | 141.3 | frontend 2776/96.8 MiB |
| body_j14 | plan | 220.7 | 556605 | 446.6 | 148.6 | frontend 2732/96.8 MiB, borrowck 42619/44.5 MiB |
| body_j14 | publish | 289.1 | 820230 | 808.1 | 127.2 | frontend 2732/96.8 MiB, borrowck 6058/7.8 MiB, plan 77/0.3 MiB |
| body_j14 | build | 289.1 | 827005 | 846.1 | 0.0 | frontend 2/0.0 MiB, borrowck 0/0.0 MiB, plan 0/0.0 MiB, publish 0/0.0 MiB |
| clean_j14 | frontend | 90.8 | 44520 | 135.4 | 96.9 | - |
| clean_j14 | borrowck | 196.3 | 203702 | 337.4 | 141.3 | frontend 2776/96.8 MiB |
| clean_j14 | plan | 221.9 | 558225 | 447.6 | 148.6 | frontend 2732/96.8 MiB, borrowck 42619/44.5 MiB |
| clean_j14 | publish | 280.3 | 806251 | 770.3 | 127.4 | frontend 2732/96.8 MiB, borrowck 6058/7.8 MiB, plan 77/0.3 MiB |
| clean_j14 | build | 280.3 | 816378 | 808.5 | 0.0 | frontend 2/0.0 MiB, borrowck 0/0.0 MiB, plan 0/0.0 MiB, publish 0/0.0 MiB |
| unchanged_j14 | frontend | 2.3 | 864 | 0.1 | 0.0 | - |
| unchanged_j14 | borrowck | 2.3 | 864 | 0.1 | 0.0 | frontend 14/0.0 MiB |
| unchanged_j14 | plan | 2.3 | 864 | 0.1 | 0.0 | frontend 14/0.0 MiB, borrowck 0/0.0 MiB |
| unchanged_j14 | publish | 2.3 | 864 | 0.1 | 0.0 | frontend 14/0.0 MiB, borrowck 0/0.0 MiB, plan 0/0.0 MiB |
| unchanged_j14 | build | 3.3 | 23690 | 3.8 | 0.0 | frontend 2/0.0 MiB, borrowck 0/0.0 MiB, plan 0/0.0 MiB, publish 0/0.0 MiB |
